import XCTest
@testable import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenStartupInvariantSequenceTests: XCTestCase {
    func testSeededSequencesPreserveNonFPSStateAcrossSourceFrameRates() throws {
        let cases: [(seed: UInt64, terminal: StartupTerminalEvent)] = [
            (0xC1A4_17A7_0000_0001, .bandwidthCollapse),
            (0xC1A4_17A7_0000_0002, .immediateQueue),
            (0xC1A4_17A7_0000_0003, .routeReplacement),
        ]
        let sourceFrameRates = [1, 3, 10, 24, 60, 120]

        for scenario in cases {
            var generator = StartupInvariantGenerator(seed: scenario.seed)
            let uncertainty = generator.permuted([
                StartupSequenceEvent.missing,
                .staleNegative,
                .malformedRTT,
            ])
            let recoveryBandwidths = [3_600_000.0, 6_000_000, 9_000_000]
            let recoveryBandwidth = recoveryBandwidths[
                generator.nextInt(upperBound: recoveryBandwidths.count)
            ]
            let events = uncertainty + [
                .healthy(recoveryBandwidth),
                .healthy(recoveryBandwidth),
                .terminal(scenario.terminal),
                .staleNegative,
                .missing,
                .hide,
                .newPeerShow,
            ]
            let seedLabel = "seed=0x" + String(scenario.seed, radix: 16)
            var reference: [StartupNonFPSSignature]?

            for sourceFPS in sourceFrameRates {
                var fixture = StartupInvariantSequenceFixture(
                    configuredCap: 50_000_000,
                    sourceFPS: sourceFPS
                )
                _ = fixture.ordinaryHealthy(bandwidth: 900_000, after: 0)
                _ = fixture.ordinaryHealthy(bandwidth: 900_000, after: 500)
                XCTAssertNotNil(
                    fixture.policy.applicationLimitedProbeOriginTier,
                    "\(seedLabel) sourceFPS=\(sourceFPS) did not establish the bounded probe"
                )
                assertRecommendationDomain(
                    fixture.policy,
                    context: "\(seedLabel) sourceFPS=\(sourceFPS) prime"
                )

                var signatures = [StartupNonFPSSignature(fixture.policy)]
                var terminalObserved = false
                for (index, event) in events.enumerated() {
                    fixture.apply(event)
                    let context = "\(seedLabel) sourceFPS=\(sourceFPS) event=\(index) \(event)"
                    assertRecommendationDomain(fixture.policy, context: context)
                    signatures.append(StartupNonFPSSignature(fixture.policy))

                    switch event {
                    case .terminal(_):
                        terminalObserved = true
                        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive, context)
                        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved, context)
                    case .hide:
                        terminalObserved = false
                        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive, context)
                    case .newPeerShow:
                        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive, context)
                        XCTAssertEqual(fixture.policy.peerGeneration, 2, context)
                    default:
                        if terminalObserved {
                            XCTAssertFalse(
                                fixture.policy.startupSpatialModeIsActive,
                                "\(context): uncertainty resurrected terminal Show authority"
                            )
                            XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved, context)
                        }
                    }
                }

                if let reference {
                    XCTAssertEqual(
                        signatures,
                        reference,
                        "\(seedLabel): source FPS changed tier/cap/ownership state at \(sourceFPS) fps"
                    )
                } else {
                    reference = signatures
                }
            }
        }
    }

    func testConfiguredCapAndSourceFPSMatrixGivesUncertaintyNoAuthority() {
        let cases: [(cap: Int, fps: Int)] = [
            (1, 1),
            (100_000, 60),
            (500_000, 3),
            (1_000_000, 24),
            (8_000_000, 120),
            (16_000_000, 10),
            (50_000_000, 1),
            (50_000_000, 3),
            (50_000_000, 24),
            (50_000_000, 60),
            (50_000_000, 120),
        ]

        for item in cases {
            var fixture = StartupInvariantSequenceFixture(
                configuredCap: item.cap,
                sourceFPS: item.fps
            )
            let initial = fixture.policy.currentRecommendation
            let initiallyActive = fixture.policy.startupSpatialModeIsActive
            let context = "cap=\(item.cap) sourceFPS=\(item.fps)"
            assertRecommendationDomain(fixture.policy, context: context + " initial")

            _ = fixture.ordinaryMissing(after: 0)
            assertUncertaintyDidNotGainAuthority(
                before: initial,
                policy: fixture.policy,
                initiallyActive: initiallyActive,
                context: context + " missing"
            )
            _ = fixture.staleNegative(after: 250)
            assertUncertaintyDidNotGainAuthority(
                before: initial,
                policy: fixture.policy,
                initiallyActive: initiallyActive,
                context: context + " stale"
            )
            _ = fixture.ordinaryMalformedRTT(after: 500)
            assertUncertaintyDidNotGainAuthority(
                before: initial,
                policy: fixture.policy,
                initiallyActive: initiallyActive,
                context: context + " malformed"
            )
            _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: fixture.peer,
                isCaptureActive: true,
                observedAt: fixture.origin.advanced(by: .seconds(60))
            )
            assertUncertaintyDidNotGainAuthority(
                before: initial,
                policy: fixture.policy,
                initiallyActive: initiallyActive,
                context: context + " no-report expiry"
            )
        }
    }

    func testProbeExpiryAndStaleInterleavingCannotResurrectBudgetOrBlurShow() throws {
        var fixture = StartupInvariantSequenceFixture(
            configuredCap: 50_000_000,
            sourceFPS: 60
        )
        _ = fixture.ordinaryHealthy(bandwidth: 900_000, after: 0)
        _ = fixture.ordinaryHealthy(bandwidth: 900_000, after: 500)
        let deadline = try XCTUnwrap(fixture.policy.applicationLimitedProbeDeadline)
        let raisedCap = fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)

        var unappliedProposal = fixture
        _ = unappliedProposal.fastHealthy(bandwidth: 3_600_000, after: 200)
        XCTAssertGreaterThan(
            unappliedProposal.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            raisedCap
        )

        _ = fixture.fastMissing(after: 200)
        XCTAssertEqual(
            fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            raisedCap,
            "A telemetry gap may hold, never grow, the accepted budget"
        )
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)
        _ = fixture.staleNegative(after: 250)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps, raisedCap)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, deadline)

        _ = fixture.policy.expireApplicationLimitedProbeWithoutReport(
            peerGeneration: fixture.peer,
            isCaptureActive: true,
            observedAt: deadline
        )
        XCTAssertNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertNil(fixture.policy.applicationLimitedProbeDeadline)
        XCTAssertLessThan(
            fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            raisedCap
        )
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        assertRecommendationDomain(fixture.policy, context: "expired accepted probe")

        let expired = fixture.policy.currentRecommendation
        fixture.policy.retainCapacityProbeObservationIdentity(from: unappliedProposal.policy)
        XCTAssertEqual(
            fixture.policy.currentRecommendation,
            expired,
            "An unapplied pre-expiry proposal cannot recreate budget after terminal expiry"
        )

        fixture.hideAndReset()
        fixture.beginNextShow()
        XCTAssertTrue(fixture.policy.startupSpatialModeIsActive)
        XCTAssertLessThan(
            fixture.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            unappliedProposal.policy.currentRecommendation.maximumTotalRTPBitrateBps
        )
        assertRecommendationDomain(fixture.policy, context: "successor Show after expiry")
    }

    func testFailedApplyOwnershipCannotCopyPositiveAuthorityOrCrossBoundaries() throws {
        var accepted = StartupInvariantSequenceFixture(
            configuredCap: 50_000_000,
            sourceFPS: 60
        )
        _ = accepted.ordinaryHealthy(bandwidth: 900_000, after: 0)
        _ = accepted.ordinaryHealthy(bandwidth: 900_000, after: 500)
        _ = try XCTUnwrap(accepted.policy.applicationLimitedProbeOriginTier)
        let acceptedRecommendation = accepted.policy.currentRecommendation
        let acceptedTier = accepted.policy.currentTier

        var positiveProposal = accepted
        var terminalProposal = accepted
        _ = positiveProposal.fastHealthy(bandwidth: 3_600_000, after: 200)
        _ = terminalProposal.fastImmediateQueue(after: 400)
        XCTAssertGreaterThan(
            positiveProposal.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            acceptedRecommendation.maximumTotalRTPBitrateBps
        )
        XCTAssertTrue(terminalProposal.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(terminalProposal.policy.startupSpatialModeIsActive)
        accepted.policy.retainCapacityProbeObservationIdentity(from: positiveProposal.policy)
        XCTAssertEqual(
            accepted.policy.currentRecommendation,
            acceptedRecommendation,
            "Failed positive apply may retain ordering identity, not its budget or geometry"
        )
        accepted.policy.retainStartupSpatialModeTerminalState(from: terminalProposal.policy)
        XCTAssertTrue(accepted.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(accepted.policy.startupSpatialModeIsActive)
        XCTAssertEqual(accepted.policy.currentTier, acceptedTier)
        XCTAssertEqual(
            accepted.policy.currentRecommendation.maximumTotalRTPBitrateBps,
            acceptedRecommendation.maximumTotalRTPBitrateBps,
            "Terminal retention must not copy the rejected proposal's tier or budget"
        )
        XCTAssertGreaterThan(accepted.policy.currentRecommendation.scaleResolutionDownBy, 1)

        accepted.policy.retainStartupSpatialModeTerminalState(from: positiveProposal.policy)
        accepted.policy.beginFloorRecoveryVisibility(
            peerGeneration: accepted.peer,
            showEpoch: accepted.showEpoch
        )
        XCTAssertFalse(
            accepted.policy.startupSpatialModeIsActive,
            "Positive callbacks and duplicate Show identity cannot resurrect a terminal Show"
        )

        accepted.hideAndReset()
        accepted.beginNextShow()
        XCTAssertTrue(accepted.policy.startupSpatialModeIsActive)
        accepted.policy.retainStartupSpatialModeTerminalState(from: terminalProposal.policy)
        XCTAssertTrue(
            accepted.policy.startupSpatialModeIsActive,
            "A predecessor Show's failed-apply callback cannot cancel its successor"
        )

        accepted.beginNewPeerShow()
        XCTAssertTrue(accepted.policy.startupSpatialModeIsActive)
        accepted.policy.retainStartupSpatialModeTerminalState(from: terminalProposal.policy)
        accepted.policy.retainCapacityProbeObservationIdentity(from: positiveProposal.policy)
        XCTAssertTrue(
            accepted.policy.startupSpatialModeIsActive,
            "A predecessor peer cannot lend either positive or terminal authority"
        )
        XCTAssertNil(accepted.policy.applicationLimitedProbeOriginTier)
        assertRecommendationDomain(accepted.policy, context: "new peer after stale callbacks")
    }

    private func assertUncertaintyDidNotGainAuthority(
        before: WorldwideScreenVideoEncodingRecommendation,
        policy: WorldwideScreenVideoAdaptationPolicy,
        initiallyActive: Bool,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let recommendation = policy.currentRecommendation
        XCTAssertLessThanOrEqual(
            recommendation.maximumBitrateBps,
            before.maximumBitrateBps,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            recommendation.maximumTotalRTPBitrateBps,
            before.maximumTotalRTPBitrateBps,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            recommendation.maximumFramesPerSecond,
            before.maximumFramesPerSecond,
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(
            policy.startupSpatialModeIsActive,
            initiallyActive,
            "\(context): uncertainty changed exact-Show spatial authority",
            file: file,
            line: line
        )
        assertRecommendationDomain(policy, context: context, file: file, line: line)
    }

    private func assertRecommendationDomain(
        _ policy: WorldwideScreenVideoAdaptationPolicy,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let recommendation = policy.currentRecommendation
        let ordinary = policy.recommendation(for: policy.currentTier)
        XCTAssertEqual(recommendation.tier, policy.currentTier, context, file: file, line: line)
        XCTAssertGreaterThan(recommendation.maximumBitrateBps, 0, context, file: file, line: line)
        XCTAssertGreaterThan(
            recommendation.maximumTotalRTPBitrateBps,
            0,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            recommendation.maximumBitrateBps,
            policy.configuredTotalRTPBitrateBps,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            recommendation.maximumTotalRTPBitrateBps,
            policy.configuredTotalRTPBitrateBps,
            context,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            recommendation.maximumFramesPerSecond,
            1,
            context,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            recommendation.maximumFramesPerSecond,
            policy.baseFramesPerSecond,
            context,
            file: file,
            line: line
        )
        XCTAssertTrue(
            [1.0, 1.25, 1.5, 2, 3, 4, 8, 12].contains(
                recommendation.scaleResolutionDownBy
            ),
            context,
            file: file,
            line: line
        )

        if policy.startupSpatialModeIsActive {
            XCTAssertEqual(
                recommendation.scaleResolutionDownBy,
                1,
                context,
                file: file,
                line: line
            )
            XCTAssertEqual(
                recommendation.maximumFramesPerSecond,
                expectedStartupFPS(
                    tier: policy.currentTier,
                    sourceFPS: policy.baseFramesPerSecond
                ),
                context,
                file: file,
                line: line
            )
        } else {
            XCTAssertEqual(
                recommendation.scaleResolutionDownBy,
                ordinary.scaleResolutionDownBy,
                context,
                file: file,
                line: line
            )
            XCTAssertEqual(
                recommendation.maximumFramesPerSecond,
                ordinary.maximumFramesPerSecond,
                context,
                file: file,
                line: line
            )
        }
    }

    /// Literal oracle for the supported tier/source-FPS cross-product used by these sequences.
    /// Keep this table independent of the production pixel-rate calculation so a math mutation
    /// cannot make both the implementation and its regression expectation change together.
    private func expectedStartupFPS(
        tier: WorldwideScreenVideoAdaptationTier,
        sourceFPS: Int
    ) -> Int {
        let sourceIndex: Int
        switch sourceFPS {
        case 1: sourceIndex = 0
        case 3: sourceIndex = 1
        case 10: sourceIndex = 2
        case 24: sourceIndex = 3
        case 60: sourceIndex = 4
        case 120: sourceIndex = 5
        default:
            XCTFail("Add a literal startup-FPS oracle before testing source FPS \(sourceFPS)")
            return min(sourceFPS, 1)
        }

        let expectedBySourceFPS: [Int]
        switch tier {
        case .full: expectedBySourceFPS = [1, 3, 10, 24, 60, 60]
        case .high: expectedBySourceFPS = [1, 3, 6, 15, 28, 28]
        case .balanced: expectedBySourceFPS = [1, 3, 5, 10, 13, 13]
        case .constrained: expectedBySourceFPS = [1, 3, 5, 5, 5, 5]
        case .critical: expectedBySourceFPS = [1, 3, 5, 5, 5, 5]
        case .survival: expectedBySourceFPS = [1, 3, 5, 5, 5, 5]
        case .emergency: expectedBySourceFPS = [1, 2, 2, 2, 2, 2]
        case .audioPriority: expectedBySourceFPS = [1, 1, 1, 1, 1, 1]
        }
        return expectedBySourceFPS[sourceIndex]
    }
}

private enum StartupTerminalEvent: CustomStringConvertible {
    case bandwidthCollapse
    case immediateQueue
    case routeReplacement

    var description: String {
        switch self {
        case .bandwidthCollapse: return "bandwidthCollapse"
        case .immediateQueue: return "immediateQueue"
        case .routeReplacement: return "routeReplacement"
        }
    }
}

private enum StartupSequenceEvent: CustomStringConvertible {
    case healthy(Double)
    case missing
    case staleNegative
    case malformedRTT
    case terminal(StartupTerminalEvent)
    case hide
    case newPeerShow

    var description: String {
        switch self {
        case let .healthy(bandwidth): return "healthy(\(Int(bandwidth)))"
        case .missing: return "missing"
        case .staleNegative: return "staleNegative"
        case .malformedRTT: return "malformedRTT"
        case let .terminal(event): return "terminal(\(event))"
        case .hide: return "hide"
        case .newPeerShow: return "newPeerShow"
        }
    }
}

private struct StartupNonFPSSignature: Equatable {
    let peer: UInt64?
    let tier: WorldwideScreenVideoAdaptationTier
    let maximumBitrateBps: Int
    let maximumTotalRTPBitrateBps: Int
    let scaleResolutionDownBy: Double
    let startupIsActive: Bool
    let startupIsDisproved: Bool
    let startupPeer: UInt64?
    let startupShow: UInt64?
    let probeOrigin: WorldwideScreenVideoAdaptationTier?
    let probeHasDeadline: Bool
    let probeFailureCount: Int
    let probeCooldown: Int
    let rttDisposition: WorldwideScreenVideoAdaptationPolicy.RoundTripTimeDisposition
    let selectedRoute: WebRTCICERouteKind?

    init(_ policy: WorldwideScreenVideoAdaptationPolicy) {
        let recommendation = policy.currentRecommendation
        peer = policy.peerGeneration
        tier = policy.currentTier
        maximumBitrateBps = recommendation.maximumBitrateBps
        maximumTotalRTPBitrateBps = recommendation.maximumTotalRTPBitrateBps
        scaleResolutionDownBy = recommendation.scaleResolutionDownBy
        startupIsActive = policy.startupSpatialModeIsActive
        startupIsDisproved = policy.startupSpatialModeIsDisproved
        startupPeer = policy.startupSpatialModePeerGeneration
        startupShow = policy.startupSpatialModeShowEpoch
        probeOrigin = policy.applicationLimitedProbeOriginTier
        probeHasDeadline = policy.applicationLimitedProbeDeadline != nil
        probeFailureCount = policy.applicationLimitedProbeFailureCount
        probeCooldown = policy.applicationLimitedProbeCooldownSamplesRemaining
        rttDisposition = policy.roundTripTimeDisposition
        selectedRoute = policy.selectedRoute?.kind
    }
}

private struct StartupInvariantGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func permuted<Element>(_ values: [Element]) -> [Element] {
        var result = values
        guard result.count > 1 else { return result }
        for index in stride(from: result.count - 1, through: 1, by: -1) {
            result.swapAt(index, nextInt(upperBound: index + 1))
        }
        return result
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private enum StartupInvariantRTTInput: Equatable {
    case fresh
    case unavailable
    case malformed
}

private enum StartupInvariantReportIdentity {
    case fresh
    case newSequenceStaleTimestamp
}

private struct StartupInvariantSequenceFixture {
    var policy: WorldwideScreenVideoAdaptationPolicy
    let origin = ContinuousClock.now
    var peer: UInt64 = 1
    var showEpoch: UInt64 = 1

    private var nowMilliseconds = 0
    private var sequence: UInt64 = 0
    private var lastNativeTimestamp: Double?
    private var packets: UInt64 = 0
    private var totalPacketSendDelay = 0.0
    private var totalRTT = 0.0
    private var responses: UInt64 = 0

    init(configuredCap: Int, sourceFPS: Int) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: configuredCap,
            baseFramesPerSecond: sourceFPS
        )
        policy.beginFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
        policy.activateFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
    }

    mutating func apply(_ event: StartupSequenceEvent) {
        switch event {
        case let .healthy(bandwidth):
            _ = ordinaryHealthy(bandwidth: bandwidth, after: 500)
        case .missing:
            _ = ordinaryMissing(after: 500)
        case .staleNegative:
            _ = staleNegative(after: 250)
        case .malformedRTT:
            _ = ordinaryMalformedRTT(after: 500)
        case let .terminal(event):
            switch event {
            case .bandwidthCollapse:
                _ = ordinaryHealthy(bandwidth: 100_000, after: 500)
                _ = ordinaryHealthy(bandwidth: 100_000, after: 500)
            case .immediateQueue:
                _ = ordinaryHealthy(
                    bandwidth: 3_600_000,
                    queueDelay: 0.250,
                    after: 500
                )
            case .routeReplacement:
                _ = ordinary(
                    bandwidth: 3_600_000,
                    queueDelay: 0.001,
                    rttInput: .fresh,
                    route: .relayed,
                    after: 500
                )
            }
        case .hide:
            hideAndReset()
        case .newPeerShow:
            beginNewPeerShow()
        }
    }

    mutating func ordinaryHealthy(
        bandwidth: Double,
        queueDelay: Double = 0.001,
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        ordinary(
            bandwidth: bandwidth,
            queueDelay: queueDelay,
            rttInput: .fresh,
            route: .direct,
            after: milliseconds
        )
    }

    mutating func ordinaryMissing(
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        ordinary(
            bandwidth: nil,
            queueDelay: 0.001,
            rttInput: .unavailable,
            route: nil,
            after: milliseconds
        )
    }

    mutating func ordinaryMalformedRTT(
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        ordinary(
            bandwidth: 900_000,
            queueDelay: 0.001,
            rttInput: .malformed,
            route: .direct,
            after: milliseconds
        )
    }

    mutating func staleNegative(
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        ordinary(
            bandwidth: 100_000,
            queueDelay: 0.250,
            rttInput: .malformed,
            route: .relayed,
            after: milliseconds,
            identity: .newSequenceStaleTimestamp,
            advancesPackets: false
        )
    }

    mutating func fastHealthy(
        bandwidth: Double,
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        fast(
            bandwidth: bandwidth,
            queueDelay: 0.001,
            rttInput: .fresh,
            route: .direct,
            after: milliseconds
        )
    }

    mutating func fastMissing(
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        fast(
            bandwidth: nil,
            queueDelay: 0.001,
            rttInput: .unavailable,
            route: nil,
            after: milliseconds
        )
    }

    mutating func fastImmediateQueue(
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        fast(
            bandwidth: 3_600_000,
            queueDelay: 0.250,
            rttInput: .fresh,
            route: .direct,
            after: milliseconds
        )
    }

    mutating func hideAndReset() {
        policy.endFloorRecoveryVisibility()
        policy.invalidateRoundTripTimeObservation()
        policy.resetForInactiveCapture()
    }

    mutating func beginNextShow() {
        showEpoch &+= 1
        policy.beginFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
        policy.activateFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
    }

    mutating func beginNewPeerShow() {
        peer &+= 1
        showEpoch = 1
        sequence = 0
        lastNativeTimestamp = nil
        packets = 0
        totalPacketSendDelay = 0
        totalRTT = 0
        responses = 0
        policy.beginFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
        policy.activateFloorRecoveryVisibility(peerGeneration: peer, showEpoch: showEpoch)
    }

    private mutating func ordinary(
        bandwidth: Double?,
        queueDelay: Double,
        rttInput: StartupInvariantRTTInput,
        route: WebRTCICERouteKind?,
        after milliseconds: Int,
        identity: StartupInvariantReportIdentity = .fresh,
        advancesPackets: Bool = true
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        nowMilliseconds += milliseconds
        let identity = reportIdentity(identity)
        if advancesPackets {
            packets &+= 100
            totalPacketSendDelay += queueDelay * 100
        }
        let rtt = roundTripTimeEvidence(input: rttInput, route: route)
        return policy.update(
            peerGeneration: peer,
            isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt.scalar,
            roundTripTimeObservation: rtt.observation,
            collectionSequence: identity.sequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: route.map { WebRTCICERouteDiagnostics(kind: $0) },
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay,
            nativeReportTimestampMicroseconds: identity.timestamp,
            observedAt: origin.advanced(by: .milliseconds(nowMilliseconds))
        )
    }

    private mutating func fast(
        bandwidth: Double?,
        queueDelay: Double,
        rttInput: StartupInvariantRTTInput,
        route: WebRTCICERouteKind?,
        after milliseconds: Int
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        nowMilliseconds += milliseconds
        let identity = reportIdentity(.fresh)
        packets &+= 100
        totalPacketSendDelay += queueDelay * 100
        let rtt = roundTripTimeEvidence(input: rttInput, route: route)
        return policy.updateCapacityProbe(
            peerGeneration: peer,
            isCaptureActive: true,
            availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: rtt.scalar,
            roundTripTimeObservation: rtt.observation,
            collectionSequence: identity.sequence,
            nativeReportTimestampMicroseconds: identity.timestamp,
            selectedRoute: route.map { WebRTCICERouteDiagnostics(kind: $0) },
            outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: totalPacketSendDelay,
            observedAt: origin.advanced(by: .milliseconds(nowMilliseconds))
        )
    }

    private mutating func reportIdentity(
        _ identity: StartupInvariantReportIdentity
    ) -> (sequence: UInt64?, timestamp: Double?) {
        switch identity {
        case .newSequenceStaleTimestamp:
            sequence &+= 1
            return (sequence, lastNativeTimestamp)
        case .fresh:
            sequence &+= 1
            let timestamp = 1_000_000
                + Double(nowMilliseconds) * 1_000
                + Double(sequence)
            lastNativeTimestamp = timestamp
            return (sequence, timestamp)
        }
    }

    private mutating func roundTripTimeEvidence(
        input: StartupInvariantRTTInput,
        route: WebRTCICERouteKind?
    ) -> (scalar: Double?, observation: WebRTCRoundTripTimeObservation) {
        switch input {
        case .unavailable:
            return (nil, .unavailable)
        case .fresh, .malformed:
            totalRTT += 0.004
            responses &+= 1
            let fingerprint: String
            if input == .malformed {
                fingerprint = "malformed"
            } else {
                fingerprint = String(
                    repeating: route == .relayed ? "b" : "a",
                    count: 64
                )
            }
            return (
                0.004,
                .measurement(.init(
                    selectedCandidatePairFingerprint: fingerprint,
                    totalRoundTripTimeSeconds: totalRTT,
                    responsesReceived: responses
                ))
            )
        }
    }
}
