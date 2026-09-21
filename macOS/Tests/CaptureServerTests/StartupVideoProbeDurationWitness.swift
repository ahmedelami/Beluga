#if os(macOS)
import Foundation

/// Verifies the first native requests' byte budgets, not transmitted probe duration or delivery.
enum StartupVideoProbeDurationWitness {
    static func evaluate(
        snapshot: StartupVideoNativeEstimatorSnapshot,
        hostWorkerID: UInt64,
        captureStartedAtUptimeNanoseconds: UInt64,
        expectedMilliseconds: Int
    ) -> StartupVideoProbeDurationWitnessSummary {
        typealias Failure = StartupVideoProbeDurationWitnessSummary.Failure
        var failures: [Failure] = []
        let expectedBytes: [UInt64]?
        switch expectedMilliseconds {
        case 15: expectedBytes = [1_688, 1_697]
        case 40: expectedBytes = [4_500, 4_525]
        default:
            expectedBytes = nil
            failures.append(.unsupportedDuration)
        }
        let estimator = snapshot.evaluate(hostWorkerID: hostWorkerID,
            captureStartedAtUptimeNanoseconds: captureStartedAtUptimeNanoseconds)
        if !estimator.isVerified { failures.append(.invalidEstimatorEvidence) }

        // The first requests precede capture. Do not filter by capture time, validity,
        // expected ID or matching bytes and accidentally borrow a later request.
        let initial = Array(snapshot.events.prefix(StartupVideoNativeEstimatorSnapshot.maximumEvents)
            .lazy.filter { $0.kind == .probeCreated }.prefix(2))
        let ids = initial.compactMap(\.probeClusterID)
        let rates = initial.compactMap(\.bitrateBps)
        let bytes = initial.compactMap(\.minimumBytes)
        let probes = initial.compactMap(\.minimumProbes)
        if initial.count != 2 { failures.append(.missingInitialRequests) }
        if ids != [1, 2] { failures.append(.unexpectedInitialIDs) }
        if rates != [900_000, 905_041] { failures.append(.unexpectedInitialBitrates) }
        if probes != [5, 5] { failures.append(.unexpectedInitialMinimumProbes) }
        if let expectedBytes, bytes != expectedBytes { failures.append(.unexpectedInitialMinimumBytes) }
        return StartupVideoProbeDurationWitnessSummary(
            isVerified: failures.isEmpty, failures: failures, expectedMilliseconds: expectedMilliseconds,
            initialProbeClusterIDs: ids, initialProbeBitratesBps: rates,
            initialProbeMinimumBytes: bytes, initialProbeMinimumProbes: probes)
    }
}

struct StartupVideoProbeDurationWitnessSummary: Codable, Equatable, Sendable {
    enum Failure: String, Codable, Sendable {
        case unsupportedDuration, invalidEstimatorEvidence, missingInitialRequests
        case unexpectedInitialIDs, unexpectedInitialBitrates
        case unexpectedInitialMinimumProbes, unexpectedInitialMinimumBytes
    }

    let isVerified: Bool
    let failures: [Failure]
    let expectedMilliseconds: Int
    let initialProbeClusterIDs: [Int]
    let initialProbeBitratesBps: [Int64]
    let initialProbeMinimumBytes: [UInt64]
    let initialProbeMinimumProbes: [UInt64]
}
#endif
