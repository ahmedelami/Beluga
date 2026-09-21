import Foundation
@testable import CaptureServer

/// Compares policy decisions at caller-owned boundaries, never drives the native peer.
/// Record before an await: post-resume expiry can otherwise hide a prior difference.
struct StartupVideoPolicyShadow: Sendable {
    enum Stage: String, Sendable {
        case initial, beforeApply, afterApply
    }

    struct Snapshot: Equatable, Sendable {
        let recommendation: WorldwideScreenVideoEncodingRecommendation
        let startupDisproved: Bool
        let probeOrigin: WorldwideScreenVideoAdaptationTier?
        let probeDeadline: ContinuousClock.Instant?
        let rttDisposition: WorldwideScreenVideoAdaptationPolicy.RoundTripTimeDisposition

        init(_ policy: WorldwideScreenVideoAdaptationPolicy) {
            recommendation = policy.currentRecommendation
            startupDisproved = policy.startupSpatialModeIsDisproved
            probeOrigin = policy.applicationLimitedProbeOriginTier
            probeDeadline = policy.applicationLimitedProbeDeadline
            rttDisposition = policy.roundTripTimeDisposition
        }
    }

    struct Divergence: Equatable, Sendable {
        let stage: Stage
        let observedAt: ContinuousClock.Instant
        let candidate: Snapshot
        let shadow: Snapshot

        var differences: [String: Bool] {
            [
                "recommendation": candidate.recommendation != shadow.recommendation,
                "startupDisproof": candidate.startupDisproved != shadow.startupDisproved,
                "probeOrigin": candidate.probeOrigin != shadow.probeOrigin,
                "probeDeadline": candidate.probeDeadline != shadow.probeDeadline,
                "rttDisposition": candidate.rttDisposition != shadow.rttDisposition,
            ]
        }
    }

    private(set) var comparisonCount = 0
    private(set) var firstDivergence: Divergence?
    var isComparing: Bool { firstDivergence == nil }

    mutating func compare(
        candidate: WorldwideScreenVideoAdaptationPolicy,
        shadow: WorldwideScreenVideoAdaptationPolicy,
        stage: Stage,
        at observedAt: ContinuousClock.Instant
    ) {
        guard isComparing else { return }
        comparisonCount += 1
        let candidateSnapshot = Snapshot(candidate)
        let shadowSnapshot = Snapshot(shadow)
        guard candidateSnapshot != shadowSnapshot else { return }
        firstDivergence = Divergence(stage: stage, observedAt: observedAt,
                                     candidate: candidateSnapshot, shadow: shadowSnapshot)
    }
}
