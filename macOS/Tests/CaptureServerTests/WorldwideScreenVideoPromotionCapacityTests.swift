import WebRTCTransport
import XCTest
@testable import CaptureServer

final class WorldwideScreenVideoPromotionCapacityTests: XCTestCase {
    func testHistoricalPromotionsKeepFreshBandwidthInsteadOfDoubledProbeCeiling() {
        var first = PromotionFixture()
        _ = first.sample(bandwidth: 688_500)
        XCTAssertEqual(first.policy.currentRecommendation.maximumTotalRTPBitrateBps, 1_377_000)
        let firstPromotion = first.sample(bandwidth: 1_073_000)
        XCTAssertEqual(firstPromotion?.tier, .survival)
        XCTAssertEqual(firstPromotion?.maximumTotalRTPBitrateBps, 1_073_000)
        XCTAssertEqual(firstPromotion?.maximumFramesPerSecond, 5)
        XCTAssertEqual(firstPromotion?.scaleResolutionDownBy, 4)

        var second = PromotionFixture()
        _ = second.sample(bandwidth: 500_000)
        _ = second.sample(bandwidth: 500_000)
        XCTAssertEqual(second.policy.currentTier, .emergency)
        _ = second.sample(bandwidth: 590_000)
        XCTAssertEqual(second.policy.applicationLimitedProbeOriginTier, .emergency)
        _ = second.sample(bandwidth: 970_000)
        XCTAssertEqual(second.policy.currentRecommendation.maximumTotalRTPBitrateBps, 1_940_000)
        let secondPromotion = second.sample(bandwidth: 970_000)
        XCTAssertEqual(secondPromotion?.tier, .survival)
        XCTAssertEqual(secondPromotion?.maximumTotalRTPBitrateBps, 970_000)

        for fixture in [first, second] {
            XCTAssertEqual(
                fixture.policy.promotionCapacityContinuity?.deadline,
                fixture.now.advanced(by: .seconds(2))
            )
            XCTAssertEqual(
                fixture.policy.recommendation(for: .survival).maximumTotalRTPBitrateBps,
                905_041
            )
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        }
    }

    func testLivePromotionsDoNotClampBandwidthAtTheGeometryBoundary() {
        let cases: [(samples: [Double], tier: WorldwideScreenVideoAdaptationTier)] = [
            ([849_000, 1_499_000, 2_287_000], .critical),
            ([3_648_000, 7_296_000, 7_950_000], .balanced),
            ([1_656_000, 3_137_000, 4_731_000], .constrained),
        ]
        for example in cases {
            var fixture = PromotionFixture()
            var lastRecommendation: WorldwideScreenVideoEncodingRecommendation?
            for bandwidth in example.samples {
                lastRecommendation = fixture.sample(bandwidth: bandwidth)
            }
            XCTAssertEqual(lastRecommendation?.tier, example.tier)
            XCTAssertEqual(
                lastRecommendation?.maximumTotalRTPBitrateBps,
                Int(example.samples.last!)
            )
            XCTAssertGreaterThan(
                fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                fixture.policy.recommendation(for: example.tier).maximumTotalRTPBitrateBps
            )
        }
    }

    func testPromotionCannotRaiseAboveItsActiveProbeCeiling() {
        var fixture = PromotionFixture()
        _ = fixture.sample(bandwidth: 8_200_000)
        _ = fixture.sample(bandwidth: 50_000_000)
        let probeCeiling = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
        let promotion = fixture.sample(bandwidth: 50_000_000)
        XCTAssertEqual(promotion?.tier, .full)
        XCTAssertEqual(promotion?.maximumTotalRTPBitrateBps, probeCeiling)
        XCTAssertEqual(
            promotion?.maximumTotalRTPBitrateBps,
            fixture.policy.recommendation(for: .full).maximumTotalRTPBitrateBps
        )
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
    }

    func testContinuityDoesNotGrowOrRenewAndFreshFallingBandwidthShrinksIt() throws {
        var fixture = PromotionFixture.promotedToSurvival()
        let deadline = try XCTUnwrap(fixture.policy.promotionCapacityContinuity?.deadline)

        _ = fixture.sample(bandwidth: 1_200_000, queueDelay: 0.050)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 1_073_000)
        let falling = fixture.sample(bandwidth: 980_000, queueDelay: 0.050)
        XCTAssertEqual(falling?.maximumTotalRTPBitrateBps, 980_000)
        _ = fixture.sample(bandwidth: 1_200_000, queueDelay: 0.050)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 980_000)
        XCTAssertEqual(fixture.policy.promotionCapacityContinuity?.deadline, deadline)

        let expired = fixture.sample(bandwidth: 1_200_000, queueDelay: 0.050)
        XCTAssertEqual(fixture.now, deadline)
        XCTAssertEqual(expired?.tier, .survival)
        XCTAssertEqual(expired?.maximumTotalRTPBitrateBps, 905_041)
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
    }

    func testFollowingProbeTakesOverWithoutAnIntermediateLowerCap() {
        var fixture = PromotionFixture.promotedToSurvival()
        let promoted = fixture.policy.currentRecommendation
        let next = fixture.sample(bandwidth: 1_073_000)
        XCTAssertEqual(next?.tier, .survival)
        XCTAssertEqual(next?.maximumTotalRTPBitrateBps, 2_146_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .survival)
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
        XCTAssertGreaterThan(
            fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            promoted.maximumTotalRTPBitrateBps
        )
    }

    func testNoReportExpiryChangesOnlyTheTemporaryCapForItsExactPeer() throws {
        var fixture = PromotionFixture.promotedToSurvival()
        let deadline = try XCTUnwrap(fixture.policy.promotionCapacityContinuity?.deadline)
        let before = fixture.policy
        XCTAssertNil(fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1,
            isCaptureActive: true,
            observedAt: deadline.advanced(by: .milliseconds(-1))
        ))
        XCTAssertNil(fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 2,
            isCaptureActive: true,
            observedAt: deadline
        ))
        XCTAssertNil(fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1,
            isCaptureActive: false,
            observedAt: deadline
        ))
        XCTAssertEqual(fixture.policy, before)

        let expired = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1,
            isCaptureActive: true,
            observedAt: deadline
        )
        XCTAssertEqual(expired?.tier, .survival)
        XCTAssertEqual(expired?.maximumTotalRTPBitrateBps, 905_041)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, before.roundTripTimeBaselineSeconds)
        XCTAssertEqual(fixture.policy.healthyUpgradeSampleCount, before.healthyUpgradeSampleCount)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
        XCTAssertNil(fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1,
            isCaptureActive: true,
            observedAt: deadline.advanced(by: .seconds(1))
        ))
    }

    func testMissingOrInvalidBandwidthCannotRetainTheObservedCapacityCap() {
        let values: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -1]
        for bandwidth in values {
            var fixture = PromotionFixture.promotedToSurvival()
            let recommendation = fixture.sample(bandwidth: bandwidth)
            XCTAssertEqual(recommendation?.tier, .survival)
            XCTAssertEqual(recommendation?.maximumTotalRTPBitrateBps, 905_041)
            XCTAssertNil(fixture.policy.promotionCapacityContinuity)
        }
    }

    func testContinuityNeverExceedsConfiguredCapacityOrRaisesAWeakNetworkFloor() {
        var capped = PromotionFixture(configuredTotalRTPBitrateBps: 1_000_000)
        _ = capped.sample(bandwidth: 688_500)
        let promotion = capped.sample(bandwidth: 2_000_000)
        XCTAssertEqual(promotion?.tier, .survival)
        XCTAssertEqual(promotion?.maximumTotalRTPBitrateBps, 1_000_000)
        XCTAssertEqual(capped.policy.promotionCapacityContinuity?.maximumTotalRTPBitrateBps, 1_000_000)

        var weak = PromotionFixture(configuredTotalRTPBitrateBps: 500_000)
        for _ in 0..<3 {
            _ = weak.sample(bandwidth: 259_000)
            XCTAssertEqual(weak.policy.currentTier, .audioPriority)
            XCTAssertNil(weak.policy.promotionCapacityContinuity)
            XCTAssertLessThanOrEqual(weak.policy.currentRecommendation.maximumTotalRTPBitrateBps, 500_000)
        }
        XCTAssertTrue(weak.policy.belowReserveProbeDisprovedSenderLimitation)
    }

    func testRecordedTransitionQueuePressureStillDowngradesImmediately() {
        for delays in [[0.0818, 0.2904], [0.1052, 0.2940]] {
            var fixture = PromotionFixture.promotedToSurvival()
            _ = fixture.sample(bandwidth: 1_073_000, queueDelay: delays[0])
            XCTAssertEqual(fixture.policy.currentTier, .survival)
            XCTAssertNotNil(fixture.policy.promotionCapacityContinuity)
            let pressured = fixture.sample(bandwidth: 1_073_000, queueDelay: delays[1])
            XCTAssertEqual(pressured?.tier, .emergency)
            XCTAssertNil(fixture.policy.promotionCapacityContinuity)
            XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
            XCTAssertNil(fixture.policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            ))
        }
    }

    func testRecordedBandwidthCollapseAndReserveFailureRemainActionable() {
        var fixture = PromotionFixture()
        for bandwidth in [3_648_000.0, 7_296_000, 7_950_000] {
            _ = fixture.sample(bandwidth: bandwidth)
        }
        XCTAssertEqual(fixture.policy.currentTier, .balanced)
        _ = fixture.sample(bandwidth: 7_950_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .balanced)
        XCTAssertEqual(fixture.sample(bandwidth: 2_376_000)?.tier, .critical)
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertEqual(fixture.sample(bandwidth: 860_000, queueDelay: 0.1432)?.tier, .survival)
        _ = fixture.sample(bandwidth: 259_000)
        _ = fixture.sample(bandwidth: 259_000)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertNil(fixture.policy.promotionCapacityContinuity)
    }

    func testRecordedRTTInflationStillWalksDownFromFullQuality() {
        var fixture = PromotionFixture()
        for bandwidth in [7_487_000.0, 14_973_000, 15_239_000] {
            _ = fixture.sample(bandwidth: bandwidth)
        }
        XCTAssertEqual(fixture.policy.currentTier, .full)
        let sequence: [(Double, WorldwideScreenVideoAdaptationTier)] = [
            (15_239_000, .high), (10_997_000, .balanced),
            (7_055_000, .constrained), (3_743_000, .critical),
        ]
        for (bandwidth, expectedTier) in sequence {
            XCTAssertEqual(fixture.sample(bandwidth: bandwidth, rtt: 0.062)?.tier, expectedTier)
            XCTAssertNil(fixture.policy.promotionCapacityContinuity)
            XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
        }

        var promoted = PromotionFixture.promotedToSurvival()
        XCTAssertEqual(promoted.sample(bandwidth: 1_073_000, rtt: 0.063)?.tier, .emergency)
        XCTAssertNil(promoted.policy.promotionCapacityContinuity)
    }

    func testPeerRouteHideResumeAndEvidenceBoundariesDiscardContinuity() {
        for boundary in PromotionBoundary.allCases {
            var fixture = PromotionFixture.promotedToSurvival()
            XCTAssertNotNil(fixture.policy.promotionCapacityContinuity)
            switch boundary {
            case .peer:
                fixture.policy.bind(toPeerGeneration: 2)
            case .routeInvalidation:
                fixture.policy.invalidateSelectedRoute()
            case .routeReplacement:
                _ = fixture.sample(bandwidth: 1_073_000, route: .init(kind: .relayed))
            case .hide:
                fixture.policy.resetForInactiveCapture()
            case .inactiveSample:
                _ = fixture.sample(bandwidth: 1_073_000, isCaptureActive: false)
            case .suspendedSample:
                _ = fixture.sample(
                    bandwidth: 1_073_000,
                    isCaptureActive: false,
                    isAutomaticallySuspended: true
                )
            case .resumeBegan:
                fixture.policy.automaticResumeAttemptBegan()
            case .resumeSucceeded:
                fixture.policy.automaticResumeAttemptSucceeded()
            case .resumeFailed:
                fixture.policy.automaticResumeAttemptFailed()
            case .evidenceGapOrCadenceChange:
                fixture.policy.resetIncompleteEvidenceWindow()
            }
            XCTAssertNil(fixture.policy.promotionCapacityContinuity, "\(boundary)")
            XCTAssertEqual(
                fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                fixture.policy.recommendation(for: fixture.policy.currentTier).maximumTotalRTPBitrateBps,
                "\(boundary)"
            )
        }
    }
}

private enum PromotionBoundary: CaseIterable {
    case peer, routeInvalidation, routeReplacement, hide, inactiveSample, suspendedSample
    case resumeBegan, resumeSucceeded, resumeFailed, evidenceGapOrCadenceChange
}

private struct PromotionFixture {
    var policy: WorldwideScreenVideoAdaptationPolicy
    var now = ContinuousClock.now
    private var packetsSent: UInt64 = 0
    private var totalPacketSendDelay = 0.0

    init(configuredTotalRTPBitrateBps: Int = 50_000_000) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps,
            baseFramesPerSecond: 60
        )
        XCTAssertEqual(sample(bandwidth: 100_000, afterMilliseconds: 0)?.tier, .audioPriority)
        _ = sample(bandwidth: 400_000)
        _ = sample(bandwidth: 400_000)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
    }

    static func promotedToSurvival() -> Self {
        var fixture = Self()
        _ = fixture.sample(bandwidth: 688_500)
        _ = fixture.sample(bandwidth: 1_073_000)
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        return fixture
    }

    @discardableResult
    mutating func sample(
        bandwidth: Double?,
        rtt: Double? = 0.003,
        queueDelay: Double = 0.001,
        afterMilliseconds: Int = 500,
        route: WebRTCICERouteDiagnostics? = nil,
        isCaptureActive: Bool = true,
        isAutomaticallySuspended: Bool = false
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        now = now.advanced(by: .milliseconds(afterMilliseconds))
        packetsSent += 100
        totalPacketSendDelay += queueDelay * 100
        return policy.update(
            peerGeneration: 1,
            isCaptureActive: isCaptureActive,
            isAutomaticallySuspended: isAutomaticallySuspended,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt,
            selectedRoute: route,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay,
            observedAt: now
        )
    }
}
