#if DEBUG && os(macOS)
import Foundation
import XCTest
@testable import WebRTCTransport

final class WebRTCStartupPacingAdmissionTests: XCTestCase {
    func testCompositionPreservesCompleteBaselineAndOnlyChangesFactor() throws {
        let baseline = WebRTCMacStartupFieldTrials.baseline
        XCTAssertEqual(baseline, "WebRTC-Bwe-ProbingBehavior/min_packet_size:0/")
        let extra = baseline + "Unknown-Future-Key/Enabled,test:7/Second-Sentinel/Disabled/"
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control, baseline: extra),
                       extra + "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/")
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.candidate, baseline: extra),
                       extra + "WebRTC-ProbingScreenshareBwe/1.15,2875,80,40,-60,3/")
    }

    func testCompositionRejectsMalformedDuplicateAndConflictingBaseline() {
        for baseline in ["", "Missing/Terminator", "Odd/Fields/Extra/", "Empty//",
                         "Control/Bad\nValue/", "A/One/A/Two/",
                         "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/",
                         "WebRTC-StrictPacingAndProbing/Enabled/", String(repeating: "a", count: 16_385) + "/v/"] {
            XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(.candidate, baseline: baseline))
        }
    }

    func testOrdinaryAdmissionPermanentlyPreventsExperimentReservation() throws {
        let admission = WebRTCStartupPacingAdmission()
        XCTAssertNil(admission.frozenConfiguration)
        try admission.admit(role: .host, topology: .videoControlOnly, token: nil)
        XCTAssertEqual(admission.frozenConfiguration, WebRTCMacStartupFieldTrials.baseline)
        XCTAssertThrowsError(try admission.reserve(factor: .candidate))
        // Normal sessions remain unrestricted by this debug-only fixture guard.
        try admission.admit(role: .viewer, topology: .full, token: nil)
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: UUID()))
    }

    func testExperimentRequiresExactTokenVideoOnlyAndOnePeerPerRole() throws {
        let admission = WebRTCStartupPacingAdmission()
        let token = try admission.reserve(factor: .candidate)
        XCTAssertThrowsError(try admission.reserve(factor: .control))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: nil))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: UUID()))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .full, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: token))
        try admission.admit(role: .host, topology: .videoControlOnly, token: token)
        try admission.admit(role: .viewer, topology: .videoControlOnly, token: token)
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .videoControlOnly, token: token))
        XCTAssertEqual(admission.frozenConfiguration,
                       "WebRTC-Bwe-ProbingBehavior/min_packet_size:0/WebRTC-ProbingScreenshareBwe/1.15,2875,80,40,-60,3/")
    }

    func testRetirementNeverReopensOrdinaryAdmissionOrChangesFrozenConfiguration() throws {
        let admission = WebRTCStartupPacingAdmission()
        let token = try admission.reserve(factor: .control)
        let frozen = admission.frozenConfiguration
        XCTAssertFalse(admission.retire(token: UUID()))
        XCTAssertTrue(admission.retire(token: token))
        XCTAssertFalse(admission.retire(token: token))
        XCTAssertEqual(admission.frozenConfiguration, frozen)
        XCTAssertThrowsError(try admission.reserve(factor: .candidate))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: nil))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
    }

    func testOptInRequiresExactSingleSelectedNativeTest() throws {
        let selected = "CaptureServerTests.WebRTCStartupClarityExperimentTests/testPacingFactorControlWeak"
        let arguments = ["/reviewed/usr/bin/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: arguments, environment: environment)
        let multiple = selected + ",Another/testCase"
        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(
            selectedTest: multiple, arguments: [arguments[0], "-XCTest", multiple, arguments[3]], environment: environment))
        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: arguments, environment: [:]))
        for wrong in [[], ["/app/CaptureServer", "-XCTest", selected, arguments[3]],
                      [arguments[0], "-XCTest", "All", arguments[3]],
                      [arguments[0], "-XCTest", selected + ",Another/testCase", arguments[3]],
                      [arguments[0], "-XCTest", selected, "-XCTest", selected, arguments[3]],
                      [arguments[0], "-XCTest", selected, "/OtherTests.xctest"]] {
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: wrong, environment: environment))
        }
    }

    func testEstimatorFlagIsExplicitControlOnlyAndPreservesBaseline() throws {
        let ordinary = try WebRTCMacStartupFieldTrials.withPacingFactor(.control)
        XCTAssertFalse(ordinary.contains("InjectedCongestionController"))
        let diagnostic = try WebRTCMacStartupFieldTrials.withPacingFactor(.control, observeEstimator: true)
        XCTAssertEqual(diagnostic, ordinary + "WebRTC-Bwe-InjectedCongestionController/Enabled/")
        XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(.candidate, observeEstimator: true))
        XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(
            .control, baseline: "WebRTC-Bwe-InjectedCongestionController/Disabled/", observeEstimator: true))
        let admission = WebRTCStartupPacingAdmission()
        _ = try admission.reserve(factor: .control, observeEstimator: true)
        XCTAssertEqual(admission.frozenConfiguration, diagnostic)
    }

    func testDelayedBaselineObserverCannotBorrowHoldOrProbeCapAdmission() throws {
        let selected = "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverDelayedDynamic"
        let arguments = ["/reviewed/usr/bin/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: arguments,
            environment: environment, observeEstimator: true)
        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
            arguments: arguments, environment: environment))
        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
            arguments: arguments, environment: environment, observeEstimator: true, holdDelayGrowthInALR: true))
        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
            arguments: arguments, environment: environment, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
        for key in environment.keys {
            var missing = environment
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: arguments, environment: missing, observeEstimator: true))
        }
    }

    func testDefaultPacingCohortRequiresItsOwnSelectionAndExactPairedFlags() throws {
        let prefix = "CaptureServerTests.WebRTCStartupClarityExperimentTests/"
        let names = [
            "testNativeEstimatorDefaultPacingDelayedDynamicControl",
            "testNativeEstimatorALRProbeCapDefaultPacingDelayedDynamic",
            "testNativeEstimatorALRProbeCapDefaultPacingWeak",
            "testNativeEstimatorALRProbeCapDefaultPacingDisabledRecovery",
            "testNativeEstimatorALRProbeCapDefaultPacingEnabledRecovery",
            "testNativeEstimatorALRProbeCapDefaultPacingSecondDrop",
            "testNativeEstimatorALRProbeCapDefaultPacingAmple"
        ]
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        for (index, name) in names.enumerated() {
            let selected = prefix + name
            let arguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            let candidate = index != 0
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: arguments, environment: environment, observeEstimator: true,
                holdDelayGrowthInALR: candidate, skipProbesBelowCurrentEstimate: candidate,
                defaultPacingCohort: true)
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: arguments, environment: environment, observeEstimator: true,
                holdDelayGrowthInALR: candidate, skipProbesBelowCurrentEstimate: candidate))
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: arguments, environment: environment, observeEstimator: false,
                holdDelayGrowthInALR: candidate, skipProbesBelowCurrentEstimate: candidate,
                defaultPacingCohort: true))
            for (hold, skip) in [(false, false), (true, false), (false, true), (true, true)]
                where hold != candidate || skip != candidate {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                    arguments: arguments, environment: environment, observeEstimator: true,
                    holdDelayGrowthInALR: hold, skipProbesBelowCurrentEstimate: skip,
                    defaultPacingCohort: true))
            }
            for key in environment.keys {
                var missing = environment
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                    arguments: arguments, environment: missing, observeEstimator: true,
                    holdDelayGrowthInALR: candidate, skipProbesBelowCurrentEstimate: candidate,
                    defaultPacingCohort: true))
            }
            var multiple = arguments
            multiple[2] += "," + prefix + "testNativeEstimatorObserverWeak"
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: multiple, environment: environment, observeEstimator: true,
                holdDelayGrowthInALR: candidate, skipProbesBelowCurrentEstimate: candidate,
                defaultPacingCohort: true))
        }
    }

    func testLegacyEstimatorAndTwentyMillisecondSelectionsCannotBorrowDefaultPacingCohort() {
        let prefix = "CaptureServerTests.WebRTCStartupClarityExperimentTests/"
        let legacy = [
            ("testNativeEstimatorObserverDelayedDynamic", false, false),
            ("testNativeEstimatorObserverWeak", false, false),
            ("testNativeEstimatorALRGrowthHoldWeak", true, false),
            ("testNativeEstimatorALRProbeCapWeak", true, true),
            ("testNativeEstimatorALRProbeCapDisabledRecovery", true, true),
            ("testNativeEstimatorALRProbeCapEnabledRecovery", true, true),
            ("testNativeEstimatorALRProbeCapSecondDrop", true, true),
            ("testNativeEstimatorALRProbeCapAmple", true, true),
            ("testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic", true, true)
        ]
        for (name, hold, skip) in legacy {
            let selected = prefix + name
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"],
                environment: ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"],
                observeEstimator: true, holdDelayGrowthInALR: hold, skipProbesBelowCurrentEstimate: skip,
                defaultPacingCohort: true))
        }
    }

    func testEstimatorOptInCannotBorrowAnOrdinaryFactorTestSelection() throws {
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        let diagnostic = "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverWeak"
        let ordinary = "CaptureServerTests.WebRTCStartupClarityExperimentTests/testPacingFactorControlWeak"
        for (selected, observe) in [(diagnostic, true), (ordinary, false)] {
            let args = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: args,
                environment: environment, observeEstimator: observe)
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: args, environment: environment, observeEstimator: !observe))
        }
    }

    func testALRGrowthHoldCompositionIsExplicitAndPreservesCompleteBaseline() throws {
        let baseline = WebRTCMacStartupFieldTrials.baseline
            + "Unknown-Future-Key/Enabled,test:7/Second-Sentinel/Disabled/"
        let observer = baseline + "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/"
            + "WebRTC-Bwe-InjectedCongestionController/Enabled/"
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true), observer)
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: false), observer)
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true),
            observer + "WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/")
        XCTAssertFalse(try WebRTCMacStartupFieldTrials.withPacingFactor(.control)
            .contains("DontIncreaseDelayBasedBweInAlr"))
    }

    func testALRGrowthHoldRequiresObserverAndControlBeforeReservation() throws {
        let invalid: [(WebRTCStartupPacingFactor, Bool)] = [
            (.control, false), (.candidate, false), (.candidate, true)
        ]
        for (factor, observe) in invalid {
            XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(factor,
                observeEstimator: observe, holdDelayGrowthInALR: true))
            let admission = WebRTCStartupPacingAdmission()
            XCTAssertThrowsError(try admission.reserve(factor: factor,
                observeEstimator: observe, holdDelayGrowthInALR: true))
            XCTAssertNil(admission.frozenConfiguration)
            _ = try admission.reserve(factor: .control, observeEstimator: true, holdDelayGrowthInALR: true)
            XCTAssertEqual(admission.frozenConfiguration,
                WebRTCMacStartupFieldTrials.baseline
                    + "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/"
                    + "WebRTC-Bwe-InjectedCongestionController/Enabled/"
                    + "WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/")
        }
    }

    func testALRGrowthHoldRejectsPreexistingTrialWithoutOverridingBaseline() {
        for group in ["Enabled", "Disabled", "Enabled,sentinel:7"] {
            let baseline = WebRTCMacStartupFieldTrials.baseline
                + "WebRTC-DontIncreaseDelayBasedBweInAlr/\(group)/"
            for (observe, hold) in [(false, false), (true, false), (true, true)] {
                XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
                    baseline: baseline, observeEstimator: observe, holdDelayGrowthInALR: hold))
            }
        }
    }

    func testALRGrowthHoldReservationPreservesProcessTopologyTokenAndRetirementGates() throws {
        let ordinary = WebRTCStartupPacingAdmission()
        try ordinary.admit(role: .host, topology: .videoControlOnly, token: nil)
        XCTAssertThrowsError(try ordinary.reserve(factor: .control,
            observeEstimator: true, holdDelayGrowthInALR: true))
        XCTAssertEqual(ordinary.frozenConfiguration, WebRTCMacStartupFieldTrials.baseline)

        let admission = WebRTCStartupPacingAdmission()
        let token = try admission.reserve(factor: .control, observeEstimator: true, holdDelayGrowthInALR: true)
        let frozen = try XCTUnwrap(admission.frozenConfiguration)
        XCTAssertTrue(frozen.hasSuffix("WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/"))
        XCTAssertThrowsError(try admission.reserve(factor: .control, observeEstimator: true))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: nil))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: UUID()))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .full, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: token))
        try admission.admit(role: .host, topology: .videoControlOnly, token: token)
        try admission.admit(role: .viewer, topology: .videoControlOnly, token: token)
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .videoControlOnly, token: token))
        XCTAssertFalse(admission.retire(token: UUID()))
        XCTAssertTrue(admission.retire(token: token))
        XCTAssertThrowsError(try admission.reserve(factor: .control,
            observeEstimator: true, holdDelayGrowthInALR: true))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: nil))
        XCTAssertEqual(admission.frozenConfiguration, frozen)
    }

    func testALRGrowthHoldOptInRequiresItsOwnExactObserverSelection() throws {
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        for held in alrGrowthHoldMethods {
            let arguments = ["/reviewed/xctest", "-XCTest", held, "/fixture/BelugaPackageTests.xctest"]
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: held, arguments: arguments,
                environment: environment, observeEstimator: true, holdDelayGrowthInALR: true)
            for (observe, hold) in [(false, false), (true, false), (false, true)] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: held,
                    arguments: arguments, environment: environment, observeEstimator: observe,
                    holdDelayGrowthInALR: hold))
            }
            for other in alrGrowthHoldMethods where other != held {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: other,
                    arguments: arguments, environment: environment, observeEstimator: true,
                    holdDelayGrowthInALR: true))
            }
        }
        for other in ["testPacingFactorControlWeak", "testPacingFactorCandidateWeak",
                      "testNativeEstimatorObserverWeak", "testNativeEstimatorObserverConstruction",
                      "testSpatialRecoveryDisabledMovingDropAndRecovery",
                      "testSpatialRecoveryEnabledMovingDropAndRecovery",
                      "testSpatialRecoveryEnabledMovingSecondCapacityDrop",
                      "testSpatialRecoveryEnabledSteadyAmpleMoving",
                      "testNativeEstimatorALRGrowthHoldWeakExtra", "testNativeEstimatorALRGrowthHoldUnknown"] {
            let selected = "CaptureServerTests.WebRTCStartupClarityExperimentTests/\(other)"
            let otherArguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: otherArguments, environment: environment, observeEstimator: true,
                holdDelayGrowthInALR: true))
        }
    }

    func testALRGrowthHoldOptInRetainsBothFlagsAndExactSingleProcessSelection() {
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        for selected in alrGrowthHoldMethods {
            let arguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            for key in environment.keys {
                for flag in [String?.none, "0"] {
                    var wrong = environment
                    wrong[key] = flag
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                        arguments: arguments, environment: wrong, observeEstimator: true, holdDelayGrowthInALR: true))
                }
            }
            for wrong in [[], ["/app/CaptureServer", "-XCTest", selected, arguments[3]],
                          [arguments[0], "-XCTest", "All", arguments[3]],
                          [arguments[0], "-XCTest", selected + ",Another/testCase", arguments[3]],
                          [arguments[0], "-XCTest", selected, "-XCTest", selected, arguments[3]],
                          [arguments[0], "-XCTest", selected, "/OtherTests.xctest"]] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                    arguments: wrong, environment: environment, observeEstimator: true, holdDelayGrowthInALR: true))
            }
        }
    }

    func testALRProbeCapCompositionIsExplicitAndPreservesCompleteBaseline() throws {
        let baseline = WebRTCMacStartupFieldTrials.baseline
            + "Unknown-Future-Key/Enabled,test:7/Second-Sentinel/Disabled/"
        let held = baseline + "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/"
            + "WebRTC-Bwe-InjectedCongestionController/Enabled/"
            + "WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/"
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true), held)
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: false), held)
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: true), held + alrProbeCapTrial)
        XCTAssertFalse(try WebRTCMacStartupFieldTrials.withPacingFactor(.control)
            .contains("WebRTC-Bwe-ProbingConfiguration"))
        XCTAssertFalse(try WebRTCMacStartupFieldTrials.withPacingFactor(.control, observeEstimator: true)
            .contains("WebRTC-Bwe-ProbingConfiguration"))
    }

    func testALRProbeCapRequiresHoldObserverAndControlBeforeReservation() throws {
        for factor in [WebRTCStartupPacingFactor.control, .candidate] {
            for observe in [false, true] {
                for hold in [false, true] where factor != .control || !observe || !hold {
                    XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(factor,
                        observeEstimator: observe, holdDelayGrowthInALR: hold,
                        skipProbesBelowCurrentEstimate: true))
                    let admission = WebRTCStartupPacingAdmission()
                    XCTAssertThrowsError(try admission.reserve(factor: factor,
                        observeEstimator: observe, holdDelayGrowthInALR: hold,
                        skipProbesBelowCurrentEstimate: true))
                    XCTAssertNil(admission.frozenConfiguration)
                    _ = try admission.reserve(factor: .control, observeEstimator: true,
                        holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true)
                    XCTAssertEqual(admission.frozenConfiguration,
                        WebRTCMacStartupFieldTrials.baseline
                            + "WebRTC-ProbingScreenshareBwe/1.0,2875,80,40,-60,3/"
                            + "WebRTC-Bwe-InjectedCongestionController/Enabled/"
                            + "WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/" + alrProbeCapTrial)
                }
            }
        }
    }

    func testALRProbeCapRejectsPreexistingTrialWithoutOverridingBaseline() {
        for trial in [alrProbeCapTrial, "WebRTC-Bwe-ProbingConfiguration/Enabled/",
                      "WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:0.0/",
                      "WebRTC-Bwe-ProbingConfiguration/skip_max_allocated_scale:3.0/"] {
            let baseline = WebRTCMacStartupFieldTrials.baseline + trial
            for (observe, hold, skip) in [(false, false, false), (true, false, false),
                                          (true, true, false), (true, true, true)] {
                XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
                    baseline: baseline, observeEstimator: observe, holdDelayGrowthInALR: hold,
                    skipProbesBelowCurrentEstimate: skip))
            }
        }
    }

    func testALRProbeCapReservationPreservesProcessTopologyTokenAndRetirementGates() throws {
        let ordinary = WebRTCStartupPacingAdmission()
        try ordinary.admit(role: .host, topology: .videoControlOnly, token: nil)
        XCTAssertThrowsError(try ordinary.reserve(factor: .control, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
        XCTAssertEqual(ordinary.frozenConfiguration, WebRTCMacStartupFieldTrials.baseline)

        let admission = WebRTCStartupPacingAdmission()
        let token = try admission.reserve(factor: .control, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true)
        let frozen = try XCTUnwrap(admission.frozenConfiguration)
        XCTAssertTrue(frozen.hasSuffix(alrProbeCapTrial))
        XCTAssertThrowsError(try admission.reserve(factor: .control,
            observeEstimator: true, holdDelayGrowthInALR: true))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: nil))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: UUID()))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .full, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: token))
        try admission.admit(role: .host, topology: .videoControlOnly, token: token)
        try admission.admit(role: .viewer, topology: .videoControlOnly, token: token)
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .videoControlOnly, token: token))
        XCTAssertFalse(admission.retire(token: UUID()))
        XCTAssertTrue(admission.retire(token: token))
        XCTAssertThrowsError(try admission.reserve(factor: .control, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
        XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
        XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: nil))
        XCTAssertEqual(admission.frozenConfiguration, frozen)
    }

    func testALRProbeCapOptInRequiresItsOwnExactHeldObserverSelection() throws {
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        for selected in alrProbeCapMethods {
            let arguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected, arguments: arguments,
                environment: environment, observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true)
            for observe in [false, true] {
                for hold in [false, true] {
                    for skip in [false, true] where !observe || !hold || !skip {
                        XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                            arguments: arguments, environment: environment, observeEstimator: observe,
                            holdDelayGrowthInALR: hold, skipProbesBelowCurrentEstimate: skip))
                    }
                }
            }
            for other in alrProbeCapMethods where other != selected {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: other,
                    arguments: arguments, environment: environment, observeEstimator: true,
                    holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
            }
        }
        let otherMethods = alrGrowthHoldMethods + ["testPacingFactorControlWeak", "testPacingFactorCandidateWeak",
            "testNativeEstimatorObserverWeak", "testNativeEstimatorObserverConstruction",
            "testSpatialRecoveryDisabledMovingDropAndRecovery", "testSpatialRecoveryEnabledMovingDropAndRecovery",
            "testSpatialRecoveryEnabledMovingSecondCapacityDrop", "testSpatialRecoveryEnabledSteadyAmpleMoving",
            "testNativeEstimatorALRProbeCapWeakExtra", "testNativeEstimatorALRProbeCapUnknown"].map {
                "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + $0
            }
        for selected in otherMethods {
            let arguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                arguments: arguments, environment: environment, observeEstimator: true,
                holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
        }
    }

    func testALRProbeCapOptInRetainsBothFlagsAndExactSingleProcessSelection() {
        let environment = ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
        for selected in alrProbeCapMethods {
            let arguments = ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
            for key in environment.keys {
                for flag in [String?.none, "0"] {
                    var wrong = environment
                    wrong[key] = flag
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                        arguments: arguments, environment: wrong, observeEstimator: true,
                        holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
                }
            }
            for wrong in [[], ["/app/CaptureServer", "-XCTest", selected, arguments[3]],
                          [arguments[0], "-XCTest", "All", arguments[3]],
                          [arguments[0], "-XCTest", selected + ",Another/testCase", arguments[3]],
                          [arguments[0], "-XCTest", selected, "-XCTest", selected, arguments[3]],
                          [arguments[0], "-XCTest", selected, "/OtherTests.xctest"]] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                    arguments: wrong, environment: environment, observeEstimator: true,
                    holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true))
            }
        }
    }

    func testProbeDurationCompositionPreservesControlAndAddsOnlyFortyMilliseconds() throws {
        let baseline = WebRTCMacStartupFieldTrials.baseline + "Future-Sentinel/Enabled,value:7/"
        let legacy = try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: true)
        let control = try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: true, probeDurationExperiment: .control15)
        let candidate = try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: true, probeDurationExperiment: .candidate40)
        XCTAssertEqual(control, legacy)
        XCTAssertFalse(control.contains("min_probe_duration"))
        XCTAssertEqual(candidate, String(legacy.dropLast()) + ",min_probe_duration:40ms/")
        XCTAssertTrue(candidate.hasPrefix(baseline))
        XCTAssertEqual(candidate.components(separatedBy: "WebRTC-Bwe-ProbingConfiguration/").count, 2)
        XCTAssertEqual(candidate.components(separatedBy: "WebRTC-Bwe-ProbingBehavior/").count, 2)
        XCTAssertEqual(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
            baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
            skipProbesBelowCurrentEstimate: true, probeDurationExperiment: nil), legacy)
    }

    func testProbeDurationRequiresAllHeldObserverFlagsAndControlBeforeReservation() throws {
        for arm in probeDurationArms {
            for factor in [WebRTCStartupPacingFactor.control, .candidate] {
                for observe in [false, true] {
                    for hold in [false, true] {
                        for skip in [false, true]
                            where factor != .control || !observe || !hold || !skip {
                            XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(factor,
                                observeEstimator: observe, holdDelayGrowthInALR: hold,
                                skipProbesBelowCurrentEstimate: skip, probeDurationExperiment: arm.experiment))
                            let admission = WebRTCStartupPacingAdmission()
                            XCTAssertThrowsError(try admission.reserve(factor: factor,
                                observeEstimator: observe, holdDelayGrowthInALR: hold,
                                skipProbesBelowCurrentEstimate: skip, probeDurationExperiment: arm.experiment))
                            XCTAssertNil(admission.frozenConfiguration)
                            _ = try admission.reserve(factor: .control, observeEstimator: true,
                                holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                                probeDurationExperiment: arm.experiment)
                            XCTAssertEqual(admission.frozenConfiguration,
                                try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
                                    observeEstimator: true, holdDelayGrowthInALR: true,
                                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
                            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(
                                selectedTest: arm.selected, arguments: probeDurationArguments(arm.selected),
                                environment: probeDurationEnvironment, factor: factor,
                                observeEstimator: observe, holdDelayGrowthInALR: hold,
                                skipProbesBelowCurrentEstimate: skip, probeDurationExperiment: arm.experiment))
                        }
                    }
                }
            }
        }
    }

    func testProbeDurationRejectsPreexistingConfigurationAndBehaviorOverrides() {
        let skipGroup = "skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0"
        let conflicts = [skipGroup, skipGroup + ",min_probe_duration:40ms", "min_probe_duration:40ms"].map {
            WebRTCMacStartupFieldTrials.baseline + "WebRTC-Bwe-ProbingConfiguration/\($0)/"
        } + ["min_packet_size:0,min_probe_duration:15ms", "min_packet_size:0,min_probe_duration:40ms",
             "min_packet_size:1200"].map { "WebRTC-Bwe-ProbingBehavior/\($0)/" }
            + ["Future-Sentinel/Enabled/"]
        for arm in probeDurationArms {
            for baseline in conflicts {
                XCTAssertThrowsError(try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
                    baseline: baseline, observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment), baseline)
            }
        }
    }

    func testProbeDurationOptInRequiresMatchingExactArmAndNoBorrowedSelection() throws {
        let oldSelections = alrProbeCapMethods + alrGrowthHoldMethods + [
            "testPacingFactorControlWeak", "testPacingFactorCandidateWeak",
            "testNativeEstimatorObserverWeak", "testNativeEstimatorObserverDelayedDynamic",
            "testNativeEstimatorObserverConstruction", "testNativeEstimatorDefaultPacingDelayedDynamicControl",
            "testNativeEstimatorALRProbeCapDefaultPacingDelayedDynamic",
            "testNativeEstimatorALRProbeCapDefaultPacingWeak",
            "testNativeEstimatorALRProbeCapDefaultPacingDisabledRecovery",
            "testNativeEstimatorALRProbeCapDefaultPacingEnabledRecovery",
            "testNativeEstimatorALRProbeCapDefaultPacingSecondDrop",
            "testNativeEstimatorALRProbeCapDefaultPacingAmple"
        ].map { "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + $0 }
        for arm in probeDurationArms {
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                factor: .control, observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment)
            let other = arm.experiment == .control15
                ? WebRTCStartupProbeDurationExperiment.candidate40 : .control15
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: other))
            for cohort in [false, true] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, defaultPacingCohort: cohort))
                for selected in oldSelections + [arm.selected + "Extra", "All"] {
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
                        arguments: probeDurationArguments(selected), environment: probeDurationEnvironment,
                        observeEstimator: true, holdDelayGrowthInALR: true,
                        skipProbesBelowCurrentEstimate: true, defaultPacingCohort: cohort,
                        probeDurationExperiment: arm.experiment), selected)
                }
            }
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, defaultPacingCohort: true,
                probeDurationExperiment: arm.experiment))
        }
    }

    func testProbeDurationOptInRetainsProcessAndEnvironmentGates() {
        for arm in probeDurationArms {
            let arguments = probeDurationArguments(arm.selected)
            for key in probeDurationEnvironment.keys {
                for value in [String?.none, "0"] {
                    var environment = probeDurationEnvironment
                    environment[key] = value
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                        arguments: arguments, environment: environment, observeEstimator: true,
                        holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                        probeDurationExperiment: arm.experiment))
                }
            }
            for wrong in [[], ["/app/CaptureServer", "-XCTest", arm.selected, arguments[3]],
                          [arguments[0], "-XCTest", "All", arguments[3]],
                          [arguments[0], "-XCTest", arm.selected + ",Other/test", arguments[3]],
                          [arguments[0], "-XCTest", arm.selected, "-XCTest", arm.selected, arguments[3]],
                          [arguments[0], "-XCTest", arm.selected, "/OtherTests.xctest"]] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: wrong, environment: probeDurationEnvironment, observeEstimator: true,
                    holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                    probeDurationExperiment: arm.experiment))
            }
        }
    }

    func testProbeDurationReservationPreservesTokenTopologyAndRetirement() throws {
        for arm in probeDurationArms {
            let ordinary = WebRTCStartupPacingAdmission()
            try ordinary.admit(role: .host, topology: .videoControlOnly, token: nil)
            XCTAssertThrowsError(try ordinary.reserve(factor: .control, observeEstimator: true,
                holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                probeDurationExperiment: arm.experiment))
            XCTAssertEqual(ordinary.frozenConfiguration, WebRTCMacStartupFieldTrials.baseline)
            let admission = WebRTCStartupPacingAdmission()
            let token = try admission.reserve(factor: .control, observeEstimator: true,
                holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                probeDurationExperiment: arm.experiment)
            let frozen = try XCTUnwrap(admission.frozenConfiguration)
            XCTAssertEqual(frozen, try WebRTCMacStartupFieldTrials.withPacingFactor(.control,
                observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                probeDurationExperiment: arm.experiment))
            XCTAssertThrowsError(try admission.reserve(factor: .control))
            XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: nil))
            XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: UUID()))
            XCTAssertThrowsError(try admission.admit(role: .host, topology: .full, token: token))
            XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: token))
            try admission.admit(role: .host, topology: .videoControlOnly, token: token)
            try admission.admit(role: .viewer, topology: .videoControlOnly, token: token)
            XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
            XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .videoControlOnly, token: token))
            XCTAssertFalse(admission.retire(token: UUID()))
            XCTAssertTrue(admission.retire(token: token))
            XCTAssertFalse(admission.retire(token: token))
            XCTAssertThrowsError(try admission.reserve(factor: .control, observeEstimator: true,
                holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
                probeDurationExperiment: arm.experiment))
            XCTAssertThrowsError(try admission.admit(role: .host, topology: .videoControlOnly, token: token))
            XCTAssertThrowsError(try admission.admit(role: .viewer, topology: .full, token: nil))
            XCTAssertEqual(admission.frozenConfiguration, frozen)
        }
    }

    func testProbeDurationMovingWeakSelectionsRequireMatchingArm() throws {
        for arm in probeDurationWeakArms {
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                factor: .control, observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment)
            for other in probeDurationWeakArms where other.experiment != arm.experiment {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: other.experiment))
            }
            // The new exact method must not displace the same arm's delayed method.
            let delayed = try XCTUnwrap(probeDurationArms.first { $0.experiment == arm.experiment })
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: delayed.selected,
                arguments: probeDurationArguments(delayed.selected), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment)
        }
    }

    func testProbeDurationMovingWeakSelectionsRejectLegacyAndMultipleSelections() {
        for arm in probeDurationWeakArms {
            for cohort in [false, true] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, defaultPacingCohort: cohort))
            }
            for legacy in alrProbeCapMethods + alrGrowthHoldMethods {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: legacy,
                    arguments: probeDurationArguments(legacy), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
            }
            for other in probeDurationArms + probeDurationWeakArms {
                let multiple = arm.selected + "," + other.selected
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: multiple,
                    arguments: probeDurationArguments(multiple), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
                if other.selected != arm.selected {
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                        arguments: probeDurationArguments(other.selected), environment: probeDurationEnvironment,
                        observeEstimator: true, holdDelayGrowthInALR: true,
                        skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
                }
            }
            let suffix = arm.selected + "Extra"
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: suffix,
                arguments: probeDurationArguments(suffix), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
        }
    }

    func testProbeDurationMovingWeakSelectionsRequireCompleteFlagsAndOwnCohort() {
        for arm in probeDurationWeakArms {
            for factor in [WebRTCStartupPacingFactor.control, .candidate] {
                for observe in [false, true] {
                    for hold in [false, true] {
                        for skip in [false, true]
                            where factor != .control || !observe || !hold || !skip {
                            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                                factor: factor, observeEstimator: observe, holdDelayGrowthInALR: hold,
                                skipProbesBelowCurrentEstimate: skip, probeDurationExperiment: arm.experiment))
                        }
                    }
                }
            }
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, defaultPacingCohort: true,
                probeDurationExperiment: arm.experiment))
            for key in probeDurationEnvironment.keys {
                var missing = probeDurationEnvironment
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: missing,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
            }
        }
    }

    func testProbeDurationMovingRecoverySelectionsRequireMatchingArm() throws {
        for arm in probeDurationRecoveryArms {
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                factor: .control, observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment)
            for other in probeDurationRecoveryArms where other.experiment != arm.experiment {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: other.experiment))
            }
            for prior in probeDurationArms + probeDurationWeakArms where prior.experiment == arm.experiment {
                try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: prior.selected,
                    arguments: probeDurationArguments(prior.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment)
            }
        }
    }

    func testProbeDurationMovingRecoverySelectionsRejectLegacyAndMultipleSelections() {
        for arm in probeDurationRecoveryArms {
            for cohort in [false, true] {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, defaultPacingCohort: cohort))
            }
            for legacy in alrProbeCapMethods + alrGrowthHoldMethods {
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: legacy,
                    arguments: probeDurationArguments(legacy), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
            }
            for other in probeDurationArms + probeDurationWeakArms + probeDurationRecoveryArms {
                let multiple = arm.selected + "," + other.selected
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: multiple,
                    arguments: probeDurationArguments(multiple), environment: probeDurationEnvironment,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
                if other.selected != arm.selected {
                    XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                        arguments: probeDurationArguments(other.selected), environment: probeDurationEnvironment,
                        observeEstimator: true, holdDelayGrowthInALR: true,
                        skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
                }
            }
            let suffix = arm.selected + "Extra"
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: suffix,
                arguments: probeDurationArguments(suffix), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
        }
    }

    func testProbeDurationMovingRecoverySelectionsRequireCompleteFlagsAndOwnCohort() {
        for arm in probeDurationRecoveryArms {
            for factor in [WebRTCStartupPacingFactor.control, .candidate] {
                for observe in [false, true] {
                    for hold in [false, true] {
                        for skip in [false, true]
                            where factor != .control || !observe || !hold || !skip {
                            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                                factor: factor, observeEstimator: observe, holdDelayGrowthInALR: hold,
                                skipProbesBelowCurrentEstimate: skip, probeDurationExperiment: arm.experiment))
                        }
                    }
                }
            }
            XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                arguments: probeDurationArguments(arm.selected), environment: probeDurationEnvironment,
                observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, defaultPacingCohort: true,
                probeDurationExperiment: arm.experiment))
            for key in probeDurationEnvironment.keys {
                var missing = probeDurationEnvironment
                missing.removeValue(forKey: key)
                XCTAssertThrowsError(try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: arm.selected,
                    arguments: probeDurationArguments(arm.selected), environment: missing,
                    observeEstimator: true, holdDelayGrowthInALR: true,
                    skipProbesBelowCurrentEstimate: true, probeDurationExperiment: arm.experiment))
            }
        }
    }

    func testEncoderBoundaryDiagnosticRequiresOwnControl15Selection() throws {
        try validateEncoderBoundary()
        let rejectedDurations: [WebRTCStartupProbeDurationExperiment?] = [nil, .candidate40]
        for duration in rejectedDurations {
            XCTAssertThrowsError(try validateEncoderBoundary(duration: duration))
        }
        XCTAssertThrowsError(try validateEncoderBoundary(observeEncoderBoundary: false))
        for prior in probeDurationArms + probeDurationWeakArms + probeDurationRecoveryArms {
            try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: prior.selected,
                arguments: probeDurationArguments(prior.selected), environment: probeDurationEnvironment,
                factor: .control, observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationExperiment: prior.experiment)
        }
    }

    func testEncoderBoundaryDiagnosticRejectsLegacyMultipleAndCrossedSelections() {
        let prior = (probeDurationArms + probeDurationWeakArms + probeDurationRecoveryArms).map { $0.selected }
            + alrProbeCapMethods + alrGrowthHoldMethods
            + ["CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorDefaultPacingDelayedDynamicControl",
               "CaptureServerTests.WebRTCStartupClarityExperimentTests/testPacingFactorControlWeak"]
        for selected in prior {
            XCTAssertThrowsError(try validateEncoderBoundary(selected: selected))
            XCTAssertThrowsError(try validateEncoderBoundary(arguments: probeDurationArguments(selected)))
            XCTAssertThrowsError(try validateEncoderBoundary(selected: selected,
                arguments: probeDurationArguments(encoderBoundarySelection)))
            XCTAssertThrowsError(try validateEncoderBoundary(selected: encoderBoundarySelection + "," + selected))
        }
        for selected in [encoderBoundarySelection + "Extra", "", encoderBoundarySelection + "," + encoderBoundarySelection] {
            XCTAssertThrowsError(try validateEncoderBoundary(selected: selected))
        }
    }

    func testEncoderBoundaryDiagnosticRequiresCompleteFlagsAndProcessOptIn() {
        for factor in [WebRTCStartupPacingFactor.control, .candidate] {
            for observe in [false, true] {
                for hold in [false, true] {
                    for skip in [false, true] where factor != .control || !observe || !hold || !skip {
                        XCTAssertThrowsError(try validateEncoderBoundary(factor: factor,
                            observeEstimator: observe, hold: hold, skip: skip))
                    }
                }
            }
        }
        XCTAssertThrowsError(try validateEncoderBoundary(defaultPacingCohort: true))
        for key in probeDurationEnvironment.keys {
            let rejectedValues: [String?] = [nil, "0", "true", "1 "]
            for value in rejectedValues {
                var environment = probeDurationEnvironment
                environment[key] = value
                XCTAssertThrowsError(try validateEncoderBoundary(environment: environment))
            }
        }
        for arguments in [
            ["/reviewed/swift", "-XCTest", encoderBoundarySelection, "/fixture/BelugaPackageTests.xctest"],
            ["/reviewed/xctest", "-XCTest", encoderBoundarySelection, "/fixture/OtherPackageTests.xctest"],
            ["/reviewed/xctest", "-XCTest", encoderBoundarySelection, "-XCTest", encoderBoundarySelection, "/fixture/BelugaPackageTests.xctest"],
            ["/reviewed/xctest", "/fixture/BelugaPackageTests.xctest"]
        ] {
            XCTAssertThrowsError(try validateEncoderBoundary(arguments: arguments))
        }
    }

    private var encoderBoundarySelection: String {
        "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEncoderBoundaryMovingRecoveryDiagnostic"
    }

    private func validateEncoderBoundary(
        selected: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String]? = nil,
        factor: WebRTCStartupPacingFactor = .control,
        observeEstimator: Bool = true,
        hold: Bool = true,
        skip: Bool = true,
        defaultPacingCohort: Bool = false,
        duration: WebRTCStartupProbeDurationExperiment? = .control15,
        observeEncoderBoundary: Bool = true
    ) throws {
        let selected = selected ?? encoderBoundarySelection
        try WebRTCStartupPacingExperimentOptIn.validate(selectedTest: selected,
            arguments: arguments ?? probeDurationArguments(selected),
            environment: environment ?? probeDurationEnvironment,
            factor: factor, observeEstimator: observeEstimator, holdDelayGrowthInALR: hold,
            skipProbesBelowCurrentEstimate: skip, defaultPacingCohort: defaultPacingCohort,
            probeDurationExperiment: duration, observeEncoderBoundary: observeEncoderBoundary)
    }

    private var probeDurationRecoveryArms: [(experiment: WebRTCStartupProbeDurationExperiment, selected: String)] {
        [(.control15, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingRecoveryControl"),
         (.candidate40, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate")]
    }

    private var probeDurationWeakArms: [(experiment: WebRTCStartupProbeDurationExperiment, selected: String)] {
        [(.control15, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingWeakControl"),
         (.candidate40, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingWeakCandidate")]
    }

    private var probeDurationArms: [(experiment: WebRTCStartupProbeDurationExperiment, selected: String)] {
        [(.control15, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15DelayedControl"),
         (.candidate40, "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40DelayedCandidate")]
    }

    private var probeDurationEnvironment: [String: String] {
        ["OPENSTEAMER_RUN_PACER_EXPERIMENT": "1", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1"]
    }

    private func probeDurationArguments(_ selected: String) -> [String] {
        ["/reviewed/xctest", "-XCTest", selected, "/fixture/BelugaPackageTests.xctest"]
    }

    private var alrProbeCapTrial: String {
        "WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0/"
    }

    private var alrProbeCapMethods: [String] {
        ["testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic",
         "testNativeEstimatorALRProbeCapWeak", "testNativeEstimatorALRProbeCapDisabledRecovery",
         "testNativeEstimatorALRProbeCapEnabledRecovery", "testNativeEstimatorALRProbeCapSecondDrop",
         "testNativeEstimatorALRProbeCapAmple"].map {
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + $0
        }
    }

    private var alrGrowthHoldMethods: [String] {
        ["testNativeEstimatorALRGrowthHoldWeak", "testNativeEstimatorALRGrowthHoldDisabledRecovery",
         "testNativeEstimatorALRGrowthHoldEnabledRecovery", "testNativeEstimatorALRGrowthHoldSecondDrop",
         "testNativeEstimatorALRGrowthHoldAmple"].map {
            "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + $0
        }
    }
}
#endif
