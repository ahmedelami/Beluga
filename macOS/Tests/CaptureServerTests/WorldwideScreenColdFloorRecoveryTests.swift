import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenColdFloorRecoveryTests: XCTestCase {
    func testColdFirstShowStableBandwidthAdmitsOnSecondLowQueueWitness() throws {
        try assertColdPlateauRecovery(configuredBitrate: 50_000_000)
    }

    func testColdStableBandwidthDoesNotDependOnConfiguredSenderCeiling() throws {
        try assertColdPlateauRecovery(configuredBitrate: 10_000_000)
    }

    func testBandwidthFallBetweenWitnessesRequiresANewCompleteWindow() throws {
        var fixture = ColdFloorRecoveryFixture(configuredBitrate: 50_000_000)
        prepareFirstWitness(&fixture)

        // An early ordinary completion still carries negative evidence. Returning to the
        // first value at 1,500 ms must not reuse the pre-fall witness from 1,000 ms.
        _ = fixture.ordinary(at: 1_250, bandwidth: 300_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        _ = fixture.ordinary(at: 1_500)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive,
                       "The bandwidth fall must invalidate the original witness")
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)

        let recovered = fixture.ordinary(at: 2_000)
        let recommendation = try XCTUnwrap(recovered,
            "Two post-fall stable witnesses must allow the bounded floor trial")
        assertVisibleFloor(fixture.policy)
        XCTAssertTrue(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed)
        XCTAssertEqual(recommendation.maximumTotalRTPBitrateBps, 612_000)
    }

    func testColdPlateauWithoutRTTProofCannotSupplyAdmissionWitnesses() {
        var fixture = ColdFloorRecoveryFixture(configuredBitrate: 50_000_000)
        for milliseconds in stride(from: 0, through: 3_000, by: 500) {
            _ = fixture.ordinary(at: milliseconds, hasRTT: false)
            assertVisibleFloor(fixture.policy)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
            XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 486_001)
        }
    }

    func testDiagnosticsDoNotChangeAdmissionEarlyOrFallingDecisions() throws {
        for scenario in [ColdFloorDiagnosticScenario.admitted, .tooEarly, .bandwidthFalling] {
            try assertDiagnosticsDoNotChangePolicy(for: scenario)
        }
    }

    func testDiagnosticsPreserveWitnessSnapshotAcrossRejectedEvidence() throws {
        for scenario in [ColdFloorDiagnosticScenario.rttBlocked, .invalidBandwidth, .queueBlocked,
                         .noNewPackets, .rejectedTimestamp, .rejectedOrder] {
            try assertDiagnosticsDoNotChangePolicy(for: scenario)
        }
    }

    func testNoPacketBandwidthFallRetiresWitnessBeforeAStableRecoveryWindow() throws {
        var fixture = ColdFloorRecoveryFixture(configuredBitrate: 50_000_000)
        prepareFirstWitness(&fixture)
        var events: [WorldwideScreenFloorRecoveryDiagnostics] = []
        _ = fixture.ordinary(at: 1_250, bandwidth: 300_000, advancesPackets: false) {
            events.append($0)
        }
        XCTAssertEqual(events.count, 1)
        let falling = try XCTUnwrap(events.first)
        XCTAssertEqual(falling.reason, .bandwidthFalling)
        XCTAssertEqual(falling.queueKind, .noNewPackets)
        XCTAssertEqual(falling.firstBandwidthBps, 306_000)
        XCTAssertEqual(falling.witnessAgeMicroseconds, 250_000)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)

        events.removeAll()
        _ = fixture.ordinary(at: 1_500) { events.append($0) }
        XCTAssertEqual(events.count, 1)
        let renewed = try XCTUnwrap(events.first)
        XCTAssertEqual(renewed.reason, .firstWitness)
        XCTAssertNil(renewed.firstBandwidthBps)
        XCTAssertNil(renewed.witnessAgeMicroseconds)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)

        events.removeAll()
        let recovered = fixture.ordinary(at: 2_000) { events.append($0) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.reason, .admitted)
        XCTAssertEqual(recovered?.maximumTotalRTPBitrateBps, 612_000)
        XCTAssertTrue(fixture.policy.floorRecoveryProbeIsActive)
        assertVisibleFloor(fixture.policy)
    }

    private func assertDiagnosticsDoNotChangePolicy(
        for scenario: ColdFloorDiagnosticScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var original = ColdFloorRecoveryFixture(configuredBitrate: 50_000_000)
        prepareFirstWitness(&original, file: file, line: line)
        var observed = original
        var silent = original
        var events: [WorldwideScreenFloorRecoveryDiagnostics] = []
        let observedRecommendation = scenario.apply(to: &observed) { events.append($0) }
        let silentRecommendation = scenario.apply(to: &silent, diagnostics: nil)
        XCTAssertEqual(observed.policy, silent.policy, "\(scenario)", file: file, line: line)
        XCTAssertEqual(observedRecommendation, silentRecommendation, "\(scenario)", file: file, line: line)
        XCTAssertEqual(events.count, 1, "\(scenario)", file: file, line: line)
        let event = try XCTUnwrap(events.first, file: file, line: line)
        XCTAssertEqual(event.reason, scenario.reason, "\(scenario)", file: file, line: line)
        XCTAssertEqual(event.firstBandwidthBps, 306_000, file: file, line: line)
        XCTAssertEqual(event.currentBandwidthBps, scenario == .invalidBandwidth ? nil
                       : scenario == .bandwidthFalling ? 300_000 : 306_000, file: file, line: line)
        XCTAssertEqual(event.trend, scenario == .invalidBandwidth ? .unknown
                       : scenario == .bandwidthFalling ? .falling : .flat, file: file, line: line)
        XCTAssertEqual(event.witnessAgeMicroseconds,
                       scenario == .tooEarly ? 250_000 : 500_000, file: file, line: line)
        XCTAssertEqual(event.showEpoch, 1, file: file, line: line)
        XCTAssertTrue(event.reserved, file: file, line: line)
        XCTAssertTrue(event.active, file: file, line: line)
        XCTAssertFalse(event.consumed, file: file, line: line)
        XCTAssertFalse(event.disproved, file: file, line: line)
        XCTAssertEqual(event.cooldownRemaining, 0, file: file, line: line)
        XCTAssertEqual(event.beforeTotalCapBps, 486_001, file: file, line: line)
        XCTAssertEqual(event.previousRegularSequence, 3, file: file, line: line)
        XCTAssertEqual(event.previousRegularReportMicroseconds, 2_000_000, file: file, line: line)
        XCTAssertEqual(event.collectionSequence, scenario == .rejectedOrder ? 3 : 4, file: file, line: line)
        XCTAssertEqual(event.identity, scenario == .rejectedOrder ? .rejectedOrder
                       : scenario == .rejectedTimestamp ? .rejectedTimestamp : .fresh, file: file, line: line)

        if scenario == .admitted {
            XCTAssertEqual(event.proposedTotalCapBps, 612_000, file: file, line: line)
            XCTAssertEqual(observedRecommendation?.maximumTotalRTPBitrateBps, 612_000, file: file, line: line)
            XCTAssertTrue(observed.policy.floorRecoveryAttemptConsumed, file: file, line: line)
            XCTAssertFalse(event.logFields.contains("nativeApply"), file: file, line: line)
        } else {
            XCTAssertEqual(event.proposedTotalCapBps, 486_001, file: file, line: line)
            XCTAssertFalse(observed.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        }
        if scenario == .rejectedOrder {
            XCTAssertEqual(event.queueKind, .notChecked, file: file, line: line)
            XCTAssertNil(event.roundTripTimeDisposition, file: file, line: line)
        } else {
            XCTAssertEqual(event.queueKind, scenario == .noNewPackets ? .noNewPackets : .measured,
                           file: file, line: line)
            XCTAssertEqual(event.queueMicroseconds, scenario == .noNewPackets ? nil
                           : scenario == .queueBlocked ? 50_000 : 0, file: file, line: line)
            XCTAssertEqual(event.roundTripTimeDisposition, scenario == .rttBlocked ? .unavailable : .retainedHealthy,
                           file: file, line: line)
            XCTAssertEqual(event.roundTripTimeAllowsUpgrade, scenario != .rttBlocked, file: file, line: line)
        }
        assertVisibleFloor(observed.policy, file: file, line: line)
    }

    private func assertColdPlateauRecovery(
        configuredBitrate: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var fixture = ColdFloorRecoveryFixture(configuredBitrate: configuredBitrate)
        prepareFirstWitness(&fixture, file: file, line: line)
        let firstRTTReference = fixture.policy.roundTripTimeBaselineSeconds
        let changed = fixture.ordinary(at: 1_500)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedHealthy, file: file, line: line)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds,
                       firstRTTReference, file: file, line: line)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional, file: file, line: line)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .milliseconds(500), file: file, line: line)
        let recommendation = try XCTUnwrap(changed,
            "Constant 306 kbps must admit by the second advancing low-queue witness; it must not wait for a BWE rise or another native ping",
            file: file, line: line)
        XCTAssertTrue(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(recommendation.maximumTotalRTPBitrateBps, 612_000, file: file, line: line)
        XCTAssertLessThanOrEqual(recommendation.maximumTotalRTPBitrateBps, 2 * 306_000, file: file, line: line)
        assertVisibleFloor(fixture.policy, file: file, line: line)
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline, file: file, line: line)
        XCTAssertEqual(deadline, fixture.now.advanced(by: .milliseconds(3_500)), file: file, line: line)

        // Ordinary identities and packet counters advance every 500 ms; native RTT advances
        // only every 2,500 ms. Neither cached RTT nor a flat BWE renews the probe deadline.
        for milliseconds in stride(from: 2_000, through: 4_000, by: 500) {
            _ = fixture.ordinary(at: milliseconds)
            XCTAssertTrue(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline, file: file, line: line)
            XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 612_000, file: file, line: line)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0, file: file, line: line)
            XCTAssertNil(fixture.policy.applicationLimitedProbeBestQualifiedTier, file: file, line: line)
            assertVisibleFloor(fixture.policy, file: file, line: line)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition,
                           milliseconds == 3_500 ? .freshHealthy : .retainedHealthy,
                           file: file, line: line)
        }
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional, file: file, line: line)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .milliseconds(500), file: file, line: line)
    }

    private func prepareFirstWitness(
        _ fixture: inout ColdFloorRecoveryFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(fixture.policy.currentTier, .survival, file: file, line: line)
        XCTAssertNil(fixture.policy.roundTripTimeBaselineSeconds, file: file, line: line)
        for milliseconds in [0, 500] {
            _ = fixture.ordinary(at: milliseconds, hasRTT: false)
            assertVisibleFloor(fixture.policy, file: file, line: line)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable, file: file, line: line)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        }
        _ = fixture.ordinary(at: 1_000)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .provisionalHealthy, file: file, line: line)
        XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, 0.004, file: file, line: line)
        XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional, file: file, line: line)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, .zero, file: file, line: line)
        XCTAssertEqual(fixture.policy.lastAveragePacketSendDelaySeconds, 0, file: file, line: line)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, 3, file: file, line: line)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 486_001, file: file, line: line)
    }

    private func assertVisibleFloor(
        _ policy: WorldwideScreenVideoAdaptationPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(policy.currentTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.maximumFramesPerSecond, 1, file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.scaleResolutionDownBy, 12, file: file, line: line)
    }
}

private enum ColdFloorDiagnosticScenario: Equatable {
    case admitted, tooEarly, bandwidthFalling, rttBlocked, invalidBandwidth
    case queueBlocked, noNewPackets, rejectedTimestamp, rejectedOrder

    var reason: WorldwideScreenFloorRecoveryDiagnostics.Reason {
        switch self {
        case .admitted: .admitted
        case .tooEarly: .tooEarly
        case .bandwidthFalling: .bandwidthFalling
        case .rttBlocked: .rttBlocked
        case .invalidBandwidth: .invalidBandwidth
        case .queueBlocked: .queueBlocked
        case .noNewPackets: .noNewPackets
        case .rejectedTimestamp: .rejectedTimestamp
        case .rejectedOrder: .rejectedOrder
        }
    }

    func apply(
        to fixture: inout ColdFloorRecoveryFixture,
        diagnostics: ((WorldwideScreenFloorRecoveryDiagnostics) -> Void)?
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        fixture.ordinary(
            at: self == .tooEarly ? 1_250 : 1_500,
            bandwidth: self == .bandwidthFalling ? 300_000 : self == .invalidBandwidth ? 0 : 306_000,
            hasRTT: self != .rttBlocked,
            advancesPackets: self != .noNewPackets,
            queueDelay: self == .queueBlocked ? 0.050 : 0,
            nativeTimestampOverride: self == .rejectedTimestamp ? 2_000_000 : nil,
            collectionSequenceOverride: self == .rejectedOrder ? 3 : nil,
            diagnostics: diagnostics
        )
    }
}

private struct ColdFloorRecoveryFixture {
    var policy: WorldwideScreenVideoAdaptationPolicy
    private let origin = ContinuousClock.now
    private(set) var now = ContinuousClock.now
    private var sequence: UInt64 = 0
    private var packets: UInt64 = 0
    private var totalPacketDelay = 0.0

    init(configuredBitrate: Int) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: configuredBitrate,
            baseFramesPerSecond: 60
        )
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
    }

    mutating func ordinary(
        at milliseconds: Int,
        bandwidth: Double = 306_000,
        hasRTT: Bool = true,
        advancesPackets: Bool = true,
        queueDelay: Double? = 0,
        nativeTimestampOverride: Double? = nil,
        collectionSequenceOverride: UInt64? = nil,
        diagnostics: ((WorldwideScreenFloorRecoveryDiagnostics) -> Void)? = nil
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        now = origin.advanced(by: .milliseconds(milliseconds))
        sequence += 1
        if advancesPackets {
            packets += 10
            totalPacketDelay += (queueDelay ?? 0) * 10
        }
        let completedPings = max(0, milliseconds - 1_000) / 2_500 + 1
        let observation: WebRTCRoundTripTimeObservation = hasRTT
            ? .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: Double(completedPings) * 0.004,
                responsesReceived: UInt64(completedPings)
            ))
            : .unavailable
        return policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: observation,
            collectionSequence: collectionSequenceOverride ?? sequence, requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: queueDelay == nil ? nil : packets,
            outboundVideoTotalPacketSendDelaySeconds: queueDelay == nil ? nil : totalPacketDelay,
            nativeReportTimestampMicroseconds: nativeTimestampOverride ?? (1_000_000 + Double(milliseconds) * 1_000),
            observedAt: now,
            diagnostics: diagnostics
        )
    }
}
