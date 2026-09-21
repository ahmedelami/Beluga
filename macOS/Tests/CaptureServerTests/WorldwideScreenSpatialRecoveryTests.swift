import XCTest
@testable import CaptureServer

final class WorldwideScreenSpatialRecoveryTests: XCTestCase {
    func testRequiresFrameBaselineThenTwoSeparatedValidatedWitnesses() {
        var fixture = Fixture()
        fixture.sample(at: 500)
        XCTAssertEqual(fixture.recovery.phase, .observing)
        fixture.sample(at: 1_000)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 1_499)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 1_500)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        XCTAssertTrue(fixture.recovery.isArmed)
        XCTAssertTrue(fixture.recovery.isTrialActive)
        XCTAssertFalse(fixture.recovery.isActive)
        XCTAssertEqual(fixture.recovery.deadline, fixture.time(4_500))
    }

    func testOneFPSAlternatingMeasuredAndNoPacketPollsAdmitAndConfirmOnlyOnAdvancingFrames() {
        var fixture = Fixture()
        fixture.sample(at: 500, encodedFrames: 10)
        fixture.sample(at: 1_000, packetEvidence: .noNewPackets, encodedFrames: 10)
        fixture.sample(at: 1_500, encodedFrames: 11)
        fixture.sample(at: 2_000, packetEvidence: .noNewPackets, encodedFrames: 11)
        XCTAssertEqual(fixture.recovery.attempt, 0, "A between-frame poll cannot confirm admission")
        fixture.sample(at: 2_500, encodedFrames: 12)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        XCTAssertEqual(fixture.recovery.deadline, fixture.time(5_500))
        fixture.recovery.markApplied(at: fixture.time(2_600))
        fixture.sample(at: 3_000, full: true, rttAt: 2_600,
                       packetEvidence: .noNewPackets, encodedFrames: 12)
        fixture.sample(at: 3_500, full: true, rttAt: 2_600, encodedFrames: 13)
        fixture.sample(at: 4_000, full: true, rttAt: 2_600,
                       packetEvidence: .noNewPackets, encodedFrames: 13)
        XCTAssertEqual(fixture.recovery.phase, .trial)
        XCTAssertEqual(fixture.recovery.deadline, fixture.time(5_500))
        fixture.sample(at: 4_500, full: true, rttAt: 2_600, encodedFrames: 14)
        XCTAssertEqual(fixture.recovery.phase, .accepted)
    }

    func testNeutralPollCannotCreateWitnessAndCannotSlideOriginalWitnessWindow() {
        var empty = Fixture()
        empty.sample(at: 500, encodedFrames: 1)
        for time in [1_000, 1_500, 2_000] {
            empty.sample(at: time, packetEvidence: .noNewPackets, encodedFrames: 1)
        }
        empty.sample(at: 2_500, encodedFrames: 2)
        XCTAssertEqual(empty.recovery.attempt, 0)

        var fixture = Fixture()
        fixture.sample(at: 500, encodedFrames: 1)
        fixture.sample(at: 1_000, encodedFrames: 2)
        for time in [1_500, 2_000, 2_500, 2_501] {
            fixture.sample(at: time, packetEvidence: .noNewPackets, encodedFrames: 2)
        }
        fixture.sample(at: 3_000, encodedFrames: 3)
        XCTAssertEqual(fixture.recovery.attempt, 0, "Neutral polls cannot move the original1.5s boundary")
        fixture.sample(at: 3_500, encodedFrames: 4)
        XCTAssertEqual(fixture.recovery.phase, .pending)
    }

    func testUnavailableMalformedOrMissingNeutralEvidenceClearsRatherThanPreservesWitness() {
        let rejected: [WorldwideScreenSpatialRecoveryPacketEvidence] = [
            .unavailable, .measured(.nan), .measured(.infinity), .measured(-0.001), .measured(0.020_001),
        ]
        for packetEvidence in rejected {
            var fixture = Fixture()
            fixture.sample(at: 500, encodedFrames: 1)
            fixture.sample(at: 1_000, encodedFrames: 2)
            fixture.sample(at: 1_500, packetEvidence: packetEvidence, encodedFrames: 2)
            fixture.sample(at: 2_000, encodedFrames: 3)
            XCTAssertEqual(fixture.recovery.attempt, 0)
            fixture.sample(at: 2_500, encodedFrames: 4)
            XCTAssertEqual(fixture.recovery.phase, .pending)
        }
        for missing in 0..<3 {
            var fixture = Fixture()
            fixture.sample(at: 500, encodedFrames: 1)
            fixture.sample(at: 1_000, encodedFrames: 2)
            fixture.sample(at: 1_500, capacity: missing == 0 ? nil : 8_000_000,
                           rttAt: missing == 1 ? nil : 100, packetEvidence: .noNewPackets,
                           omitFrames: missing == 2, encodedFrames: 2)
            fixture.sample(at: 2_000, encodedFrames: 3)
            XCTAssertEqual(fixture.recovery.attempt, 0)
        }
    }

    func testAdvancingFramesWithoutMeasuredPacketsCannotCreateOrConfirmWitnesses() {
        var fixture = Fixture()
        fixture.sample(at: 500, encodedFrames: 1)
        fixture.sample(at: 1_000, encodedFrames: 2)
        fixture.sample(at: 1_500, packetEvidence: .noNewPackets, encodedFrames: 3)
        fixture.sample(at: 2_000, encodedFrames: 4)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 2_500, encodedFrames: 5)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        fixture.recovery.markApplied(at: fixture.time(2_600))
        fixture.sample(at: 2_700, full: true, encodedFrames: 6)
        fixture.sample(at: 3_200, full: true, packetEvidence: .noNewPackets, encodedFrames: 7)
        fixture.sample(at: 3_700, full: true, encodedFrames: 8)
        XCTAssertEqual(fixture.recovery.phase, .trial)
    }

    func testNeutralCapacityHighWatermarkRejectsLaterFallWithoutRenewingWitnessTime() {
        var falling = Fixture()
        falling.sample(at: 500, encodedFrames: 1)
        falling.sample(at: 1_000, encodedFrames: 2)
        falling.sample(at: 1_250, capacity: 10_000_000, packetEvidence: .noNewPackets, encodedFrames: 2)
        falling.sample(at: 1_500, capacity: 9_000_000, packetEvidence: .noNewPackets, encodedFrames: 2)
        falling.sample(at: 2_000, capacity: 9_000_000, encodedFrames: 3)
        XCTAssertEqual(falling.recovery.attempt, 0)
        falling.sample(at: 2_500, capacity: 9_000_000, encodedFrames: 4)
        XCTAssertEqual(falling.recovery.phase, .pending)

        var age = Fixture()
        age.sample(at: 500, encodedFrames: 1)
        age.sample(at: 1_000, encodedFrames: 2)
        age.sample(at: 2_000, capacity: 10_000_000, packetEvidence: .noNewPackets, encodedFrames: 2)
        age.sample(at: 2_501, capacity: 10_000_000, encodedFrames: 3)
        XCTAssertEqual(age.recovery.attempt, 0, "Rising neutral capacity cannot renew the witness clock")
        age.sample(at: 3_001, capacity: 10_000_000, encodedFrames: 4)
        XCTAssertEqual(age.recovery.phase, .pending)
    }

    func testReorderedNeutralReportCannotClearCurrentWitnessOrRenewRTT() {
        var fixture = Fixture()
        fixture.sample(at: 500, encodedFrames: 1)
        fixture.sample(at: 1_000, encodedFrames: 2)
        let before = fixture.recovery
        fixture.sample(at: 900, capacity: nil, rttAt: nil,
                       packetEvidence: .noNewPackets, encodedFrames: 2)
        XCTAssertEqual(fixture.recovery, before)
        fixture.sample(at: 1_500, encodedFrames: 3)
        XCTAssertEqual(fixture.recovery.phase, .pending)

        var expiredRTT = Fixture()
        expiredRTT.sample(at: 3_000, encodedFrames: 1)
        expiredRTT.sample(at: 3_500, encodedFrames: 2)
        expiredRTT.sample(at: 4_001, packetEvidence: .noNewPackets, encodedFrames: 2)
        expiredRTT.sample(at: 4_101, packetEvidence: .noNewPackets, encodedFrames: 2)
        expiredRTT.sample(at: 4_500, rttAt: 4_200, encodedFrames: 3)
        XCTAssertEqual(expiredRTT.recovery.attempt, 0, "Neutral polls cannot renew expired RTT health")
    }

    func testRequiresNativeApplyThenTwoFullSourceProgressWitnesses() {
        var fixture = Fixture()
        fixture.admit()
        fixture.sample(at: 1_600, full: true)
        fixture.sample(at: 2_100, full: true)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        fixture.recovery.markApplied(at: fixture.time(2_200))
        XCTAssertEqual(fixture.recovery.phase, .trial)
        XCTAssertTrue(fixture.recovery.isActive)
        fixture.sample(at: 2_300, full: true)
        XCTAssertEqual(fixture.recovery.phase, .trial)
        fixture.sample(at: 2_800, full: true)
        XCTAssertEqual(fixture.recovery.phase, .accepted)
        XCTAssertFalse(fixture.recovery.isTrialActive)
        XCTAssertTrue(fixture.recovery.isActive)
        XCTAssertNil(fixture.recovery.deadline)
    }

    func testAdmissionQueueBoundaryRemainsTwentyMilliseconds() {
        for delay in [0.020, 0.020_001, 0.034, 0.055, 0.100] {
            var fixture = Fixture()
            for time in [500, 1_000, 1_500] { fixture.sample(at: time, queue: delay) }
            XCTAssertEqual(fixture.recovery.phase, delay == 0.020 ? .pending : .observing)
            XCTAssertEqual(fixture.recovery.attempt, delay == 0.020 ? 1 : 0,
                           "Confirmation tolerance must not authorize admission")
        }
    }

    func testPostApplyFullFrameConfirmationAcceptsOneHundredMillisecondsButNotMore() {
        for delay in [0.020_001, 0.034, 0.055, 0.100, 0.100_001] {
            var fixture = Fixture()
            fixture.admit()
            fixture.recovery.markApplied(at: fixture.time(1_600))
            fixture.sample(at: 1_700, full: true, queue: delay)
            XCTAssertEqual(fixture.recovery.phase, .trial)
            XCTAssertEqual(fixture.recovery.deadline, fixture.time(4_500))
            fixture.sample(at: 2_200, full: true, queue: delay)
            XCTAssertEqual(fixture.recovery.phase, delay <= 0.100 ? .accepted : .trial)
            XCTAssertEqual(fixture.recovery.attempt, 1)
        }
    }

    func testOverOneHundredMillisecondsClearsPartialConfirmationWithoutExtendingDeadline() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(1_600))
        fixture.sample(at: 1_700, full: true, queue: 0.055)
        fixture.sample(at: 2_200, full: true, queue: 0.100_001)
        fixture.sample(at: 2_700, full: true, queue: 0.055)
        XCTAssertEqual(fixture.recovery.phase, .trial,
                       "One above-boundary report clears the preceding confirmation witness")
        XCTAssertEqual(fixture.recovery.deadline, fixture.time(4_500))
        fixture.sample(at: 3_200, full: true, queue: 0.055)
        XCTAssertEqual(fixture.recovery.phase, .accepted)
    }

    func testConfirmationToleranceCannotOverrideFreshPressureOrAbsoluteDeadline() {
        var pressure = Fixture()
        pressure.admit()
        pressure.recovery.markApplied(at: pressure.time(1_600))
        pressure.sample(at: 1_700, full: true, queue: 0.055)
        pressure.sample(at: 2_200, pressure: true, full: true, queue: 0.055)
        XCTAssertEqual(pressure.recovery.phase, .cooldown)

        var expired = Fixture()
        expired.admit()
        expired.recovery.markApplied(at: expired.time(1_600))
        expired.sample(at: 4_000, full: true, rttAt: 3_500, queue: 0.055)
        expired.sample(at: 4_500, full: true, rttAt: 3_500, queue: 0.055)
        XCTAssertEqual(expired.recovery.phase, .cooldown)
        XCTAssertEqual(expired.recovery.attempt, 1)
    }

    func testRequestedFullScaleCannotConfirmDownscaledEncoderOutput() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(1_600))
        fixture.sample(at: 1_700)
        fixture.sample(at: 2_200)
        fixture.sample(at: 2_700)
        XCTAssertEqual(fixture.recovery.phase, .trial)
        fixture.recovery.expire(at: fixture.time(4_500))
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertFalse(fixture.recovery.isActive)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(19_500))
    }

    func testAbsoluteDeadlineCannotBeExtendedByNativeApplyOrMissingReports() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(4_400))
        XCTAssertEqual(fixture.recovery.deadline, fixture.time(4_500))
        fixture.recovery.markApplied(at: fixture.time(4_450))
        XCTAssertEqual(fixture.recovery.appliedAt, fixture.time(4_400))
        fixture.recovery.expire(at: fixture.time(4_500))
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        fixture.recovery.markApplied(at: fixture.time(4_600))
        fixture.recovery.expire(at: fixture.time(100_000))
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        XCTAssertFalse(fixture.recovery.isTrialActive)
    }

    func testNativeSuccessAtDeadlineNeverStartsTrial() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(4_500))
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertNil(fixture.recovery.appliedAt)
        XCTAssertFalse(fixture.recovery.isActive)
    }

    func testPressureBeforeAcknowledgementCannotMintTrialAndRequiresNewRTT() {
        var fixture = Fixture()
        fixture.sample(at: 500, eligible: false, pressure: true)
        fixture.sample(at: 1_000, eligible: false)
        for time in [1_500, 2_000, 2_500] { fixture.sample(at: time) }
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 3_000, rttAt: 1_000)
        XCTAssertEqual(fixture.recovery.attempt, 0, "Equal adverse/RTT times are not advancement")
        fixture.sample(at: 3_500, rttAt: 3_100)
        fixture.sample(at: 4_000, rttAt: 3_100)
        XCTAssertEqual(fixture.recovery.phase, .pending)
    }

    func testAllowsTrialBlocksOnlyAdmissionNotAnAlreadyAdmittedTrial() {
        var fixture = Fixture()
        for time in [500, 1_000, 1_500] { fixture.sample(at: time, allowsTrial: false) }
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 2_000)
        fixture.sample(at: 2_500)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        fixture.recovery.markApplied(at: fixture.time(2_600))
        fixture.sample(at: 2_700, full: true, allowsTrial: false)
        fixture.sample(at: 3_200, full: true, allowsTrial: false)
        XCTAssertEqual(fixture.recovery.phase, .accepted)
    }

    func testMissingMalformedAndExpiredEvidenceCannotAdmit() {
        enum Missing { case capacity, rtt, queue, frames }
        for missing in [Missing.capacity, .rtt, .queue, .frames] {
            var fixture = Fixture()
            for time in [500, 1_000, 1_500] {
                fixture.sample(at: time,
                    capacity: missing == .capacity ? nil : 8_000_000,
                    rttAt: missing == .rtt ? nil : 100,
                    queue: missing == .queue ? nil : 0.001,
                    omitFrames: missing == .frames)
            }
            XCTAssertEqual(fixture.recovery.attempt, 0)
        }
        for bad in [Double.nan, .infinity, -1, 0, 7_999_999] {
            var fixture = Fixture()
            for time in [500, 1_000, 1_500] { fixture.sample(at: time, capacity: bad) }
            XCTAssertEqual(fixture.recovery.attempt, 0)
        }
        for bad in [Double.nan, .infinity, -0.001, 0.020_001] {
            var fixture = Fixture()
            for time in [500, 1_000, 1_500] { fixture.sample(at: time, queue: bad) }
            XCTAssertEqual(fixture.recovery.attempt, 0)
        }
        var expired = Fixture()
        for time in [5_000, 5_500, 6_000] { expired.sample(at: time, rttAt: 100) }
        XCTAssertEqual(expired.recovery.attempt, 0)
        var future = Fixture()
        for time in [500, 1_000, 1_500] { future.sample(at: time, rttAt: 2_000) }
        XCTAssertEqual(future.recovery.attempt, 0)
    }

    func testFallingCapacityAndLongWitnessGapsRestartQualification() {
        var fixture = Fixture()
        fixture.sample(at: 500)
        fixture.sample(at: 1_000, capacity: 10_000_000)
        fixture.sample(at: 1_500, capacity: 9_000_000)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 2_000, capacity: 9_000_000)
        fixture.sample(at: 3_501, capacity: 9_000_000)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 4_001, capacity: 9_000_000, rttAt: 3_600)
        XCTAssertEqual(fixture.recovery.phase, .pending)
    }

    func testFrameCounterResetOrEqualityCannotConfirm() {
        for reset in [false, true] {
            var fixture = Fixture()
            fixture.admit()
            fixture.recovery.markApplied(at: fixture.time(1_600))
            fixture.sample(at: 1_700, full: true, encodedFrames: 20)
            fixture.sample(at: 2_200, full: true, encodedFrames: reset ? 0 : 20)
            XCTAssertEqual(fixture.recovery.phase, .trial)
            fixture.sample(at: 2_700, full: true, encodedFrames: 21)
            XCTAssertEqual(fixture.recovery.phase, reset ? .trial : .accepted)
            fixture.sample(at: 3_200, full: true, encodedFrames: 22)
            XCTAssertEqual(fixture.recovery.phase, .accepted)
        }
    }

    func testSourceSizeChangePermanentlyRetiresExactShowEvenWithOldEncodedSize() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(1_600))
        fixture.sample(at: 1_700, full: true, sourceWidth: 540, sourceHeight: 960)
        XCTAssertEqual(fixture.recovery.phase, .retired)
        XCTAssertFalse(fixture.recovery.isArmed)
        fixture.recovery.begin(peerGeneration: 1, showEpoch: 1, at: fixture.time(2_000))
        fixture.sample(at: 2_500, full: true)
        XCTAssertEqual(fixture.recovery.phase, .retired)
    }

    func testMalformedFrameSizesCannotProvideGeometryProof() {
        for dimensions in [(0, 1_920), (-1, 1_920), (1_081, 1_920), (1_080, Int.max)] {
            var fixture = Fixture()
            for index in 1...3 {
                fixture.recovery.observe(at: fixture.time(index * 500), eligible: true, pressure: false,
                    capacityBps: 8_000_000, requiredCapacityBps: 8_000_000,
                    healthyRTTAdvancedAt: fixture.time(100), packetEvidence: .measured(0.001),
                    frames: .init(encodedFrames: UInt64(index), encodedWidth: dimensions.0,
                                  encodedHeight: dimensions.1, sourceWidth: 1_080, sourceHeight: 1_920),
                    allowsTrial: true)
            }
            XCTAssertEqual(fixture.recovery.attempt, 0)
        }
    }

    func testAcceptedMissingTelemetryHoldsGeometryButFreshPressureRetiresIt() {
        var fixture = Fixture()
        fixture.accept()
        fixture.sample(at: 10_000, capacity: nil, rttAt: nil, queue: nil, omitFrames: true)
        fixture.recovery.expire(at: fixture.time(100_000))
        XCTAssertEqual(fixture.recovery.phase, .accepted)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        fixture.sample(at: 100_500, pressure: true, omitFrames: true)
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertFalse(fixture.recovery.isActive)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(115_500))
    }

    func testAdvancingDownscaledEncoderOutputRevokesAcceptanceWithoutEndingShow() {
        var fixture = Fixture()
        fixture.accept()
        fixture.sample(at: 2_700, capacity: nil, rttAt: nil, queue: nil)
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(17_700))
        XCTAssertEqual(fixture.recovery.attempt, 1)
        XCTAssertTrue(fixture.recovery.isArmed, "A later qualified retry remains possible in this Show")
        XCTAssertFalse(fixture.recovery.isActive)
    }

    func testCachedOrResetSmallerFrameCounterIsNotAnAffirmativeContradiction() {
        for reset in [false, true] {
            var fixture = Fixture()
            fixture.accept()
            let lastFrameCount = fixture.frameCount
            fixture.sample(at: 2_700, encodedFrames: reset ? 0 : lastFrameCount)
            XCTAssertEqual(fixture.recovery.phase, .accepted)
            fixture.sample(at: 3_200, encodedFrames: lastFrameCount + 1)
            XCTAssertEqual(fixture.recovery.phase, .cooldown)
        }
    }

    func testIneligiblePendingTrialAndAcceptedStatesRetireWithoutBorrowingAuthority() {
        for applied in [false, true] {
            var fixture = Fixture()
            fixture.admit()
            if applied { fixture.recovery.markApplied(at: fixture.time(1_600)) }
            fixture.sample(at: 1_700, eligible: false)
            XCTAssertEqual(fixture.recovery.phase, .cooldown)
            XCTAssertFalse(fixture.recovery.isActive)
            XCTAssertFalse(fixture.recovery.isTrialActive)
        }
        var accepted = Fixture()
        accepted.accept()
        accepted.sample(at: 3_000, eligible: false)
        XCTAssertEqual(accepted.recovery.phase, .cooldown)
    }

    func testCooldownRetriesUse15Then30Then60SecondsAndRequireNewWitnesses() {
        var fixture = Fixture()
        fixture.admit()
        fixture.sample(at: 1_600, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(16_600))
        fixture.qualify(startingAt: 15_000, rttAt: 14_900)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        fixture.qualify(startingAt: 16_600, rttAt: 16_500)
        XCTAssertEqual(fixture.recovery.attempt, 2)
        fixture.sample(at: 18_000, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(48_000))
        fixture.qualify(startingAt: 48_000, rttAt: 47_900)
        XCTAssertEqual(fixture.recovery.attempt, 3)
        fixture.sample(at: 49_500, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(109_500))
        fixture.qualify(startingAt: 109_500, rttAt: 109_400)
        XCTAssertEqual(fixture.recovery.attempt, 4)
        fixture.sample(at: 111_000, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(171_000))
    }

    func testRepeatedPressureDoesNotIncrementFailureCountOrMintRetry() {
        var fixture = Fixture()
        fixture.admit()
        fixture.sample(at: 1_600, pressure: true)
        for time in [2_000, 3_000, 4_000] { fixture.sample(at: time, pressure: true) }
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(16_600))
        fixture.qualify(startingAt: 17_000, rttAt: 4_000)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        fixture.qualify(startingAt: 19_000, rttAt: 18_900)
        XCTAssertEqual(fixture.recovery.attempt, 2)
        fixture.sample(at: 20_100, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(50_100))
    }

    func testSuccessfulRecoveryResetsBackoffForLaterIndependentCongestionEpisode() {
        var fixture = Fixture()
        fixture.admit()
        fixture.sample(at: 1_600, pressure: true)
        fixture.qualify(startingAt: 16_600, rttAt: 16_500)
        fixture.recovery.markApplied(at: fixture.time(17_700))
        fixture.sample(at: 17_800, full: true, rttAt: 16_500)
        fixture.sample(at: 18_300, full: true, rttAt: 16_500)
        XCTAssertEqual(fixture.recovery.phase, .accepted)
        fixture.sample(at: 18_500, pressure: true)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(33_500))
    }

    func testCadenceResetCannotResetAllowanceDeadlineOrRetainPartialWitnesses() {
        var fixture = Fixture()
        fixture.sample(at: 500)
        fixture.sample(at: 1_000)
        fixture.recovery.clearWitnesses()
        fixture.sample(at: 1_500)
        fixture.sample(at: 2_000)
        XCTAssertEqual(fixture.recovery.attempt, 0)
        fixture.sample(at: 2_500)
        XCTAssertEqual(fixture.recovery.phase, .pending)
        let deadline = fixture.recovery.deadline
        fixture.recovery.clearWitnesses()
        XCTAssertEqual(fixture.recovery.deadline, deadline)
        XCTAssertEqual(fixture.recovery.attempt, 1)
        fixture.recovery.expire(at: fixture.time(5_500))
        let cooldown = fixture.recovery.retryNotBefore
        fixture.recovery.clearWitnesses()
        XCTAssertEqual(fixture.recovery.retryNotBefore, cooldown)
    }

    func testPreAwaitConsumptionImportsOnlyAttemptAndFailedCooldown() {
        var fixture = Fixture()
        fixture.sample(at: 500)
        fixture.sample(at: 1_000)
        var committed = fixture.recovery
        fixture.sample(at: 1_500)
        let proposed = fixture.recovery
        committed.retainAttemptConsumption(from: proposed)
        XCTAssertEqual(committed.attempt, 1)
        XCTAssertEqual(committed.phase, .cooldown)
        XCTAssertEqual(committed.retryNotBefore, fixture.time(16_500))
        XCTAssertNil(committed.appliedAt)
        XCTAssertNil(committed.deadline)
        XCTAssertFalse(committed.isActive)
        XCTAssertFalse(committed.isTrialActive)
        let once = committed
        committed.retainAttemptConsumption(from: proposed)
        XCTAssertEqual(committed, once)
        fixture.recovery.markApplied(at: fixture.time(1_600))
        committed = fixture.recovery
        XCTAssertEqual(committed.phase, .trial, "Only full accepted proposal assignment commits positive state")
    }

    func testPendingApplyRejectionDoesNotInstallTrialOrRetireAcceptedState() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.rejectPendingApplication(at: fixture.time(1_600))
        XCTAssertEqual(fixture.recovery.phase, .cooldown)
        XCTAssertEqual(fixture.recovery.retryNotBefore, fixture.time(16_600))
        let rejected = fixture.recovery
        fixture.recovery.rejectPendingApplication(at: fixture.time(2_000))
        XCTAssertEqual(fixture.recovery, rejected)
        var accepted = Fixture()
        accepted.accept()
        let before = accepted.recovery
        accepted.recovery.rejectPendingApplication(at: accepted.time(3_000))
        XCTAssertEqual(accepted.recovery, before)
    }

    func testFailedNativeRollbackRetainsExactTerminalStateWithoutPositiveProposal() {
        var fixture = Fixture()
        fixture.admit()
        fixture.recovery.markApplied(at: fixture.time(1_600))
        var actual = fixture.recovery
        fixture.recovery.expire(at: fixture.time(4_500))
        actual.retainTerminalState(from: fixture.recovery)
        XCTAssertEqual(actual.phase, .cooldown)
        XCTAssertEqual(actual.attempt, 1)
        XCTAssertNil(actual.deadline)
        XCTAssertFalse(actual.isActive)
        actual.retainTerminalState(from: Fixture().recovery)
        XCTAssertEqual(actual.phase, .cooldown)
    }

    func testOldAttemptTerminalCannotCancelNewAttemptInSameShow() {
        var fixture = Fixture()
        fixture.admit()
        fixture.sample(at: 1_600, pressure: true)
        let previousFailure = fixture.recovery
        fixture.qualify(startingAt: 16_600, rttAt: 16_500)
        XCTAssertEqual(fixture.recovery.attempt, 2)
        let newAttempt = fixture.recovery
        fixture.recovery.retainTerminalState(from: previousFailure)
        fixture.recovery.retainAttemptConsumption(from: previousFailure)
        XCTAssertEqual(fixture.recovery, newAttempt)
    }

    func testEndRetainsReplayFenceAndOldOwnersCannotSpendOrRetireSuccessors() {
        var fixture = Fixture()
        fixture.admit()
        let oldPositive = fixture.recovery
        fixture.sample(at: 1_600, pressure: true)
        let oldNegative = fixture.recovery
        fixture.recovery.end()
        XCTAssertFalse(fixture.recovery.isArmed)
        fixture.recovery.begin(peerGeneration: 1, showEpoch: 1, at: fixture.time(2_000))
        XCTAssertFalse(fixture.recovery.isArmed)
        fixture.recovery.begin(peerGeneration: 1, showEpoch: 2, at: fixture.time(2_100))
        let newShow = fixture.recovery
        fixture.recovery.retainAttemptConsumption(from: oldPositive)
        fixture.recovery.retainTerminalState(from: oldNegative)
        XCTAssertEqual(fixture.recovery, newShow)
        fixture.recovery.begin(peerGeneration: 2, showEpoch: 1, at: fixture.time(2_200))
        let newPeer = fixture.recovery
        fixture.recovery.begin(peerGeneration: 1, showEpoch: 999, at: fixture.time(2_300))
        fixture.recovery.retainTerminalState(from: oldNegative)
        XCTAssertEqual(fixture.recovery, newPeer)
    }

    func testReorderedTimeCannotApplyPressureOrLateNativeSuccessToNewerState() {
        var fixture = Fixture()
        fixture.accept()
        let accepted = fixture.recovery
        fixture.sample(at: 500, pressure: true)
        fixture.recovery.expire(at: fixture.time(1_000))
        fixture.recovery.markApplied(at: fixture.time(1_100))
        XCTAssertEqual(fixture.recovery, accepted)
    }

    private struct Fixture {
        let origin = ContinuousClock.now
        var recovery = WorldwideScreenSpatialRecovery()
        var frameCount: UInt64 = 0

        init() { recovery.begin(peerGeneration: 1, showEpoch: 1, at: origin) }

        func time(_ milliseconds: Int) -> ContinuousClock.Instant {
            origin.advanced(by: .milliseconds(milliseconds))
        }

        mutating func sample(
            at milliseconds: Int,
            eligible: Bool = true,
            pressure: Bool = false,
            full: Bool = false,
            capacity: Double? = 8_000_000,
            rttAt: Int? = 100,
            queue: Double? = 0.001,
            packetEvidence: WorldwideScreenSpatialRecoveryPacketEvidence? = nil,
            omitFrames: Bool = false,
            encodedFrames: UInt64? = nil,
            sourceWidth: Int = 1_080,
            sourceHeight: Int = 1_920,
            allowsTrial: Bool = true
        ) {
            frameCount = encodedFrames ?? (frameCount + 1)
            recovery.observe(at: time(milliseconds), eligible: eligible, pressure: pressure,
                capacityBps: capacity, requiredCapacityBps: 8_000_000,
                healthyRTTAdvancedAt: rttAt.map(time),
                packetEvidence: packetEvidence ?? queue.map { .measured($0) } ?? .unavailable,
                frames: omitFrames ? nil : .init(encodedFrames: frameCount,
                    encodedWidth: full ? 1_080 : 720, encodedHeight: full ? 1_920 : 1_280,
                    sourceWidth: sourceWidth, sourceHeight: sourceHeight),
                allowsTrial: allowsTrial)
        }

        mutating func qualify(startingAt start: Int, rttAt: Int = 100) {
            for time in [start, start + 500, start + 1_000] { sample(at: time, rttAt: rttAt) }
        }

        mutating func admit() {
            qualify(startingAt: 500)
            XCTAssertEqual(recovery.phase, .pending)
        }

        mutating func accept() {
            admit()
            recovery.markApplied(at: time(1_600))
            sample(at: 1_700, full: true)
            sample(at: 2_200, full: true)
            XCTAssertEqual(recovery.phase, .accepted)
        }
    }
}
