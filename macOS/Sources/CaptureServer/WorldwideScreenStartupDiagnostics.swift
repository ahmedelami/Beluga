import Foundation
import WebRTCTransport

/// Observability only. These values must never grant adaptation permission or invalidate a route.
/// Route metadata cannot identify a selected pair; native pair continuity is tracked separately.
struct WorldwideScreenStartupDiagnostics {
    enum RouteDifference: String {
        case unavailable, firstBinding, unchanged, metadataEnrichment, metadataChanged
    }

    enum PairContinuity: String {
        case unavailable, rejectedReport, firstObserved, unchanged, changed
    }

    private var binding: Binding?
    private var lastSequence: UInt64?
    private var lastNativeTimestamp: UInt64?
    private var lastPairFingerprint: String?

    private struct Binding: Equatable {
        let peer: UInt64
        let show: UInt64
    }

    /// Compare only current, advancing native reports. No identity is emitted into logs, and a
    /// missing observation retains the last identity for a later comparison without proving health.
    mutating func observePair(
        peerGeneration: UInt64,
        showEpoch: UInt64,
        collectionSequence: UInt64?,
        nativeTimestamp: Double?,
        observation: WebRTCRoundTripTimeObservation?
    ) -> PairContinuity {
        let currentBinding = Binding(peer: peerGeneration, show: showEpoch)
        if binding != currentBinding {
            binding = currentBinding
            lastSequence = nil
            lastNativeTimestamp = nil
            lastPairFingerprint = nil
        }
        guard let collectionSequence,
              let timestamp = WorldwideScreenCapacityProbeDiagnostics.boundedInteger(nativeTimestamp),
              timestamp > 0 else { return .unavailable }
        guard lastSequence.map({ collectionSequence > $0 }) ?? true,
              lastNativeTimestamp.map({ timestamp > $0 }) ?? true else {
            return .rejectedReport
        }
        lastSequence = collectionSequence
        lastNativeTimestamp = timestamp
        guard case let .measurement(measurement) = observation,
              measurement.totalRoundTripTimeSeconds.isFinite,
              measurement.totalRoundTripTimeSeconds >= 0 else { return .unavailable }
        let fingerprint = measurement.selectedCandidatePairFingerprint
        guard fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return .unavailable
        }
        defer { lastPairFingerprint = fingerprint }
        guard let lastPairFingerprint else { return .firstObserved }
        return fingerprint == lastPairFingerprint ? .unchanged : .changed
    }

    static func routeDifference(
        from previous: WebRTCICERouteDiagnostics?,
        to current: WebRTCICERouteDiagnostics?
    ) -> RouteDifference {
        guard let current else { return .unavailable }
        guard let previous else { return .firstBinding }
        guard previous != current else { return .unchanged }
        guard previous.kind == current.kind,
              isCandidateEnrichment(from: previous.local, to: current.local),
              isCandidateEnrichment(from: previous.remote, to: current.remote) else {
            return .metadataChanged
        }
        return .metadataEnrichment
    }

    private static func isCandidateEnrichment(
        from previous: WebRTCCandidateDiagnostics?,
        to current: WebRTCCandidateDiagnostics?
    ) -> Bool {
        guard let previous else { return true }
        guard let current, previous.type == current.type else { return false }
        return (previous.transport == nil || previous.transport == current.transport)
            && (previous.networkType == nil || previous.networkType == current.networkType)
            && (previous.relayProtocol == nil || previous.relayProtocol == current.relayProtocol)
    }

    static func spatialState(_ policy: WorldwideScreenVideoAdaptationPolicy) -> String {
        policy.startupSpatialModeIsActive ? "active"
            : (policy.startupSpatialModeIsDisproved ? "disproved" : "inactive")
    }

    static func transitionFields(
        before: WorldwideScreenVideoAdaptationPolicy,
        after: WorldwideScreenVideoAdaptationPolicy,
        incomingRoute: WebRTCICERouteDiagnostics?
    ) -> String {
        "startupSpatialBefore=\(spatialState(before))"
            + " startupSpatialAfter=\(spatialState(after))"
            + " routeMetadataDelta=\(routeDifference(from: before.selectedRoute, to: incomingRoute).rawValue)"
            + " policyRouteWasBound=\(before.selectedRoute != nil)"
    }
}
