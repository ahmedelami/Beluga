#if os(macOS)
import XCTest

final class StartupVideoDefaultPacingProfileTests: XCTestCase {
    func testProbeDurationArmsPreserveOriginalDelayedWorkloadWithoutBorrowingCohorts() throws {
        for milliseconds in [15, 40] {
            try StartupVideoDefaultPacingEstimatorProfile.validateProbeDurationFixture(
                milliseconds: milliseconds, oneWayDelayMilliseconds: 50, followsPolicyFPS: true,
                hasCapacityExperiment: false, hasOtherObserver: false)
            for delay in [nil, 0, 20, 49, 51] as [Int?] {
                XCTAssertThrowsError(try StartupVideoDefaultPacingEstimatorProfile.validateProbeDurationFixture(
                    milliseconds: milliseconds, oneWayDelayMilliseconds: delay, followsPolicyFPS: true,
                    hasCapacityExperiment: false, hasOtherObserver: false))
            }
            for flags in [(false, false, false), (true, true, false), (true, false, true)] {
                XCTAssertThrowsError(try StartupVideoDefaultPacingEstimatorProfile.validateProbeDurationFixture(
                    milliseconds: milliseconds, oneWayDelayMilliseconds: 50, followsPolicyFPS: flags.0,
                    hasCapacityExperiment: flags.1, hasOtherObserver: flags.2))
            }
        }
        for milliseconds in [-1, 0, 14, 16, 39, 41, Int.max] {
            XCTAssertThrowsError(try StartupVideoDefaultPacingEstimatorProfile.validateProbeDurationFixture(
                milliseconds: milliseconds, oneWayDelayMilliseconds: 50, followsPolicyFPS: true,
                hasCapacityExperiment: false, hasOtherObserver: false))
        }
    }

    func testControlAndCandidateKeepDefaultPacingWithOnlyPairedALRFlagsDifferent() {
        let control = StartupVideoDefaultPacingEstimatorProfile.control
        let candidate = StartupVideoDefaultPacingEstimatorProfile.alrProbeCap
        XCTAssertEqual(control.pacerMode, .sdkDefault)
        XCTAssertEqual(candidate.pacerMode, .sdkDefault)
        XCTAssertFalse(control.holdDelayGrowthInALR)
        XCTAssertFalse(control.skipProbesBelowCurrentEstimate)
        XCTAssertTrue(candidate.holdDelayGrowthInALR)
        XCTAssertTrue(candidate.skipProbesBelowCurrentEstimate)
    }

    func testDelayedProfilesRejectCapacityWorkloadAndCadenceOrDelayDrift() throws {
        for profile in StartupVideoDefaultPacingEstimatorProfile.allCases {
            try profile.validateOriginalDelayedFixture(oneWayDelayMilliseconds: 50,
                followsPolicyFPS: true, hasCapacityExperiment: false)
            let wrongDelays: [Int?] = [nil, 0, 20, 49, 51]
            for delay in wrongDelays {
                XCTAssertThrowsError(try profile.validateOriginalDelayedFixture(
                    oneWayDelayMilliseconds: delay, followsPolicyFPS: true, hasCapacityExperiment: false))
            }
            XCTAssertThrowsError(try profile.validateOriginalDelayedFixture(
                oneWayDelayMilliseconds: 50, followsPolicyFPS: false, hasCapacityExperiment: false))
            XCTAssertThrowsError(try profile.validateOriginalDelayedFixture(
                oneWayDelayMilliseconds: 50, followsPolicyFPS: true, hasCapacityExperiment: true))
        }
    }
}
#endif
