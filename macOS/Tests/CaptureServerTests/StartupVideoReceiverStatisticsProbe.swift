#if os(macOS)
import Foundation
import WebRTCTransport

struct StartupVideoReceiverStatisticsRecord: Codable, Equatable, Sendable {
    let requestedUptimeNanoseconds: UInt64
    let completedUptimeNanoseconds: UInt64
    let collectionSequence: UInt64?
    // The whole-peer snapshot API does not expose the native report timestamp.
    // Never substitute its wall-clock collectedAt for that missing identity.
    let nativeReportTimestampMicroseconds: Double?
    let inboundVideo: WebRTCVideoStatistics
}

struct StartupVideoReceiverStatisticsBatch: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let capacity: Int
    let requestCount: UInt64
    let startedCount: UInt64
    let completedCount: UInt64
    let skippedBusyCount: UInt64
    let skippedRetiredCount: UInt64
    let omittedVideoCount: UInt64
    let saturatedCount: UInt64
    let malformedClockCount: UInt64
    let regressingClockCount: UInt64
    let retiredCompletionCount: UInt64
    let records: [StartupVideoReceiverStatisticsRecord]
}

/// Numeric test diagnostics only. Call request from existing ordinary sampling ticks;
/// the injected collection must already have its own bounded native callback deadline.
final class StartupVideoReceiverStatisticsProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let collect: @Sendable () async -> WebRTCStatisticsSnapshot
    private let now: @Sendable () -> UInt64
    private let capacity: Int
    private var currentTask: Task<Void, Never>?
    private var retired = false
    private var lastClock: UInt64 = 0
    private var records: [StartupVideoReceiverStatisticsRecord] = []
    private var requestCount: UInt64 = 0
    private var startedCount: UInt64 = 0
    private var completedCount: UInt64 = 0
    private var skippedBusyCount: UInt64 = 0
    private var skippedRetiredCount: UInt64 = 0
    private var omittedVideoCount: UInt64 = 0
    private var saturatedCount: UInt64 = 0
    private var malformedClockCount: UInt64 = 0
    private var regressingClockCount: UInt64 = 0
    private var retiredCompletionCount: UInt64 = 0

    init(
        collect: @escaping @Sendable () async -> WebRTCStatisticsSnapshot,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        capacity: Int = 128
    ) {
        precondition((0...128).contains(capacity))
        self.collect = collect
        self.now = now
        self.capacity = capacity
        records.reserveCapacity(capacity)
    }

    /// Never waits for collection. Busy and full ledgers do not launch another request.
    func request() {
        lock.withLock {
            Self.increment(&requestCount)
            guard !retired else {
                Self.increment(&skippedRetiredCount)
                return
            }
            guard currentTask == nil else {
                Self.increment(&skippedBusyCount)
                return
            }
            guard records.count < capacity else {
                Self.increment(&saturatedCount)
                return
            }
            let requestedAt = now()
            guard acceptClock(requestedAt) else { return }
            Self.increment(&startedCount)
            // Publish the handle while holding the same lock used by completion/retirement.
            currentTask = Task { [self] in
                let snapshot = await collect()
                complete(snapshot, requestedAt: requestedAt)
            }
        }
    }

    /// Retirement precedes cancellation. A collector that ignores cancellation may finish
    /// its existing bounded request, but can no longer append evidence.
    func finish() async {
        let task = lock.withLock {
            retired = true
            return currentTask
        }
        task?.cancel()
        await task?.value
    }

    /// The separate final sample must not overlap a retiring diagnostic request.
    func finishAndCollectFinalSnapshot() async -> WebRTCStatisticsSnapshot {
        await finish()
        return await collect()
    }

    func snapshot() -> StartupVideoReceiverStatisticsBatch {
        lock.withLock {
            StartupVideoReceiverStatisticsBatch(
                schemaVersion: 1, capacity: capacity,
                requestCount: requestCount, startedCount: startedCount,
                completedCount: completedCount, skippedBusyCount: skippedBusyCount,
                skippedRetiredCount: skippedRetiredCount, omittedVideoCount: omittedVideoCount,
                saturatedCount: saturatedCount, malformedClockCount: malformedClockCount,
                regressingClockCount: regressingClockCount,
                retiredCompletionCount: retiredCompletionCount, records: records
            )
        }
    }

    private func complete(_ snapshot: WebRTCStatisticsSnapshot, requestedAt: UInt64) {
        lock.withLock {
            currentTask = nil
            Self.increment(&completedCount)
            guard !retired else {
                Self.increment(&retiredCompletionCount)
                return
            }
            let completedAt = now()
            guard acceptClock(completedAt) else { return }
            guard let video = snapshot.inboundVideo else {
                Self.increment(&omittedVideoCount)
                return
            }
            records.append(StartupVideoReceiverStatisticsRecord(
                requestedUptimeNanoseconds: requestedAt,
                completedUptimeNanoseconds: completedAt,
                collectionSequence: snapshot.collectionSequence,
                nativeReportTimestampMicroseconds: nil,
                inboundVideo: video
            ))
        }
    }

    // Called only under lock. Equal clock readings are not regressions.
    private func acceptClock(_ value: UInt64) -> Bool {
        guard value != 0 else {
            Self.increment(&malformedClockCount)
            return false
        }
        guard value >= lastClock else {
            Self.increment(&regressingClockCount)
            return false
        }
        lastClock = value
        return true
    }

    private static func increment(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
#endif
