import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenVideoProbeCadenceTests: XCTestCase {
    func testFastCapacityGrowthPreservesPrimaryEvidenceGeometryAndDeadline() throws {
        var fixture = CapacityCadenceFixture()
        let primary = PrimaryCadenceState(fixture.policy)
        let fullCap = fixture.policy.recommendation(for: .full).maximumTotalRTPBitrateBps
        var previousCap = try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        for bandwidth in [950_000.0, 1_800_000, 3_500_000, 6_500_000, 12_000_000] {
            let changed = fixture.fast(bandwidth: bandwidth)
            let cap = try XCTUnwrap(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
            XCTAssertGreaterThan(cap, previousCap)
            XCTAssertLessThanOrEqual(cap, Int(bandwidth * 2))
            XCTAssertLessThanOrEqual(cap, fullCap)
            XCTAssertLessThanOrEqual(cap, fixture.policy.configuredTotalRTPBitrateBps)
            XCTAssertEqual(changed?.maximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
            previousCap = cap
        }
        XCTAssertEqual(previousCap, fullCap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)

        _ = fixture.normal(bandwidth: 15_390_000)
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 1)
        XCTAssertEqual(fixture.normal(bandwidth: 15_390_000)?.tier, .full)
    }

    func testSameCapLimitedNativeFeedbackReachesFullSoonerWithIntermediateReports() throws {
        let ordinary = try runCapacityLimitedPath(accelerated: false)
        let accelerated = try runCapacityLimitedPath(accelerated: true)
        XCTAssertLessThan(accelerated.fullCapMilliseconds, ordinary.fullCapMilliseconds)
        XCTAssertLessThan(accelerated.fullGeometryMilliseconds, ordinary.fullGeometryMilliseconds)
        XCTAssertLessThanOrEqual(accelerated.fullCapMilliseconds, 1_000)
        XCTAssertLessThanOrEqual(accelerated.fullGeometryMilliseconds, 2_000)
        XCTAssertGreaterThanOrEqual(ordinary.fullCapMilliseconds, 2_000)
        XCTAssertEqual(accelerated.visibleTiers, [.audioPriority, .full])
        XCTAssertEqual(ordinary.visibleTiers, [.audioPriority, .full])
    }

    func testFastReportsCannotStartAProbeOrOperateInactiveCapture() {
        var unstarted = CapacityCadenceFixture(startProbe: false)
        _ = unstarted.policy.bind(toPeerGeneration: 1)
        let before = unstarted.policy
        XCTAssertNil(unstarted.fast(bandwidth: 50_000_000))
        XCTAssertEqual(unstarted.policy, before)

        var inactive = CapacityCadenceFixture()
        let activeState = inactive.policy
        XCTAssertNil(inactive.fast(bandwidth: 950_000, isCaptureActive: false))
        XCTAssertEqual(inactive.policy, activeState)
    }

    func testWrongPeerCannotGrowOrCancelCurrentOwnersProbe() {
        var fixture = CapacityCadenceFixture()
        let before = fixture.policy
        fixture.peer = 2
        fixture.observation = .unavailable
        XCTAssertNil(fixture.fast(bandwidth: 100_000, queueDelay: 0.250))
        XCTAssertEqual(fixture.policy, before)
    }

    func testMissingEqualRegressingAndInvalidNativeTimestampsCannotGrowCapacity() {
        for timestamp in [nil, 0, -1, Double.nan, .infinity, -.infinity, 2_000_000, 1_999_999] as [Double?] {
            var fixture = CapacityCadenceFixture()
            let primary = PrimaryCadenceState(fixture.policy)
            let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
            XCTAssertNil(fixture.fast(bandwidth: 950_000, timestamp: .value(timestamp)))
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
        }
    }

    func testNewCollectionSequencesCannotRebrandOneCachedNativeReport() {
        var fixture = CapacityCadenceFixture()
        _ = fixture.fast(bandwidth: 950_000)
        let timestamp = fixture.nativeTimestamp
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        let primary = PrimaryCadenceState(fixture.policy)
        for _ in 0..<5 {
            XCTAssertNil(fixture.fast(bandwidth: 8_000_000, timestamp: .value(timestamp)))
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
        }
    }

    func testMissingDuplicateAndOlderCollectionSequencesCannotGrowCapacity() {
        for sequence in [nil, 0, 2, 3] as [UInt64?] {
            var fixture = CapacityCadenceFixture()
            let primary = PrimaryCadenceState(fixture.policy)
            let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
            XCTAssertNil(fixture.fast(bandwidth: 950_000, sequence: .value(sequence)))
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
        }
        var fixture = CapacityCadenceFixture()
        _ = fixture.fast(bandwidth: 950_000)
        let sequence = fixture.sequence
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        XCTAssertNil(fixture.fast(bandwidth: 1_800_000, sequence: .value(sequence)))
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
    }

    func testOlderPrimaryReportCannotOverwriteNewerCapacityLaneEvidence() {
        var fixture = CapacityCadenceFixture()
        _ = fixture.fast(bandwidth: 950_000, sequence: .value(10))
        let primary = PrimaryCadenceState(fixture.policy)
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        fixture.observation = .unavailable
        XCTAssertNil(fixture.normal(bandwidth: 100_000, rtt: 0.500, queueDelay: 0.250, sequence: .value(9)))
        XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
    }

    func testRepeatedEqualBandwidthCannotCompoundTheSpeculativeCeiling() {
        var fixture = CapacityCadenceFixture()
        _ = fixture.fast(bandwidth: 950_000)
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        let primary = PrimaryCadenceState(fixture.policy)
        for _ in 0..<5 {
            XCTAssertNil(fixture.fast(bandwidth: 950_000))
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
        }
    }

    func testFreshInvalidBandwidthHoldsCapacityUntilPrimaryReportClearsVeto() {
        for bandwidth in [nil, 0, -1, Double.nan, .infinity] as [Double?] {
            var fixture = CapacityCadenceFixture()
            let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
            let primary = PrimaryCadenceState(fixture.policy)
            _ = fixture.fast(bandwidth: bandwidth)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
            _ = fixture.fast(bandwidth: 950_000)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            _ = fixture.normal(bandwidth: 950_000)
            let recoveredCap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps ?? 0
            _ = fixture.fast(bandwidth: 1_800_000)
            XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps ?? 0, recoveredCap)
        }
    }

    func testGenuineFastBandwidthCollapseCancelsOnlySpeculativeCapacity() {
        var fixture = CapacityCadenceFixture()
        let primarySequence = fixture.policy.lastConsumedCollectionSequence
        _ = fixture.fast(bandwidth: 100_000)
        assertFailedAtOrigin(fixture)
        XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, primarySequence)
    }

    func testTinyBandwidthDeclineDoesNotRestartAnOtherwiseHealthyProbe() {
        var fixture = CapacityCadenceFixture()
        _ = fixture.fast(bandwidth: 950_000)
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        let primary = PrimaryCadenceState(fixture.policy)
        _ = fixture.fast(bandwidth: 948_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
        XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
    }

    func testFreshUnknownMalformedOrInflatedRTTCancelsWithoutRepeatedDescent() {
        for invalid in InvalidCapacityRTT.allCases {
            var fixture = CapacityCadenceFixture()
            let baseline = fixture.policy.roundTripTimeBaselineSeconds
            var scalar: Double? = 0.005
            switch invalid {
            case .missingObservation: fixture.observation = nil
            case .unavailable: fixture.observation = .unavailable
            case .missingScalar: scalar = nil
            case .invalidScalar: scalar = .nan
            case .changedCachedScalar: scalar = 0.080
            case .distinctInflated:
                fixture.advanceRTT(by: 0.080)
                scalar = 0.080
            case .invalidFingerprint:
                fixture.observation = .measurement(.init(selectedCandidatePairFingerprint: "not-a-fingerprint", totalRoundTripTimeSeconds: 1, responsesReceived: 10))
            }
            _ = fixture.fast(bandwidth: 950_000, rtt: scalar)
            assertFailedAtOrigin(fixture)
            let failures = fixture.policy.applicationLimitedProbeFailureCount
            let cooldown = fixture.policy.applicationLimitedProbeCooldownSamplesRemaining
            for _ in 0..<3 { _ = fixture.fast(bandwidth: 1_800_000, rtt: scalar) }
            XCTAssertEqual(fixture.policy.currentTier, .audioPriority)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, failures)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, cooldown)
            XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
        }
    }

    func testFastDistinctRTTMeasurementsCannotRenewPrimaryHealthLease() {
        var fixture = CapacityCadenceFixture()
        let baseline = fixture.policy.roundTripTimeBaselineSeconds
        for _ in 0..<6 {
            fixture.advanceRTT(by: 0.005)
            let bandwidth = Double(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps) * 0.95
            _ = fixture.fast(bandwidth: bandwidth, afterMilliseconds: 400)
            XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
            XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
            XCTAssertTrue(fixture.policy.roundTripTimeReferenceIsProvisional)
            XCTAssertEqual(fixture.policy.lastConsumedCollectionSequence, 3)
        }
        fixture.advanceRTT(by: 0.005)
        _ = fixture.fast(bandwidth: 15_390_000, afterMilliseconds: 700)
        XCTAssertLessThan(fixture.now, fixture.probeStartedAt.advanced(by: .milliseconds(3_500)))
        assertFailedAtOrigin(fixture)
    }

    func testFastPairReplacementPoisonsRegularABA() {
        var fixture = CapacityCadenceFixture()
        let original = fixture.observation
        fixture.observation = .measurement(.init(selectedCandidatePairFingerprint: String(repeating: "b", count: 64), totalRoundTripTimeSeconds: 2, responsesReceived: 20))
        _ = fixture.fast(bandwidth: 950_000)
        assertFailedAtOrigin(fixture)
        fixture.observation = original
        _ = fixture.normal(bandwidth: 950_000)
        assertRTTIsUnknown(fixture)
        fixture.advanceRTT(by: 0.005)
        _ = fixture.normal(bandwidth: 950_000)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
    }

    func testFastMalformedThenRepairedCachedRTTRemainsUnknown() {
        for malformed in [false, true] {
            var fixture = CapacityCadenceFixture()
            let original = fixture.observation
            if malformed {
                fixture.observation = .measurement(.init(selectedCandidatePairFingerprint: "bad", totalRoundTripTimeSeconds: 1, responsesReceived: 10))
            }
            _ = fixture.fast(bandwidth: 950_000, rtt: malformed ? 0.005 : 0.080)
            assertFailedAtOrigin(fixture)
            fixture.observation = original
            _ = fixture.normal(bandwidth: 950_000)
            assertRTTIsUnknown(fixture)
            fixture.advanceRTT(by: 0.005)
            _ = fixture.normal(bandwidth: 950_000)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        }
    }

    func testRegularRTTRegressionAgainstEarlierFastObservationReseedsUnknown() {
        var fixture = CapacityCadenceFixture()
        let original = fixture.observation
        fixture.advanceRTT(by: 0.005)
        _ = fixture.fast(bandwidth: 950_000)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        fixture.observation = original
        _ = fixture.normal(bandwidth: 950_000)
        assertRTTIsUnknown(fixture)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0)
    }

    func testFastRTTRegressionAgainstEarlierFastObservationReseedsUnknown() {
        var fixture = CapacityCadenceFixture()
        let original = fixture.observation
        fixture.advanceRTT(by: 0.005)
        _ = fixture.fast(bandwidth: 950_000)
        fixture.observation = original
        _ = fixture.fast(bandwidth: 1_800_000)
        assertFailedAtOrigin(fixture)
        _ = fixture.normal(bandwidth: 950_000)
        assertRTTIsUnknown(fixture)
    }

    func testFailedNativeCapApplyRetainsOnlyObservedIdentityNotBudgetOrHealth() {
        var fixture = CapacityCadenceFixture()
        let originalObservation = fixture.observation
        let originalPolicy = fixture.policy
        fixture.advanceRTT(by: 0.005)
        _ = fixture.fast(bandwidth: 950_000)
        let proposed = fixture.policy
        XCTAssertGreaterThan(proposed.currentRecommendation.maximumTotalRTPBitrateBps, originalPolicy.currentRecommendation.maximumTotalRTPBitrateBps)
        fixture.policy = originalPolicy
        fixture.policy.retainCapacityProbeObservationIdentity(from: proposed)
        XCTAssertEqual(PrimaryCadenceState(fixture.policy), PrimaryCadenceState(originalPolicy))
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, originalPolicy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        XCTAssertEqual(fixture.policy.roundTripTimeObservationAge, originalPolicy.roundTripTimeObservationAge)
        XCTAssertEqual(fixture.policy.roundTripTimeReferenceIsProvisional, originalPolicy.roundTripTimeReferenceIsProvisional)
        fixture.observation = originalObservation
        _ = fixture.normal(bandwidth: 950_000)
        assertRTTIsUnknown(fixture)
    }

    func testFastInflatedRTTStillAppliesPressureOnceOnRegularSample() {
        var fixture = CapacityCadenceFixture()
        _ = fixture.normal(bandwidth: 950_000)
        _ = fixture.normal(bandwidth: 950_000)
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        for _ in 0..<3 {
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
            fixture.advanceRTT(by: 0.005)
            _ = fixture.normal(bandwidth: 900_000)
        }
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, .survival)
        fixture.advanceRTT(by: 0.080)
        _ = fixture.fast(bandwidth: 950_000, rtt: 0.080)
        XCTAssertEqual(fixture.policy.currentTier, .survival)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1)
        _ = fixture.normal(bandwidth: 950_000, rtt: 0.080)
        XCTAssertEqual(fixture.policy.currentTier, .emergency)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshInflated)
        _ = fixture.normal(bandwidth: 950_000, rtt: 0.080)
        XCTAssertEqual(fixture.policy.currentTier, .emergency)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .retainedInflated)
    }

    func testNeutralOrMissingQueueHoldsCapacityAndLatchesUntilPrimaryReport() {
        for invalid in InvalidCapacityQueue.allCases {
            var fixture = CapacityCadenceFixture()
            let primary = PrimaryCadenceState(fixture.policy)
            let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
            var queueDelay = 0.001
            var advancesPackets = true
            var includeQueue = true
            switch invalid {
            case .gray: queueDelay = 0.0348
            case .softPressure: queueDelay = 0.1111
            case .missing: includeQueue = false
            case .nan: fixture.delay = .nan; advancesPackets = false
            case .packetReset: fixture.packets = 0; advancesPackets = false
            case .delayReset: fixture.delay = 0; advancesPackets = false
            }
            _ = fixture.fast(bandwidth: 950_000, queueDelay: queueDelay, advancesPackets: advancesPackets, includeQueue: includeQueue)
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
            fixture.packets = 1_000
            fixture.delay = 1
            for _ in 0..<2 { _ = fixture.fast(bandwidth: 950_000) }
            XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, cap)
            XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
            _ = fixture.normal(bandwidth: 950_000)
            let recoveredCap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps ?? 0
            _ = fixture.fast(bandwidth: 1_800_000)
            XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps ?? 0, recoveredCap)
        }
    }

    func testGenuineFastQueuePressureCancelsWithoutConsumingPrimaryPressureWindow() {
        for queueDelay in [0.200, 0.250] {
            var fixture = CapacityCadenceFixture()
            let baseline = fixture.policy.lastAveragePacketSendDelaySeconds
            _ = fixture.fast(bandwidth: 950_000, queueDelay: queueDelay)
            assertFailedAtOrigin(fixture)
            XCTAssertEqual(fixture.policy.lastAveragePacketSendDelaySeconds, baseline)
            XCTAssertEqual(fixture.policy.queuePressureSampleCount, 0)
        }
    }

    func testNoPacketFastSampleMayUseOnlyUnexpiredPrimaryLowQueueLease() {
        var fixture = CapacityCadenceFixture()
        let cap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        XCTAssertNotNil(fixture.fast(bandwidth: 950_000, advancesPackets: false))
        XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps ?? 0, cap ?? 0)
        for bandwidth in [1_800_000.0, 3_500_000, 6_500_000] {
            _ = fixture.fast(bandwidth: bandwidth, afterMilliseconds: 400)
            XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        }
        // These fresh fast packet deltas must not extend the primary lease past 1.5 seconds.
        _ = fixture.fast(bandwidth: 12_000_000, afterMilliseconds: 200, advancesPackets: false)
        XCTAssertEqual(fixture.probeStartedAt.duration(to: fixture.now), .milliseconds(1_600))
        let heldCap = fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps
        XCTAssertNotNil(heldCap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 0)
        _ = fixture.fast(bandwidth: 12_000_000)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, heldCap)
    }

    func testCachedFastReportsCannotExtendTheAbsoluteProbeDeadline() throws {
        var fixture = CapacityCadenceFixture()
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        fixture.advanceRTT(by: 0.005)
        _ = fixture.normal(bandwidth: 486_001, afterMilliseconds: 1_000)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        let timestamp = fixture.nativeTimestamp
        for _ in 0..<12 {
            _ = fixture.fast(bandwidth: 486_001, timestamp: .value(timestamp))
            XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        }
        _ = fixture.fast(bandwidth: 486_001, afterMilliseconds: 100, timestamp: .value(timestamp))
        XCTAssertEqual(fixture.now, deadline)
        assertFailedAtOrigin(fixture)
    }

    func testSamePeerRouteChangeCancelsProbeWithoutAdoptingNewRoute() {
        for advancingFastTuple in [false, true] {
            var fixture = CapacityCadenceFixture()
            let baseline = fixture.policy.roundTripTimeBaselineSeconds
            if advancingFastTuple { fixture.advanceRTT(by: 0.005) }
            fixture.route = WebRTCICERouteDiagnostics(kind: .relayed)
            _ = fixture.fast(bandwidth: 950_000)
            assertFailedAtOrigin(fixture)
            XCTAssertEqual(fixture.policy.selectedRoute, WebRTCICERouteDiagnostics(kind: .direct))
            XCTAssertEqual(fixture.policy.roundTripTimeBaselineSeconds, baseline)
            fixture.route = WebRTCICERouteDiagnostics(kind: .direct)
            _ = fixture.normal(bandwidth: 950_000)
            assertRTTIsUnknown(fixture)
            fixture.advanceRTT(by: 0.005)
            _ = fixture.normal(bandwidth: 950_000)
            XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .freshHealthy)
        }
    }

    func testFastLaneCannotRestoreHealthRevokedBySynchronousHide() {
        var fixture = CapacityCadenceFixture()
        fixture.policy.invalidateRoundTripTimeObservation()
        fixture.policy.resetIncompleteEvidenceWindow()
        fixture.advanceRTT(by: 0.005)
        _ = fixture.fast(bandwidth: 950_000)
        assertFailedAtOrigin(fixture)
        XCTAssertEqual(fixture.policy.roundTripTimeDisposition, .unavailable)
    }

    func testOrdinaryCadenceAndIndependentPressureWindowsRemainUnchanged() {
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.sampleIntervalMilliseconds, 500)
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.fallbackSampleIntervalMilliseconds, 1_000)
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.requiredHealthyUpgradeSampleCount, 2)
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.requiredQueuePressureSampleCount, 2)
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.requiredBandwidthOnlyDowngradeSampleCount, 2)
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.applicationLimitedProbeGraceDuration, .milliseconds(3_500))
        XCTAssertEqual(WorldwideScreenVideoAdaptationPolicy.promotionCapacityContinuityDuration, .seconds(2))
    }

    private func assertFailedAtOrigin(_ fixture: CapacityCadenceFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.policy.currentTier, .audioPriority, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 12, file: file, line: line)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 1, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, file: file, line: line)
        XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline, file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeFailureCount, 1, file: file, line: line)
        XCTAssertGreaterThan(fixture.policy.applicationLimitedProbeCooldownSamplesRemaining, 0, file: file, line: line)
    }

    private func assertRTTIsUnknown(_ fixture: CapacityCadenceFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue([.unavailable, .reseeded, .expired].contains(fixture.policy.roundTripTimeDisposition), file: file, line: line)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeHealthySampleCount, 0, file: file, line: line)
    }

    private func runCapacityLimitedPath(accelerated: Bool) throws -> CapacityRampResult {
        var fixture = CapacityCadenceFixture()
        let fullCap = fixture.policy.recommendation(for: .full).maximumTotalRTPBitrateBps
        var fullCapMilliseconds: Int?
        var fullGeometryMilliseconds: Int?
        var visibleTiers: [WorldwideScreenVideoAdaptationTier] = [.audioPriority]
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: fixture.now)
        cadence.setCapacityProbeEnabled(accelerated, at: fixture.now)
        for elapsed in stride(from: 100, through: 3_500, by: 100) {
            fixture.advanceClock(by: 100)
            guard let slot = cadence.takeDueSample(at: fixture.now) else { continue }
            let normalSample = slot == .regular
            // Identical capacity-limited feedback in both lanes: fresh native BWE can reveal
            // 95% of the currently applied cap, bounded by the same 50 Mbps physical path.
            let bandwidth = min(50_000_000, Double(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps) * 0.95)
            if normalSample {
                if elapsed == 1_500 { fixture.advanceRTT(by: 0.005) }
                _ = fixture.normal(bandwidth: bandwidth, afterMilliseconds: 0)
            } else {
                let primary = PrimaryCadenceState(fixture.policy)
                _ = fixture.fast(bandwidth: bandwidth, afterMilliseconds: 0)
                XCTAssertEqual(PrimaryCadenceState(fixture.policy), primary)
            }
            cadence.didFinishSample(at: fixture.now)
            if fullCapMilliseconds == nil,
               fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps == fullCap {
                fullCapMilliseconds = elapsed
            }
            if fixture.policy.currentTier != visibleTiers.last {
                visibleTiers.append(fixture.policy.currentTier)
            }
            if fixture.policy.currentTier == .full {
                XCTAssertTrue(normalSample)
                fullGeometryMilliseconds = elapsed
                break
            }
        }
        return CapacityRampResult(
            fullCapMilliseconds: try XCTUnwrap(fullCapMilliseconds),
            fullGeometryMilliseconds: try XCTUnwrap(fullGeometryMilliseconds),
            visibleTiers: visibleTiers
        )
    }
}

private struct CapacityRampResult {
    let fullCapMilliseconds: Int
    let fullGeometryMilliseconds: Int
    let visibleTiers: [WorldwideScreenVideoAdaptationTier]
}

private enum InvalidCapacityRTT: CaseIterable {
    case missingObservation, unavailable, missingScalar, invalidScalar
    case changedCachedScalar, distinctInflated, invalidFingerprint
}

private enum InvalidCapacityQueue: CaseIterable {
    case gray, softPressure, missing, nan, packetReset, delayReset
}

private enum CapacityTimestamp {
    case clock
    case value(Double?)
}

private enum CapacitySequence {
    case advancing
    case value(UInt64?)
}

private struct PrimaryCadenceState: Equatable {
    let tier: WorldwideScreenVideoAdaptationTier
    let framesPerSecond: Int
    let scale: Double
    let maximumVideoBitrate: Int
    let counts: [Int]
    let bestTier: WorldwideScreenVideoAdaptationTier?
    let deadline: ContinuousClock.Instant?
    let baselineRTT: Double?
    let queueDelay: Double?
    let primarySequence: UInt64?
    let route: WebRTCICERouteDiagnostics?

    init(_ policy: WorldwideScreenVideoAdaptationPolicy) {
        tier = policy.currentTier
        framesPerSecond = policy.currentRecommendation.maximumFramesPerSecond
        scale = policy.currentRecommendation.scaleResolutionDownBy
        maximumVideoBitrate = policy.currentRecommendation.maximumBitrateBps
        counts = [policy.healthyUpgradeSampleCount, policy.bandwidthOnlyDowngradeSampleCount,
                  policy.queuePressureSampleCount, policy.unavailableBandwidthSampleCount,
                  policy.positiveBandwidthBootstrapSampleCount, policy.applicationLimitedUpgradeSampleCount,
                  policy.applicationLimitedProbeHealthySampleCount, policy.applicationLimitedProbeGraceSamplesRemaining,
                  policy.applicationLimitedProbeCooldownSamplesRemaining, policy.applicationLimitedProbeFailureCount,
                  policy.automaticSuspensionPressureSampleCount, policy.stableSuspensionResumeProbeSampleCount,
                  policy.maximumSuspensionResumeProbeSampleCount]
        bestTier = policy.applicationLimitedProbeBestQualifiedTier
        deadline = policy.applicationLimitedProbeDeadline
        baselineRTT = policy.roundTripTimeBaselineSeconds
        queueDelay = policy.lastAveragePacketSendDelaySeconds
        primarySequence = policy.lastConsumedCollectionSequence
        route = policy.selectedRoute
    }
}

private struct CapacityCadenceFixture {
    var policy = WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60)
    var now = ContinuousClock.now
    var probeStartedAt: ContinuousClock.Instant
    var peer: UInt64 = 1
    var route = WebRTCICERouteDiagnostics(kind: .direct)
    var sequence: UInt64 = 0
    var packets: UInt64 = 0
    var delay = 0.0
    var totalRTT = 1.0
    var responses: UInt64 = 10
    var observation: WebRTCRoundTripTimeObservation?
    private var clockMilliseconds = 0
    var nativeTimestamp: Double { 1_000_000 + Double(clockMilliseconds) * 1_000 }

    init(startProbe: Bool = true) {
        probeStartedAt = now
        advanceRTT(by: 0, responses: 0)
        guard startProbe else { return }
        _ = normal(bandwidth: 100_000, afterMilliseconds: 0)
        XCTAssertEqual(policy.currentTier, .survival)
        _ = normal(bandwidth: 100_000)
        XCTAssertEqual(policy.currentTier, .audioPriority)
        _ = normal(bandwidth: 486_001)
        probeStartedAt = now
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        XCTAssertEqual(policy.applicationLimitedProbeMaximumTotalRTPBitrateBps, 972_002)
        XCTAssertEqual(policy.applicationLimitedProbeHealthySampleCount, 0)
        XCTAssertEqual(policy.lastConsumedCollectionSequence, 3)
    }

    mutating func advanceRTT(by amount: Double, responses increment: UInt64 = 1) {
        totalRTT += amount
        responses += increment
        observation = .measurement(.init(selectedCandidatePairFingerprint: String(repeating: "a", count: 64), totalRoundTripTimeSeconds: totalRTT, responsesReceived: responses))
    }

    mutating func advanceClock(by milliseconds: Int) {
        clockMilliseconds += milliseconds
        now = now.advanced(by: .milliseconds(milliseconds))
    }

    private mutating func prepare(afterMilliseconds: Int, queueDelay: Double, advancesPackets: Bool, sequence selection: CapacitySequence) -> UInt64? {
        advanceClock(by: afterMilliseconds)
        if advancesPackets { packets += 100; delay += queueDelay * 100 }
        switch selection {
        case .advancing: sequence += 1; return sequence
        case .value(let value):
            if let value { sequence = max(sequence, value) }
            return value
        }
    }

    mutating func normal(bandwidth: Double?, rtt: Double? = 0.005, queueDelay: Double = 0.001, afterMilliseconds: Int = 500, sequence: CapacitySequence = .advancing) -> WorldwideScreenVideoEncodingRecommendation? {
        let collection = prepare(afterMilliseconds: afterMilliseconds, queueDelay: queueDelay, advancesPackets: true, sequence: sequence)
        return policy.update(peerGeneration: peer, isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: rtt,
            roundTripTimeObservation: observation, collectionSequence: collection,
            requireRoundTripTimeObservation: true, selectedRoute: route,
            outboundVideoPacketsSent: packets, outboundVideoTotalPacketSendDelaySeconds: delay,
            nativeReportTimestampMicroseconds: nativeTimestamp, observedAt: now)
    }

    mutating func fast(bandwidth: Double?, rtt: Double? = 0.005, queueDelay: Double = 0.001, afterMilliseconds: Int = 200, timestamp: CapacityTimestamp = .clock, sequence: CapacitySequence = .advancing, advancesPackets: Bool = true, includeQueue: Bool = true, isCaptureActive: Bool = true) -> WorldwideScreenVideoEncodingRecommendation? {
        let collection = prepare(afterMilliseconds: afterMilliseconds, queueDelay: queueDelay, advancesPackets: advancesPackets, sequence: sequence)
        let reportTimestamp: Double?
        switch timestamp {
        case .clock: reportTimestamp = nativeTimestamp
        case .value(let value): reportTimestamp = value
        }
        return policy.updateCapacityProbe(peerGeneration: peer, isCaptureActive: isCaptureActive,
            availableOutgoingBitrateBps: bandwidth, currentRoundTripTimeSeconds: rtt,
            roundTripTimeObservation: observation, collectionSequence: collection,
            nativeReportTimestampMicroseconds: reportTimestamp, selectedRoute: route,
            outboundVideoPacketsSent: includeQueue ? packets : nil,
            outboundVideoTotalPacketSendDelaySeconds: includeQueue ? delay : nil,
            observedAt: now)
    }
}
