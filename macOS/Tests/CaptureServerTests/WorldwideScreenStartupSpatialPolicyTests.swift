import XCTest
@testable import WebRTCTransport
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

    func testCachedDiagnosticRouteCannotTurnMissingNativeEvidenceIntoAReplacement() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        let original = fixture.policy.currentRecommendation
        // Native candidate stats and delegate SDP metadata can differ even on the same path.
        // The missing native report must not inherit that difference as a new route event.
        let cachedDiagnosticRoute = WebRTCICERouteDiagnostics(
            kind: .direct,
            local: WebRTCCandidateDiagnostics(type: .host, transport: "udp"),
            remote: WebRTCCandidateDiagnostics(type: .host, transport: "udp"))
        let report = WebRTCScreenVideoStatisticsReport(
            snapshot: WebRTCStatisticsSnapshot(collectionSequence: 2,
                roundTripTimeObservation: .unavailable,
                outboundVideo: WebRTCVideoStatistics(packets: 200,
                    totalPacketSendDelay: 0.2)),
            nativeReportTimestampMicroseconds: 1_500_000
        ).restoringRouteIfNeeded(cachedDiagnosticRoute)
        XCTAssertNotEqual(report.snapshot.route, fixture.policy.selectedRoute)
        XCTAssertNil(report.nativeSnapshot.route)
        let evidence = report.nativeSnapshot
        _ = fixture.policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: evidence.availableOutgoingBitrate,
            currentRoundTripTimeSeconds: evidence.currentRoundTripTime,
            roundTripTimeObservation: evidence.roundTripTimeObservation,
            collectionSequence: evidence.collectionSequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: evidence.route,
            outboundVideoPacketsSent: evidence.outboundVideo?.packets,
            outboundVideoTotalPacketSendDelaySeconds: evidence.outboundVideo?.totalPacketSendDelay,
            nativeReportTimestampMicroseconds: report.nativeReportTimestampMicroseconds,
            observedAt: fixture.origin.advanced(by: .milliseconds(500)))
        XCTAssertEqual(fixture.policy.currentRecommendation, original)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
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
                let expectedFPS: Int
                switch recommendation.tier {
                case .high: expectedFPS = 28
                case .balanced: expectedFPS = 13
                default: expectedFPS = 5
                }
                XCTAssertEqual(recommendation.maximumFramesPerSecond, expectedFPS)
                sawIntermediate = sawIntermediate || recommendation.tier.rawValue <
                    WorldwideScreenVideoAdaptationTier.survival.rawValue
            }
        }
        XCTAssertTrue(sawIntermediate)
        XCTAssertEqual(fixture.policy.currentTier, .full)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 60)
    }

    func testQualifiedModerateBandwidthDoesNotFreezeMotionAtColdStartFPS() {
        let cases: [(Double, WorldwideScreenVideoAdaptationTier, Int)] = [
            (3_000_000, .constrained, 5),
            (6_000_000, .balanced, 13),
            (9_000_000, .high, 28),
        ]
        for (bandwidth, expectedTier, expectedFPS) in cases {
            var fixture = SpatialFixture()
            for time in stride(from: 0, through: 10_000, by: 500) {
                _ = fixture.sample(at: time, bandwidth: bandwidth)
                if fixture.policy.currentTier == expectedTier,
                   fixture.policy.applicationLimitedProbeOriginTier == nil {
                    break
                }
            }
            let recommendation = fixture.policy.currentRecommendation
            print("STARTUP_SPATIAL_PLATEAU bandwidth=\(Int(bandwidth)) tier=\(recommendation.tier) "
                  + "fps=\(recommendation.maximumFramesPerSecond) scale=\(recommendation.scaleResolutionDownBy)")
            XCTAssertEqual(recommendation.tier, expectedTier)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(recommendation.scaleResolutionDownBy, 1)
            XCTAssertEqual(recommendation.maximumFramesPerSecond, expectedFPS)
            let ordinary = fixture.policy.recommendation(for: expectedTier)
            XCTAssertEqual(recommendation.maximumBitrateBps,
                           ordinary.maximumBitrateBps)
            XCTAssertEqual(recommendation.maximumTotalRTPBitrateBps,
                           ordinary.maximumTotalRTPBitrateBps)
            XCTAssertLessThanOrEqual(
                Double(recommendation.maximumFramesPerSecond),
                Double(ordinary.maximumFramesPerSecond) /
                    (ordinary.scaleResolutionDownBy * ordinary.scaleResolutionDownBy))
        }
    }

    func testQualifiedSpatialFPSRetainsOnMissingBWEAndRetiresOnConfirmedPressure() {
        for usesQueuePressure in [false, true] {
            var fixture = SpatialFixture()
            var plateauTime = 0
            for time in stride(from: 0, through: 10_000, by: 500) {
                _ = fixture.sample(at: time, bandwidth: 9_000_000)
                plateauTime = time
                if fixture.policy.currentTier == .high,
                   fixture.policy.applicationLimitedProbeOriginTier == nil {
                    break
                }
            }
            let qualified = fixture.policy.currentRecommendation
            XCTAssertEqual(qualified.tier, .high)
            XCTAssertEqual(qualified.maximumFramesPerSecond, 28)
            XCTAssertEqual(qualified.scaleResolutionDownBy, 1)

            _ = fixture.sample(at: plateauTime + 500, bandwidth: nil)
            XCTAssertEqual(fixture.policy.currentRecommendation, qualified,
                           "Missing BWE must neither invent more FPS nor blur qualified pixels")
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)

            if usesQueuePressure {
                _ = fixture.sample(at: plateauTime + 1_000,
                                   bandwidth: 9_000_000, queueDelay: 0.250)
            } else {
                _ = fixture.sample(at: plateauTime + 1_000, bandwidth: 100_000)
                _ = fixture.sample(at: plateauTime + 1_500, bandwidth: 100_000)
            }

            XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
            XCTAssertEqual(
                fixture.policy.currentRecommendation,
                fixture.policy.recommendation(for: fixture.policy.currentTier),
                "Confirmed pressure must restore the ordinary tier geometry and FPS"
            )
        }
    }

    func testQualifiedSpatialFPSRespectsTheConfiguredSourceFrameRate() {
        for baseFPS in [1, 3, 10, 24, 60] {
            var fixture = SpatialFixture(baseFramesPerSecond: baseFPS)
            XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond,
                           min(5, baseFPS))
            for time in stride(from: 0, through: 10_000, by: 500) {
                _ = fixture.sample(at: time, bandwidth: 9_000_000)
            }
            let recommendation = fixture.policy.currentRecommendation
            XCTAssertEqual(recommendation.tier, .high)
            let ordinaryFPS = min(baseFPS, 45)
            let expectedFPS = min(ordinaryFPS, max(min(5, ordinaryFPS),
                Int((Double(ordinaryFPS) / (1.25 * 1.25)).rounded(.down))))
            XCTAssertEqual(recommendation.maximumFramesPerSecond, expectedFPS)
            XCTAssertLessThanOrEqual(recommendation.maximumFramesPerSecond, baseFPS)
            XCTAssertEqual(recommendation.scaleResolutionDownBy, 1)
        }
    }

    func testSparseFastSelectedPairWithholdsGrowthWithoutRestartingDiscovery() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500)
        let origin = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        let recommendation = fixture.policy.currentRecommendation
        let failures = fixture.policy.applicationLimitedProbeFailureCount
        _ = fixture.policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
            roundTripTimeObservation: .unavailable, collectionSequence: 3,
            nativeReportTimestampMicroseconds: 1_700_000, selectedRoute: nil,
            outboundVideoPacketsSent: 210,
            outboundVideoTotalPacketSendDelaySeconds: 0.21,
            observedAt: fixture.origin.advanced(by: .milliseconds(700)))
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, origin)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, failures)
        var expiryPolicy = fixture.policy
        _ = expiryPolicy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
            roundTripTimeObservation: .unavailable, collectionSequence: 4,
            nativeReportTimestampMicroseconds: 1_900_000, selectedRoute: nil,
            outboundVideoPacketsSent: 220,
            outboundVideoTotalPacketSendDelaySeconds: 0.22,
            observedAt: fixture.origin.advanced(by: .milliseconds(900)))
        XCTAssertEqual(expiryPolicy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(expiryPolicy.currentRecommendation, recommendation)
        _ = expiryPolicy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: deadline)
        XCTAssertNil(expiryPolicy.applicationLimitedProbeOriginTier)
        XCTAssertLessThan(expiryPolicy.currentRecommendation.maximumTotalRTPBitrateBps,
                          recommendation.maximumTotalRTPBitrateBps)
        // A repaired cached RTT tuple cannot regain positive permission after the gap.
        _ = fixture.policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: 18_000_000, currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: 0.004, responsesReceived: 1)),
            collectionSequence: 4, nativeReportTimestampMicroseconds: 1_900_000,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: 220,
            outboundVideoTotalPacketSendDelaySeconds: 0.22,
            observedAt: fixture.origin.advanced(by: .milliseconds(900)))
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                                 recommendation.maximumTotalRTPBitrateBps)
        // Regardless of missing reports, the original wall-clock deadline remains terminal.
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: deadline)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
    }

    func testSparseFastSelectedPairStillAppliesImmediateSenderQueuePressure() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
            roundTripTimeObservation: .unavailable, collectionSequence: 3,
            nativeReportTimestampMicroseconds: 1_700_000, selectedRoute: nil,
            outboundVideoPacketsSent: 210,
            outboundVideoTotalPacketSendDelaySeconds: 2.7,
            observedAt: fixture.origin.advanced(by: .milliseconds(700)))
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testSparseFastHoldDoesNotApplyToPresentRouteOrBandwidthOrPartialRTT() {
        for variant in 0..<4 {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            _ = fixture.sample(at: 500)
            let ceiling = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
            _ = fixture.policy.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: variant == 0 ? 100_000 : nil,
                currentRoundTripTimeSeconds: variant == 2 ? 0.004 : nil,
                roundTripTimeObservation: variant == 3 ? nil : .unavailable,
                collectionSequence: 3, nativeReportTimestampMicroseconds: 1_700_000,
                selectedRoute: variant == 1 ? WebRTCICERouteDiagnostics(kind: .relayed) : nil,
                outboundVideoPacketsSent: 210,
                outboundVideoTotalPacketSendDelaySeconds: 0.21,
                observedAt: fixture.origin.advanced(by: .milliseconds(700)))
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, "variant \(variant)")
            XCTAssertLessThan(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                              ceiling, "Only a wholly absent selected-pair slice may hold the existing cap")
            if variant < 2 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved,
                              "Missing RTT cannot hide present route/BWE negatives")
            }
        }
    }

    func testSparseFastHoldRequiresCurrentPrimaryLeaseAndObservableQueueBaseline() throws {
        for variant in 0..<3 {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            _ = fixture.sample(at: 1_000)
            let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
            let sampleTime = variant == 0 ? 4_100 : 1_200
            XCTAssertGreaterThan(deadline, fixture.origin.advanced(by: .milliseconds(sampleTime)))
            if variant == 1 { fixture.policy.resetIncompleteEvidenceWindow() }
            _ = fixture.policy.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
                roundTripTimeObservation: .unavailable, collectionSequence: 3,
                nativeReportTimestampMicroseconds: 1_000_000 + Double(sampleTime) * 1_000,
                selectedRoute: nil,
                outboundVideoPacketsSent: variant == 2 ? nil : 210,
                outboundVideoTotalPacketSendDelaySeconds: variant == 2 ? nil : 0.21,
                observedAt: fixture.origin.advanced(by: .milliseconds(sampleTime)))
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                         "variant \(variant) cannot safely hold the raised budget")
        }
    }

    func testFreshFastRTTAfterSparseOrdinaryReportWaitsForPrimaryRequalification() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500)
        let recommendation = fixture.policy.currentRecommendation
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        _ = fixture.policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
            roundTripTimeObservation: .unavailable, collectionSequence: 3,
            requireRoundTripTimeObservation: true, selectedRoute: nil,
            outboundVideoPacketsSent: 210,
            outboundVideoTotalPacketSendDelaySeconds: 0.21,
            nativeReportTimestampMicroseconds: 1_700_000,
            observedAt: fixture.origin.advanced(by: .milliseconds(700)))
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation)
        _ = fixture.policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: 3_600_000, currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: 0.008, responsesReceived: 2)),
            collectionSequence: 4, nativeReportTimestampMicroseconds: 1_900_000,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: 220,
            outboundVideoTotalPacketSendDelaySeconds: 0.22,
            observedAt: fixture.origin.advanced(by: .milliseconds(900)))
        XCTAssertEqual(fixture.policy.currentRecommendation, recommendation,
                       "Fast health may hold the existing budget, never increase it")
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable,
                       "A fast report must not repair ordinary RTT permission")
        _ = fixture.sample(at: 1_000, bandwidth: 3_600_000, pingCount: 2,
                           totalRTT: 0.008, sequence: 5)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
    }

    func testFreshFastRTTAfterMalformedOrdinaryReportStillFailsClosed() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        _ = fixture.sample(at: 500)
        let recommendation = fixture.policy.currentRecommendation
        let failures = fixture.policy.applicationLimitedProbeFailureCount
        _ = fixture.policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: 900_000, currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: "malformed",
                totalRoundTripTimeSeconds: 0.008, responsesReceived: 2)),
            collectionSequence: 3, requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: 210,
            outboundVideoTotalPacketSendDelaySeconds: 0.21,
            nativeReportTimestampMicroseconds: 1_700_000,
            observedAt: fixture.origin.advanced(by: .milliseconds(700)))
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)

        _ = fixture.policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: 3_600_000, currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: 0.012, responsesReceived: 3)),
            collectionSequence: 4, nativeReportTimestampMicroseconds: 1_900_000,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: 220,
            outboundVideoTotalPacketSendDelaySeconds: 0.22,
            observedAt: fixture.origin.advanced(by: .milliseconds(900)))
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                     "Malformed ordinary evidence must not mint the sparse-report bridge")
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, failures + 1)
        XCTAssertLessThan(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                          recommendation.maximumTotalRTPBitrateBps)
    }

    func testFreshFastRTTBridgeStillAppliesIndependentPressureAndRouteBoundaries() {
        for variant in 0..<4 {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            _ = fixture.sample(at: 500)
            _ = fixture.policy.update(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
                roundTripTimeObservation: .unavailable, collectionSequence: 3,
                requireRoundTripTimeObservation: true, selectedRoute: nil,
                outboundVideoPacketsSent: 210,
                outboundVideoTotalPacketSendDelaySeconds: 0.21,
                nativeReportTimestampMicroseconds: 1_700_000,
                observedAt: fixture.origin.advanced(by: .milliseconds(700)))
            XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)

            let isImmediateQueue = variant == 0
            let isBandwidthCollapse = variant == 1
            _ = fixture.policy.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: isBandwidthCollapse ? 100_000 : 3_600_000,
                currentRoundTripTimeSeconds: 0.004,
                roundTripTimeObservation: .measurement(.init(
                    // Isolate route-diagnostics replacement from RTT pair-reseed rejection,
                    // which has its own independent fail-closed regression coverage.
                    selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                    totalRoundTripTimeSeconds: 0.008, responsesReceived: 2)),
                collectionSequence: 4, nativeReportTimestampMicroseconds: 1_900_000,
                selectedRoute: WebRTCICERouteDiagnostics(
                    kind: variant == 2 ? .relayed : .direct),
                outboundVideoPacketsSent: variant == 3 ? nil : 220,
                outboundVideoTotalPacketSendDelaySeconds:
                    variant == 3 ? nil : (isImmediateQueue ? 2.71 : 0.22),
                observedAt: fixture.origin.advanced(by: .milliseconds(900)))
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                         "variant \(variant) must terminate the bounded bridge")
            if variant < 3 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved,
                              "variant \(variant) is affirmative terminal evidence")
                XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
            }
        }
    }

    func testFreshFastRTTBridgeCannotOutlivePrimaryLeaseOrProbeDeadline() throws {
        do {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            _ = fixture.sample(at: 1_000)
            let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
            XCTAssertGreaterThan(deadline, fixture.origin.advanced(by: .milliseconds(4_100)))
            _ = fixture.policy.update(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
                roundTripTimeObservation: .unavailable, collectionSequence: 3,
                requireRoundTripTimeObservation: true, selectedRoute: nil,
                outboundVideoPacketsSent: 210,
                outboundVideoTotalPacketSendDelaySeconds: 0.21,
                nativeReportTimestampMicroseconds: 4_900_000,
                observedAt: fixture.origin.advanced(by: .milliseconds(3_900)))
            XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
            _ = fixture.policy.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: 3_600_000, currentRoundTripTimeSeconds: 0.004,
                roundTripTimeObservation: .measurement(.init(
                    selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                    totalRoundTripTimeSeconds: 0.008, responsesReceived: 2)),
                collectionSequence: 4, nativeReportTimestampMicroseconds: 5_100_000,
                selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
                outboundVideoPacketsSent: 220,
                outboundVideoTotalPacketSendDelaySeconds: 0.22,
                observedAt: fixture.origin.advanced(by: .milliseconds(4_100)))
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier,
                         "Fresh fast evidence cannot bridge an expired primary RTT lease")
        }

        do {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0)
            _ = fixture.sample(at: 500)
            let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
            let raisedCap = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
            _ = fixture.policy.update(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: nil, currentRoundTripTimeSeconds: nil,
                roundTripTimeObservation: .unavailable, collectionSequence: 3,
                requireRoundTripTimeObservation: true, selectedRoute: nil,
                outboundVideoPacketsSent: 210,
                outboundVideoTotalPacketSendDelaySeconds: 0.21,
                nativeReportTimestampMicroseconds: 1_700_000,
                observedAt: fixture.origin.advanced(by: .milliseconds(700)))
            _ = fixture.policy.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true,
                availableOutgoingBitrateBps: 3_600_000, currentRoundTripTimeSeconds: 0.004,
                roundTripTimeObservation: .measurement(.init(
                    selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                    totalRoundTripTimeSeconds: 0.008, responsesReceived: 2)),
                collectionSequence: 4, nativeReportTimestampMicroseconds: 5_000_000,
                selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
                outboundVideoPacketsSent: 220,
                outboundVideoTotalPacketSendDelaySeconds: 0.22,
                observedAt: deadline)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline)
            XCTAssertLessThan(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                              raisedCap,
                              "The fast bridge cannot extend the original wall-clock deadline")
        }
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

    init(baseFramesPerSecond: Int = 60) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000,
            baseFramesPerSecond: baseFramesPerSecond)
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
