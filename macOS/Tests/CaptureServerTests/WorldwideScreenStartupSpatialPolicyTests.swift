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
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                      "Full tier is not permission to forget Show-bound pixel protection")

        for time in stride(from: 4_500, through: 6_500, by: 500) {
            _ = fixture.sample(at: time, bandwidth: 100_000)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1,
                           "A later sender-censored estimate must remain temporal-first")
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)

        for index in 0..<5 {
            _ = fixture.sample(
                at: 7_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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

    func testQualifiedSpatialFPSRetainsOnMissingOrRawLowBWE() {
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
        _ = fixture.sample(at: plateauTime + 1_000, bandwidth: 100_000)
        _ = fixture.sample(at: plateauTime + 1_500, bandwidth: 100_000)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                      "Raw sender-censored BWE is not spatial pressure")
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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
            if variant == 1 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved,
                              "Missing RTT cannot hide a present route replacement")
            } else if variant == 0 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                              "Fast BWE may terminate the probe, but cannot blur startup pixels")
                XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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
            if variant == 0 || variant == 2 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved,
                              "variant \(variant) is affirmative terminal evidence")
                XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
            } else {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                              "variant \(variant) may terminate a probe but lacks spatial authority")
                XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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

    func testRawLowBandwidthMayReduceTemporalTierButKeepsFullPixels() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testBelowReserveProbeWitnessIsScopedToItsExactShow() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000)
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertTrue(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness
        )

        fixture.policy.endFloorRecoveryVisibility()

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation,
                      "Peer-wide suspension evidence may remain latched")
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "Spatial authority must not cross a Hide/new-Show boundary"
        )
    }

    func testBelowReserveProbeWitnessIsInvalidatedByMaterialRecovery() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000)
        XCTAssertTrue(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness
        )

        _ = fixture.sample(
            at: 2_000, bandwidth: 250_000,
            selectedPairBytesSent: 10_000)
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "Atomic pair recovery must invalidate authority without video stats"
        )

        var videoBytes: UInt64 = 5_625
        var pairBytes: UInt64 = 10_000
        for index in 0..<5 {
            if index > 0 {
                videoBytes += 14_063
                pairBytes += 14_063
            }
            _ = fixture.sample(
                at: 2_500 + index * 500,
                bandwidth: 250_000,
                videoBytesSent: videoBytes,
                videoFramesEncoded: UInt64(index + 2),
                videoTargetBitrateBps: 250_000,
                selectedPairBytesSent: pairBytes)
        }

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness
        )
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testBelowReserveFailureWithoutAtomicPairOnlyLatchesPeerWideAndCannotAuthorizePixels()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000,
            selectedPairBytesSent: 0)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)

        _ = fixture.sample(
            at: 1_500,
            bandwidth: 100_000,
            omitRTTEvidence: true,
            includeSelectedPairOutbound: false
        )
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "top-level BWE without an atomic same-pair tuple cannot mint spatial authority"
        )

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                selectedPairBytesSent: UInt64(index) * 5_625
            )
        }

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testBelowReserveFailureWithMismatchedTopLevelAndAtomicBWECannotMintWitness()
        throws {
        var fixture = SpatialFixture()
        let pairA = String(repeating: "a", count: 64)
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000,
            startupPairFingerprint: pairA,
            selectedPairBytesSent: 0,
            selectedPairBandwidthBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)

        _ = fixture.sample(
            at: 1_500,
            bandwidth: 100_000,
            videoBytesSent: 5_625,
            videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            startupPairFingerprint: pairA,
            selectedPairBytesSent: 5_625,
            selectedPairBandwidthBps: 300_000)
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "a different atomic BWE cannot authenticate a top-level collapse"
        )

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                startupPairFingerprint: pairA,
                selectedPairBytesSent: 5_625 + UInt64(index) * 5_625,
                selectedPairBandwidthBps: 100_000)
        }

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testExactShowAtomicFailedProbeWitnessCanCorroborateNonQLRSaturatedDemand()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                selectedPairBytesSent: 5_625 + UInt64(index) * 5_625)
        }

        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testAcceptedOriginRestoreKeepsFreshFailedProbeWitnessForNonQLRDemand()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        let previouslyCommitted = fixture.policy

        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        fixture.policy.resetForAcceptedSenderConfigurationEpoch(
            previouslyCommitted: previouslyCommitted
        )
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                selectedPairBytesSent: 5_625 + UInt64(index) * 5_625)
        }
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testCorrectiveNativeReconciliationRevokesWitnessMintedByUnknownConfiguration()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)

        // The native cache is unknown. The service fences pre-write counters before reducing
        // this report, but the report may still observe a failed probe under unknown limits.
        fixture.policy = WorldwideScreenNativeApplicationCache
            .policyForSenderConfigurationReconciliation(fixture.policy)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        // Corrective accepted apply cannot preserve that fresh-but-unqualified witness.
        fixture.policy.resetForSenderConfigurationEpoch()
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                selectedPairBytesSent: 5_625 + UInt64(index) * 5_625)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testAcceptedUnrelatedSenderChangeRevokesCarriedFailedProbeWitness()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        let previouslyCommitted = fixture.policy

        fixture.policy.resetForAcceptedSenderConfigurationEpoch(
            previouslyCommitted: previouslyCommitted
        )

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
    }

    func testFramebufferRebuildRevokesExactProbeWitnessButPreservesPeerWideLatch()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000,
            selectedPairBytesSent: 0)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        fixture.policy.resetForCaptureGeometryEpoch()

        XCTAssertTrue(
            fixture.policy.belowReserveProbeDisprovedSenderLimitation,
            "peer-wide suspension evidence remains fail-closed across a source rebuild"
        )
        XCTAssertFalse(
            fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "the preceding geometry's failed probe cannot authorize replacement pixels"
        )

        for index in 0..<5 {
            _ = fixture.sample(
                at: 2_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                selectedPairBytesSent: 5_625 + UInt64(index) * 5_625)
        }

        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testSustainedDemandProofRetiresFullPixelsOnlyOnFourthFreshReport() {
        var fixture = SpatialFixture()
        let target = 100_000.0
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        _ = fixture.sample(
            at: 1_000, bandwidth: 100_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: target,
            videoQualityLimitationReason: .bandwidth)

        let reports: [(time: Int, bytes: UInt64, frames: UInt64)] = [
            (1_500, 5_625, 1),
            (2_000, 11_250, 2),
            (2_500, 16_875, 3),
            (3_000, 22_500, 4),
        ]
        for (index, report) in reports.enumerated() {
            _ = fixture.sample(
                at: report.time, bandwidth: 100_000,
                videoBytesSent: report.bytes,
                videoFramesEncoded: report.frames,
                videoTargetBitrateBps: target,
                videoQualityLimitationReason: .bandwidth)
            if index < reports.count - 1 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                              "Demand proof must remain bounded to four fresh reports")
                XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
            }
        }

        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testBandwidthDemandProofRejectsUnexercisedTargetsAndBrokenCounters() {
        let cases: [(
            bandwidth: Double,
            target: Double,
            videoBytes: [UInt64],
            pairBytes: [UInt64],
            frames: [UInt64],
            independentPressure: Bool
        )] = [
            // Pair load saturates BWE, but video stayed below 80% of its stated target.
            (100_000, 100_000, [0, 2_000, 4_000, 6_000, 8_000],
             [0, 5_625, 11_250, 16_875, 22_500], [0, 1, 2, 3, 4], true),
            // Pair/video bytes saturate every rate gate without encoded-frame progress.
            (100_000, 100_000, [0, 5_625, 11_250, 16_875, 22_500],
             [0, 5_625, 11_250, 16_875, 22_500], [0, 0, 0, 0, 0], true),
            // A regressing cumulative video counter invalidates the in-flight window.
            (100_000, 100_000, [10_000, 15_625, 21_250, 12_000, 17_625],
             [50_000, 55_625, 61_250, 66_875, 72_500], [0, 1, 2, 3, 4], true),
            // Near-saturated allocator targets do not prove an independently limited path.
            (110_000, 100_000, [0, 5_625, 11_250, 16_875, 22_500],
             [0, 5_625, 11_250, 16_875, 22_500], [0, 1, 2, 3, 4], false),
        ]
        let times = [1_000, 1_500, 2_000, 2_500, 3_000]

        for (caseIndex, evidence) in cases.enumerated() {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0, bandwidth: evidence.bandwidth)
            _ = fixture.sample(at: 500, bandwidth: evidence.bandwidth)
            for sampleIndex in times.indices {
                _ = fixture.sample(
                    at: times[sampleIndex], bandwidth: evidence.bandwidth,
                    videoBytesSent: evidence.videoBytes[sampleIndex],
                    videoFramesEncoded: evidence.frames[sampleIndex],
                    videoTargetBitrateBps: evidence.target,
                    videoQualityLimitationReason:
                        evidence.independentPressure ? .bandwidth : nil,
                    selectedPairBytesSent: evidence.pairBytes[sampleIndex])
            }
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                          "invalid demand case \(caseIndex) must retain full pixels")
            XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        }
    }

    func testAggregateAudioTargetAloneCannotProvePathLimitation() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 120_000)
        _ = fixture.sample(at: 500, bandwidth: 120_000)
        let times = [1_000, 1_500, 2_000, 2_500, 3_000]
        for index in times.indices {
            _ = fixture.sample(
                at: times[index], bandwidth: 120_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 90_000,
                audioTargetBitrateBps: 30_000,
                selectedPairBytesSent: UInt64(index) * 6_750)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testInvalidAudioTargetsAreDiagnosticsOnlyAndCannotVetoQLRProof() {
        let invalidAudioTargets: [(name: String, value: Double?)] = [
            ("missing-after-malformed-native-value", nil),
            ("negative", -1),
            ("positive-infinity", .infinity),
            ("negative-infinity", -.infinity),
            ("not-a-number", .nan),
        ]

        for invalidAudioTarget in invalidAudioTargets {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0, bandwidth: 120_000)
            _ = fixture.sample(at: 500, bandwidth: 120_000)
            for index in 0..<5 {
                _ = fixture.sample(
                    at: 1_000 + index * 500,
                    bandwidth: 120_000,
                    videoBytesSent: UInt64(index) * 5_625,
                    videoFramesEncoded: UInt64(index),
                    videoTargetBitrateBps: 90_000,
                    audioTargetBitrateBps: invalidAudioTarget.value,
                    videoQualityLimitationReason: .bandwidth,
                    selectedPairBytesSent: UInt64(index) * 6_750)
            }

            XCTAssertTrue(
                fixture.policy.startupSpatialModeIsDisproved,
                "\(invalidAudioTarget.name) audio target must not veto valid video/path proof"
            )
            XCTAssertEqual(
                fixture.policy.startupSpatialModeDisproofCause,
                .demandProvenBandwidth
            )
            XCTAssertGreaterThan(
                fixture.policy.currentRecommendation.scaleResolutionDownBy,
                1
            )
        }
    }

    func testSustainedNativeBandwidthLimitationCanCorroborateOfferedLoad() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 120_000)
        _ = fixture.sample(at: 500, bandwidth: 120_000)
        let times = [1_000, 1_500, 2_000, 2_500, 3_000]
        for index in times.indices {
            _ = fixture.sample(
                at: times[index], bandwidth: 120_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 90_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 6_750)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthLimitedIntervalCount, 4)
    }

    func testInterruptedNativeBandwidthLimitationCannotProvePathPressure() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 120_000)
        _ = fixture.sample(at: 500, bandwidth: 120_000)
        let reasons: [WebRTCVideoQualityLimitationReason?] = [
            .bandwidth, .bandwidth, nil, .bandwidth, .bandwidth,
        ]
        for index in reasons.indices {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 120_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 90_000,
                videoQualityLimitationReason: reasons[index],
                selectedPairBytesSent: UInt64(index) * 6_750)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testSelectedPairDemandProofRejectsMissingAndRegressingEvidence() {
        enum Mutation: Equatable {
            case missing
            case regressing
        }
        for mutation in [Mutation.missing, .regressing] {
            var fixture = SpatialFixture()
            _ = fixture.sample(at: 0, bandwidth: 100_000)
            _ = fixture.sample(at: 500, bandwidth: 100_000)
            for index in 0..<5 {
                let mutate = index == 3
                _ = fixture.sample(
                    at: 1_000 + index * 500,
                    bandwidth: 100_000,
                    videoBytesSent: UInt64(index) * 5_625,
                    videoFramesEncoded: UInt64(index),
                    videoTargetBitrateBps: 100_000,
                    videoQualityLimitationReason: .bandwidth,
                    selectedPairBytesSent: mutate && mutation == .regressing
                        ? 1 : UInt64(index) * 5_625,
                    includeSelectedPairOutbound: !(mutate && mutation == .missing))
            }
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                          "\(mutation) pair evidence must fail closed")
            XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        }
    }

    func testSelectedPairDeltaCannotTrailPrimaryVideoDelta() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: 100_000 + UInt64(index) * 5_313)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testRisingStartupBandwidthRampNeverBlurs() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        let ramp = [200_000.0, 260_000, 330_000, 420_000, 550_000]
        var cumulativeBytes: UInt64 = 0
        for (index, bandwidth) in ramp.enumerated() {
            if index > 0 {
                cumulativeBytes += UInt64(
                    (bandwidth * 0.90 * 0.5 / 8).rounded()
                )
            }
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: bandwidth,
                videoBytesSent: cumulativeBytes,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: bandwidth,
                videoQualityLimitationReason: .bandwidth)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1,
                           "Rising startup BWE at sample \(index) must stay temporal-first")
            XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        }
    }

    func testUShapedStartupBandwidthRecoveryRestartsDemandProof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        let reports: [(Int, Double, UInt64)] = [
            (1_000, 300_000, 0),
            (1_500, 100_000, 5_625),
            (2_000, 100_000, 11_250),
            (2_500, 200_000, 22_500),
            (3_000, 250_000, 36_563),
        ]
        for (index, report) in reports.enumerated() {
            _ = fixture.sample(
                at: report.0, bandwidth: report.1,
                videoBytesSent: report.2,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: report.1,
                videoQualityLimitationReason: .bandwidth)
            XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        }
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testTwoKeyFrameOnlyBurstsAndStaticPlateausCannotProveDemand() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        let reports: [(time: Int, bytes: UInt64, frames: UInt64, keyFrames: UInt64)] = [
            (1_000, 0, 0, 0),
            (1_500, 11_250, 1, 1),
            (2_000, 11_250, 1, 1),
            (2_500, 22_500, 2, 2),
            (3_000, 22_500, 2, 2),
        ]
        var maximumDemandIntervals = 0
        for report in reports {
            _ = fixture.sample(
                at: report.time, bandwidth: 100_000,
                videoBytesSent: report.bytes,
                videoFramesEncoded: report.frames,
                videoKeyFramesEncoded: report.keyFrames,
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth)
            maximumDemandIntervals = max(
                maximumDemandIntervals,
                fixture.policy.startupSpatialBandwidthDemandIntervalCount
            )
        }

        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(maximumDemandIntervals, 0)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthDemandIntervalCount, 0)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testKeyFrameCounterAvailabilityChangeCannotReuseEarlierBursts() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        let reports: [(Int, UInt64, UInt64, Bool)] = [
            (1_000, 0, 0, true),
            (1_500, 7_500, 1, true),
            (2_000, 15_000, 2, true),
            (2_500, 22_500, 3, false),
            (3_000, 30_000, 4, false),
        ]
        for report in reports {
            _ = fixture.sample(
                at: report.0, bandwidth: 100_000,
                videoBytesSent: report.1,
                videoFramesEncoded: report.2,
                videoKeyFramesEncoded: report.2,
                includeKeyFrameCounter: report.3,
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testMissingOptionalKeyFrameCounterStillAllowsCompleteDemandProof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for (index, time) in [1_000, 1_500, 2_000, 2_500, 3_000].enumerated() {
            _ = fixture.sample(
                at: time, bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                includeKeyFrameCounter: false,
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth)
        }

        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testRecommendationTransitionReportCannotSeedDemandProof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 100_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth)
        _ = fixture.sample(
            at: 500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)

        let reports: [(time: Int, bytes: UInt64, frames: UInt64)] = [
            (1_000, 11_250, 2),
            (1_500, 16_875, 3),
            (2_000, 22_500, 4),
            (2_500, 28_125, 5),
            (3_000, 33_750, 6),
        ]
        for (index, report) in reports.enumerated() {
            _ = fixture.sample(
                at: report.time, bandwidth: 100_000,
                videoBytesSent: report.bytes,
                videoFramesEncoded: report.frames,
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth)
            if index < reports.count - 1 {
                XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
            }
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testFramebufferRebuildCannotCombinePartialDemandAcrossGeometry() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<3 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 2)

        // The service invokes this epoch fence before stopping the old framebuffer source.
        // RTP counters may stay monotonic across the rebuild, but their earlier deltas cannot
        // contribute to the new geometry's proof.
        fixture.policy.resetForCaptureGeometryEpoch()
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)

        _ = fixture.sample(
            at: 2_500,
            bandwidth: 100_000,
            videoBytesSent: 16_875,
            videoFramesEncoded: 3,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 16_875)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)

        for interval in 1...3 {
            _ = fixture.sample(
                at: 2_500 + interval * 500,
                bandwidth: 100_000,
                videoBytesSent: 16_875 + UInt64(interval) * 5_625,
                videoFramesEncoded: 3 + UInt64(interval),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: 16_875 + UInt64(interval) * 5_625)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)

        _ = fixture.sample(
            at: 4_500,
            bandwidth: 100_000,
            videoBytesSent: 39_375,
            videoFramesEncoded: 7,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 39_375)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
    }

    func testFramebufferRebuildRearmsDemandProvenPixelsAndRequiresFreshProof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)

        fixture.policy.resetForCaptureGeometryEpoch()

        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertNil(fixture.policy.startupSpatialModeDisproofCause)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)

        _ = fixture.sample(
            at: 3_500,
            bandwidth: 100_000,
            videoBytesSent: 28_125,
            videoFramesEncoded: 5,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 28_125)
        XCTAssertEqual(
            fixture.policy.startupSpatialBandwidthProofSampleCount,
            0,
            "the first report for the replacement geometry only seeds its proof"
        )
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testMutableDiagnosticCauseCannotVetoDemandGeometryRearm() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .demandProvenBandwidth)

        // The display diagnostic can change independently of the terminal Show-scoped
        // authority. Geometry rearm must use the latter, even for a carried legacy state.
        fixture.policy.overrideLastDowngradeCauseForTesting(.bandwidthOnly)
        XCTAssertEqual(fixture.policy.lastDowngradeCause, .bandwidthOnly)
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .demandProvenBandwidth)

        fixture.policy.resetForCaptureGeometryEpoch()

        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testFastProbeBandwidthCollapseDoesNotBlockDemandGeometryRearm() throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .demandProvenBandwidth)

        var probeTime = 3_500
        for time in stride(from: 3_500, through: 10_000, by: 500) {
            _ = fixture.sample(at: time, bandwidth: 900_000)
            probeTime = time
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
        }
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        let raisedCap = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
        _ = fixture.fastSample(at: probeTime + 200, bandwidth: 10_000)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertLessThan(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
                          raisedCap)
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .demandProvenBandwidth)

        fixture.policy.resetForCaptureGeometryEpoch()
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testFastImmediateQueueAfterDemandDisproofSurvivesGeometryRebuild() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .demandProvenBandwidth)

        var probeTime = 3_500
        for time in stride(from: 3_500, through: 10_000, by: 500) {
            _ = fixture.sample(at: time, bandwidth: 900_000)
            probeTime = time
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
        }
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.fastSample(at: probeTime + 200,
                               bandwidth: 900_000,
                               queueDelay: 0.250)
        XCTAssertEqual(fixture.policy.startupSpatialModeDisproofCause,
                       .confirmedQueuePressure)

        fixture.policy.resetForCaptureGeometryEpoch()
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
    }

    func testFramebufferRebuildCannotEraseHardPressureAfterDemandDisproof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<5 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )

        fixture.policy.invalidateSelectedRoute()
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .selectedRouteReplacement
        )
        XCTAssertEqual(fixture.policy.lastDowngradeCause, .selectedRouteReplacement)

        fixture.policy.resetForCaptureGeometryEpoch()

        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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

    func testSelectedPairFingerprintReplacementRetiresFullPixelsWhenRouteMetadataMatches() {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0,
            route: .direct,
            pairFingerprint: String(repeating: "a", count: 64))
        _ = fixture.sample(
            at: 500,
            route: .direct,
            pairFingerprint: String(repeating: "b", count: 64))

        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .selectedRouteReplacement
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testAtomicSelectedPairReplacementRetiresPixelsWithoutRTTEvidence() {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 100_000,
            omitRTTEvidence: true,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            startupPairFingerprint: String(repeating: "a", count: 64))
        let changed = fixture.sample(
            at: 500, bandwidth: 100_000,
            omitRTTEvidence: true,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            startupPairFingerprint: String(repeating: "b", count: 64))

        XCTAssertNotNil(changed)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .selectedRouteReplacement
        )
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testImmediateQueuePressureAtProbeDeadlineStillRetiresFullPixels() throws {
        var fixture = SpatialFixture()
        for time in [0, 500, 1_000] {
            _ = fixture.sample(at: time)
        }
        let deadline = try XCTUnwrap(
            fixture.policy.applicationLimitedProbeDeadline
        )

        let changed = fixture.fastSample(
            at: 4_000,
            bandwidth: 900_000,
            queueDelay: 0.250,
            observedAt: deadline
        )

        XCTAssertNotNil(changed)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            fixture.policy.startupSpatialModeDisproofCause,
            .confirmedQueuePressure
        )
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

    func testSuccessorShowRearmsFullPixelsAfterPriorSpatialDisproof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0)
        fixture.policy.invalidateSelectedRoute()
        let previouslyApplied = fixture.policy.currentRecommendation
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertGreaterThan(previouslyApplied.scaleResolutionDownBy, 1)

        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)

        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertNotEqual(previouslyApplied, fixture.policy.currentRecommendation)
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

    func testFailedNativeApplyAfterFullProposalCommitRestartsPartialDemandProof() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<3 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 2)

        var proposal = fixture
        _ = proposal.sample(
            at: 2_500,
            bandwidth: 100_000,
            videoBytesSent: 16_875,
            videoFramesEncoded: 3,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 16_875)
        XCTAssertEqual(proposal.policy.startupSpatialBandwidthProofSampleCount, 3)

        // Exercise the service's full-proposal selection and post-selection reconciliation.
        let committed = WorldwideScreenNativeApplicationCache
            .reconciledPolicyAfterCurrentOwnerFailure(
                current: fixture.policy,
                proposed: proposal.policy,
                commitEntireProposal: true,
                capacityProbeOnly: false
            )
        XCTAssertEqual(committed.startupSpatialBandwidthProofSampleCount, 0)
        XCTAssertEqual(committed.startupSpatialBandwidthDemandIntervalCount, 0)
        XCTAssertEqual(committed.startupSpatialBandwidthDisposition, .awaitingEvidence)
        proposal.policy = committed

        // The next report is only a fresh seed; it cannot reuse the rejected proposal's count.
        _ = proposal.sample(
            at: 3_000,
            bandwidth: 100_000,
            videoBytesSent: 22_500,
            videoFramesEncoded: 4,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 22_500)
        XCTAssertEqual(proposal.policy.startupSpatialBandwidthProofSampleCount, 0)
        XCTAssertTrue(proposal.policy.startupSpatialModeIsActive)

        for interval in 1...4 {
            _ = proposal.sample(
                at: 3_000 + interval * 500,
                bandwidth: 100_000,
                videoBytesSent: 22_500 + UInt64(interval) * 5_625,
                videoFramesEncoded: 4 + UInt64(interval),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: 22_500 + UInt64(interval) * 5_625)
            if interval < 4 {
                XCTAssertTrue(
                    proposal.policy.startupSpatialModeIsActive,
                    "a rejected partial window cannot shorten the fresh four-interval proof"
                )
            }
        }
        XCTAssertTrue(proposal.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(
            proposal.policy.startupSpatialModeDisproofCause,
            .demandProvenBandwidth
        )
    }

    func testSuccessfulCacheMismatchReconciliationRejectsThePreWriteDemandReport() {
        var fixture = SpatialFixture()
        _ = fixture.sample(at: 0, bandwidth: 100_000)
        _ = fixture.sample(at: 500, bandwidth: 100_000)
        for index in 0..<4 {
            _ = fixture.sample(
                at: 1_000 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: UInt64(index) * 5_625,
                videoFramesEncoded: UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: .bandwidth,
                selectedPairBytesSent: UInt64(index) * 5_625)
        }
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 3)

        // The cache mismatch is known before reducing the report. Fence once so the report
        // cannot finish the old window, then fence again after reduction so counters collected
        // before the corrective native write cannot seed the newly applied sender epoch.
        fixture.policy = WorldwideScreenNativeApplicationCache
            .policyForSenderConfigurationReconciliation(fixture.policy)
        _ = fixture.sample(
            at: 3_000,
            bandwidth: 100_000,
            videoBytesSent: 22_500,
            videoFramesEncoded: 4,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 22_500)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        fixture.policy = WorldwideScreenNativeApplicationCache
            .policyForSenderConfigurationReconciliation(fixture.policy)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthProofSampleCount, 0)
        XCTAssertEqual(fixture.policy.startupSpatialBandwidthDemandIntervalCount, 0)

        _ = fixture.sample(
            at: 3_500,
            bandwidth: 100_000,
            videoBytesSent: 28_125,
            videoFramesEncoded: 5,
            videoTargetBitrateBps: 100_000,
            videoQualityLimitationReason: .bandwidth,
            selectedPairBytesSent: 28_125)
        XCTAssertEqual(
            fixture.policy.startupSpatialBandwidthProofSampleCount,
            0,
            "the first post-apply report is only the fresh proof seed"
        )
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testFailedNativeRecoveryProposalKeepsExactWitnessRevokedButPeerLatchConservative()
        throws {
        var fixture = SpatialFixture()
        _ = fixture.sample(
            at: 0, bandwidth: 900_000,
            videoBytesSent: 0, videoFramesEncoded: 0,
            videoTargetBitrateBps: 900_000)
        _ = fixture.sample(at: 500, bandwidth: 900_000)
        _ = fixture.sample(at: 1_000, bandwidth: 900_000)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.sample(
            at: 1_500, bandwidth: 100_000,
            videoBytesSent: 5_625, videoFramesEncoded: 1,
            videoTargetBitrateBps: 100_000,
            selectedPairBytesSent: 5_625)
        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertTrue(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        var proposal = fixture
        var capProposal: WorldwideScreenVideoEncodingRecommendation?
        for index in 0..<8 {
            let recommendation = proposal.sample(
                at: 2_000 + index * 500,
                bandwidth: 500_000,
                pingCount: UInt64(index + 2),
                totalRTT: Double(index + 2) * 0.004,
                selectedPairBytesSent: 28_125 + UInt64(index) * 28_125
            )
            if let recommendation,
               proposal.policy.applicationLimitedProbeOriginTier != nil {
                capProposal = recommendation
                break
            }
        }
        XCTAssertNotNil(capProposal)
        XCTAssertNotNil(proposal.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(proposal.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)

        let committed = WorldwideScreenNativeApplicationCache
            .reconciledPolicyAfterCurrentOwnerFailure(
                current: fixture.policy,
                proposed: proposal.policy,
                commitEntireProposal: false,
                capacityProbeOnly: false
            )
        XCTAssertTrue(
            committed.belowReserveProbeDisprovedSenderLimitation,
            "a rejected recovery proposal cannot erase peer-wide suspension evidence"
        )
        XCTAssertFalse(
            committed.startupSpatialHasCurrentShowBelowReserveProbeWitness,
            "affirmative same-pair recovery must keep exact spatial authority revoked"
        )
        fixture.policy = committed

        for index in 0..<5 {
            _ = fixture.sample(
                at: 3_500 + index * 500,
                bandwidth: 100_000,
                videoBytesSent: 5_625 + UInt64(index) * 5_625,
                videoFramesEncoded: 1 + UInt64(index),
                videoTargetBitrateBps: 100_000,
                videoQualityLimitationReason: nil,
                selectedPairBytesSent: 28_125 + UInt64(index) * 5_625)
        }

        XCTAssertTrue(fixture.policy.belowReserveProbeDisprovedSenderLimitation)
        XCTAssertFalse(fixture.policy.startupSpatialHasCurrentShowBelowReserveProbeWitness)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testFastLaneBandwidthCollapseCannotRetireStartupPixels() throws {
        var fixture = SpatialFixture()
        for time in [0, 500, 1_000] { _ = fixture.sample(at: time) }
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        _ = fixture.fastSample(at: 1_200, bandwidth: 100_000)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive,
                      "Fast BWE is a negative probe signal, not ordinary demand proof")
        XCTAssertFalse(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
    }

    func testFastLaneImmediateQueuePressureStillRetiresStartupPixels() throws {
        var fixture = SpatialFixture()
        for time in [0, 500, 1_000] { _ = fixture.sample(at: time) }
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        let changed = fixture.fastSample(
            at: 1_200, bandwidth: 900_000, queueDelay: 0.250)
        XCTAssertNotNil(changed)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
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
        omitRTTEvidence: Bool = false,
        route: WebRTCICERouteKind = .direct,
        pairFingerprint: String? = nil,
        sequence sequenceOverride: UInt64? = nil, timestamp: Double? = nil,
        omitTimestamp: Bool = false,
        videoBytesSent: UInt64? = nil,
        videoFramesEncoded: UInt64? = nil,
        videoKeyFramesEncoded: UInt64? = nil,
        includeKeyFrameCounter: Bool = true,
        videoTargetBitrateBps: Double? = nil,
        audioTargetBitrateBps: Double? = nil,
        videoQualityLimitationReason:
            WebRTCVideoQualityLimitationReason? = nil,
        startupPairFingerprint: String? = nil,
        selectedPairBytesSent: UInt64? = nil,
        selectedPairBandwidthBps: Double? = nil,
        includeSelectedPairOutbound: Bool = true
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        sequence += 1
        if advancesPackets {
            packets += 100
            totalDelay += queueDelay * 100
        }
        let count = pingCount ?? UInt64(milliseconds / 2_500 + 1)
        let hasSelectedPairOutbound = includeSelectedPairOutbound
            && (videoBytesSent != nil || selectedPairBytesSent != nil)
        return policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: omitRTTEvidence ? nil : rtt,
            roundTripTimeObservation: omitRTTEvidence ? .unavailable
                : .measurement(.init(
                    selectedCandidatePairFingerprint: pairFingerprint
                        ?? String(repeating: route == .direct ? "a" : "b", count: 64),
                    totalRoundTripTimeSeconds: totalRTT ?? Double(count) * rtt,
                    responsesReceived: count)),
            collectionSequence: sequenceOverride ?? sequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: route),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalDelay,
            outboundVideoBytesSent: videoBytesSent,
            outboundVideoFramesEncoded: videoFramesEncoded,
            outboundVideoKeyFramesEncoded: includeKeyFrameCounter
                ? (videoKeyFramesEncoded ?? videoFramesEncoded.map { _ in 0 })
                : nil,
            outboundVideoTargetBitrateBps: videoTargetBitrateBps,
            outboundAudioTargetBitrateBps: audioTargetBitrateBps,
            outboundVideoQualityLimitationReason:
                videoQualityLimitationReason,
            selectedPairFingerprint: hasSelectedPairOutbound
                ? (startupPairFingerprint ?? pairFingerprint
                    ?? String(repeating: route == .direct ? "a" : "b", count: 64))
                : nil,
            selectedPairBytesSent: hasSelectedPairOutbound
                ? (selectedPairBytesSent ?? videoBytesSent)
                : nil,
            selectedPairAvailableOutgoingBitrateBps:
                hasSelectedPairOutbound
                    ? (selectedPairBandwidthBps ?? bandwidth) : nil,
            nativeReportTimestampMicroseconds: omitTimestamp ? nil
                : timestamp ?? 1_000_000 + Double(milliseconds) * 1_000,
            observedAt: origin.advanced(by: .milliseconds(milliseconds)))
    }

    mutating func fastSample(
        at milliseconds: Int,
        bandwidth: Double?,
        queueDelay: Double = 0.001,
        pairFingerprint: String = String(repeating: "a", count: 64),
        observedAt: ContinuousClock.Instant? = nil
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        sequence += 1
        packets += 100
        totalDelay += queueDelay * 100
        let count = UInt64(milliseconds / 2_500 + 1)
        return policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: pairFingerprint,
                totalRoundTripTimeSeconds: Double(count) * 0.004,
                responsesReceived: count)),
            collectionSequence: sequence,
            nativeReportTimestampMicroseconds: 1_000_000 + Double(milliseconds) * 1_000,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalDelay,
            observedAt: observedAt
                ?? origin.advanced(by: .milliseconds(milliseconds)))
    }
}
