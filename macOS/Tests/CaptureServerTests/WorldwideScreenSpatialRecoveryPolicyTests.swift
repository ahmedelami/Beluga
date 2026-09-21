import XCTest
@testable import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenSpatialRecoveryPolicyTests: XCTestCase {
    func testRecoveredModerateCapacityRestoresPixelsWithoutRearmingStartupOrRaisingCaps() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        var control = RecoveryPolicyFixture(enabled: false)
        control.sample()
        control.sample(queueDelay: 0.25)
        while control.sequence < fixture.sequence { control.sample() }
        XCTAssertTrue(fixture.policy.spatialRecoveryIsTrialActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentTier, .balanced)
        let recovery = fixture.policy.currentRecommendation
        let capacityOnly = control.policy.currentRecommendation
        XCTAssertEqual(recovery.scaleResolutionDownBy, 1)
        XCTAssertEqual(recovery.maximumFramesPerSecond, 13)
        XCTAssertEqual(recovery.maximumBitrateBps, capacityOnly.maximumBitrateBps)
        XCTAssertEqual(recovery.maximumTotalRTPBitrateBps, capacityOnly.maximumTotalRTPBitrateBps)
        fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
        fixture.sample(fullFrames: true)
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testRequestedPixelsWithoutNativeApplyOrEncodedProgressCannotConfirm() {
        for markApplied in [false, true] {
            var fixture = RecoveryPolicyFixture()
            fixture.reachTrial()
            if markApplied { fixture.policy.markSpatialRecoveryApplied(at: fixture.now) }
            for _ in 0..<7 { fixture.sample(fullFrames: true, advancesFrames: false) }
            XCTAssertFalse(fixture.policy.spatialRecoveryIsTrialActive)
            XCTAssertNotEqual(fixture.policy.spatialRecoveryPhase, "accepted")
            XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
            XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 1)
        }
    }

    func testMissingReportsExpireTrialButNotAcceptedGeometry() {
        for accepted in [false, true] {
            var fixture = RecoveryPolicyFixture()
            fixture.reachTrial()
            if accepted {
                fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
                fixture.sample(fullFrames: true)
                fixture.sample(fullFrames: true)
                XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
            }
            let previous = fixture.policy.currentRecommendation
            _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1, isCaptureActive: true,
                observedAt: fixture.now.advanced(by: .seconds(10)))
            if accepted {
                XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy,
                               previous.scaleResolutionDownBy)
                XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond,
                               previous.maximumFramesPerSecond)
                XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
                let ordinary = fixture.policy.recommendation(for: fixture.policy.currentTier)
                XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                               ordinary.maximumTotalRTPBitrateBps,
                               "Keeping pixels cannot extend the independent capacity deadline")
                XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumBitrateBps,
                                        previous.maximumBitrateBps)
            } else {
                XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
            }
        }
    }

    func testIndependentFastNegativeRetiresRecoveryWithoutCapacityProbe() {
        for negative in ["queue", "capacity", "route", "rtt"] {
            var fixture = RecoveryPolicyFixture()
            fixture.reachTrial()
            fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
            fixture.sample(fullFrames: true)
            fixture.sample(fullFrames: true)
            XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
            fixture.milliseconds += 4_000
            _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1, isCaptureActive: true, observedAt: fixture.now)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            fixture.fast(negative: negative)
            XCTAssertFalse(fixture.policy.spatialRecoveryIsTrialActive, negative)
            XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1, negative)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved, negative)
        }
    }

    func testStaleFastAndRegularReportsCannotRetireOrConfirmRecovery() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        let trial = fixture.policy.currentRecommendation
        fixture.fast(negative: "queue", staleTimestamp: true)
        XCTAssertEqual(fixture.policy.currentRecommendation, trial)
        fixture.sample(bandwidth: 100_000, queueDelay: 0.4, staleTimestamp: true)
        XCTAssertEqual(fixture.policy.currentRecommendation, trial)
        XCTAssertTrue(fixture.policy.spatialRecoveryIsTrialActive)
    }

    func testMalformedPacketDelayCannotSeedTheNextHealthyRecoveryWitness() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
        let deadline = fixture.policy.spatialRecoveryDeadline
        let recommendation = fixture.policy.currentRecommendation
        fixture.sample(fullFrames: true, packetCounters: (fixture.packets + 100, -0.001))
        fixture.sample(fullFrames: true, packetCounters: (fixture.packets + 100, 0))
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "trial",
                       "The first valid report after malformed counters establishes a baseline, not health")
        XCTAssertEqual(fixture.policy.spatialRecoveryDeadline, deadline)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
    }

    func testFastPollsCannotConsumeOrdinaryPacketIntervalForFullFrameConfirmation() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
        let deadline = fixture.policy.spatialRecoveryDeadline
        for index in 0..<2 {
            fixture.fast(negative: "healthy")
            XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "trial",
                           "A fast report cannot provide geometry confirmation")
            let fastCounters = (packets: fixture.packets, delay: fixture.delay)
            // All packets in this ordinary interval were already seen by the
            // fast poll, but the full-size encoder counter advances only here.
            fixture.sample(fullFrames: true, packetCounters: fastCounters)
            XCTAssertEqual(fixture.packets, fastCounters.packets)
            XCTAssertEqual(fixture.delay, fastCounters.delay)
            XCTAssertEqual(fixture.policy.spatialRecoveryPhase, index == 0 ? "trial" : "accepted")
            if index == 0 { XCTAssertEqual(fixture.policy.spatialRecoveryDeadline, deadline) }
        }
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 1)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testWholePairGapHoldsAcceptedRecoveryProbeUntilFreshOrdinaryEvidence() throws {
        var fixture = RecoveryPolicyFixture()
        fixture.reachAcceptedWithProbe()
        let recommendation = fixture.policy.currentRecommendation
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        fixture.sparseFast()
        XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        fixture.fast(negative: "healthy")
        XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation,
                       "Fresh fast health cannot grow a held cap or repair ordinary RTT permission")
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        fixture.sample(bandwidth: 4_000_000, fullFrames: true)
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testPreAdmissionOrdinaryGapRetainsOnlyExistingDiscoveryUntilFreshOrdinaryReport() throws {
        for enabled in [false, true] {
            var fixture = RecoveryPolicyFixture(enabled: enabled)
            fixture.reachObservingWithProbe()
            let recommendation = fixture.policy.currentRecommendation
            let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
            let probeOrigin = fixture.policy.applicationLimitedProbeOriginTier
            fixture.sample(omitFrames: true, wholePairUnavailable: true)
            XCTAssertEqual(fixture.policy.spatialRecoverySparseProbeIsHolding, enabled)
            XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
            fixture.fast(negative: "healthy")
            XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
            if enabled {
                XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "observing")
                XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
                XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, probeOrigin)
                XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
                XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
                fixture.sample(bandwidth: 4_000_000, omitFrames: true)
                XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
                XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
                XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
                XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
            } else {
                XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
                XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                             "The disabled comparison retains its preexisting failed-requalification behavior")
            }
        }
    }

    func testPreAdmissionDiscoveryHoldCannotBorrowMalformedCachedPressureOrHiddenEvidence() {
        for variant in 0..<5 {
            var fixture = RecoveryPolicyFixture()
            fixture.reachObservingWithProbe()
            switch variant {
            case 0:
                fixture.sample(omitFrames: true, packetCounters: (fixture.packets + 100, -0.001),
                               wholePairUnavailable: true)
            case 1:
                fixture.sparseFast(staleTimestamp: true)
            case 2:
                fixture.fast(negative: "queue")
            case 3:
                fixture.policy.endFloorRecoveryVisibility()
                fixture.sparseFast()
            default:
                fixture.sparseFast(observation: .measurement(.init(
                    selectedCandidatePairFingerprint: "malformed",
                    totalRoundTripTimeSeconds: 0.004, responsesReceived: 1)))
            }
            XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding, "variant \(variant)")
            XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
            if variant == 2 || variant == 4 {
                XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, "variant \(variant)")
            }
        }
    }

    func testPreAdmissionDiscoveryHoldCannotOutlivePrimaryRTTLease() throws {
        var fixture = RecoveryPolicyFixture()
        fixture.reachObservingWithProbe()
        let lastHealthyMilliseconds = fixture.milliseconds
        let retainedRTTSequence = fixture.sequence
        // Fresh ordinary packet/BWE evidence can finish this probe and begin
        // another without claiming that its retained RTT tuple is a new ping.
        for _ in 0..<4 {
            fixture.sample(bandwidth: 8_000_000, omitFrames: true,
                           retainedRTTSequence: retainedRTTSequence)
            if fixture.policy.applicationLimitedProbeOriginTier == nil { break }
        }
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        for _ in 0..<4 {
            fixture.sample(bandwidth: 8_000_000, omitFrames: true,
                           retainedRTTSequence: retainedRTTSequence)
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
        }
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        fixture.milliseconds = lastHealthyMilliseconds + 4_001 - 125
        XCTAssertGreaterThan(deadline, fixture.now.advanced(by: .milliseconds(125)))
        fixture.sparseFast()
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
    }

    func testRecoverySparseHoldRejectsPartialMalformedAndCachedReports() {
        for variant in 0..<7 {
            var fixture = RecoveryPolicyFixture()
            fixture.reachAcceptedWithProbe()
            fixture.sparseFast(
                bandwidth: variant == 0 ? 4_000_000 : nil,
                rtt: variant == 1 ? 0.004 : nil,
                observation: variant == 2 ? nil : (variant == 3
                    ? .measurement(.init(selectedCandidatePairFingerprint: "malformed",
                                         totalRoundTripTimeSeconds: 0.004, responsesReceived: 1))
                    : .unavailable),
                route: variant == 4 ? .init(kind: .direct) : nil,
                omitPackets: variant == 5,
                malformedDelay: variant == 6)
            XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding, "variant \(variant)")
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, "variant \(variant)")
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        }
        var cached = RecoveryPolicyFixture()
        cached.reachAcceptedWithProbe()
        cached.sparseFast(staleTimestamp: true)
        XCTAssertFalse(cached.policy.spatialRecoverySparseProbeIsHolding,
                       "A cached report cannot acquire whole-pair-gap authority")
    }

    func testOrdinaryWholePairGapRetainsCountersForFastRequalificationWithoutGrowth() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachAcceptedWithProbe()
        let recommendation = fixture.policy.currentRecommendation
        let deadline = fixture.policy.applicationLimitedProbeDeadline
        fixture.sample(fullFrames: true, wholePairUnavailable: true)
        XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        fixture.fast(negative: "healthy")
        XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testRepeatedOrdinaryRecoveryGapsPreserveGraceUntilExactOriginalDeadline() throws {
        var fixture = RecoveryPolicyFixture()
        fixture.reachAcceptedWithProbe()
        let recommendation = fixture.policy.currentRecommendation
        let grace = fixture.policy.applicationLimitedProbeGraceSamplesRemaining
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        for _ in 0..<3 {
            fixture.sample(fullFrames: true, wholePairUnavailable: true, elapsedMilliseconds: 100)
            XCTAssertLessThan(fixture.now, deadline)
            XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeGraceSamplesRemaining, grace,
                           "Fresh report cadence must not shorten a validated whole-gap hold")
            XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        }
        fixture.fast(negative: "healthy")
        XCTAssertLessThan(fixture.now, deadline)
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeGraceSamplesRemaining, grace)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: deadline)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testMalformedOrPartialOrdinaryReportsCannotPreserveRecoveryGapGrace() {
        for malformedPackets in [false, true] {
            var fixture = RecoveryPolicyFixture()
            fixture.reachAcceptedWithProbe()
            fixture.sparseFast()
            XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
            let grace = fixture.policy.applicationLimitedProbeGraceSamplesRemaining
            fixture.sample(
                bandwidth: nil, fullFrames: true,
                packetCounters: malformedPackets ? (fixture.packets + 100, -0.001) : nil,
                wholePairUnavailable: malformedPackets, elapsedMilliseconds: 100)
            XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
            XCTAssertLessThan(fixture.policy.applicationLimitedProbeGraceSamplesRemaining, grace,
                              "Malformed packets or a present partial pair must use existing non-hold behavior")
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        }
    }

    func testRecoverySparseHoldRejectsExpiredPrimaryLeaseBeforeLiveProbeDeadline() throws {
        var fixture = RecoveryPolicyFixture()
        fixture.reachAcceptedWithProbe()
        let lastHealthyMilliseconds = fixture.milliseconds
        let retainedRTTSequence = fixture.sequence
        // Finish this probe without renewing RTT, then let ordinary cached-but-
        // still-valid health authorize a new independent capacity probe.
        for _ in 0..<8 {
            fixture.milliseconds += 125
            _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1, isCaptureActive: true, observedAt: fixture.now)
            if fixture.policy.applicationLimitedProbeOriginTier == nil { break }
        }
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        for _ in 0..<4 {
            fixture.sample(bandwidth: 4_000_000, fullFrames: true,
                           retainedRTTSequence: retainedRTTSequence)
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
        }
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        fixture.milliseconds = lastHealthyMilliseconds + 4_001 - 125
        XCTAssertGreaterThan(deadline, fixture.now.advanced(by: .milliseconds(125)),
                             "RTT expiry, not probe expiry, must be the deciding boundary")
        fixture.sparseFast()
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
    }

    func testRecoverySparseHoldCannotRenewProbeDeadlineOrSuppressFreshPressure() throws {
        var expired = RecoveryPolicyFixture()
        expired.reachAcceptedWithProbe()
        let deadline = try XCTUnwrap(expired.policy.applicationLimitedProbeDeadline)
        expired.sparseFast()
        expired.sparseFast()
        XCTAssertEqual(expired.policy.applicationLimitedProbeDeadline, deadline)
        _ = expired.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: deadline)
        XCTAssertNil(expired.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(expired.policy.spatialRecoverySparseProbeIsHolding)
        for negative in ["queue", "capacity", "route", "rtt"] {
            var fixture = RecoveryPolicyFixture()
            fixture.reachAcceptedWithProbe()
            fixture.sparseFast()
            fixture.fast(negative: negative)
            XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding, negative)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, negative)
            XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "cooldown", negative)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        }
    }

    func testRecoverySparseHoldDoesNotSurviveHideOrSuccessorShow() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachAcceptedWithProbe()
        fixture.sparseFast()
        XCTAssertTrue(fixture.policy.spatialRecoverySparseProbeIsHolding)
        fixture.policy.endFloorRecoveryVisibility()
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2, at: fixture.now)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        fixture.sparseFast()
        XCTAssertFalse(fixture.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
    }

    func testFastPacketResetCannotPreserveAnOrdinaryConfirmationWitnessThroughNeutralPoll() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
        let deadline = fixture.policy.spatialRecoveryDeadline
        let recommendation = fixture.policy.currentRecommendation
        fixture.sample(fullFrames: true)
        fixture.fast(negative: "none", packetCounters: (0, 0))
        fixture.sample(fullFrames: true, advancesFrames: false, packetCounters: (0, 0))
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "trial",
                       "A reset observed by the fast lane must clear the preceding ordinary witness")
        XCTAssertEqual(fixture.policy.spatialRecoveryDeadline, deadline)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, recommendation.scaleResolutionDownBy)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, recommendation.maximumFramesPerSecond)
        XCTAssertEqual(fixture.policy.currentRecommendation.tier, recommendation.tier)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                     "Recovery cannot preserve a capacity probe invalidated by its own reset guard")
        let ordinary = fixture.policy.recommendation(for: fixture.policy.currentTier)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, ordinary.maximumTotalRTPBitrateBps)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
    }

    func testFastCounterResetCannotBridgeARepairedOrdinaryCounterEpoch() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
        let deadline = fixture.policy.spatialRecoveryDeadline
        fixture.sample(fullFrames: true)
        let previousCounters = (packets: fixture.packets, delay: fixture.delay)
        fixture.fast(negative: "healthy", packetCounters: (0, 0))
        fixture.sample(fullFrames: true, advancesFrames: false, packetCounters: previousCounters)
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "trial",
                       "A repaired counter tuple cannot bridge the reset seen by the other lane")
        XCTAssertEqual(fixture.policy.spatialRecoveryDeadline, deadline)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        fixture.sample(fullFrames: true)
        XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
    }

    func testDisabledCandidateAndMissingFrameEvidenceNeverAcquireRecovery() {
        for enabled in [false, true] {
            var fixture = RecoveryPolicyFixture(enabled: enabled)
            fixture.sample()
            fixture.sample(queueDelay: 0.25)
            for _ in 0..<30 { fixture.sample(omitFrames: true) }
            XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
            XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        }
    }

    func testHideAndSuccessorShowDoNotInheritFailedApplyTombstone() {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        let predecessor = fixture.policy
        fixture.policy.endFloorRecoveryVisibility()
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2, at: fixture.now)
        fixture.policy.retainSpatialRecoveryAttemptConsumption(from: predecessor)
        fixture.policy.retainSpatialRecoveryTerminalState(from: predecessor)
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
        XCTAssertFalse(fixture.policy.spatialRecoveryIsTrialActive)
    }

    func testFailedNativeApplyRetainsAttemptAndNeverInstallsPositiveGeometry() throws {
        var fixture = RecoveryPolicyFixture()
        fixture.reachTrial()
        var committed = try XCTUnwrap(fixture.beforeAdmission)
        let previous = committed.currentRecommendation
        committed.retainSpatialRecoveryAttemptConsumption(from: fixture.policy)
        XCTAssertEqual(committed.spatialRecoveryAttemptCount, 1)
        XCTAssertEqual(committed.currentRecommendation, previous)
        XCTAssertFalse(committed.spatialRecoveryIsTrialActive)
        fixture.policy.rejectPendingSpatialRecoveryApplication(at: fixture.now)
        committed.retainSpatialRecoveryTerminalState(from: fixture.policy)
        XCTAssertEqual(committed.spatialRecoveryPhase, "cooldown")
        XCTAssertEqual(committed.currentRecommendation, previous)
        fixture.policy = committed
        for _ in 0..<10 { fixture.sample() }
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 1,
                       "Rejected native calls must not turn statistics into a retry loop")
    }

    func testRecoveryRespectsSourceFPSAndExplicitLowCaps() {
        for fps in [1, 3, 5, 10, 24, 60, 120] {
            var fixture = RecoveryPolicyFixture(fps: fps)
            fixture.reachTrial()
            XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, fps)
            XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 13)
        }
        for cap in [1, 100_000, 500_000, 1_000_000, 8_000_000] {
            var fixture = RecoveryPolicyFixture(cap: cap)
            for _ in 0..<25 { fixture.sample(bandwidth: 50_000_000) }
            XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, 0)
            XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, cap)
        }
    }

    func testRecordedTransientLowCapacityRetainsAcceptedSurvivalPixelsUntilProbeExpiryAndRebound() throws {
        var fixture = RecoveryPolicyFixture()
        try fixture.reachAcceptedSurvivalProbe()
        let attempt = fixture.policy.spatialRecoveryAttemptCount
        try fixture.replayRecordedSurvivalLowCapacityThroughExpiry()
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 905_041)
        fixture.sample(bandwidth: 767_589, queueDelay: 0.024633580645,
                       fullFrames: true, elapsedMilliseconds: 0,
                       elapsedNanoseconds: 503_811_333)
        fixture.assertAcceptedSurvival()
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline)
        XCTAssertNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 905_041)
        XCTAssertEqual(fixture.policy.spatialRecoveryAttemptCount, attempt)
        XCTAssertEqual(fixture.policy.bandwidthOnlyDowngradeSampleCount, 0)
        fixture.assertCaptureRemainsVisible()
    }

    func testPersistentLowCapacityAfterProbeExpiryRetiresAcceptedSurvivalPixels() throws {
        var expired = RecoveryPolicyFixture()
        try expired.reachAcceptedSurvivalProbe()
        try expired.replayRecordedSurvivalLowCapacityThroughExpiry()
        let attempt = expired.policy.spatialRecoveryAttemptCount
        let ordinaryCap = expired.policy.currentRecommendation.maximumTotalRTPBitrateBps

        // These are alternate continuations, not modifications of the native RED result.
        for interruption in ["stale", "missing", "rebound"] {
            var interrupted = expired
            interrupted.sample(bandwidth: 482_502, queueDelay: 0.010375444444, fullFrames: true)
            interrupted.assertAcceptedSurvival()
            XCTAssertEqual(interrupted.policy.bandwidthOnlyDowngradeSampleCount, 1)
            interrupted.sample(
                bandwidth: interruption == "missing" ? nil
                    : (interruption == "rebound" ? 767_589 : 482_502),
                queueDelay: interruption == "rebound" ? 0.024633580645 : 0.010375444444,
                fullFrames: true, staleTimestamp: interruption == "stale")
            interrupted.assertAcceptedSurvival()
            XCTAssertEqual(interrupted.policy.bandwidthOnlyDowngradeSampleCount,
                           interruption == "stale" ? 1 : 0, interruption)
            XCTAssertNil(interrupted.policy.applicationLimitedProbeOriginTier, interruption)
            XCTAssertEqual(interrupted.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                           ordinaryCap, interruption)
            interrupted.assertCaptureRemainsVisible()
        }

        // Only two fresh, positively healthy ordinary reports after retirement
        // establish persistent sub-survival capacity. Fast polls do not stand in for them.
        expired.sample(bandwidth: 482_502, queueDelay: 0.010375444444, fullFrames: true)
        expired.assertAcceptedSurvival()
        XCTAssertEqual(expired.policy.bandwidthOnlyDowngradeSampleCount, 1)
        XCTAssertEqual(expired.policy.roundTripTimeDisposition, .freshHealthy)
        expired.sample(bandwidth: 482_502, queueDelay: 0.010375444444, fullFrames: true)
        XCTAssertEqual(expired.policy.currentTier, .emergency)
        XCTAssertEqual(expired.policy.spatialRecoveryPhase, "cooldown")
        XCTAssertGreaterThan(expired.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertNil(expired.policy.applicationLimitedProbeOriginTier)
        XCTAssertNil(expired.policy.applicationLimitedProbeDeadline)
        XCTAssertLessThanOrEqual(expired.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                                 ordinaryCap)
        XCTAssertEqual(expired.policy.spatialRecoveryAttemptCount, attempt)
        XCTAssertTrue(expired.policy.startupSpatialModeIsDisproved)
        expired.assertCaptureRemainsVisible()
    }

    func testIndependentPressureDuringAcceptedSurvivalProbeRequiresFreshEvidence() throws {
        var admitted = RecoveryPolicyFixture()
        try admitted.reachAcceptedSurvivalProbe()
        let deadline = try XCTUnwrap(admitted.policy.applicationLimitedProbeDeadline)
        let recommendation = admitted.policy.currentRecommendation
        let attempt = admitted.policy.spatialRecoveryAttemptCount

        var missing = admitted
        missing.sparseFast()
        missing.assertAcceptedSurvival()
        XCTAssertTrue(missing.policy.spatialRecoverySparseProbeIsHolding)
        XCTAssertEqual(missing.policy.currentRecommendation, recommendation)
        XCTAssertEqual(missing.policy.applicationLimitedProbeDeadline, deadline)

        for pressure in ["queue", "rtt", "collapse"] {
            var stale = admitted
            stale.fast(negative: pressure == "rtt" ? "rtt" : "healthy",
                       staleTimestamp: true,
                       bandwidth: pressure == "collapse" ? 359_999 : 818_666,
                       queueDelay: pressure == "queue" ? 0.150 : 0.001)
            stale.assertAcceptedSurvival()
            XCTAssertEqual(stale.policy.currentRecommendation, recommendation, pressure)
            XCTAssertEqual(stale.policy.applicationLimitedProbeDeadline, deadline, pressure)

            var fresh = admitted
            fresh.fast(negative: pressure == "rtt" ? "rtt" : "healthy",
                       bandwidth: pressure == "collapse" ? 359_999 : 818_666,
                       queueDelay: pressure == "queue" ? 0.150 : 0.001)
            if pressure == "queue" {
                fresh.assertAcceptedSurvival()
                XCTAssertEqual(fresh.policy.currentRecommendation, recommendation)
                XCTAssertEqual(fresh.policy.applicationLimitedProbeDeadline, deadline)
                var staleSecond = fresh
                staleSecond.fast(negative: "healthy", staleTimestamp: true,
                                 bandwidth: 818_666, queueDelay: 0.150)
                staleSecond.assertAcceptedSurvival()
                XCTAssertEqual(staleSecond.policy.applicationLimitedProbeDeadline, deadline)
                fresh.fast(negative: "healthy", bandwidth: 818_666, queueDelay: 0.150)
            }
            XCTAssertNotEqual(fresh.policy.spatialRecoveryPhase, "accepted", pressure)
            XCTAssertGreaterThan(fresh.policy.currentRecommendation.scaleResolutionDownBy, 1, pressure)
            XCTAssertNil(fresh.policy.applicationLimitedProbeOriginTier, pressure)
            XCTAssertNil(fresh.policy.applicationLimitedProbeDeadline, pressure)
            XCTAssertLessThan(fresh.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                              recommendation.maximumTotalRTPBitrateBps, pressure)
            XCTAssertEqual(fresh.policy.spatialRecoveryAttemptCount, attempt, pressure)
            XCTAssertTrue(fresh.policy.startupSpatialModeIsDisproved, pressure)
            fresh.assertCaptureRemainsVisible()
        }
    }
}

private struct RecoveryPolicyFixture {
    var policy: WorldwideScreenVideoAdaptationPolicy
    let origin = ContinuousClock.now
    var milliseconds = 0
    var additionalNanoseconds: Int64 = 0
    var sequence: UInt64 = 0
    var packets: UInt64 = 0
    var frames: UInt64 = 0
    var delay = 0.0
    var beforeAdmission: WorldwideScreenVideoAdaptationPolicy?
    var now: ContinuousClock.Instant {
        origin.advanced(by: .milliseconds(milliseconds)).advanced(by: .nanoseconds(additionalNanoseconds))
    }
    private var nativeTimestamp: Double {
        Double(milliseconds) * 1_000 + Double(additionalNanoseconds) / 1_000
    }

    init(enabled: Bool = true, fps: Int = 60, cap: Int = 50_000_000) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: cap, baseFramesPerSecond: fps,
            spatialRecoveryEnabled: enabled)
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1, at: origin)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
    }

    mutating func reachTrial(file: StaticString = #filePath, line: UInt = #line) {
        sample()
        sample(queueDelay: 0.25)
        XCTAssertTrue(policy.startupSpatialModeIsDisproved, file: file, line: line)
        for _ in 0..<40 {
            let preceding = policy
            sample()
            if policy.spatialRecoveryIsTrialActive {
                beforeAdmission = preceding
                break
            }
        }
        XCTAssertTrue(policy.spatialRecoveryIsTrialActive,
                      "phase=\(policy.spatialRecoveryPhase) tier=\(policy.currentTier)", file: file, line: line)
    }

    mutating func reachObservingWithProbe(file: StaticString = #filePath, line: UInt = #line) {
        sample(bandwidth: 4_000_000)
        sample(bandwidth: 4_000_000, queueDelay: 0.25)
        for _ in 0..<16 {
            sample(bandwidth: 4_000_000, omitFrames: true)
            if policy.applicationLimitedProbeOriginTier != nil { break }
        }
        XCTAssertNotNil(policy.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertEqual(policy.spatialRecoveryAttemptCount, 0, file: file, line: line)
        XCTAssertTrue(policy.startupSpatialModeIsDisproved, file: file, line: line)
    }

    mutating func reachAcceptedWithProbe(file: StaticString = #filePath, line: UInt = #line) {
        reachObservingWithProbe(file: file, line: line)
        for _ in 0..<6 {
            sample(bandwidth: 4_000_000)
            if policy.spatialRecoveryIsTrialActive { break }
        }
        XCTAssertTrue(policy.spatialRecoveryIsTrialActive, file: file, line: line)
        policy.markSpatialRecoveryApplied(at: now)
        // Geometry confirmation is not capacity qualification. These healthy,
        // non-pressure reports retain the independent probe without promoting it.
        sample(bandwidth: 4_000_000, queueDelay: 0.055, fullFrames: true)
        sample(bandwidth: 4_000_000, queueDelay: 0.055, fullFrames: true)
        XCTAssertEqual(policy.spatialRecoveryPhase, "accepted", file: file, line: line)
        XCTAssertNotNil(policy.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertTrue(policy.startupSpatialModeIsDisproved, file: file, line: line)
    }

    mutating func reachAcceptedSurvivalProbe(file: StaticString = #filePath, line: UInt = #line) throws {
        sample(bandwidth: 818_666)
        sample(bandwidth: 818_666, queueDelay: 0.25)
        for _ in 0..<12 {
            sample(bandwidth: 818_666)
            if policy.spatialRecoveryIsTrialActive { break }
        }
        XCTAssertEqual(policy.currentTier, .survival, file: file, line: line)
        XCTAssertTrue(policy.spatialRecoveryIsTrialActive, file: file, line: line)
        policy.markSpatialRecoveryApplied(at: now)
        sample(bandwidth: 818_666, queueDelay: 0.055, fullFrames: true)
        sample(bandwidth: 818_666, queueDelay: 0.055, fullFrames: true)
        assertAcceptedSurvival(file: file, line: line)

        // Earn a separately owned, full-duration discovery window after acceptance.
        // Expiry is a production entrypoint; no reducer state or native acceptance is reset.
        milliseconds += 4_000
        _ = policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: now)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier, file: file, line: line)
        for _ in 0..<6 {
            sample(bandwidth: 818_666, fullFrames: true)
            if policy.applicationLimitedProbeOriginTier != nil { break }
        }
        let deadline = try XCTUnwrap(policy.applicationLimitedProbeDeadline, file: file, line: line)
        XCTAssertEqual(now.duration(to: deadline), .milliseconds(3_500), file: file, line: line)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival, file: file, line: line)
        XCTAssertNil(policy.applicationLimitedProbeConfirmedTier, file: file, line: line)
        let ordinaryRTTSequence = sequence
        fast(negative: "healthy", bandwidth: 1_560_727,
             retainedRTTSequence: ordinaryRTTSequence)
        XCTAssertEqual(policy.applicationLimitedProbeDeadline, deadline, file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.maximumTotalRTPBitrateBps, 3_121_454,
                       file: file, line: line)
        assertAcceptedSurvival(file: file, line: line)
    }

    mutating func replayRecordedSurvivalLowCapacityThroughExpiry(
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let deadline = try XCTUnwrap(policy.applicationLimitedProbeDeadline, file: file, line: line)
        let cap = policy.currentRecommendation.maximumTotalRTPBitrateBps
        let attempt = policy.spatialRecoveryAttemptCount
        // Native ordinary offsets from the 13,597.286750-ms probe admission.
        // BWE, queue delays and spacing are recorded; monotonic packet/frame/RTT
        // counters are deterministic witnesses, not simulated native acceptance.
        let rows: [(offset: Int64, bandwidth: Double, queue: Double, freshRTT: Bool)] = [
            (503_846_417, 773_103, 0.005163265, false),
            (1_006_871_500, 541_325, 0.006810521739, false),
            (1_510_146_375, 482_502, 0.028841714286, true),
            (2_019_310_292, 482_502, 0.016524142857, false),
            (2_522_223_667, 482_502, 0.01585235, false),
            (3_025_562_834, 482_502, 0.024691260870, false),
            (3_528_323_292, 482_502, 0.010375444444, false)
        ]
        var precedingOffset: Int64 = 125_000_000 // The already-admitted fast growth report.
        var rttSequence = sequence - 1
        var ordinaryPackets = packets - 10
        var ordinaryDelay = delay - 0.01
        for row in rows {
            ordinaryPackets += 100
            ordinaryDelay += row.queue * 100
            if row.freshRTT { rttSequence = sequence + 1 }
            sample(bandwidth: row.bandwidth, fullFrames: true,
                   packetCounters: (ordinaryPackets, ordinaryDelay), retainedRTTSequence: rttSequence,
                   elapsedMilliseconds: 0, elapsedNanoseconds: row.offset - precedingOffset)
            precedingOffset = row.offset
            assertAcceptedSurvival(file: file, line: line)
            XCTAssertFalse(policy.lastSampleHasLatencyPressure, file: file, line: line)
            XCTAssertEqual(policy.spatialRecoveryAttemptCount, attempt, file: file, line: line)
            XCTAssertEqual(policy.lastAveragePacketSendDelaySeconds ?? -1, row.queue,
                           accuracy: 0.000000001, file: file, line: line)
            XCTAssertEqual(policy.roundTripTimeDisposition,
                           row.freshRTT ? .freshHealthy : .retainedHealthy, file: file, line: line)
            if now < deadline {
                XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .survival, file: file, line: line)
                XCTAssertEqual(policy.applicationLimitedProbeDeadline, deadline, file: file, line: line)
                XCTAssertEqual(policy.currentRecommendation.maximumTotalRTPBitrateBps, cap,
                               file: file, line: line)
            } else {
                XCTAssertNil(policy.applicationLimitedProbeOriginTier, file: file, line: line)
                XCTAssertNil(policy.applicationLimitedProbeDeadline, file: file, line: line)
                XCTAssertEqual(policy.currentRecommendation.maximumTotalRTPBitrateBps, 905_041,
                               file: file, line: line)
                XCTAssertEqual(policy.bandwidthOnlyDowngradeSampleCount, 0, file: file, line: line)
            }
            assertCaptureRemainsVisible(file: file, line: line)
        }
    }

    func assertAcceptedSurvival(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(policy.currentTier, .survival, file: file, line: line)
        XCTAssertEqual(policy.spatialRecoveryPhase, "accepted", file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.scaleResolutionDownBy, 1, file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 5, file: file, line: line)
        XCTAssertTrue(policy.startupSpatialModeIsDisproved, file: file, line: line)
        XCTAssertFalse(policy.startupSpatialModeIsActive, file: file, line: line)
    }

    mutating func assertCaptureRemainsVisible(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(policy.currentRecommendation.maximumFramesPerSecond, 0, file: file, line: line)
        XCTAssertNil(policy.automaticSuspensionDecision(
            isCaptureActive: true, isAutomaticallySuspended: false), file: file, line: line)
    }

    mutating func sample(
        bandwidth: Double? = 8_000_000, queueDelay: Double = 0.001,
        fullFrames: Bool = false, advancesFrames: Bool = true,
        omitFrames: Bool = false, staleTimestamp: Bool = false,
        packetCounters: (packets: UInt64, delay: Double)? = nil,
        retainedRTTSequence: UInt64? = nil, wholePairUnavailable: Bool = false,
        elapsedMilliseconds: Int = 500, elapsedNanoseconds: Int64 = 0
    ) {
        milliseconds += elapsedMilliseconds
        additionalNanoseconds += elapsedNanoseconds
        sequence += 1
        packets = packetCounters?.packets ?? (packets + 100)
        delay = packetCounters?.delay ?? (delay + queueDelay * 100)
        if advancesFrames { frames += 10 }
        _ = policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: wholePairUnavailable ? nil : bandwidth,
            currentRoundTripTimeSeconds: wholePairUnavailable ? nil : 0.004,
            roundTripTimeObservation: wholePairUnavailable ? .unavailable
                : observation(sequence: retainedRTTSequence), collectionSequence: sequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: wholePairUnavailable ? nil : WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: packets, outboundVideoTotalPacketSendDelaySeconds: delay,
            nativeReportTimestampMicroseconds: staleTimestamp ? 1 : nativeTimestamp,
            spatialRecoveryFrames: omitFrames ? nil : .init(
                encodedFrames: frames, encodedWidth: fullFrames ? 1080 : 720,
                encodedHeight: fullFrames ? 1920 : 1280, sourceWidth: 1080, sourceHeight: 1920),
            observedAt: now)
    }

    mutating func fast(
        negative: String, staleTimestamp: Bool = false,
        packetCounters: (packets: UInt64, delay: Double)? = nil,
        bandwidth: Double? = nil, queueDelay: Double? = nil,
        retainedRTTSequence: UInt64? = nil
    ) {
        milliseconds += 125
        sequence += 1
        packets = packetCounters?.packets ?? (packets + 10)
        delay = packetCounters?.delay
            ?? (delay + (queueDelay.map { $0 * 10 } ?? (negative == "queue" ? 3 : 0.01)))
        _ = policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth ?? (negative == "capacity" ? 100_000
                : (negative == "healthy" ? 8_000_000 : nil)),
            currentRoundTripTimeSeconds: negative == "rtt" ? 0.8
                : (["none", "healthy"].contains(negative) ? 0.004 : nil),
            roundTripTimeObservation: negative == "rtt" ? observation(rtt: 0.8)
                : (["none", "healthy"].contains(negative)
                    ? observation(sequence: retainedRTTSequence) : .unavailable),
            collectionSequence: sequence,
            nativeReportTimestampMicroseconds: staleTimestamp ? 1 : nativeTimestamp,
            selectedRoute: negative == "route" ? .init(kind: .relayed)
                : (negative == "healthy" ? .init(kind: .direct) : nil),
            outboundVideoPacketsSent: packets, outboundVideoTotalPacketSendDelaySeconds: delay,
            observedAt: now)
    }

    mutating func sparseFast(
        bandwidth: Double? = nil, rtt: Double? = nil,
        observation: WebRTCRoundTripTimeObservation? = .unavailable,
        route: WebRTCICERouteDiagnostics? = nil,
        omitPackets: Bool = false, malformedDelay: Bool = false,
        staleTimestamp: Bool = false
    ) {
        milliseconds += 125
        sequence += 1
        packets += 10
        delay += 0.01
        _ = policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: rtt,
            roundTripTimeObservation: observation, collectionSequence: sequence,
            nativeReportTimestampMicroseconds: staleTimestamp ? 1 : nativeTimestamp,
            selectedRoute: route,
            outboundVideoPacketsSent: omitPackets ? nil : packets,
            outboundVideoTotalPacketSendDelaySeconds: malformedDelay ? -0.001 : delay,
            observedAt: now)
    }

    private func observation(rtt: Double = 0.004, sequence: UInt64? = nil) -> WebRTCRoundTripTimeObservation {
        let count = sequence ?? self.sequence
        return .measurement(.init(selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                                 totalRoundTripTimeSeconds: Double(count) * rtt,
                                 responsesReceived: count))
    }
}
