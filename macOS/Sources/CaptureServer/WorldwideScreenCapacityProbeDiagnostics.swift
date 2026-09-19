import Foundation

/// One proposed evaluation, independent of whether the native sender accepts its limits.
struct WorldwideScreenCapacityProbeDiagnostics: Equatable, Sendable {
    enum Reason: String, Equatable, Sendable {
        case inactive, expired, rejectedReport, roundTripTime, routeChanged
        case missingPrimaryEvidence, immediateQueue, missingBandwidth, bandwidthCollapse
        case queueWithheld, growthVetoed, bandwidthNotAdvanced, atCeiling, increased
    }

    var reason: Reason = .rejectedReport
    let origin: WorldwideScreenVideoAdaptationTier?
    let collectionSequence: UInt64?
    let previousNativeReportMicroseconds: UInt64?
    let nativeReportMicroseconds: UInt64?
    let beforeTotalCapBps: Int
    var proposedTotalCapBps: Int
    var collapseThresholdBps: UInt64?
    var deltaPackets: UInt64?
    var deltaSendDelayMicroseconds: UInt64?
    var averageQueueMicroseconds: UInt64?

    init(
        origin: WorldwideScreenVideoAdaptationTier?,
        collectionSequence: UInt64?,
        previousNativeReportTimestamp: Double?,
        nativeReportTimestamp: Double?,
        beforeTotalCapBps: Int
    ) {
        self.origin = origin
        self.collectionSequence = collectionSequence
        previousNativeReportMicroseconds = Self.boundedInteger(previousNativeReportTimestamp)
        nativeReportMicroseconds = Self.boundedInteger(nativeReportTimestamp)
        self.beforeTotalCapBps = beforeTotalCapBps
        proposedTotalCapBps = beforeTotalCapBps
    }

    mutating func recordQueue(
        previousPackets: UInt64?, previousDelay: Double?,
        packets: UInt64?, delay: Double?
    ) {
        guard let previousPackets, let packets, packets >= previousPackets,
              let previousDelay, let delay,
              previousDelay.isFinite, previousDelay >= 0,
              delay.isFinite, delay >= previousDelay else { return }
        let count = packets - previousPackets
        deltaPackets = count
        deltaSendDelayMicroseconds = Self.boundedInteger((delay - previousDelay) * 1_000_000)
        if count > 0 {
            averageQueueMicroseconds = Self.boundedInteger(
                (delay - previousDelay) / Double(count) * 1_000_000
            )
        }
    }

    static func boundedInteger(_ value: Double?) -> UInt64? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return UInt64(exactly: value.rounded())
    }

    var logFields: String {
        "probeReason=\(reason.rawValue)"
            + " probeOriginBefore=\(origin.map { String(describing: $0) } ?? "none")"
            + " collectionSeq=\(collectionSequence.map(String.init) ?? "unknown")"
            + " previousNativeReportMicros=\(previousNativeReportMicroseconds.map(String.init) ?? "unknown")"
            + " nativeReportMicros=\(nativeReportMicroseconds.map(String.init) ?? "unknown")"
            + " beforeTotalCapBps=\(beforeTotalCapBps) proposedTotalCapBps=\(proposedTotalCapBps)"
            + " collapseThresholdBps=\(collapseThresholdBps.map(String.init) ?? "unknown")"
            + " fastDeltaPackets=\(deltaPackets.map(String.init) ?? "unknown")"
            + " fastDeltaSendDelayMicros=\(deltaSendDelayMicroseconds.map(String.init) ?? "unknown")"
            + " fastQueueMicros=\(averageQueueMicroseconds.map(String.init) ?? "unknown")"
    }
}
