import XCTest
@testable import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenSpatialRecoveryIntegrationTests: XCTestCase {
    func testConstrainedRecoveryUsesFiveFPSWithoutChangingOrdinaryCapacityAuthority() {
        var fixture = IntegrationFixture()
        var control = IntegrationFixture(enabled: false)
        fixture.disproveStartup()
        control.disproveStartup()
        for _ in 0..<12 {
            fixture.sample()
            control.sample()
            if fixture.policy.spatialRecoveryIsTrialActive { break }
        }
        XCTAssertTrue(fixture.policy.spatialRecoveryIsTrialActive)
        XCTAssertEqual(fixture.policy.currentTier, .constrained)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(fixture.policy.currentRecommendation.maximumFramesPerSecond, 5)
        assertSameCapacityAuthority(fixture.policy, control.policy)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
        XCTAssertFalse(fixture.policy.startupSpatialModeIsActive)
    }

    func testPendingTrialPreservesExistingCapacityProbeWithoutRaisingItsCeilingOrRenewingDeadline() {
        var fixture = IntegrationFixture()
        var control = IntegrationFixture(enabled: false)
        fixture.disproveStartup()
        control.disproveStartup()
        for _ in 0..<16 {
            fixture.sample(omitFrames: true)
            control.sample(omitFrames: true)
            if fixture.policy.applicationLimitedProbeOriginTier != nil { break }
        }
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeOriginTier)
        XCTAssertFalse(fixture.policy.spatialRecoveryIsTrialActive)
        XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        let originalDeadline = fixture.policy.applicationLimitedProbeDeadline
        let originalOrigin = fixture.policy.applicationLimitedProbeOriginTier
        var existingProbeAtAdmission = false
        for _ in 0..<6 {
            let hadProbe = fixture.policy.applicationLimitedProbeOriginTier != nil
            fixture.sample()
            control.sample()
            if fixture.policy.spatialRecoveryIsTrialActive {
                existingProbeAtAdmission = hadProbe
                break
            }
        }
        XCTAssertTrue(existingProbeAtAdmission, "This case must cross a real existing-probe boundary")
        XCTAssertTrue(fixture.policy.spatialRecoveryIsTrialActive)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeOriginTier, originalOrigin)
        XCTAssertEqual(fixture.policy.applicationLimitedProbeDeadline, originalDeadline)
        XCTAssertNotNil(fixture.policy.applicationLimitedProbeMaximumTotalRTPBitrateBps)
        XCTAssertEqual(fixture.policy.currentTier, .constrained)
        XCTAssertEqual(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
        assertSameCapacityAuthority(fixture.policy, control.policy)
        XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
    }

    func testInjectedRouteAndRTTInvalidationsRetirePendingAndAcceptedRecovery() {
        for accepted in [false, true] {
            for routeInvalidation in [false, true] {
                var fixture = IntegrationFixture()
                fixture.disproveStartup()
                for _ in 0..<12 {
                    fixture.sample()
                    if fixture.policy.spatialRecoveryIsTrialActive { break }
                }
                XCTAssertTrue(fixture.policy.spatialRecoveryIsTrialActive)
                if accepted {
                    fixture.policy.markSpatialRecoveryApplied(at: fixture.now)
                    fixture.sample(full: true)
                    fixture.sample(full: true)
                    XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "accepted")
                }
                let invalidatedAt = fixture.now.advanced(by: .milliseconds(100))
                if routeInvalidation {
                    fixture.policy.invalidateSelectedRoute(at: invalidatedAt)
                } else {
                    fixture.policy.invalidateRoundTripTimeObservation(at: invalidatedAt)
                }
                XCTAssertEqual(fixture.policy.spatialRecoveryPhase, "cooldown")
                XCTAssertFalse(fixture.policy.spatialRecoveryIsTrialActive)
                XCTAssertGreaterThan(fixture.policy.currentRecommendation.scaleResolutionDownBy, 1)
                XCTAssertTrue(fixture.policy.startupSpatialModeIsDisproved)
            }
        }
    }

    private func assertSameCapacityAuthority(
        _ policy: WorldwideScreenVideoAdaptationPolicy,
        _ control: WorldwideScreenVideoAdaptationPolicy,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(policy.currentRecommendation.maximumBitrateBps,
                       control.currentRecommendation.maximumBitrateBps, file: file, line: line)
        XCTAssertEqual(policy.currentRecommendation.maximumTotalRTPBitrateBps,
                       control.currentRecommendation.maximumTotalRTPBitrateBps, file: file, line: line)
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier,
                       control.applicationLimitedProbeOriginTier, file: file, line: line)
    }
}

private struct IntegrationFixture {
    let origin = ContinuousClock.now
    var policy: WorldwideScreenVideoAdaptationPolicy
    var milliseconds = 0
    var sequence: UInt64 = 0
    var packets: UInt64 = 0
    var frames: UInt64 = 0
    var delay = 0.0
    var now: ContinuousClock.Instant { origin.advanced(by: .milliseconds(milliseconds)) }

    init(enabled: Bool = true) {
        policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60,
            spatialRecoveryEnabled: enabled)
        policy.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1, at: origin)
        policy.activateFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
    }

    mutating func disproveStartup() {
        sample()
        sample(queueDelay: 0.25)
        XCTAssertTrue(policy.startupSpatialModeIsDisproved)
    }

    mutating func sample(queueDelay: Double = 0.001, omitFrames: Bool = false, full: Bool = false) {
        milliseconds += 500
        sequence += 1
        packets += 100
        frames += 10
        delay += queueDelay * 100
        _ = policy.update(
            peerGeneration: 1, isCaptureActive: true,
            availableOutgoingBitrateBps: 4_000_000, currentRoundTripTimeSeconds: 0.004,
            roundTripTimeObservation: .measurement(.init(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: Double(sequence) * 0.004, responsesReceived: sequence)),
            collectionSequence: sequence, requireRoundTripTimeObservation: true,
            selectedRoute: .init(kind: .direct), outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: delay,
            nativeReportTimestampMicroseconds: Double(milliseconds) * 1_000,
            spatialRecoveryFrames: omitFrames ? nil : .init(
                encodedFrames: frames, encodedWidth: full ? 1_080 : 540,
                encodedHeight: full ? 1_920 : 960, sourceWidth: 1_080, sourceHeight: 1_920),
            observedAt: now)
    }
}
