#if os(macOS)
import Foundation

/// Measures the real send boundary separately from the scheduler's ideal link
/// deadlines. A delayed dispatch callback can release several overdue packets.
struct StartupVideoDatagramReleaseMeasurements {
    struct Batch {
        private(set) var datagrams = 0
        private(set) var bytes = 0
        private(set) var maximumLatenessNanoseconds: UInt64 = 0

        mutating func recordAttempt(byteCount: Int, deliveryDeadline: UInt64, at now: UInt64) {
            guard (0...65_535).contains(byteCount) else { return }
            datagrams += 1
            bytes += byteCount
            let lateness = now >= deliveryDeadline ? now - deliveryDeadline : 0
            maximumLatenessNanoseconds = max(maximumLatenessNanoseconds, lateness)
        }
    }

    private(set) var maximumDeliveryLatenessNanoseconds: UInt64 = 0
    private(set) var maximumReleaseBatchDatagrams = 0
    private(set) var maximumReleaseBatchBytes = 0

    mutating func record(_ batch: Batch) {
        maximumDeliveryLatenessNanoseconds = max(
            maximumDeliveryLatenessNanoseconds, batch.maximumLatenessNanoseconds
        )
        maximumReleaseBatchDatagrams = max(maximumReleaseBatchDatagrams, batch.datagrams)
        maximumReleaseBatchBytes = max(maximumReleaseBatchBytes, batch.bytes)
    }
}

/// Test-only, clock-driven UDP link model. Rate limits count UDP payload bits,
/// not IP/link overhead, and apply independently in each direction.
struct StartupVideoDatagramScheduler {
    enum Direction: Int, Sendable {
        case host = 0
        case viewer = 1

        var opposite: Direction { self == .host ? .viewer : .host }
    }

    enum Failure: Error {
        case invalidConfiguration
        case invalidClock
        case stopped
    }

    struct Counters: Sendable {
        var configuredBitsPerSecond: UInt64?
        var pendingDatagrams = 0
        var pendingBytes = 0
        var maximumPendingBytes = 0
        var overflowDatagrams: UInt64 = 0
        var expiredDatagrams: UInt64 = 0
        var discardedDatagrams: UInt64 = 0
        var backpressureDatagrams: UInt64 = 0
        var serializationDelayNanoseconds: UInt64 = 0
        var maximumSerializationDelayNanoseconds: UInt64 = 0

        var droppedDatagrams: UInt64 {
            overflowDatagrams + expiredDatagrams + discardedDatagrams
        }
    }

    struct Datagram {
        let sequence: UInt64
        let from: Direction
        let bytes: Data
        let receivedAt: UInt64
        let deliveryDeadline: UInt64
    }

    private struct Pending {
        let sequence: UInt64
        let bytes: Data
        let receivedAt: UInt64
        let expiresAt: UInt64
        var remainingBitNanoseconds: UInt64
        var serializedAt: UInt64?
    }

    private struct Link {
        var pending: [Pending] = []
        var counters: Counters
    }

    private let delayNanoseconds: UInt64
    private let maximumQueuedBytes: Int
    private let maximumQueuedDatagrams: Int
    private let maximumQueueAgeNanoseconds: UInt64
    private var links: [Link]
    private var clock: UInt64?
    private var nextSequence: UInt64 = 0
    private(set) var generation: UInt64 = 0
    private(set) var maximumPendingBytes = 0
    private(set) var stopped = false

    init(
        oneWayDelayNanoseconds: UInt64,
        hostToViewerBitsPerSecond: UInt64? = nil,
        viewerToHostBitsPerSecond: UInt64? = nil,
        maximumQueuedBytes: Int = 4 * 1_024 * 1_024,
        maximumQueuedDatagrams: Int = 4_096,
        maximumQueueAgeNanoseconds: UInt64 = 2_000_000_000
    ) throws {
        guard oneWayDelayNanoseconds <= 500_000_000,
              (1...(4 * 1_024 * 1_024)).contains(maximumQueuedBytes),
              (1...4_096).contains(maximumQueuedDatagrams),
              (1...10_000_000_000).contains(maximumQueueAgeNanoseconds),
              Self.validRate(hostToViewerBitsPerSecond),
              Self.validRate(viewerToHostBitsPerSecond) else {
            throw Failure.invalidConfiguration
        }
        delayNanoseconds = oneWayDelayNanoseconds
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedDatagrams = maximumQueuedDatagrams
        self.maximumQueueAgeNanoseconds = maximumQueueAgeNanoseconds
        links = [
            Link(counters: Counters(configuredBitsPerSecond: hostToViewerBitsPerSecond)),
            Link(counters: Counters(configuredBitsPerSecond: viewerToHostBitsPerSecond)),
        ]
    }

    var pendingDatagrams: Int { links.reduce(0) { $0 + $1.counters.pendingDatagrams } }
    var pendingBytes: Int { links.reduce(0) { $0 + $1.counters.pendingBytes } }

    func counters(from direction: Direction) -> Counters { links[direction.rawValue].counters }

    /// The next serialization, expiry, or delivery event; never a polling timer.
    var nextDeadline: UInt64? {
        guard !stopped, let clock else { return nil }
        var deadline: UInt64?
        for link in links {
            var foundSerializerHead = false
            for packet in link.pending {
                deadline = min(deadline ?? packet.expiresAt, packet.expiresAt)
                if let serializedAt = packet.serializedAt {
                    let delivery = Self.add(serializedAt, delayNanoseconds)
                    deadline = min(deadline ?? delivery, delivery)
                } else if !foundSerializerHead {
                    foundSerializerHead = true
                    let duration = Self.serializationDuration(
                        packet.remainingBitNanoseconds,
                        at: link.counters.configuredBitsPerSecond
                    )
                    let completion = Self.add(clock, duration)
                    deadline = min(deadline ?? completion, completion)
                }
            }
        }
        return deadline
    }

    @discardableResult
    mutating func enqueue(_ bytes: Data, from direction: Direction, at now: UInt64) -> Bool {
        guard !stopped, advance(to: now) else { return false }
        let index = direction.rawValue
        guard bytes.count <= 65_535,
              pendingDatagrams < maximumQueuedDatagrams,
              bytes.count <= maximumQueuedBytes - pendingBytes,
              now <= UInt64.max - maximumQueueAgeNanoseconds else {
            links[index].counters.overflowDatagrams += 1
            return false
        }
        let packet = Pending(
            sequence: nextSequence,
            bytes: bytes,
            receivedAt: now,
            expiresAt: now + maximumQueueAgeNanoseconds,
            remainingBitNanoseconds: UInt64(bytes.count) * 8 * 1_000_000_000
        )
        nextSequence += 1
        links[index].pending.append(packet)
        links[index].counters.pendingDatagrams += 1
        links[index].counters.pendingBytes += bytes.count
        links[index].counters.maximumPendingBytes = max(
            links[index].counters.maximumPendingBytes, links[index].counters.pendingBytes
        )
        maximumPendingBytes = max(maximumPendingBytes, pendingBytes)
        // Unlimited links complete now; zero-length datagrams still obey FIFO.
        advanceLink(index, from: now, to: now)
        return true
    }

    /// Preserves work already serialized at the old rate. Capacity changes do not
    /// retroactively speed up queued packets or restart an in-progress packet.
    mutating func setBandwidth(_ bitsPerSecond: UInt64?, from direction: Direction, at now: UInt64) throws {
        guard !stopped else { throw Failure.stopped }
        guard Self.validRate(bitsPerSecond) else { throw Failure.invalidConfiguration }
        guard advance(to: now) else { throw Failure.invalidClock }
        links[direction.rawValue].counters.configuredBitsPerSecond = bitsPerSecond
        advanceLink(direction.rawValue, from: now, to: now)
    }

    /// A queued timer callback carries the generation captured when scheduled.
    /// After blackout/stop it cannot release newly admitted packets either.
    mutating func takeDue(at now: UInt64, generation expectedGeneration: UInt64) -> [Datagram] {
        guard !stopped, expectedGeneration == generation, advance(to: now) else { return [] }
        var result: [Datagram] = []
        for direction in [Direction.host, .viewer] {
            let index = direction.rawValue
            var retained: [Pending] = []
            for packet in links[index].pending {
                if let serializedAt = packet.serializedAt,
                   Self.add(serializedAt, delayNanoseconds) <= now {
                    result.append(Datagram(
                        sequence: packet.sequence,
                        from: direction,
                        bytes: packet.bytes,
                        receivedAt: packet.receivedAt,
                        deliveryDeadline: Self.add(serializedAt, delayNanoseconds)
                    ))
                    removeAccounting(packet, from: index)
                } else {
                    retained.append(packet)
                }
            }
            links[index].pending = retained
        }
        return result.sorted {
            $0.deliveryDeadline == $1.deliveryDeadline
                ? $0.sequence < $1.sequence : $0.deliveryDeadline < $1.deliveryDeadline
        }
    }

    mutating func recordBackpressure(from direction: Direction) {
        links[direction.rawValue].counters.backpressureDatagrams += 1
    }

    mutating func discardPending(stop: Bool = false) {
        generation += 1
        stopped = stopped || stop
        for index in links.indices {
            links[index].counters.discardedDatagrams += UInt64(links[index].pending.count)
            links[index].pending.removeAll(keepingCapacity: false)
            links[index].counters.pendingDatagrams = 0
            links[index].counters.pendingBytes = 0
        }
    }

    private mutating func advance(to now: UInt64) -> Bool {
        let previous = clock ?? now
        guard now >= previous else { return false }
        for index in links.indices { advanceLink(index, from: previous, to: now) }
        clock = now
        return true
    }

    private mutating func advanceLink(_ index: Int, from previous: UInt64, to now: UInt64) {
        var cursor = previous
        var serializerBlocked = false
        let rate = links[index].counters.configuredBitsPerSecond
        var retained: [Pending] = []
        for var packet in links[index].pending {
            if packet.serializedAt == nil && !serializerBlocked {
                cursor = max(cursor, packet.receivedAt)
                let duration = Self.serializationDuration(packet.remainingBitNanoseconds, at: rate)
                let completion = Self.add(cursor, duration)
                if packet.expiresAt <= completion && packet.expiresAt <= now {
                    cursor = max(cursor, packet.expiresAt)
                    links[index].counters.expiredDatagrams += 1
                    removeAccounting(packet, from: index)
                    continue
                }
                if completion <= now {
                    packet.remainingBitNanoseconds = 0
                    packet.serializedAt = completion
                    cursor = completion
                    let delay = completion - packet.receivedAt
                    links[index].counters.serializationDelayNanoseconds += delay
                    links[index].counters.maximumSerializationDelayNanoseconds = max(
                        links[index].counters.maximumSerializationDelayNanoseconds, delay
                    )
                } else {
                    if let rate, cursor < now {
                        // completion > now bounds this product below remaining work.
                        packet.remainingBitNanoseconds -= (now - cursor) * rate
                    }
                    cursor = now
                    serializerBlocked = true
                }
            }
            if packet.expiresAt <= now {
                links[index].counters.expiredDatagrams += 1
                removeAccounting(packet, from: index)
            } else {
                retained.append(packet)
            }
        }
        links[index].pending = retained
    }

    private mutating func removeAccounting(_ packet: Pending, from index: Int) {
        links[index].counters.pendingDatagrams -= 1
        links[index].counters.pendingBytes -= packet.bytes.count
    }

    private static func validRate(_ value: UInt64?) -> Bool {
        value.map { (1...1_000_000_000).contains($0) } ?? true
    }

    private static func serializationDuration(_ work: UInt64, at rate: UInt64?) -> UInt64 {
        guard let rate else { return 0 }
        return work / rate + (work % rate == 0 ? 0 : 1)
    }

    private static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? UInt64.max : value
    }
}
#endif
