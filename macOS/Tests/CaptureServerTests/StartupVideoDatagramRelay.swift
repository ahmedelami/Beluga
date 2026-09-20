#if os(macOS)
import Darwin
import Dispatch
import Foundation
import RemoteSessionCore
@testable import WebRTCTransport

/// A per-fixture UDP path. Only numeric endpoints emitted by the two fixture peers
/// are admitted; the two public sockets are bound to loopback and ephemeral ports.
/// Unlimited serialization retains fixed-delay behavior, except that the configured
/// queue-age bound now also drops packets held by a stalled dispatch callback.
final class StartupVideoDatagramRelay: @unchecked Sendable {
    typealias Side = StartupVideoDatagramScheduler.Direction

    enum Failure: Error {
        case invalidConfiguration
        case invalidSessionDescription
        case unsupportedRenegotiation
        case stopped
        case socket(Int32)
    }

    struct DirectionCounters: Sendable {
        var receivedDatagrams: UInt64 = 0
        var receivedBytes: UInt64 = 0
        var forwardedDatagrams: UInt64 = 0
        var forwardedBytes: UInt64 = 0
        var droppedDatagrams: UInt64 = 0
        var configuredBitsPerSecond: UInt64?
        var pendingDatagrams = 0
        var pendingBytes = 0
        var maximumPendingBytes = 0
        var overflowDatagrams: UInt64 = 0
        var expiredDatagrams: UInt64 = 0
        var backpressureDatagrams: UInt64 = 0
        var serializationDelayNanoseconds: UInt64 = 0
        var maximumSerializationDelayNanoseconds: UInt64 = 0
        var maximumDeliveryLatenessNanoseconds: UInt64 = 0
        var maximumReleaseBatchDatagrams = 0
        var maximumReleaseBatchBytes = 0
    }

    struct Snapshot: Sendable {
        let hostToViewer: DirectionCounters
        let viewerToHost: DirectionCounters
        let mappedSideCount: Int
        let rejectedSourceDatagrams: UInt64
        let filteredCandidates: UInt64
        let rewrittenCandidates: UInt64
        let pendingDatagrams: Int
        let pendingBytes: Int
        let maximumPendingBytes: Int
        let maximumDeliveryLatenessNanoseconds: UInt64
        let maximumReleaseBatchDatagrams: Int
        let maximumReleaseBatchBytes: Int
        let errorCount: UInt64
        let stopped: Bool
    }

    private struct Endpoint {
        var address: sockaddr_in
        let fragment: String

        func matches(_ other: sockaddr_in) -> Bool {
            address.sin_addr.s_addr == other.sin_addr.s_addr
                && address.sin_port == other.sin_port
        }
    }

    private let queue = DispatchQueue(label: "Beluga.StartupVideoDatagramRelay")
    private let localAddresses: Set<UInt32>
    private let descriptors: [Int32]
    private let advertisedPorts: [UInt16]
    private var readSources: [DispatchSourceRead] = []
    private var timer: DispatchSourceTimer?
    private var endpoints: [Endpoint?] = [nil, nil]
    private var descriptionSeen = [false, false]
    private var counters = [DirectionCounters(), DirectionCounters()]
    private var scheduler: StartupVideoDatagramScheduler
    private var releaseMeasurements = StartupVideoDatagramReleaseMeasurements()
    private var directionalReleaseMeasurements = [
        StartupVideoDatagramReleaseMeasurements(), StartupVideoDatagramReleaseMeasurements(),
    ]
    private var rejectedSourceDatagrams: UInt64 = 0
    private var filteredCandidates: UInt64 = 0
    private var rewrittenCandidates: UInt64 = 0
    private var errorCount: UInt64 = 0
    private var dropAll: Bool
    private var stopped = false
    private var activeSources = 2
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        oneWayDelayMilliseconds: Int = 50,
        dropAll: Bool = false,
        hostToViewerBitsPerSecond: UInt64? = nil,
        viewerToHostBitsPerSecond: UInt64? = nil,
        maximumQueuedBytes: Int = 4 * 1_024 * 1_024,
        maximumQueueAgeMilliseconds: Int = 2_000
    ) throws {
        guard (0...500).contains(oneWayDelayMilliseconds),
              (1...10_000).contains(maximumQueueAgeMilliseconds) else {
            throw Failure.invalidConfiguration
        }
        scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: UInt64(oneWayDelayMilliseconds) * 1_000_000,
            hostToViewerBitsPerSecond: hostToViewerBitsPerSecond,
            viewerToHostBitsPerSecond: viewerToHostBitsPerSecond,
            maximumQueuedBytes: maximumQueuedBytes,
            maximumQueueAgeNanoseconds: UInt64(maximumQueueAgeMilliseconds) * 1_000_000
        )
        self.dropAll = dropAll
        localAddresses = try Self.localIPv4Addresses()
        let first = try Self.makeSocket()
        let second: (descriptor: Int32, port: UInt16)
        do {
            second = try Self.makeSocket()
        } catch {
            Darwin.close(first.descriptor)
            throw error
        }
        descriptors = [first.descriptor, second.descriptor]
        advertisedPorts = [first.port, second.port]

        for side in [Side.host, .viewer] {
            let descriptor = descriptors[side.rawValue]
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.receive(on: side) }
            source.setCancelHandler { [weak self] in
                Darwin.close(descriptor)
                guard let self else { return }
                self.activeSources -= 1
                if self.activeSources == 0 {
                    let waiters = self.stopWaiters
                    self.stopWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
            }
            readSources.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.forwardDueDatagrams(generation: 0) }
        timer.schedule(deadline: .distantFuture)
        self.timer = timer
        for source in readSources { source.resume() }
        timer.resume()
    }

    deinit {
        for source in readSources { source.cancel() }
        timer?.cancel()
    }

    /// Call for every signaling payload before passing it to the other peer.
    /// A nil result is a deliberately filtered candidate, never permission to
    /// forward the original payload.
    func rewrite(_ payload: RemoteSignalPayload, from side: Side) throws -> RemoteSignalPayload? {
        try queue.sync {
            guard !stopped else { throw Failure.stopped }
            switch payload {
            case .offer(let sdp):
                return .offer(sdp: try rewriteDescription(sdp, from: side))
            case .answer(let sdp):
                return .answer(sdp: try rewriteDescription(sdp, from: side))
            case .candidate(let candidate):
                return try rewriteCandidate(candidate, from: side).map(RemoteSignalPayload.candidate)
            case .iceRestartRequest:
                throw Failure.unsupportedRenegotiation
            default:
                return payload
            }
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            Snapshot(
                hostToViewer: directionCounters(from: .host),
                viewerToHost: directionCounters(from: .viewer),
                mappedSideCount: endpoints.compactMap { $0 }.count,
                rejectedSourceDatagrams: rejectedSourceDatagrams,
                filteredCandidates: filteredCandidates,
                rewrittenCandidates: rewrittenCandidates,
                pendingDatagrams: scheduler.pendingDatagrams,
                pendingBytes: scheduler.pendingBytes,
                maximumPendingBytes: scheduler.maximumPendingBytes,
                maximumDeliveryLatenessNanoseconds: releaseMeasurements.maximumDeliveryLatenessNanoseconds,
                maximumReleaseBatchDatagrams: releaseMeasurements.maximumReleaseBatchDatagrams,
                maximumReleaseBatchBytes: releaseMeasurements.maximumReleaseBatchBytes,
                errorCount: errorCount,
                stopped: stopped
            )
        }
    }

    /// Changes only this fixture's UDP payload serialization capacity. Both
    /// directions retain independent clocks; nil restores fixed-delay-only mode.
    func setBandwidth(bitsPerSecond: UInt64?, from side: Side) throws {
        try queue.sync {
            guard !stopped else { throw Failure.stopped }
            try scheduler.setBandwidth(bitsPerSecond, from: side, at: DispatchTime.now().uptimeNanoseconds)
            scheduleNext()
        }
    }

    /// Closing the gate also drops queued datagrams, so a blackout has an exact
    /// boundary. Native decoder/network buffers still need a separate drain.
    func setDropAll(_ value: Bool) {
        queue.sync {
            dropAll = value
            if value { discardPending() }
        }
    }

    /// Completes after both dispatch-source cancellation handlers close their
    /// exact owned descriptors. It never waits for ICE or a peer callback.
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.activeSources == 0 {
                    continuation.resume()
                    return
                }
                self.stopWaiters.append(continuation)
                guard !self.stopped else { return }
                self.stopped = true
                self.discardPending(stop: true)
                self.timer?.cancel()
                for source in self.readSources { source.cancel() }
            }
        }
    }

    private func rewriteDescription(_ sdp: String, from side: Side) throws -> String {
        guard !descriptionSeen[side.rawValue],
              let mapping = ICEUsernameFragmentParser.mapping(inSessionDescription: sdp),
              !mapping.declaredFragments.isEmpty else {
            throw Failure.invalidSessionDescription
        }
        let lines = sdp.split(whereSeparator: \.isNewline).map(String.init)
        let bundleGroups = lines.filter { $0.hasPrefix("a=group:BUNDLE ") }
        guard bundleGroups.count == 1 else { throw Failure.invalidSessionDescription }
        let bundledMIDs = Set(bundleGroups[0].split(separator: " ").dropFirst().map(String.init))
        guard mapping.mediaSections.allSatisfy({ section in
            section.mid.map { bundledMIDs.contains($0) } == true
        }) else { throw Failure.invalidSessionDescription }

        var mediaIndex: Int32 = -1
        var result: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("m=") {
                mediaIndex += 1
                var fields = line.split(separator: " ").map(String.init)
                guard fields.count >= 4 else { throw Failure.invalidSessionDescription }
                if fields[1] != "0" { fields[1] = "9" }
                result.append(fields.joined(separator: " "))
            } else if lower.hasPrefix("a=candidate:") {
                guard let section = mapping.mediaSections.first(where: { $0.mLineIndex == mediaIndex }),
                      let fragment = section.effectiveFragment else {
                    throw Failure.invalidSessionDescription
                }
                let candidate = RemoteICECandidate(
                    sdp: String(line.dropFirst(2)),
                    sdpMid: section.mid,
                    sdpMLineIndex: section.mLineIndex,
                    usernameFragment: fragment
                )
                if let rewritten = try rewriteCandidate(candidate, from: side) {
                    result.append("a=" + rewritten.sdp)
                }
            } else if lower.hasPrefix("a=end-of-candidates")
                || lower.hasPrefix("a=remote-candidates:") {
                continue
            } else if lower.hasPrefix("c=") {
                result.append("c=IN IP4 0.0.0.0")
            } else if lower.hasPrefix("a=rtcp:") {
                result.append("a=rtcp:9 IN IP4 0.0.0.0")
            } else {
                result.append(line)
            }
        }
        descriptionSeen[side.rawValue] = true
        return result.joined(separator: "\r\n") + "\r\n"
    }

    private func rewriteCandidate(_ candidate: RemoteICECandidate, from side: Side) throws -> RemoteICECandidate? {
        let fields = candidate.sdp.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 8,
              fields[0].lowercased().hasPrefix("candidate:"),
              fields[1] == "1", fields[2].lowercased() == "udp",
              fields[6].lowercased() == "typ", fields[7].lowercased() == "host",
              let port = UInt16(fields[5]), port > 0,
              let fragment = candidate.usernameFragment, !fragment.isEmpty,
              let address = Self.numericIPv4(fields[4]),
              localAddresses.contains(address.s_addr) else {
            filteredCandidates += 1
            return nil
        }
        var nativeAddress = sockaddr_in()
        nativeAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        nativeAddress.sin_family = sa_family_t(AF_INET)
        nativeAddress.sin_addr = address
        nativeAddress.sin_port = port.bigEndian
        if let existing = endpoints[side.rawValue] {
            guard existing.fragment == fragment else { throw Failure.unsupportedRenegotiation }
            guard existing.matches(nativeAddress) else {
                filteredCandidates += 1
                return nil
            }
        } else {
            endpoints[side.rawValue] = Endpoint(address: nativeAddress, fragment: fragment)
        }
        // Rebuild the bounded host form instead of retaining raddr/rport or an
        // unknown extension that could expose an unmediated endpoint.
        let rewritten = [
            fields[0], "1", "udp", fields[3], "127.0.0.1",
            String(advertisedPorts[side.rawValue]), "typ", "host", "ufrag", fragment,
        ].joined(separator: " ")
        rewrittenCandidates += 1
        return RemoteICECandidate(
            sdp: rewritten,
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            usernameFragment: fragment
        )
    }

    private func receive(on advertisedSide: Side) {
        guard !stopped else { return }
        forwardDueDatagrams(generation: scheduler.generation)
        defer { scheduleNext() }
        let from = advertisedSide.opposite
        let descriptor = descriptors[advertisedSide.rawValue]
        var buffer = [UInt8](repeating: 0, count: 65_535)
        for _ in 0..<128 {
            var sourceAddress = sockaddr_in()
            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sourceAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, $0, &addressLength)
                    }
                }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                errorCount += 1
                return
            }
            guard addressLength == socklen_t(MemoryLayout<sockaddr_in>.size),
                  sourceAddress.sin_family == sa_family_t(AF_INET),
                  let endpoint = endpoints[from.rawValue], endpoint.matches(sourceAddress) else {
                rejectedSourceDatagrams += 1
                continue
            }
            counters[from.rawValue].receivedDatagrams += 1
            counters[from.rawValue].receivedBytes += UInt64(count)
            guard !dropAll, endpoints[advertisedSide.rawValue] != nil else {
                counters[from.rawValue].droppedDatagrams += 1
                continue
            }
            scheduler.enqueue(Data(buffer.prefix(count)), from: from,
                              at: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func forwardDueDatagrams(generation: UInt64) {
        guard !stopped, !dropAll else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var batch = StartupVideoDatagramReleaseMeasurements.Batch()
        var directionalBatches = [
            StartupVideoDatagramReleaseMeasurements.Batch(), StartupVideoDatagramReleaseMeasurements.Batch(),
        ]
        for datagram in scheduler.takeDue(at: now, generation: generation) {
            let destination = datagram.from.opposite
            guard var address = endpoints[destination.rawValue]?.address else {
                counters[datagram.from.rawValue].droppedDatagrams += 1
                continue
            }
            // Emit from the socket advertised for the original sender. The
            // receiver therefore sees only the relay as its remote ICE endpoint.
            // Count attempts conservatively, including sendto backpressure. Each
            // timer/read-source flush is one batch; this never changes pacing.
            let sendTime = DispatchTime.now().uptimeNanoseconds
            batch.recordAttempt(byteCount: datagram.bytes.count,
                                deliveryDeadline: datagram.deliveryDeadline, at: sendTime)
            directionalBatches[datagram.from.rawValue].recordAttempt(
                byteCount: datagram.bytes.count, deliveryDeadline: datagram.deliveryDeadline, at: sendTime
            )
            let count = datagram.bytes.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.sendto(descriptors[datagram.from.rawValue], bytes.baseAddress,
                                      bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if count == datagram.bytes.count {
                counters[datagram.from.rawValue].forwardedDatagrams += 1
                counters[datagram.from.rawValue].forwardedBytes += UInt64(count)
            } else {
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    scheduler.recordBackpressure(from: datagram.from)
                }
                errorCount += 1
                counters[datagram.from.rawValue].droppedDatagrams += 1
            }
        }
        releaseMeasurements.record(batch)
        for index in directionalBatches.indices {
            directionalReleaseMeasurements[index].record(directionalBatches[index])
        }
        scheduleNext()
    }

    private func scheduleNext() {
        if let deadline = scheduler.nextDeadline {
            let generation = scheduler.generation
            timer?.setEventHandler { [weak self] in self?.forwardDueDatagrams(generation: generation) }
            timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline),
                            leeway: .microseconds(100))
        } else {
            timer?.schedule(deadline: .distantFuture)
        }
    }

    private func discardPending(stop: Bool = false) {
        scheduler.discardPending(stop: stop)
        timer?.schedule(deadline: .distantFuture)
    }

    private func directionCounters(from side: Side) -> DirectionCounters {
        var result = counters[side.rawValue]
        let scheduled = scheduler.counters(from: side)
        result.droppedDatagrams += scheduled.droppedDatagrams
        result.configuredBitsPerSecond = scheduled.configuredBitsPerSecond
        result.pendingDatagrams = scheduled.pendingDatagrams
        result.pendingBytes = scheduled.pendingBytes
        result.maximumPendingBytes = scheduled.maximumPendingBytes
        result.overflowDatagrams = scheduled.overflowDatagrams
        result.expiredDatagrams = scheduled.expiredDatagrams
        result.backpressureDatagrams = scheduled.backpressureDatagrams
        result.serializationDelayNanoseconds = scheduled.serializationDelayNanoseconds
        result.maximumSerializationDelayNanoseconds = scheduled.maximumSerializationDelayNanoseconds
        let release = directionalReleaseMeasurements[side.rawValue]
        result.maximumDeliveryLatenessNanoseconds = release.maximumDeliveryLatenessNanoseconds
        result.maximumReleaseBatchDatagrams = release.maximumReleaseBatchDatagrams
        result.maximumReleaseBatchBytes = release.maximumReleaseBatchBytes
        return result
    }

    private static func numericIPv4(_ value: String) -> in_addr? {
        var result = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &result) } == 1 ? result : nil
    }

    private static func localIPv4Addresses() throws -> Set<UInt32> {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw Failure.socket(errno) }
        defer { freeifaddrs(first) }
        var result = Set<UInt32>()
        var current = first
        while let item = current {
            if let address = item.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                result.insert(value.sin_addr.s_addr)
            }
            current = item.pointee.ifa_next
        }
        return result
    }

    private static func makeSocket() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        var keep = false
        defer { if !keep { Darwin.close(descriptor) } }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw Failure.socket(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = numericIPv4("127.0.0.1")!
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw Failure.socket(errno) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard queried == 0, address.sin_port != 0 else { throw Failure.socket(errno) }
        keep = true
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }
}
#endif
