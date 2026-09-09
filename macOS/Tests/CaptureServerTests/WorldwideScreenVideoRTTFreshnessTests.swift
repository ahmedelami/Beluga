import WebRTCTransport
@testable import CaptureServer
import XCTest

final class WorldwideScreenVideoRTTFreshnessTests: XCTestCase {
    func testFiveDuplicateInflatedReportsApplyOnlyOneRTTDescent() {
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.currentTier, .high)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
        for _ in 0..<5 {
            XCTAssertNil(fixture.sample(rtt: 0.060))
            XCTAssertEqual(fixture.policy.currentTier, .high)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedInflated)
            XCTAssertFalse(fixture.policy.lastSampleHasLatencyPressure)
            XCTAssertEqual(fixture.policy.healthyUpgradeSampleCount, 0)
        }
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
    }

    func testIdenticalScalarWithDistinctWatermarksRetainsImmediateRTTPenalties() {
        var fixture = fullFixture()
        for tier in [WorldwideScreenVideoAdaptationTier.high, .balanced, .constrained, .critical, .survival] {
            fixture.advanceWatermark(total: 0.060, responses: 1)
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, tier)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
            XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
        }
    }

    func testTotalOnlyPiggybackAndResponseOnlyAdvancementAreDistinct() {
        for responses in [UInt64(0), 10] {
            var fixture = fullFixture(responses: responses)
            fixture.advanceWatermark(total: 0.060, responses: 0)
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .high)
            XCTAssertEqual(fixture.responses, responses)
            fixture.advanceWatermark(total: 0, responses: 1)
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .balanced)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
        }
    }

    func testProvisionalReferenceLearnsOnlyDistinctHealthyMeasurements() {
        var fixture = RTTFixture()
        _ = fixture.sample(rtt: 0.100)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.100)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
        fixture.advanceWatermark(total: 0.020, responses: 1)
        _ = fixture.sample(rtt: 0.020)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds ?? .nan, 0.090, accuracy: 0.000_001)
        for _ in 0..<5 { _ = fixture.sample(rtt: 0.020) }
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds ?? .nan, 0.090, accuracy: 0.000_001)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
        fixture.advanceWatermark(total: 0.300, responses: 1)
        _ = fixture.sample(rtt: 0.300)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds ?? .nan, 0.090, accuracy: 0.000_001)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
        fixture.advanceWatermark(total: 0.020, responses: 1)
        _ = fixture.sample(rtt: 0.020)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds ?? .nan, 0.080, accuracy: 0.000_001)
        XCTAssertFalse(fixture.policy.roundTripTimeReferenceIsProvisional)
    }

    func testStrictMissingObservationCannotUseLegacyQueueOnlyUpgrade() {
        var fixture = RTTFixture()
        fixture.observation = .unavailable
        for _ in 0..<5 {
            _ = fixture.sample(rtt: nil)
            XCTAssertEqual(fixture.policy.currentTier, .survival)
            XCTAssertEqual(fixture.policy.healthyUpgradeSampleCount, 0)
        }
        fixture.observation = nil
        for _ in 0..<5 {
            _ = fixture.sample(rtt: 0.005)
            XCTAssertEqual(fixture.policy.currentTier, .survival)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        }
    }

    func testLegacyNilObservationKeepsScalarCompatibility() {
        var fixture = RTTFixture()
        fixture.observation = nil
        fixture.strict = false
        for _ in 0..<4 { _ = fixture.sample() }
        XCTAssertEqual(fixture.policy.currentTier, .full)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .legacy)
        for tier in [WorldwideScreenVideoAdaptationTier.high, .balanced] {
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, tier)
        }
    }

    func testMissingOrMalformedAfterUnhealthyCannotReviveOrRepeatPressure() {
        let malformed: [WebRTCRoundTripTimeObservation?] = [
            nil, .unavailable,
            measurement(pair: "bad", total: 2, responses: 11),
            measurement(pair: RTTFixture.pairA, total: .nan, responses: 11),
            measurement(pair: RTTFixture.pairA, total: -.infinity, responses: 11),
            measurement(pair: RTTFixture.pairA, total: -1, responses: 11),
        ]
        for badObservation in malformed {
            var fixture = fullFixture()
            fixture.advanceWatermark(total: 0.060, responses: 1)
            _ = fixture.sample(rtt: 0.060)
            let consumed = fixture.observation
            fixture.observation = badObservation
            for _ in 0..<3 { _ = fixture.sample(rtt: 0.060) }
            XCTAssertEqual(fixture.policy.currentTier, .high)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            fixture.observation = consumed
            for _ in 0..<3 { _ = fixture.sample(rtt: 0.060) }
            XCTAssertEqual(fixture.policy.currentTier, .high)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            XCTAssertEqual(fixture.policy.healthyUpgradeSampleCount, 0)
        }
    }

    func testInvalidScalarConsumesWatermarkWithoutAuthorizingHealth() {
        for scalar in [Double?.none, 0, .nan, .infinity, -0.005, 2] {
            var fixture = fullFixture()
            fixture.advanceWatermark(total: 0.060, responses: 1)
            _ = fixture.sample(rtt: scalar)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            for _ in 0..<3 { _ = fixture.sample(rtt: 0.060) }
            XCTAssertEqual(fixture.policy.currentTier, .full)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            fixture.advanceWatermark(total: 0.060, responses: 1)
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .high)
        }
    }

    func testZeroWatermarkIsNotPositiveRTTButSubsequentPiggybackCanBootstrap() {
        var fixture = RTTFixture(total: 0, responses: 0)
        _ = fixture.sample(rtt: 0)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        fixture.advanceWatermark(total: 0.005, responses: 0)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
    }

    func testPairReplacementAndABAReturnRequireAdvancement() {
        var fixture = fullFixture()
        fixture.pair = RTTFixture.pairB
        fixture.total = 20
        fixture.responses = 200
        fixture.refreshObservation()
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reseeded)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        fixture.pair = RTTFixture.pairA
        fixture.total = 1
        fixture.responses = 10
        fixture.refreshObservation()
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reseeded)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
    }

    func testEitherCounterRegressionSeedsUnknownEvenWhenOtherCounterAdvances() {
        for resetTotal in [true, false] {
            var fixture = fullFixture()
            fixture.advanceWatermark(total: 0.060, responses: 1)
            _ = fixture.sample(rtt: 0.060)
            fixture.total = resetTotal ? 0.060 : 2
            fixture.responses = resetTotal ? 12 : 0
            fixture.refreshObservation()
            _ = fixture.sample(rtt: 0.060)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reseeded)
            XCTAssertEqual(fixture.policy.currentTier, .high)
            _ = fixture.sample(rtt: 0.060)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
            fixture.advanceWatermark(total: 0.060, responses: 1)
            XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .balanced)
        }
    }

    func testOutOfOrderAcrossFastFallbackLanesCannotConsumeAnyEvidence() {
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060, sequence: 10)
        let cap = fixture.policy.currentRecommendation
        let baseline = fixture.policy.roundTripTimeBaselineSeconds
        let spike = fixture.observation
        fixture.advanceWatermark(total: 0.500, responses: 100)
        XCTAssertNil(fixture.sample(bandwidth: 100_000, sequence: 9))
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reordered)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, 10)
        XCTAssertEqual(fixture.policy.currentRecommendation, cap)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
        fixture.observation = spike
        _ = fixture.sample(rtt: 0.060, sequence: 11, advancesPackets: false)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedInflated)
        XCTAssertEqual(fixture.policy.currentTier, .high)
        XCTAssertNil(fixture.sample(bandwidth: 100_000, sequence: 11))
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reordered)
        XCTAssertEqual(fixture.policy.currentTier, .high)
    }

    func testStrictMissingSequenceCannotSupplyFreshRTTQueueOrBWE() {
        var fixture = fullFixture()
        let lastSequence = fixture.policy.lastConsumedCollectionSequence
        fixture.advanceWatermark(total: 0.060, responses: 1)
        XCTAssertNil(fixture.policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 100_000,
            currentRoundTripTimeSeconds: 0.060,
            roundTripTimeObservation: fixture.observation,
            requireRoundTripTimeObservation: true,
            outboundVideoPacketsSent: 10_000,
            outboundVideoTotalPacketSendDelaySeconds: 3_000,
            observedAt: fixture.now
        ))
        XCTAssertEqual(fixture.policy.currentTier, .full)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, lastSequence)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertFalse(fixture.policy.lastSampleHasLatencyPressure)
        XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .high)
    }

    func testHealthyObservationTTLDoesNotRenewOnDuplicatePolls() {
        var fixture = RTTFixture()
        let startedAt = fixture.now
        _ = fixture.sample(bandwidth: 100_000, afterMilliseconds: 0)
        for _ in 0..<8 { _ = fixture.sample(bandwidth: 100_000) }
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedHealthy)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .seconds(4))
        _ = fixture.sample(afterMilliseconds: 1)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .expired)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        for _ in 0..<3 { _ = fixture.sample() }
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(startedAt.duration(to: fixture.now), .milliseconds(5_501))
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .zero)
    }

    func testMissingHealthyEvidenceCannotBeRevivedByUnchangedWatermarkWithinTTL() {
        var fixture = fullFixture()
        let healthy = fixture.observation
        fixture.observation = .unavailable
        _ = fixture.sample()
        fixture.observation = healthy
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
    }

    func testChangedScalarWithoutWatermarkRevokesHealthWithoutNewPressure() {
        var fixture = audioPriorityFixture()
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertFalse(fixture.policy.lastSampleHasLatencyPressure)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        for _ in 0..<3 { _ = fixture.sample() }
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
    }

    func testClockRegressionRevokesHealthWithoutReplayingItsWatermark() {
        var fixture = fullFixture()
        _ = fixture.sample(afterMilliseconds: -1_000)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        _ = fixture.sample(afterMilliseconds: 1_000)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
    }

    func testCachedInflatedRTTCannotCountAsStableAutomaticResume() {
        var fixture = RTTFixture()
        _ = fixture.sample(bandwidth: 100_000, afterMilliseconds: 0)
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(bandwidth: 100_000, rtt: 0.060)
        for _ in 0..<WorldwideScreenVideoAdaptationPolicy.requiredStableSuspensionResumeProbeSampleCount {
            _ = fixture.sample(bandwidth: 100_000, rtt: 0.060)
            XCTAssertNil(fixture.policy.automaticSuspensionDecision(isCaptureActive: false, isAutomaticallySuspended: true))
            XCTAssertEqual(fixture.policy.stableSuspensionResumeProbeSampleCount, 0)
        }
        // The deliberate maximum-pause escape hatch remains separate from a claim of health.
        for _ in fixture.policy.maximumSuspensionResumeProbeSampleCount..<WorldwideScreenVideoAdaptationPolicy.requiredMaximumSuspensionResumeProbeSampleCount - 1 {
            XCTAssertNil(fixture.policy.automaticSuspensionDecision(isCaptureActive: false, isAutomaticallySuspended: true))
        }
        XCTAssertNotNil(fixture.policy.automaticSuspensionDecision(isCaptureActive: false, isAutomaticallySuspended: true))
    }

    func testRejectedReportsAndNoReportExpiryAgeHealthyLeaseForSuspendedResume() {
        for noReport in [true, false] {
            var fixture = audioPriorityFixture()
            for _ in 0..<WorldwideScreenVideoAdaptationPolicy.requiredStableSuspensionResumeProbeSampleCount {
                fixture.now = fixture.now.advanced(by: .seconds(5))
                if noReport {
                    _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(peerGeneration: 1, isCaptureActive: false, observedAt: fixture.now)
                } else {
                    _ = fixture.policy.update(
                        peerGeneration: 1,
                        isCaptureActive: false,
                        isAutomaticallySuspended: true,
                        availableOutgoingBitrateBps: 50_000_000,
                        currentRoundTripTimeSeconds: 0.005,
                        roundTripTimeObservation: fixture.observation,
                        collectionSequence: 1,
                        requireRoundTripTimeObservation: true,
                        observedAt: fixture.now
                    )
                }
                XCTAssertNil(fixture.policy.automaticSuspensionDecision(isCaptureActive: false, isAutomaticallySuspended: true))
                XCTAssertEqual(fixture.policy.stableSuspensionResumeProbeSampleCount, 0)
            }
        }
    }

    func testReorderedAndMissingSequenceReportsStillExpireProbeAtAbsoluteDeadline() throws {
        for missingSequence in [true, false] {
            var fixture = audioPriorityFixture()
            _ = fixture.sample(bandwidth: 400_000)
            let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
            let sequence = try XCTUnwrap(fixture.policy.lastConsumedCollectionSequence)
            let result = fixture.policy.update(
                peerGeneration: 1,
                isCaptureActive: true,
                availableOutgoingBitrateBps: 50_000_000,
                currentRoundTripTimeSeconds: 0.005,
                roundTripTimeObservation: fixture.observation,
                collectionSequence: missingSequence ? nil : sequence,
                requireRoundTripTimeObservation: true,
                observedAt: deadline
            )
            XCTAssertNotNil(result)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
            XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, sequence)
        }
    }

    func testCadenceAndGapResetDoNotForgetWatermarkSequenceOrObservationAge() {
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060)
        let sequence = fixture.policy.lastConsumedCollectionSequence
        fixture.policy.resetIncompleteEvidenceWindow()
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, sequence)
        _ = fixture.sample(rtt: 0.060, afterMilliseconds: 5_000)
        XCTAssertEqual(fixture.policy.currentTier, .high)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedInflated)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .seconds(5))
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
    }

    func testHideAndRouteInvalidationRevokeHealthWithoutManufacturingNewPeer() {
        for hide in [true, false] {
            var fixture = fullFixture()
            let sequence = fixture.policy.lastConsumedCollectionSequence
            if hide { fixture.policy.resetForInactiveCapture() }
            else { fixture.policy.invalidateSelectedRoute() }
            XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, sequence)
            for _ in 0..<3 { _ = fixture.sample() }
            XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            XCTAssertEqual(fixture.policy.currentTier, hide ? .survival : .full)
            fixture.advanceWatermark(total: 0.005, responses: 1)
            _ = fixture.sample()
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        }
    }

    func testHiddenReportSeedsTombstoneAndNewPeerAloneGetsInitialReferenceAgain() {
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060, isCaptureActive: false)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        fixture.peer = 2
        _ = fixture.sample(rtt: 0.060, sequence: 1)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, 1)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .provisionalHealthy)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.060)
    }

    func testSynchronousHideEpochRevokesHealthBeforeAnyInactiveReport() throws {
        var fixture = audioPriorityFixture()
        _ = fixture.sample(bandwidth: 486_001)
        _ = fixture.sample(bandwidth: 950_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)
        let sequence = fixture.policy.lastConsumedCollectionSequence
        let baseline = fixture.policy.roundTripTimeBaselineSeconds
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        let probeCap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps

        // Exact policy composition at the service's synchronous Hide boundary: RTT authorization
        // is revoked, then the existing statistics epoch clears partial qualification evidence.
        fixture.policy.invalidateRoundTripTimeObservation()
        fixture.policy.resetIncompleteEvidenceWindow()
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, sequence)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, probeCap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)

        // No inactive report is inserted: these model a rapid Show with cached native RTT.
        for _ in 0..<2 {
            _ = fixture.sample(bandwidth: 950_000)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        }
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample(bandwidth: 950_000)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)
        XCTAssertEqual(fixture.sample(bandwidth: 950_000)?.tier, .survival)
        XCTAssertLessThan(fixture.now, deadline)
    }

    func testSynchronousHideDoesNotReplayInflatedWatermarkOrEraseReference() {
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.currentTier, .high)
        fixture.policy.invalidateRoundTripTimeObservation()
        fixture.policy.resetIncompleteEvidenceWindow()
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.policy.currentTier, .high)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertFalse(fixture.policy.lastSampleHasLatencyPressure)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
        fixture.advanceWatermark(total: 0.060, responses: 1)
        XCTAssertEqual(fixture.sample(rtt: 0.060)?.tier, .balanced)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
    }

    func testHideBeforeFirstObservationRevokesInitialReferencePrivilegeForSamePeer() {
        var fixture = RTTFixture()
        fixture.policy.bind(toPeerGeneration: 1)
        fixture.policy.invalidateRoundTripTimeObservation()
        fixture.policy.resetIncompleteEvidenceWindow()
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .reseeded)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        fixture.advanceWatermark(total: 0.005, responses: 1)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.005)
    }

    func testSynchronousHidePreservesLegacyAutomaticResumeFailureRestoration() {
        var fixture = audioPriorityFixture()
        _ = fixture.sample(bandwidth: 486_001)
        _ = fixture.sample(bandwidth: 100_000)
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        let failures = fixture.policy.applicationLimitedProbeFailureCount
        let cooldown = fixture.policy.applicationLimitedProbeCooldownSamplesRemaining
        let baseline = fixture.policy.roundTripTimeBaselineSeconds
        XCTAssertGreaterThan(failures, 0)
        XCTAssertGreaterThan(cooldown, 0)
        fixture.policy.automaticResumeAttemptBegan()
        XCTAssertFalse(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        fixture.policy.invalidateRoundTripTimeObservation()
        fixture.policy.resetIncompleteEvidenceWindow()
        fixture.policy.automaticResumeAttemptFailed()
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, failures)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, cooldown)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
    }

    func testColdStartProbeStillCommitsAfterTwoQualifiedBWEsWithOneRTTMeasurement() {
        for cadence in [500, 1_000] {
            var fixture = audioPriorityFixture(cadence: cadence)
            // Start at the current 486,001 bps ceiling so the bounded probe raises it to
            // 972,002 bps. A genuinely observed 950 kbps then fits inside that probe and exceeds
            // survival's ordinary 905,041 bps cap, exercising a real continuity lease.
            _ = fixture.sample(bandwidth: 486_001, afterMilliseconds: cadence)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, 972_002)
            XCTAssertEqual(fixture.policy.recommendation(for: .survival).maximumTotalRTPBitrateBps, 905_041)
            let probeStartedAt = fixture.now
            _ = fixture.sample(bandwidth: 950_000, afterMilliseconds: cadence)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
            XCTAssertEqual(fixture.sample(bandwidth: 950_000, afterMilliseconds: cadence)?.tier, .survival)
            XCTAssertEqual(probeStartedAt.duration(to: fixture.now), .milliseconds(cadence * 2))
            XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
            XCTAssertEqual(fixture.policy.promotionCapacityContinuity?.maximumTotalRTPBitrateBps, 950_000)
            XCTAssertEqual(fixture.policy.promotionCapacityContinuity?.deadline, fixture.now.advanced(by: .seconds(2)))
        }
    }

    func testColdStartCannotProbeWithoutAdvancingLowQueueOrTwoQualifiedBWEs() {
        var fixture = RTTFixture()
        _ = fixture.sample(bandwidth: 100_000, afterMilliseconds: 0)
        _ = fixture.sample(bandwidth: 400_000, advancesPackets: false)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(bandwidth: 400_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority)
        _ = fixture.sample(bandwidth: 700_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)
        _ = fixture.sample(bandwidth: nil)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
        _ = fixture.sample(bandwidth: 700_000)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.sample(bandwidth: 700_000)?.tier, .survival)
    }

    func testFreshQueueAndBandwidthEmergenciesRemainIndependentOfDuplicateRTT() {
        for queueDelay in [0.110, 0.250] {
            var fixture = fullFixture()
            fixture.advanceWatermark(total: 0.060, responses: 1)
            _ = fixture.sample(rtt: 0.060)
            _ = fixture.sample(rtt: 0.060, queueDelay: queueDelay)
            if queueDelay < 0.200 {
                XCTAssertEqual(fixture.policy.currentTier, .high)
                _ = fixture.sample(rtt: 0.060, queueDelay: queueDelay)
            }
            XCTAssertEqual(fixture.policy.currentTier, .balanced)
            XCTAssertTrue(fixture.policy.lastSampleHasLatencyPressure)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedInflated)
        }
        var fixture = fullFixture()
        fixture.advanceWatermark(total: 0.060, responses: 1)
        _ = fixture.sample(rtt: 0.060)
        XCTAssertEqual(fixture.sample(bandwidth: 100_000, rtt: 0.060)?.tier, .audioPriority)
    }

    private func fullFixture(responses: UInt64 = 10) -> RTTFixture {
        var fixture = RTTFixture(responses: responses)
        _ = fixture.sample(afterMilliseconds: 0)
        _ = fixture.sample()
        XCTAssertEqual(fixture.policy.currentTier, .full)
        return fixture
    }

    private func audioPriorityFixture(cadence: Int = 500) -> RTTFixture {
        var fixture = RTTFixture()
        _ = fixture.sample(bandwidth: 100_000, afterMilliseconds: 0)
        // A provisional healthy RTT intentionally preserves the existing BWE-only debounce.
        // Two independently collected low-capacity reports, not another RTT ping, establish the
        // floor used by probe/deadline/resume tests. Do not silently assume the first one did it.
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        XCTAssertEqual(fixture.policy.bandwidthOnlyDowngradeSampleCount, 1)
        _ = fixture.sample(bandwidth: 100_000, afterMilliseconds: cadence)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedHealthy)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
        return fixture
    }

    private func measurement(pair: String, total: Double, responses: UInt64) -> WebRTCRoundTripTimeObservation {
        .measurement(.init(selectedCandidatePairFingerprint: pair, totalRoundTripTimeSeconds: total, responsesReceived: responses))
    }
}

private struct RTTFixture {
    static let pairA = String(repeating: "a", count: 64)
    static let pairB = String(repeating: "b", count: 64)
    var policy = WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60)
    var now = ContinuousClock.now
    var peer: UInt64 = 1
    var pair = pairA
    var total: Double
    var responses: UInt64
    var observation: WebRTCRoundTripTimeObservation?
    var strict = true
    private var nextSequence: UInt64 = 0
    private var packets: UInt64 = 0
    private var delay: Double = 0

    init(total: Double = 1, responses: UInt64 = 10) {
        self.total = total
        self.responses = responses
        refreshObservation()
    }

    mutating func refreshObservation() {
        observation = .measurement(.init(selectedCandidatePairFingerprint: pair, totalRoundTripTimeSeconds: total, responsesReceived: responses))
    }

    mutating func advanceWatermark(total delta: Double, responses increment: UInt64) {
        total += delta
        responses += increment
        refreshObservation()
    }

    mutating func sample(
        bandwidth: Double? = 50_000_000,
        rtt: Double? = 0.005,
        queueDelay: Double = 0.001,
        afterMilliseconds: Int = 500,
        sequence: UInt64? = nil,
        advancesPackets: Bool = true,
        isCaptureActive: Bool = true
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        now = now.advanced(by: .milliseconds(afterMilliseconds))
        nextSequence = sequence ?? (nextSequence + 1)
        if advancesPackets {
            packets += 100
            delay += queueDelay * 100
        }
        return policy.update(
            peerGeneration: peer,
            isCaptureActive: isCaptureActive,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt,
            roundTripTimeObservation: observation,
            collectionSequence: nextSequence,
            requireRoundTripTimeObservation: strict,
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: delay,
            observedAt: now
        )
    }
}
