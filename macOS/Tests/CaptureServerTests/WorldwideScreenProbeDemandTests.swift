import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenProbeDemandTests: XCTestCase {
    // The existing Double calculation rounds the calibrated 16.2 Mbps cap up by one bit/s.
    private let roundedFullCapacityCeilingBps = 16_200_001

    func testHighProbeAtFiftyMegabitsSurvivesStableAndRisingCapacityReports() throws {
        try assertCapacityReportsRecoverFull(from: .high)
    }

    func testBalancedProbeAtFiftyMegabitsSurvivesStableAndRisingCapacityReports() throws {
        try assertCapacityReportsRecoverFull(from: .balanced)
    }

    func testHighProbeAtFiftyMegabitsSurvivesOrdinaryReportsBelowNominalVideoCeiling() throws {
        try assertOrdinaryReportsRecoverFull(from: .high)
    }

    func testBalancedProbeAtFiftyMegabitsSurvivesOrdinaryReportsBelowNominalVideoCeiling() throws {
        try assertOrdinaryReportsRecoverFull(from: .balanced)
    }

    func testCalibratedCollapseBoundaryStillRejectsGenuineCapacityLossInBothLanes() throws {
        for origin in [WorldwideScreenVideoAdaptationTier.high, .balanced] {
            let threshold = calibratedCollapseThreshold(for: origin)
            for capacityOnly in [false, true] {
                var boundary = try ProbeDemandFixture(origin: origin)
                _ = boundary.report(bandwidth: threshold, capacityOnly: capacityOnly)
                XCTAssertEqual(boundary.policy.currentTier, origin)
                XCTAssertEqual(boundary.policy.applicationLimitedProbeOriginTier, origin)
                XCTAssertEqual(boundary.policy.applicationLimitedProbeFailureCount, 0)

                var collapsed = try ProbeDemandFixture(origin: origin)
                _ = collapsed.report(bandwidth: threshold - 1, capacityOnly: capacityOnly)
                XCTAssertNil(collapsed.policy.applicationLimitedProbeOriginTier)
                XCTAssertNil(collapsed.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
                XCTAssertEqual(collapsed.policy.applicationLimitedProbeFailureCount, 1)
                XCTAssertGreaterThan(collapsed.policy.applicationLimitedProbeCooldownSamplesRemaining, 0)
                if capacityOnly {
                    XCTAssertEqual(collapsed.policy.currentTier, origin)
                } else {
                    XCTAssertGreaterThan(collapsed.policy.currentTier.rawValue, origin.rawValue)
                }
            }
        }
    }

    func testTwoHundredMillisecondQueuePressureStillCancelsProbeInBothLanes() throws {
        for origin in [WorldwideScreenVideoAdaptationTier.high, .balanced] {
            for capacityOnly in [false, true] {
                for queueDelay in [0.200, 0.250] {
                    var fixture = try ProbeDemandFixture(origin: origin)
                    let primarySequence = fixture.policy.lastConsumedCollectionSequence
                    _ = fixture.report(
                        bandwidth: 16_200_000,
                        capacityOnly: capacityOnly,
                        queueDelay: queueDelay
                    )
                    XCTAssertEqual(fixture.policy.currentTier, origin)
                    XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
                    XCTAssertNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
                    XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
                    XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, 0)
                    if capacityOnly {
                        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, primarySequence)
                    }
                }
            }
        }
    }

    func testBalancedDemandDecisionsMatchAtTenAndFiftyMegabitsDespiteDifferentCaps() throws {
        var ten = try ProbeDemandFixture(origin: .balanced, configuredCap: 10_000_000)
        var fifty = try ProbeDemandFixture(origin: .balanced)
        XCTAssertEqual(ten.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, 10_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(fifty.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps), 10_000_000)

        for bandwidth in [7_055_000.0, 8_000_000] {
            _ = ten.fast(bandwidth: bandwidth)
            _ = fifty.fast(bandwidth: bandwidth)
            assertMatchingDemandDecisions(ten.policy, fifty.policy)
            XCTAssertEqual(ten.policy.applicationLimitedProbeOriginTier, .balanced)
            XCTAssertEqual(fifty.policy.applicationLimitedProbeOriginTier, .balanced)
            XCTAssertLessThanOrEqual(ten.policy.currentRecommendation.maximumTotalRTPBitrateBps, 10_000_000)
            XCTAssertLessThanOrEqual(fifty.policy.currentRecommendation.maximumTotalRTPBitrateBps, roundedFullCapacityCeilingBps)
        }
        _ = ten.normal(bandwidth: 8_000_000, afterMilliseconds: 100)
        _ = fifty.normal(bandwidth: 8_000_000, afterMilliseconds: 100)
        assertMatchingDemandDecisions(ten.policy, fifty.policy)
        XCTAssertEqual(ten.policy.currentTier, .balanced)
        XCTAssertEqual(fifty.policy.currentTier, .balanced)

        for _ in 0..<2 {
            _ = ten.normal(bandwidth: 9_000_000)
            _ = fifty.normal(bandwidth: 9_000_000)
            assertMatchingDemandDecisions(ten.policy, fifty.policy)
        }
        XCTAssertEqual(ten.policy.currentTier, .high)
        XCTAssertEqual(fifty.policy.currentTier, .high)
    }

    func testTenMegabitConfigurationDoesNotProbePastItsSupportedQualityCeiling() throws {
        var fixture = try ProbeDemandFixture(origin: .high, configuredCap: 10_000_000, startProbe: false)
        for _ in 0..<4 {
            _ = fixture.normal(bandwidth: 10_000_000)
            XCTAssertEqual(fixture.policy.currentTier, .high)
            XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
            XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 10_000_000)
        }
    }

    private func assertCapacityReportsRecoverFull(
        from origin: WorldwideScreenVideoAdaptationTier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var fixture = try ProbeDemandFixture(origin: origin)
        let primary = ProbeDemandPrimaryEvidence(fixture.policy)
        let originalCap = try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        let risingBandwidth = origin == .high ? 12_000_000.0 : 8_000_000.0
        for bandwidth in [fixture.originBandwidth, risingBandwidth] {
            _ = fixture.fast(bandwidth: bandwidth)
            XCTAssertEqual(ProbeDemandPrimaryEvidence(fixture.policy), primary, file: file, line: line)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, origin, file: file, line: line)
            let cap = try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
            XCTAssertGreaterThanOrEqual(cap, originalCap, file: file, line: line)
            XCTAssertLessThanOrEqual(cap, roundedFullCapacityCeilingBps, file: file, line: line)
        }
        if origin == .balanced {
            XCTAssertGreaterThan(try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps), originalCap)
        }

        _ = fixture.normal(bandwidth: 16_200_000, afterMilliseconds: 100)
        XCTAssertEqual(fixture.policy.currentTier, origin, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeBestQualifiedTier, .full, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1, file: file, line: line)
        let oneQualifiedReport = ProbeDemandPrimaryEvidence(fixture.policy)
        _ = fixture.fast(bandwidth: 16_200_000)
        XCTAssertEqual(ProbeDemandPrimaryEvidence(fixture.policy), oneQualifiedReport, file: file, line: line)
        let completed = fixture.normal(bandwidth: 16_200_000, afterMilliseconds: 300)
        XCTAssertEqual(completed?.tier, .full, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentTier, .full, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 16_200_000, file: file, line: line)
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, roundedFullCapacityCeilingBps, file: file, line: line)
    }

    private func assertOrdinaryReportsRecoverFull(
        from origin: WorldwideScreenVideoAdaptationTier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var fixture = try ProbeDemandFixture(origin: origin)
        let deadline = fixture.policy.applicationLimitedProbeDeadline
        _ = fixture.normal(bandwidth: fixture.originBandwidth)
        XCTAssertEqual(fixture.policy.currentTier, origin, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, origin, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0, file: file, line: line)

        _ = fixture.normal(bandwidth: 16_200_000)
        XCTAssertEqual(fixture.policy.currentTier, origin, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeBestQualifiedTier, .full, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.normal(bandwidth: 16_200_000)?.tier, .full, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentTier, .full, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0, file: file, line: line)
    }

    private func calibratedCollapseThreshold(for origin: WorldwideScreenVideoAdaptationTier) -> Double {
        // These are 75% of the calibrated high/balanced video demand, independent of the
        // configured sender headroom: 9,344,000 bps times the respective 67% / 42% tier.
        origin == .high ? 4_695_360 : 2_943_360
    }

    private func assertMatchingDemandDecisions(
        _ lhs: WorldwideScreenVideoAdaptationPolicy,
        _ rhs: WorldwideScreenVideoAdaptationPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.currentTier, rhs.currentTier, file: file, line: line)
        XCTAssertEqual(lhs.currentRecommendation.scaleResolutionDownBy, rhs.currentRecommendation.scaleResolutionDownBy, file: file, line: line)
        XCTAssertEqual(lhs.applicationLimitedProbeOriginTier, rhs.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertEqual(lhs.applicationLimitedProbeBestQualifiedTier, rhs.applicationLimitedProbeBestQualifiedTier, file: file, line: line)
        XCTAssertEqual(lhs.applicationLimitedProbeHealthySampleCount, rhs.applicationLimitedProbeHealthySampleCount, file: file, line: line)
        XCTAssertEqual(lhs.applicationLimitedProbeFailureCount, 0, file: file, line: line)
        XCTAssertEqual(rhs.applicationLimitedProbeFailureCount, 0, file: file, line: line)
    }
}

private struct ProbeDemandPrimaryEvidence: Equatable {
    let tier: WorldwideScreenVideoAdaptationTier
    let framesPerSecond: Int
    let scale: Double
    let sequence: UInt64?
    let deadline: ContinuousClock.Instant?
    let bestTier: WorldwideScreenVideoAdaptationTier?
    let healthyCount: Int
    let failureCount: Int
    let cooldown: Int
    let grace: Int
    let queueDelay: Double?
    let roundTripTimeBaseline: Double?
    let roundTripTimeReferenceIsProvisional: Bool

    init(_ policy: WorldwideScreenVideoAdaptationPolicy) {
        tier = policy.currentTier
        framesPerSecond = policy.currentRecommendation.maximumFramesPerSecond
        scale = policy.currentRecommendation.scaleResolutionDownBy
        sequence = policy.lastConsumedCollectionSequence
        deadline = policy.applicationLimitedProbeDeadline
        bestTier = policy.applicationLimitedProbeBestQualifiedTier
        healthyCount = policy.applicationLimitedProbeHealthySampleCount
        failureCount = policy.applicationLimitedProbeFailureCount
        cooldown = policy.applicationLimitedProbeCooldownSamplesRemaining
        grace = policy.applicationLimitedProbeGraceSamplesRemaining
        queueDelay = policy.lastAveragePacketSendDelaySeconds
        roundTripTimeBaseline = policy.roundTripTimeBaselineSeconds
        roundTripTimeReferenceIsProvisional = policy.roundTripTimeReferenceIsProvisional
    }
}

private struct ProbeDemandFixture {
    var policy: WorldwideScreenVideoAdaptationPolicy
    let originBandwidth: Double
    private var now = ContinuousClock.now
    private var clockMilliseconds = 0
    private var sequence: UInt64 = 0
    private var packets: UInt64 = 0
    private var totalPacketDelay = 0.0
    private var totalRTT = 1.0
    private var responses: UInt64 = 10

    init(
        origin: WorldwideScreenVideoAdaptationTier,
        configuredCap: Int = 50_000_000,
        startProbe: Bool = true
    ) throws {
        policy = WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: configuredCap, baseFramesPerSecond: 60)
        originBandwidth = min(Double(configuredCap), origin == .high ? 10_997_000 : 7_055_000)
        _ = normal(bandwidth: originBandwidth, afterMilliseconds: 0)
        for _ in 0..<3 {
            if policy.currentTier == origin { break }
            _ = normal(bandwidth: originBandwidth)
        }
        XCTAssertEqual(policy.currentTier, origin)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        guard startProbe else { return }
        for _ in 0..<3 {
            if policy.applicationLimitedProbeOriginTier != nil { break }
            _ = normal(bandwidth: originBandwidth)
        }
        XCTAssertEqual(policy.currentTier, origin)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, origin)
        XCTAssertEqual(policy.applicationLimitedProbeHealthySampleCount, 0)
        XCTAssertEqual(policy.applicationLimitedProbeFailureCount, 0)
        _ = try XCTUnwrap(policy.applicationLimitedProbeDeadline)
        _ = try XCTUnwrap(policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
    }

    mutating func report(bandwidth: Double, capacityOnly: Bool, queueDelay: Double = 0) -> WorldwideScreenVideoEncodingRecommendation? {
        capacityOnly
            ? fast(bandwidth: bandwidth, queueDelay: queueDelay)
            : normal(bandwidth: bandwidth, queueDelay: queueDelay)
    }

    mutating func normal(bandwidth: Double, queueDelay: Double = 0, afterMilliseconds: Int = 500) -> WorldwideScreenVideoEncodingRecommendation? {
        prepare(afterMilliseconds: afterMilliseconds, queueDelay: queueDelay)
        totalRTT += 0.005
        responses += 1
        return policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: 0.005,
            roundTripTimeObservation: observation, collectionSequence: sequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketDelay,
            nativeReportTimestampMicroseconds: nativeTimestamp, observedAt: now
        )
    }

    mutating func fast(bandwidth: Double, queueDelay: Double = 0) -> WorldwideScreenVideoEncodingRecommendation? {
        prepare(afterMilliseconds: 200, queueDelay: queueDelay)
        return policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: 0.005,
            roundTripTimeObservation: observation, collectionSequence: sequence,
            nativeReportTimestampMicroseconds: nativeTimestamp,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketDelay, observedAt: now
        )
    }

    private var observation: WebRTCRoundTripTimeObservation {
        .measurement(.init(
            selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
            totalRoundTripTimeSeconds: totalRTT, responsesReceived: responses
        ))
    }

    private var nativeTimestamp: Double { 1_000_000 + Double(clockMilliseconds) * 1_000 }

    private mutating func prepare(afterMilliseconds: Int, queueDelay: Double) {
        clockMilliseconds += afterMilliseconds
        now = now.advanced(by: .milliseconds(afterMilliseconds))
        sequence += 1
        packets += 100
        totalPacketDelay += queueDelay * 100
    }
}
