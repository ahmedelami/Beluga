import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenStartupSpatialPolicyTests: XCTestCase {
    func testShowKeepsExistingTrafficCeilingsButStartsWithFullPixels() {
        var policy = makePolicy()
        let ordinary = policy.currentRecommendation
        XCTAssertEqual(ordinary.scaleResolutionDownBy, 4)
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        let startup = policy.currentRecommendation
        XCTAssertEqual(startup.scaleResolutionDownBy, 1)
        XCTAssertEqual(startup.maximumFramesPerSecond, 5)
        XCTAssertEqual(startup.maximumBitrateBps, ordinary.maximumBitrateBps)
        XCTAssertEqual(startup.maximumTotalRTPBitrateBps, ordinary.maximumTotalRTPBitrateBps)
        XCTAssertEqual(startup.tier, ordinary.tier)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        XCTAssertEqual(policy.currentRecommendation, startup)
    }

    func testExplicitLowCeilingDoesNotAcquireSpeculativeFullPixels() {
        for cap in [100_000, 500_000, 1_000_000] {
            var policy = makePolicy(cap: cap)
            let ordinary = policy.currentRecommendation
            policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
            XCTAssertEqual(policy.currentRecommendation, ordinary, "configured cap \(cap)")
        }
    }

    func testInitialRouteDoesNotLookLikeAReplacement() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 5)
    }

    func testMissingBandwidthAndExpiredProbeDoNotBlurOrInventFPSCapacity() {
        var fixture = SpatialFixture()
        let original = fixture.policy.currentRecommendation
        for time in stride(from: 0, through: 10_000, by: 500) {
            _ = fixture.sample(at: time, bandwidth: nil)
        }
        XCTAssertEqual(fixture.policy.currentRecommendation, original)
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true,
            observedAt: fixture.origin.advanced(by: .seconds(60))
        )
        XCTAssertEqual(fixture.policy.currentRecommendation, original)
    }

    func testHealthyIntermediatePromotionsKeepPixelsAndFullQualificationReleasesFPS() {
        var fixture = SpatialFixture()
        var sawIntermediate = false
        for (index, bandwidth) in [900_000.0, 900_000, 3_000_000, 3_000_000,
                                   9_000_000, 9_000_000, 18_000_000, 18_000_000,
                                   18_000_000].enumerated() {
            _ = fixture.sample(at: index * 500, bandwidth: bandwidth)
            let recommendation = fixture.policy.currentRecommendation
            XCTAssertEqual(recommendation.scaleResolutionDownBy, 1)
            if recommendation.tier != .full {
                XCTAssertEqual(recommendation.maximumFramesPerSecond, 5)
                sawIntermediate = sawIntermediate || recommendation.tier.rawValue <
                    WorldwideScreenVideoAdaptationTier.survival.rawValue
            }
        }
        XCTAssertTrue(sawIntermediate)
        XCTAssertEqual(fixture.policy.currentTier, .full)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 60)
    }

    func testImmediateQueuePressureRetiresFullPixelsWithoutSuspendingCapture() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        let changed = fixture.sample(at: 500, queueDelay: 0.250)
        XCTAssertNotNil(changed)
        XCTAssertGreaterThanOrEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 4)
        XCTAssertNil(fixture.policy.automaticSuspensionDecision(
            isCaptureActive: true, isAutomaticallySuspended: false))
        _ = fixture.sample(at: 1_000)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testSoftQueuePressureNeedsConfirmationButNoPacketGapDoesNotEraseIt() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500, queueDelay: 0.110)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        _ = fixture.sample(at: 1_000, advancesPackets: false)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        _ = fixture.sample(at: 1_500, queueDelay: 0.110)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testConfirmedBandwidthCollapseRetiresFullPixelsOnFirstShow() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 12)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1)
    }

    func testFreshInflatedRTTRetiresFullPixels() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500, rtt: 0.2, pingCount: 2, totalRTT: 0.204)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testReplacementRouteRetiresFullPixelsWithoutRearmingInSameShow() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500, route: .relayed)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testHideAndNewPeerCannotRetainSpatialStartupOwnership() {
        var fixture = SpatialFixture()
        fixture.policy.endFloorRecoveryVisibility()
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 4)
        fixture.policy.resetForInactiveCapture()
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        fixture.policy.bind(toPeerGeneration: 2)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 4)
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 2, showEpoch: 1)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testDuplicateNativeReportCannotPromoteStartupFPS() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 18_000_000)
        for time in stride(from: 500, through: 4_000, by: 500) {
            _ = fixture.sample(at: time, bandwidth: 18_000_000, sequence: 1,
                               timestamp: 1_000_000)
        }
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 5)
    }

    func testNewRequestWithStaleOrMissingNativeReportCannotApplyNegativeEvidence() {
        for invalidTimestamp: Double? in [1_000_000, 900_000, nil] {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            let before = fixture.policy.currentRecommendation
            _ = fixture.sample(at: 500, bandwidth: 100_000, queueDelay: 0.250,
                               rtt: 0.2, pingCount: 2, totalRTT: 0.204,
                               route: .relayed, timestamp: invalidTimestamp,
                               omitTimestamp: invalidTimestamp == nil)
            XCTAssertEqual(fixture.policy.currentRecommendation, before)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
            XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
            _ = fixture.sample(at: 1_000, bandwidth: 100_000, queueDelay: 0.250,
                               rtt: 0.2, pingCount: 2, totalRTT: 0.204, route: .relayed)
            XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        }
    }

    func testNoReportOrAllMissingMeasurementsCannotBlurNewShow() {
        var fixture = SpatialFixture()
        let original = fixture.policy.currentRecommendation
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true,
            observedAt: fixture.origin.advanced(by: .seconds(60)))
        XCTAssertEqual(fixture.policy.currentRecommendation, original)
        _ = fixture.policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
            roundTripTimeObservation: .unavailable, collectionSequence: 1,
            requireRoundTripTimeObservation: true,
            outboundVideoPacketsSent: nil, outboundVideoTotalPacketSendDelaySeconds: nil,
            nativeReportTimestampMicroseconds: 1_000_000,
            observedAt: fixture.origin.advanced(by: .seconds(61)))
        XCTAssertEqual(fixture.policy.currentRecommendation, original)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testExplicitRouteInvalidationDistinguishesInitialBindingAndReplacement() {
        var fixture = SpatialFixture()
        fixture.policy.invalidateSelectedRoute()
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        _ = fixture.sample(at: 0)
        fixture.policy.invalidateSelectedRoute()
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testRejectedNativeApplyRetainsOnlyExactShowTerminalDisproof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        let original = fixture.policy
        _ = fixture.sample(at: 500, queueDelay: 0.250)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        var failedApply = original
        failedApply.retainStartupSpatialModeTerminalState(from: fixture.policy)
        XCTAssertFalse(failedApply.startupSpatialModeIsActive)
        XCTAssertEqual(failedApply.currentTier, original.currentTier,
                       "The rejected native geometry/tier is not a committed promotion")
        XCTAssertEqual(failedApply.currentRecommendation.scaleResolutionDownBy, 4,
                       "The unapplied full-pixel sender must differ so the next report retries")
        failedApply.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        XCTAssertFalse(failedApply.startupSpatialModeIsActive)

        var nextShow = original
        nextShow.endFloorRecoveryVisibility()
        nextShow.resetForInactiveCapture()
        nextShow.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        nextShow.retainStartupSpatialModeTerminalState(from: fixture.policy)
        XCTAssertTrue(nextShow.startupSpatialModeIsActive,
                      "An old negative callback cannot cancel a newer Show")
        nextShow.bind(toPeerGeneration: 2)
        nextShow.beginFloorRecoveryVisibility(peerGeneration: 2, showEpoch: 1)
        nextShow.retainStartupSpatialModeTerminalState(from: fixture.policy)
        XCTAssertTrue(nextShow.startupSpatialModeIsActive,
                      "An old peer cannot cancel the current peer's startup")
    }

    func testCopyingPositiveProposalCannotRearmDisprovedMode() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        let positive = fixture.policy
        _ = fixture.sample(at: 500, queueDelay: 0.250)
        fixture.policy.retainStartupSpatialModeTerminalState(from: positive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testFastLaneCollapseOrImmediateQueueRetiresSpatialMode() throws {
        for isQueue in [false, true] {
            var fixture = SpatialFixture()
            for time in [0, 500, 1_000] { _ = fixture.sample(at: time) }
            _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
            let changed = fixture.fastSample(at: 1_200,
                bandwidth: isQueue ? 900_000 : 100_000,
                queueDelay: isQueue ? 0.250 : 0.001)
            XCTAssertNotNil(changed)
            XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
            XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        }
    }

    func testFastMissingBandwidthCannotTurnIntoAConfirmedSpatialFailure() throws {
        var fixture = SpatialFixture()
        for time in [0, 500, 1_000] { _ = fixture.sample(at: time) }
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.fastSample(at: 1_200, bandwidth: nil)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true,
            observedAt: fixture.origin.advanced(by: .seconds(30)))
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    private func makePolicy(cap: Int = 50_000_000) -> WorldwideScreenVideoAdaptationPolicy {
        WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: cap,
                                             baseFramesPerSecond: 60)
    }
}

private struct SpatialFixture {
    var policy = WorldwideScreenVideoAdaptationPolicy(
        configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60)
    let origin = ContinuousClock.now
    private var sequence: UInt64 = 0
    private var packets: UInt64 = 0
    private var totalDelay = 0.0

    init() {
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
    }

    mutating func sample(
        at milliseconds: Int, bandwidth: Double? = 900_000,
        queueDelay: Double = 0.001, advancesPackets: Bool = true,
        rtt: Double = 0.004, pingCount: UInt64? = nil, totalRTT: Double? = nil,
        route: WebRTCICERouteKind = .direct,
        sequence sequenceOverride: UInt64? = nil, timestamp: Double? = nil,
        omitTimestamp: Bool = false
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        sequence += 1
        if advancesPackets {
            packets += 100
            totalDelay += queueDelay * 100
        }
        let count = pingCount ?? UInt64(milliseconds / 2_500 + 1)
        return policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: route == .direct ? "a" : "b", count: 64),
                totalRoundTripTimeSeconds: totalRTT ?? Double(count) * rtt,
                responsesReceived: count)),
            collectionSequence: sequenceOverride ?? sequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: route),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalDelay,
            nativeReportTimestampMicroseconds: omitTimestamp ? nil
                : timestamp ?? 1_000_000 + Double(milliseconds) * 1_000,
            observedAt: origin.advanced(by: .milliseconds(milliseconds)))
    }

    mutating func fastSample(at milliseconds: Int, bandwidth: Double?,
                             queueDelay: Double = 0.001) -> WorldwideScreenVideoEncodingRecommendation? {
        sequence += 1
        packets += 100
        totalDelay += queueDelay * 100
        let count = UInt64(milliseconds / 2_500 + 1)
        return policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: Double(count) * 0.004,
                responsesReceived: count)),
            collectionSequence: sequence,
            nativeReportTimestampMicroseconds: 1_000_000 + Double(milliseconds) * 1_000,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalDelay,
            observedAt: origin.advanced(by: .milliseconds(milliseconds)))
    }
}
