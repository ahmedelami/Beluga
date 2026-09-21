import XCTest
@testable import CaptureServer

final class StartupVideoPolicyShadowTests: XCTestCase {
    func testInitialAndEqualPrefixComparisonsRemainOpen() {
        let now = ContinuousClock.now
        let candidate = policy(enabled: true, at: now)
        let shadow = policy(enabled: false, at: now)
        var recorder = StartupVideoPolicyShadow()
        XCTAssertEqual(recorder.comparisonCount, 0)
        recorder.compare(candidate: candidate, shadow: shadow, stage: .initial, at: now)
        recorder.compare(candidate: candidate, shadow: shadow, stage: .beforeApply,
                         at: now.advanced(by: .milliseconds(500)))
        recorder.compare(candidate: candidate, shadow: shadow, stage: .afterApply,
                         at: now.advanced(by: .milliseconds(600)))
        XCTAssertEqual(recorder.comparisonCount, 3)
        XCTAssertTrue(recorder.isComparing)
        XCTAssertNil(recorder.firstDivergence)
    }

    func testInitialDifferenceIsRecordedBeforeAnyReportOrNativeApply() throws {
        let now = ContinuousClock.now
        let candidate = policy(enabled: true, at: now)
        let shadow = policy(enabled: false, cap: 1_000_000, at: now)
        XCTAssertNotEqual(candidate.currentRecommendation, shadow.currentRecommendation)
        var recorder = StartupVideoPolicyShadow()
        recorder.compare(candidate: candidate, shadow: shadow, stage: .initial, at: now)
        let difference = try XCTUnwrap(recorder.firstDivergence)
        XCTAssertEqual(difference.stage, .initial)
        XCTAssertEqual(difference.observedAt, now)
        XCTAssertEqual(difference.candidate.recommendation, candidate.currentRecommendation)
        XCTAssertEqual(difference.shadow.recommendation, shadow.currentRecommendation)
        XCTAssertEqual(difference.differences["recommendation"], true)
        XCTAssertEqual(recorder.comparisonCount, 1)
        XCTAssertFalse(recorder.isComparing)
    }

    func testPreApplyDifferenceSurvivesPolicyReconvergenceAndLaterDifferences() throws {
        let now = ContinuousClock.now
        var candidate = policy(enabled: true, at: now)
        var shadow = policy(enabled: false, at: now)
        var recorder = StartupVideoPolicyShadow()
        recorder.compare(candidate: candidate, shadow: shadow, stage: .initial, at: now)

        // Removing one Show's startup geometry creates a real recommendation difference.
        // Removing the other's later makes the same two policies reconverge.
        candidate.endFloorRecoveryVisibility()
        XCTAssertNotEqual(candidate.currentRecommendation, shadow.currentRecommendation)
        let beforeApply = now.advanced(by: .milliseconds(500))
        recorder.compare(candidate: candidate, shadow: shadow, stage: .beforeApply, at: beforeApply)
        let first = try XCTUnwrap(recorder.firstDivergence)
        XCTAssertEqual(first.stage, .beforeApply)
        XCTAssertEqual(first.observedAt, beforeApply)
        XCTAssertEqual(first.differences["recommendation"], true)
        XCTAssertEqual(first.candidate.recommendation.scaleResolutionDownBy, 4)
        XCTAssertEqual(first.shadow.recommendation.scaleResolutionDownBy, 1)

        shadow.endFloorRecoveryVisibility()
        XCTAssertEqual(StartupVideoPolicyShadow.Snapshot(candidate),
                       StartupVideoPolicyShadow.Snapshot(shadow))
        recorder.compare(candidate: candidate, shadow: shadow, stage: .afterApply,
                         at: now.advanced(by: .seconds(1)))
        XCTAssertEqual(recorder.firstDivergence, first)
        XCTAssertEqual(recorder.comparisonCount, 2)
        XCTAssertFalse(recorder.isComparing)

        candidate.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2,
                                               at: now.advanced(by: .seconds(2)))
        XCTAssertNotEqual(candidate.currentRecommendation, shadow.currentRecommendation)
        recorder.compare(candidate: candidate, shadow: shadow, stage: .beforeApply,
                         at: now.advanced(by: .seconds(2)))
        XCTAssertEqual(recorder.firstDivergence, first, "Later differences cannot replace the first boundary")
        XCTAssertEqual(recorder.comparisonCount, 2)
    }

    func testSnapshotCopiesAllComparedPolicyValues() {
        let source = policy(enabled: true, at: .now)
        let snapshot = StartupVideoPolicyShadow.Snapshot(source)
        XCTAssertEqual(snapshot.recommendation, source.currentRecommendation)
        XCTAssertEqual(snapshot.startupDisproved, source.startupSpatialModeIsDisproved)
        XCTAssertEqual(snapshot.probeOrigin, source.applicationLimitedProbeOriginTier)
        XCTAssertEqual(snapshot.probeDeadline, source.applicationLimitedProbeDeadline)
        XCTAssertEqual(snapshot.rttDisposition, source.roundTripTimeDisposition)
    }

    private func policy(
        enabled: Bool, cap: Int = 50_000_000, at now: ContinuousClock.Instant
    ) -> WorldwideScreenVideoAdaptationPolicy {
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: cap, baseFramesPerSecond: 60,
            spatialRecoveryEnabled: enabled)
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1, at: now)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        return policy
    }
}
