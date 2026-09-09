import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenFloorRecoveryTests: XCTestCase {
    func testRecordedQueueBurstThenTwoLowQueueReportsStartsBoundedFloorTrial() throws {
        var fixture = FloorRecoveryFixture()
        let originalCap = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
        XCTAssertEqual(originalCap, 486_001)
        _ = fixture.normal(bandwidth: 304_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        let changed = fixture.normal(bandwidth: 331_000)
        try assertActiveFloor(fixture)
        XCTAssertEqual(changed?.maximumTotalRTPBitrateBps, 662_000)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps), originalCap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, fixture.now.advanced(by: .milliseconds(3_500)))
    }

    func testCapacityOnlyReportsCannotSupplyEitherAdmissionWitness() throws {
        var fixture = FloorRecoveryFixture()
        _ = fixture.normal(bandwidth: 304_000)
        let primarySequence = fixture.policy.lastConsumedCollectionSequence
        for bandwidth in [331_000.0, 350_000] {
            _ = fixture.fast(bandwidth: bandwidth)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
            XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, primarySequence)
        }
        _ = fixture.normal(bandwidth: 361_000, afterMilliseconds: 100)
        try assertActiveFloor(fixture)
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 722_000)
    }

    func testNoPacketReportRetainsFirstWitnessButDoesNotCountOrRenewIt() throws {
        var retained = FloorRecoveryFixture()
        _ = retained.normal(bandwidth: 304_000)
        _ = retained.normal(bandwidth: 331_000, advancesPackets: false)
        XCTAssertFalse(retained.policy.floorRecoveryProbeIsActive)
        _ = retained.normal(bandwidth: 350_000)
        try assertActiveFloor(retained)

        var expired = FloorRecoveryFixture()
        _ = expired.normal(bandwidth: 304_000)
        _ = expired.normal(bandwidth: 331_000, afterMilliseconds: 1_000, advancesPackets: false)
        _ = expired.normal(bandwidth: 350_000, afterMilliseconds: 600)
        XCTAssertFalse(expired.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(expired.policy.floorRecoveryAttemptConsumed)
        _ = expired.normal(bandwidth: 361_000)
        try assertActiveFloor(expired)
    }

    func testAdmissionRequiresFiveHundredMillisecondsAndAtMostOnePointFiveSeconds() throws {
        var early = FloorRecoveryFixture()
        _ = early.normal(bandwidth: 304_000)
        _ = early.normal(bandwidth: 331_000, afterMilliseconds: 499)
        XCTAssertFalse(early.policy.floorRecoveryProbeIsActive)
        _ = early.normal(bandwidth: 350_000, afterMilliseconds: 1)
        try assertActiveFloor(early)

        var boundary = FloorRecoveryFixture()
        _ = boundary.normal(bandwidth: 304_000)
        _ = boundary.normal(bandwidth: 331_000, afterMilliseconds: 1_500)
        try assertActiveFloor(boundary)

        var gap = FloorRecoveryFixture()
        _ = gap.normal(bandwidth: 304_000)
        _ = gap.normal(bandwidth: 331_000, afterMilliseconds: 1_501)
        XCTAssertFalse(gap.policy.floorRecoveryProbeIsActive)
        _ = gap.normal(bandwidth: 350_000)
        try assertActiveFloor(gap)
    }

    func testMissingCachedOrRegressingNativeIdentityCannotAdmitFloorTrial() {
        for invalid in InvalidFloorReportIdentity.allCases {
            var fixture = FloorRecoveryFixture()
            _ = fixture.normal(bandwidth: 304_000)
            let timestamp = fixture.nativeTimestamp
            let sequence = fixture.sequence
            switch invalid {
            case .missingTimestamp:
                _ = fixture.normal(bandwidth: 331_000, timestamp: .value(nil))
            case .cachedTimestamp:
                _ = fixture.normal(bandwidth: 331_000, timestamp: .value(timestamp))
            case .regressingTimestamp:
                _ = fixture.normal(bandwidth: 331_000, timestamp: .value(timestamp - 1))
            case .nonfiniteTimestamp:
                _ = fixture.normal(bandwidth: 331_000, timestamp: .value(.nan))
            case .zeroTimestamp:
                _ = fixture.normal(bandwidth: 331_000, timestamp: .value(0))
            case .missingSequence:
                _ = fixture.normal(bandwidth: 331_000, collection: .value(nil))
            case .cachedSequence:
                _ = fixture.normal(bandwidth: 331_000, collection: .value(sequence))
            case .reorderedSequence:
                _ = fixture.normal(bandwidth: 331_000, collection: .value(sequence - 1))
            }
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive, "\(invalid)")
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed, "\(invalid)")
        }
    }

    func testNonrisingInvalidOrInsufficientBandwidthCannotAdmitTrial() {
        for bandwidth in [nil, 0, -1, Double.nan, .infinity, 300_000, 304_000] as [Double?] {
            var fixture = FloorRecoveryFixture()
            _ = fixture.normal(bandwidth: 304_000)
            _ = fixture.normal(bandwidth: bandwidth)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        }
        var insufficient = FloorRecoveryFixture()
        _ = insufficient.normal(bandwidth: 200_000)
        _ = insufficient.normal(bandwidth: 230_000)
        XCTAssertFalse(insufficient.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(insufficient.policy.floorRecoveryAttemptConsumed)
    }

    func testUnknownRTTUnavailableQueueOrInactiveCaptureCannotAdmitTrial() {
        for missingEvidence in 0..<3 {
            var fixture = FloorRecoveryFixture()
            _ = fixture.normal(bandwidth: 304_000)
            _ = fixture.normal(
                bandwidth: 331_000,
                queueDelay: missingEvidence == 1 ? nil : 0,
                validRTT: missingEvidence != 0,
                isCaptureActive: missingEvidence != 2
            )
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        }
    }

    func testSubReserveRisingReportsGrowTrialWithoutResettingVisibleFloorOrDeadline() throws {
        var fixture = try admittedFixture()
        let deadline = fixture.policy.applicationLimitedProbeDeadline
        _ = fixture.normal(bandwidth: 345_000)
        try assertActiveFloor(fixture)
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 690_000)
        let primarySequence = fixture.policy.lastConsumedCollectionSequence
        _ = fixture.fast(bandwidth: 350_000)
        try assertActiveFloor(fixture)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, primarySequence)
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 700_000)
        _ = fixture.normal(bandwidth: 355_000, afterMilliseconds: 300)
        try assertActiveFloor(fixture)
        XCTAssertLessThanOrEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, 710_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
    }

    func testSeedRelativeCollapseStillCancelsInBothLanes() throws {
        for capacityOnly in [false, true] {
            var fixture = try admittedFixture()
            _ = fixture.report(bandwidth: 248_250, capacityOnly: capacityOnly)
            try assertActiveFloor(fixture)
            _ = fixture.report(bandwidth: 248_249, capacityOnly: capacityOnly)
            assertCancelled(fixture)
        }
    }

    func testImmediateQueuePressureStillCancelsInBothLanes() throws {
        for capacityOnly in [false, true] {
            for queueDelay in [0.200, 0.250] {
                var queued = try admittedFixture()
                _ = queued.report(bandwidth: 350_000, capacityOnly: capacityOnly, queueDelay: queueDelay)
                assertCancelled(queued)
            }
        }
    }

    func testFastUnknownRTTCancelsFloorTrialImmediately() throws {
        var fixture = try admittedFixture()
        _ = fixture.fast(bandwidth: 350_000, validRTT: false)
        assertCancelled(fixture)
    }

    func testOrdinaryUnknownRTTCannotGrowOrQualifyAndStillExpiresAtOriginalDeadline() throws {
        var fixture = try admittedFixture()
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        let deadline = fixture.policy.applicationLimitedProbeDeadline
        _ = fixture.normal(bandwidth: 350_000, validRTT: false)
        try assertActiveFloor(fixture)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        XCTAssertNil(fixture.policy.applicationLimitedProbeBestQualifiedTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
        fixture.advanceClock(by: 3_000)
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: fixture.now
        )
        assertCancelled(fixture)
    }

    func testPlateauExpiresAndCannotRefundTheSameShowAttempt() throws {
        var fixture = try admittedFixture()
        for _ in 0..<6 {
            _ = fixture.normal(bandwidth: 331_000)
            try assertActiveFloor(fixture)
        }
        _ = fixture.normal(bandwidth: 331_000)
        assertCancelled(fixture)
        for bandwidth in [304_000.0, 331_000, 350_000, 361_000] {
            _ = fixture.normal(bandwidth: bandwidth)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed)
        }
    }

    func testMissingReportsCannotExtendTheOriginalHardDeadline() throws {
        var fixture = try admittedFixture()
        fixture.advanceClock(by: 3_500)
        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: 1, isCaptureActive: true, observedAt: fixture.now
        )
        assertCancelled(fixture)
    }

    func testReservedShowAndLateActivationCannotAuthorizeRecovery() throws {
        var reserved = FloorRecoveryFixture(activate: false)
        _ = reserved.normal(bandwidth: 304_000)
        _ = reserved.normal(bandwidth: 331_000)
        XCTAssertFalse(reserved.policy.floorRecoveryProbeIsActive)
        reserved.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        _ = reserved.normal(bandwidth: 350_000)
        XCTAssertFalse(reserved.policy.floorRecoveryProbeIsActive)
        _ = reserved.normal(bandwidth: 361_000)
        try assertActiveFloor(reserved)

        var ended = FloorRecoveryFixture()
        _ = ended.normal(bandwidth: 304_000)
        ended.policy.endFloorRecoveryVisibility()
        ended.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        _ = ended.normal(bandwidth: 331_000)
        _ = ended.normal(bandwidth: 350_000)
        XCTAssertFalse(ended.policy.floorRecoveryProbeIsActive)
        XCTAssertFalse(ended.policy.floorRecoveryAttemptConsumed)
    }

    func testRepeatedOrStaleShowCannotResetConsumptionButSuccessorNeedsFreshEvidence() throws {
        var fixture = try admittedFixture(showEpoch: 2)
        let admitted = fixture.policy
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 99, showEpoch: 2)
        XCTAssertEqual(fixture.policy, admitted)

        fixture.policy.endFloorRecoveryVisibility()
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed)
        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        _ = fixture.normal(bandwidth: 304_000)
        _ = fixture.normal(bandwidth: 331_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)

        fixture.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 3)
        fixture.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 3)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        drainCooldown(&fixture)
        _ = fixture.normal(bandwidth: 350_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        _ = fixture.normal(bandwidth: 361_000)
        try assertActiveFloor(fixture)
    }

    func testFailedNativeApplicationRetainsOnlyConsumptionAndCannotPoisonSuccessorShow() throws {
        var original = FloorRecoveryFixture()
        _ = original.normal(bandwidth: 304_000)
        let before = original.policy
        var proposed = original
        _ = proposed.normal(bandwidth: 331_000)
        try assertActiveFloor(proposed)
        original.policy.retainFloorRecoveryAttemptConsumption(from: proposed.policy)
        XCTAssertTrue(original.policy.floorRecoveryAttemptConsumed)
        XCTAssertFalse(original.policy.floorRecoveryProbeIsActive)
        XCTAssertEqual(original.policy.currentRecommendation, before.currentRecommendation)
        XCTAssertEqual(original.policy.lastConsumedCollectionSequence, before.lastConsumedCollectionSequence)
        XCTAssertEqual(original.policy.roundTripTimeBaselineSeconds, before.roundTripTimeBaselineSeconds)
        XCTAssertEqual(original.policy.roundTripTimeDisposition, before.roundTripTimeDisposition)
        XCTAssertEqual(original.policy.applicationLimitedProbeDeadline, before.applicationLimitedProbeDeadline)
        _ = original.normal(bandwidth: 331_000)
        _ = original.normal(bandwidth: 350_000)
        XCTAssertFalse(original.policy.floorRecoveryProbeIsActive)

        original.policy.endFloorRecoveryVisibility()
        original.policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        original.policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 2)
        original.policy.retainFloorRecoveryAttemptConsumption(from: proposed.policy)
        XCTAssertFalse(original.policy.floorRecoveryAttemptConsumed)
        _ = original.normal(bandwidth: 304_000)
        XCTAssertFalse(original.policy.floorRecoveryProbeIsActive)
        _ = original.normal(bandwidth: 331_000)
        try assertActiveFloor(original)
    }

    func testFailedOrdinaryProbeCooldownDrainsOnlyOnEligibleNormalReportsBeforeNewWitnesses() throws {
        var fixture = FloorRecoveryFixture()
        _ = fixture.normal(bandwidth: 486_001)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        _ = fixture.normal(bandwidth: 486_001, queueDelay: 0.250)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, 0)
        XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        let originalCooldown = fixture.policy.applicationLimitedProbeCooldownSamplesRemaining
        _ = fixture.fast(bandwidth: 304_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, originalCooldown)
        drainCooldown(&fixture)
        _ = fixture.normal(bandwidth: 350_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        _ = fixture.normal(bandwidth: 361_000)
        try assertActiveFloor(fixture)
    }

    func testDisprovedSubReserveOrdinaryProbeBlocksFloorTrialUntilCapacityRecovers() throws {
        var fixture = FloorRecoveryFixture()
        _ = fixture.normal(bandwidth: 486_001)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        _ = fixture.normal(bandwidth: 100_000)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        for bandwidth in [304_000.0, 331_000, 345_000, 350_000] {
            _ = fixture.normal(bandwidth: bandwidth)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(fixture.policy.floorRecoveryAttemptConsumed)
        }
        _ = fixture.normal(bandwidth: 361_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        drainCooldown(&fixture)
        _ = fixture.normal(bandwidth: 350_000)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        _ = fixture.normal(bandwidth: 361_000)
        try assertActiveFloor(fixture)
    }

    func testAutomaticResumeFailureRetiresFloorSeedBeforeAnOrdinaryProbe() throws {
        var fixture = try admittedFixture()
        fixture.policy.automaticResumeAttemptBegan()
        fixture.policy.automaticResumeAttemptFailed()
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        for _ in 0..<3 {
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
            _ = fixture.normal(bandwidth: 486_001)
        }
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        let failures = fixture.policy.applicationLimitedProbeFailureCount
        // This is below the ordinary reserve but above 75% of the retired 331 kbps seed.
        _ = fixture.fast(bandwidth: 300_000)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive)
        XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeFailureCount, failures)
    }

    private func admittedFixture(showEpoch: UInt64 = 1) throws -> FloorRecoveryFixture {
        var fixture = FloorRecoveryFixture(showEpoch: showEpoch)
        _ = fixture.normal(bandwidth: 304_000)
        _ = fixture.normal(bandwidth: 331_000)
        try assertActiveFloor(fixture)
        return fixture
    }

    private func drainCooldown(_ fixture: inout FloorRecoveryFixture, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<4 {
            guard fixture.policy.applicationLimitedProbeCooldownSamplesRemaining > 0 else { break }
            _ = fixture.normal(bandwidth: 304_000 + Double(index) * 10_000)
            XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
            let remaining = fixture.policy.applicationLimitedProbeCooldownSamplesRemaining
            _ = fixture.fast(bandwidth: 345_000)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, remaining, file: file, line: line)
        }
        XCTAssertEqual(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, 0, file: file, line: line)
    }

    private func assertActiveFloor(_ fixture: FloorRecoveryFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 12, file: file, line: line)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, file: file, line: line)
        _ = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline, file: file, line: line)
    }

    private func assertCancelled(_ fixture: FloorRecoveryFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.policy.floorRecoveryProbeIsActive, file: file, line: line)
        XCTAssertTrue(fixture.policy.floorRecoveryProbeWasCancelled, file: file, line: line)
        XCTAssertTrue(fixture.policy.floorRecoveryAttemptConsumed, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 12, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline, file: file, line: line)
    }
}

private enum InvalidFloorReportIdentity: CaseIterable {
    case missingTimestamp, cachedTimestamp, regressingTimestamp, nonfiniteTimestamp, zeroTimestamp
    case missingSequence, cachedSequence, reorderedSequence
}

private enum FloorReportTimestamp {
    case advancing
    case value(Double?)
}

private enum FloorReportSequence {
    case advancing
    case value(UInt64?)
}

private struct FloorRecoveryFixture {
    var policy = WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60)
    var now = ContinuousClock.now
    var sequence: UInt64 = 0
    private var clockMilliseconds = 0
    private var packets: UInt64 = 0
    private var totalPacketDelay = 0.0
    private var totalRTT = 1.0
    private var responses: UInt64 = 10
    var nativeTimestamp: Double { 1_000_000 + Double(clockMilliseconds) * 1_000 }

    init(showEpoch: UInt64 = 1, activate: Bool = true) {
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: showEpoch)
        if activate {
            policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: showEpoch)
        }
        _ = normal(bandwidth: 100_000, afterMilliseconds: 0)
        _ = normal(bandwidth: 100_000)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        _ = normal(bandwidth: 251_000)
        for (bandwidth, queueDelay) in [(262_000.0, 0.492), (276_000, 0.943), (292_000, 0.470)] {
            _ = normal(bandwidth: bandwidth, queueDelay: queueDelay)
            XCTAssertEqual(policy.currentTier, .audioPriority)
            XCTAssertEqual(policy.lastAveragePacketSendDelaySeconds ?? -1, queueDelay, accuracy: 0.000_001)
            XCTAssertFalse(policy.floorRecoveryProbeIsActive)
            XCTAssertFalse(policy.floorRecoveryAttemptConsumed)
        }
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
    }

    mutating func advanceClock(by milliseconds: Int) {
        clockMilliseconds += milliseconds
        now = now.advanced(by: .milliseconds(milliseconds))
    }

    mutating func report(bandwidth: Double?, capacityOnly: Bool, queueDelay: Double? = 0, validRTT: Bool = true) -> WorldwideScreenVideoEncodingRecommendation? {
        capacityOnly
            ? fast(bandwidth: bandwidth, queueDelay: queueDelay, validRTT: validRTT)
            : normal(bandwidth: bandwidth, queueDelay: queueDelay, validRTT: validRTT)
    }

    mutating func normal(
        bandwidth: Double?, queueDelay: Double? = 0, afterMilliseconds: Int = 500,
        advancesPackets: Bool = true, validRTT: Bool = true, isCaptureActive: Bool = true,
        timestamp: FloorReportTimestamp = .advancing,
        collection: FloorReportSequence = .advancing
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        prepare(afterMilliseconds: afterMilliseconds, queueDelay: queueDelay, advancesPackets: advancesPackets)
        totalRTT += 0.005
        responses += 1
        let reportTimestamp: Double?
        switch timestamp {
        case .advancing: reportTimestamp = nativeTimestamp
        case .value(let value): reportTimestamp = value
        }
        let reportSequence: UInt64?
        switch collection {
        case .advancing: reportSequence = sequence
        case .value(let value): reportSequence = value
        }
        return policy.update(
            peerGeneration: 1, isCaptureActive: isCaptureActive,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: 0.005,
            roundTripTimeObservation: validRTT ? observation : .unavailable,
            collectionSequence: reportSequence, requireRoundTripTimeObservation: true,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: queueDelay == nil ? nil : packets,
            outboundVideoTotalPacketSendDelaySeconds: queueDelay == nil ? nil : totalPacketDelay,
            nativeReportTimestampMicroseconds: reportTimestamp, observedAt: now
        )
    }

    mutating func fast(bandwidth: Double?, queueDelay: Double? = 0, validRTT: Bool = true) -> WorldwideScreenVideoEncodingRecommendation? {
        prepare(afterMilliseconds: 200, queueDelay: queueDelay, advancesPackets: true)
        return policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: 0.005,
            roundTripTimeObservation: validRTT ? observation : .unavailable,
            collectionSequence: sequence, nativeReportTimestampMicroseconds: nativeTimestamp,
            selectedRoute: WebRTCICERouteDiagnostics(kind: .direct),
            outboundVideoPacketsSent: queueDelay == nil ? nil : packets,
            outboundVideoTotalPacketSendDelaySeconds: queueDelay == nil ? nil : totalPacketDelay,
            observedAt: now
        )
    }

    private var observation: WebRTCRoundTripTimeObservation {
        .measurement(.init(
            selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
            totalRoundTripTimeSeconds: totalRTT, responsesReceived: responses
        ))
    }

    private mutating func prepare(afterMilliseconds: Int, queueDelay: Double?, advancesPackets: Bool) {
        advanceClock(by: afterMilliseconds)
        sequence += 1
        if advancesPackets {
            packets += 100
            totalPacketDelay += (queueDelay ?? 0) * 100
        }
    }
}
