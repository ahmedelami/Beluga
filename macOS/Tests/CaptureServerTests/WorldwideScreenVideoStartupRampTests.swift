import XCTest
@testable import CaptureServer

final class WorldwideScreenVideoStartupRampTests: XCTestCase {
    func testMeasuredStartupPlateauImprovesOnSecondHealthyReportAtEitherCadence() {
        for cadence in [500, 1_000] {
            var fixture = ProbeFixture()
            let probeStartedAt = fixture.now
            XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1)
            XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 12)

            _ = fixture.sample(bandwidth: 700_000, afterMilliseconds: cadence)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
            let improvement = fixture.sample(bandwidth: 700_000, afterMilliseconds: cadence)

            XCTAssertEqual(improvement?.tier, .survival)
            XCTAssertEqual(improvement?.maximumFramesPerSecond, 5)
            XCTAssertEqual(improvement?.scaleResolutionDownBy, 4)
            XCTAssertEqual(probeStartedAt.duration(to: fixture.now), .milliseconds(cadence * 2))
            XCTAssertLessThan(
                probeStartedAt.duration(to: fixture.now),
                WorldwideScreenVideoAdaptationPolicy.applicationLimitedProbeGraceDuration
            )
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline)
        }
    }

    func testEveryQualifiedIntermediateTierCanFinishWithoutWaitingForFullQuality() {
        let cases: [(Double, WorldwideScreenVideoAdaptationTier)] = [
            (500_000, .emergency),
            (700_000, .survival),
            (1_500_000, .critical),
            (3_000_000, .constrained),
            (6_000_000, .balanced),
            (9_000_000, .high),
            (16_000_000, .full),
        ]
        for (bandwidth, expectedTier) in cases {
            var fixture = ProbeFixture()
            _ = fixture.sample(bandwidth: bandwidth)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
            XCTAssertEqual(fixture.sample(bandwidth: bandwidth)?.tier, expectedTier)
            XCTAssertEqual(fixture.policy.currentTier, expectedTier)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
        }
    }

    func testInterruptedQualificationRequiresTwoNewHealthyReports() {
        for interruption in QualificationInterruption.allCases {
            var fixture = ProbeFixture()
            _ = fixture.sample(bandwidth: 700_000)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)

            switch interruption {
            case .missingBandwidth:
                _ = fixture.sample(bandwidth: nil)
            case .invalidBandwidth:
                _ = fixture.sample(bandwidth: .nan)
            case .missingRTT:
                _ = fixture.sample(bandwidth: 700_000, rtt: nil)
            case .grayQueue:
                _ = fixture.sample(bandwidth: 700_000, queueDelay: 0.050)
            case .softQueueBurst:
                _ = fixture.sample(bandwidth: 700_000, queueDelay: 0.110)
            case .staleLowFPSQueue:
                _ = fixture.sample(
                    bandwidth: 700_000,
                    afterMilliseconds: 1_700,
                    advancesPackets: false
                )
            case .cadenceReset:
                fixture.policy.resetIncompleteEvidenceWindow()
            }

            XCTAssertEqual(fixture.policy.currentTier, .audioPriority, "\(interruption)")
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0, "\(interruption)")
            _ = fixture.sample(bandwidth: 700_000)
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority, "\(interruption)")
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1, "\(interruption)")
            XCTAssertEqual(fixture.sample(bandwidth: 700_000)?.tier, .survival, "\(interruption)")
        }
    }

    func testOneQualifiedReportCannotCommitWhenReportsStop() throws {
        var fixture = ProbeFixture()
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        _ = fixture.sample(bandwidth: 700_000)
        XCTAssertEqual(
            fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1,
                isCaptureActive: true,
                observedAt: deadline
            )?.tier,
            .audioPriority
        )
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
    }

    func testCommittedImprovementSurvivesOldDeadlineAndLaterProbeFailure() throws {
        var fixture = ProbeFixture()
        let oldDeadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        _ = fixture.sample(bandwidth: 700_000)
        XCTAssertEqual(fixture.sample(bandwidth: 700_000)?.tier, .survival)

        XCTAssertNil(
            fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: 1,
                isCaptureActive: true,
                observedAt: oldDeadline
            )
        )
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        fixture.now = oldDeadline

        _ = fixture.sample(bandwidth: 900_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .survival)
        XCTAssertEqual(fixture.sample(bandwidth: 900_000, rtt: 0.080)?.tier, .survival)
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        XCTAssertNil(
            fixture.policy.automaticSuspensionDecision(
                isCaptureActive: true,
                isAutomaticallySuspended: false
            )
        )
    }

    func testRapidlyIncreasingCapacityStillReachesFullInOneGeometryTransition() {
        var fixture = ProbeFixture()
        let probeStartedAt = fixture.now
        var visibleTiers: [WorldwideScreenVideoAdaptationTier] = [.audioPriority]
        for bandwidth in [700_000.0, 1_465_000, 2_831_000, 10_308_000, 15_896_000, 15_896_000] {
            _ = fixture.sample(bandwidth: bandwidth)
            if fixture.policy.currentTier != visibleTiers.last {
                visibleTiers.append(fixture.policy.currentTier)
            }
            XCTAssertNil(
                fixture.policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }
        XCTAssertEqual(visibleTiers, [.audioPriority, .full])
        XCTAssertEqual(probeStartedAt.duration(to: fixture.now), .milliseconds(3_000))
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 60)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
    }

    func testEarlyIntermediateCommitDoesNotDelaySubsequentFullRecovery() {
        var fixture = ProbeFixture()
        _ = fixture.sample(bandwidth: 700_000)
        XCTAssertEqual(fixture.sample(bandwidth: 700_000)?.tier, .survival)
        let committedAt = fixture.now
        var visibleTiers: [WorldwideScreenVideoAdaptationTier] = [.survival]

        _ = fixture.sample(bandwidth: 900_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .survival)
        for bandwidth in [1_465_000.0, 2_831_000, 5_662_000, 10_308_000, 15_896_000, 15_896_000] {
            let previousTier = fixture.policy.currentTier
            _ = fixture.sample(bandwidth: bandwidth)
            XCTAssertLessThanOrEqual(fixture.policy.currentTier.rawValue, previousTier.rawValue)
            if fixture.policy.currentTier != visibleTiers.last {
                visibleTiers.append(fixture.policy.currentTier)
            }
            XCTAssertNil(
                fixture.policy.automaticSuspensionDecision(
                    isCaptureActive: true,
                    isAutomaticallySuspended: false
                )
            )
        }

        XCTAssertEqual(visibleTiers, [.survival, .full])
        XCTAssertLessThanOrEqual(committedAt.duration(to: fixture.now), .milliseconds(3_500))
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 60)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
    }
}

private enum QualificationInterruption: CaseIterable {
    case missingBandwidth
    case invalidBandwidth
    case missingRTT
    case grayQueue
    case softQueueBurst
    case staleLowFPSQueue
    case cadenceReset
}

private struct ProbeFixture {
    var policy = WorldwideScreenVideoAdaptationPolicy(
        configuredTotalRTPBitrateBps: 50_000_000,
        baseFramesPerSecond: 60
    )
    var now = ContinuousClock.now
    private var packetsSent: UInt64 = 0
    private var totalPacketSendDelay = 0.0

    init() {
        XCTAssertEqual(sample(bandwidth: 100_000, afterMilliseconds: 0)?.tier, .audioPriority)
        _ = sample(bandwidth: 400_000)
        _ = sample(bandwidth: 400_000)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeHealthySampleCount, 0)
    }

    mutating func sample(
        bandwidth: Double?,
        rtt: Double? = 0.003,
        queueDelay: Double = 0.001,
        afterMilliseconds: Int = 500,
        advancesPackets: Bool = true
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        now = now.advanced(by: .milliseconds(afterMilliseconds))
        if advancesPackets {
            packetsSent += 100
            totalPacketSendDelay += queueDelay * 100
        }
        return policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt,
            outboundVideoPacketsSent: packetsSent,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay,
            observedAt: now
        )
    }
}
