import AVFAudio
import AudioToolbox
import CallKit
import CryptoKit
import Darwin
@preconcurrency import LiveKitWebRTC
@preconcurrency import MediaPlayer
import ObjectiveC
import os
import RemoteSessionCore
import UIKit
import XCTest
@testable import opensteamer
@testable import WebRTCTransport

/// Verifies the native WebRTC audio-device contract and recovery authorization boundary.
/// Deterministic tests assert the production configuration-operation inputs and synchronous
/// revocation rules; the physical-device test remains the hardware RemoteIO oracle.
@MainActor
final class WebRTCAudioPlaybackSessionTests: XCTestCase {
    func testPackagedDynamicFrameworkRetriesItsRealCustomAudioDevice() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This byte-bound artifact smoke check uses Xcode's unmodified Simulator framework; physical RemoteIO has a separate oracle.")
        #else
        XCTAssertTrue(LKRTCInitializeSSL())
        let device = DynamicFrameworkRetryDevice()
        var factory: LKRTCPeerConnectionFactory? = LKRTCPeerConnectionFactory(
            encoderFactory: nil, decoderFactory: nil, audioDevice: device
        )
        let configuration = LKRTCConfiguration()
        configuration.iceServers = []
        configuration.sdpSemantics = .unifiedPlan
        var peer = factory?.peerConnection(
            with: configuration,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        )
        defer {
            peer?.close()
            peer = nil
            factory = nil
            let final = device.snapshot
            XCTAssertEqual(final.initializations, 1)
            XCTAssertEqual(final.terminations, 1)
            XCTAssertFalse(final.initialized)
            XCTAssertFalse(final.playing)
            XCTAssertFalse(final.delegateBound)
            XCTAssertEqual(final.recordingInitializations, 0)
            XCTAssertEqual(final.recordingStarts, 0)
            XCTAssertEqual(final.recordingStops, 1, "The real media engine performs one harmless recording stop during teardown.")
            XCTAssertFalse(final.wrongWorker)
        }
        XCTAssertNotNil(peer)
        XCTAssertTrue(device.snapshot.initialized)
        XCTAssertEqual(device.snapshot.playoutInitializations, 0)
        let proof = try XCTUnwrap(device.exerciseRetry())
        XCTAssertTrue(proof.supportsRetry)
        let image = try XCTUnwrap(proof.imagePath)
        let imageURL = URL(fileURLWithPath: image).resolvingSymlinksInPath().standardizedFileURL
        let factoryImage = try XCTUnwrap(Bundle(for: LKRTCPeerConnectionFactory.self).executableURL)
            .resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(imageURL, factoryImage,
                       "The factory and retry implementation must execute from the same dynamic framework.")
        // Pinned Xcode injects its build-products framework through DYLD_FRAMEWORK_PATH
        // during hosted Simulator tests. Bind the actual loaded image to the exact verified
        // Simulator artifact bytes instead of assuming it uses the app's re-signed copy.
        let imageDigest = SHA256.hash(data: try Data(contentsOf: imageURL))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(imageDigest,
                       "89ad833585353cc20f8bad3272170a574c0ae4c7dea433c8abd45ff2b53d2abe")
        XCTAssertEqual(proof.accepted, [false, true, true])
        XCTAssertEqual(proof.snapshots.map(\.playoutInitializations), [1, 2, 2])
        XCTAssertEqual(proof.snapshots.map(\.playoutStarts), [0, 1, 1])
        XCTAssertEqual(proof.snapshots.map(\.playing), [false, true, true])
        XCTAssertTrue(proof.snapshots.allSatisfy {
            $0.initialized && !$0.wrongWorker
                && $0.recordingInitializations == 0 && $0.recordingStarts == 0
                && $0.recordingStops == 0
        })
        XCTAssertEqual(proof.inactivePCM?.status, noErr)
        XCTAssertEqual(proof.activePCM?.status, noErr)
        XCTAssertEqual(proof.inactivePCM?.flags, .unitRenderAction_OutputIsSilence)
        XCTAssertEqual(proof.activePCM?.flags, [])
        XCTAssertEqual(proof.inactivePCM?.allZero, true)
        XCTAssertEqual(proof.activePCM?.allZero, true, "No track is present; this proves wrapper dispatch, not audibility.")
        #endif
    }

    func testOutputOnlyPolicyRepairIsOneShotAndKeepsExactTransactionFences() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugOutputOnlyPolicyRepairForTesting()
        func value(_ key: String) throws -> NSNumber {
            try XCTUnwrap(result[key], "Missing native result: \(key)")
        }
        XCTAssertEqual(try value("ordinaryOutputPolicy").intValue, 1)
        XCTAssertEqual(try value("microphonePolicy").intValue, 0)
        XCTAssertEqual(try value("hostedPolicy").intValue, 0)
        for target in ["input", "output", "hosted"] {
            for policy in ["default", "longFormAudio", "independent", "video", "unknown"] {
                let expected = target == "input"
                    ? ["default", "longFormAudio"].contains(policy)
                    : policy == (target == "hosted" ? "default" : "longFormAudio")
                XCTAssertEqual(try value("\(target).\(policy).exact").boolValue, expected,
                               "\(target) must accept only effective policies in its exact named profile: \(policy)")
            }
        }
        for policy in ["default", "longFormAudio"] {
            for negative in ["wrongCategoryRejected", "wrongModeRejected", "wrongOptionsRejected", "hostedInputRejected"] {
                XCTAssertTrue(try value("input.\(policy).\(negative)").boolValue, "\(policy): \(negative)")
            }
            for check in ["prepared", "starting", "consumed", "revalidated", "unsupportedRejected"] {
                XCTAssertTrue(try value("input.\(policy).route.\(check)").boolValue, "\(policy): \(check)")
            }
        }
        for (policy, raw) in [("default", 0), ("longFormAudio", 1), ("independent", 2), ("video", 3), ("unknown", -1)] {
            let accepted = raw == 0 || raw == 1
            for state in ["pending", "prepared", "starting", "consumed"] {
                let prefix = "input.\(policy).\(state)."
                XCTAssertEqual(try value(prefix + "accepted").boolValue, accepted, prefix)
                XCTAssertEqual(try value(prefix + "profileMatches").boolValue, accepted, prefix)
                XCTAssertEqual(try value(prefix + "requestedRaw").intValue, 0, "The setter still requests default.")
                XCTAssertEqual(try value(prefix + "observedRaw").intValue, raw, "Readback must not be normalized.")
                XCTAssertTrue(try value(prefix + "identityPreserved").boolValue, prefix)
            }
        }
        for key in ["outputRoutePrepare", "outputRouteStart", "outputRouteCommit", "outputRouteConsumed",
                    "wrongPoliciesRejectedAcrossRouteStates"] {
            XCTAssertTrue(try value(key).boolValue, key)
        }
        let scenarios = ["converged", "persistent", "exact", "setterRejected", "ownershipChanged",
                         "systemChanged", "targetChanged", "outputChanged", "configurationChanged",
                         "expired", "priorRejected", "queuedRejected", "wrongCategory",
                         "recordingIntentChanged", "privacyLatchChanged", "wrongMode", "wrongOptions", "unknownPolicy"]
        let expectedRejections: [String: (first: Int, repeated: Int)] = [
            "converged": (0, 0), "persistent": (1072, 1040), "exact": (0, 0),
            "setterRejected": (1064, 1040), "ownershipChanged": (1737, 1041),
            "systemChanged": (1057, 1041), "targetChanged": (1857, 1041),
            "outputChanged": (1945, 1041), "configurationChanged": (1761, 1041),
            "expired": (1809, 1041), "priorRejected": (1048, 1048),
            "queuedRejected": (1057, 1041), "wrongCategory": (1400, 1400),
            "recordingIntentChanged": (1697, 1041), "privacyLatchChanged": (1721, 1041),
            "wrongMode": (1408, 1408), "wrongOptions": (1416, 1416), "unknownPolicy": (1076, 1044),
        ]
        for scenario in scenarios {
            let succeeds = scenario == "converged" || scenario == "exact"
            let calls = ["exact", "priorRejected", "wrongCategory", "wrongMode", "wrongOptions"].contains(scenario) ? 0 : 1
            XCTAssertTrue(try value(scenario + "FixtureReady").boolValue, scenario)
            XCTAssertEqual(try value(scenario + "Accepted").boolValue, succeeds, scenario)
            XCTAssertEqual(try value(scenario + "Repeated").boolValue, succeeds, scenario)
            XCTAssertEqual(try value(scenario + "FirstCalls").intValue, calls, scenario)
            XCTAssertEqual(try value(scenario + "TotalCalls").intValue, calls, "No second setter: \(scenario)")
            let expected = try XCTUnwrap(expectedRejections[scenario])
            XCTAssertEqual(try value(scenario + "RejectionCode").intValue, expected.first, scenario)
            XCTAssertEqual(try value(scenario + "RepeatedRejectionCode").intValue, expected.repeated, scenario)
            if scenario != "systemChanged" && scenario != "expired" {
                XCTAssertTrue(try value(scenario + "IdentityPreserved").boolValue, scenario)
            }
        }
        XCTAssertTrue(try value("priorRejectedRejectedRemainedRejected").boolValue)
        XCTAssertTrue(try value("queuedRejectedRejectedRemainedRejected").boolValue)
        XCTAssertEqual(try value("setterRejectedError").intValue, -777)
        XCTAssertTrue(try value("rejectionRetainedBeforeRollback").boolValue)
        XCTAssertTrue(try value("healthyRetainsTargetPolicyRejection").boolValue)
        XCTAssertTrue(try value("noAudioIO").boolValue)
    }

    func testPendingCategoryRouteCursorRequiresExactChainedTransactionEvidence() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugOutputOnlyPolicyRepairForTesting()
        for key in ["boundExact", "unboundExact", "reasonEightDispositionUnchanged"] {
            XCTAssertTrue(try XCTUnwrap(result["categoryCursor." + key], key).boolValue, key)
        }
        for rejected in ["notExpected", "notCurrent", "prepared", "starting", "consumed",
                         "rejected", "none", "reasonEight", "oldSequence", "expired",
                         "configuration", "system", "missingFingerprints", "unchained",
                         "policy", "output", "ownership", "inactive"] {
            let key = "categoryCursor.reject." + rejected
            XCTAssertTrue(try XCTUnwrap(result[key], key).boolValue, key)
        }
        for policy in ["default", "longFormAudio"] {
            for proof in ["beforeRejected", "handlerExpectedCategory", "advancedExactly",
                          "startSettlementUntouched", "gatesStayedClosed", "afterPrepared"] {
                let key = "categoryCursor." + policy + "." + proof
                XCTAssertTrue(try XCTUnwrap(result[key], key).boolValue, key)
            }
        }
    }

    func testFrameworkMicrophoneStopClosesCaptureWithoutStealingOutputOnlyTransaction() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugOutputOnlyPolicyRepairForTesting()
        for scenario in ["none", "output", "microphone"] {
            for proof in ["published", "stopped", "privacyClosed", "noPolicyMutation",
                          "truthfulConfiguredInput", "bareStartRejected", "pendingPreserved"] {
                let key = "frameworkStop." + scenario + "." + proof
                XCTAssertTrue(try XCTUnwrap(result[key], key).boolValue, key)
            }
        }
        for proof in ["microphone.outputCannotBorrow", "output.competingEnableRejected",
                      "output.exactCClaimed", "output.nextArmTagged", "output.receiptCorrelated"] {
            let key = "frameworkStop." + proof
            XCTAssertTrue(try XCTUnwrap(result[key], key).boolValue, key)
        }
        XCTAssertTrue(try XCTUnwrap(result["noAudioIO"]).boolValue)
    }

    func testConfigurationGenerationRecoveryUsesMonotonicAllocationAfterRollback() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugConfigurationGenerationRecoveryForTesting()
        func value(_ key: String) throws -> NSNumber {
            try XCTUnwrap(result[key], "Missing native result: \(key)")
        }
        XCTAssertEqual(try value("initialGeneration").uint64Value, 1)
        for attempt in 1...3 {
            let prefix = "attempt\(attempt)"
            XCTAssertTrue(try value(prefix + "RollbackClearedActive").boolValue)
            XCTAssertEqual(try value(prefix + "Generation").uint64Value, UInt64(attempt + 1))
            XCTAssertTrue(try value(prefix + "BaselinesExact").boolValue)
            XCTAssertTrue(try value(prefix + "MismatchesRejected").boolValue)
            XCTAssertTrue(try value(prefix + "Accepted").boolValue, "\(result)")
        }
        XCTAssertTrue(try value("systemBoundaryRejectsOldTag").boolValue)
        XCTAssertEqual(try value("exhaustedAllocation").uint64Value, 0)
        XCTAssertEqual(try value("exhaustedStage").uint64Value, 0)
        XCTAssertEqual(try value("exhaustedActive").uint64Value, 0)
        XCTAssertTrue(try value("inputRemainedClosed").boolValue)
    }

    func testExactRecoveryReconfiguresAfterInitialPlayoutFailureBeforeStart() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugRetryAfterFailedInitialPlayoutForTesting()

        func value(_ key: String) throws -> NSNumber {
            try XCTUnwrap(result[key], "Missing native result: \(key)")
        }

        XCTAssertTrue(try value("initialInitializeFailed").boolValue)
        XCTAssertFalse(try value("initialPlaying").boolValue)
        XCTAssertFalse(try value("initialPlayoutInitialized").boolValue)
        let initialConfigurations = try value("initialConfigurationCount").intValue
        XCTAssertGreaterThan(initialConfigurations, 0)
        for attempt in 1...2 {
            let prefix = "attempt\(attempt)"
            XCTAssertTrue(try value(prefix + "Accepted").boolValue, "\(result)")
            XCTAssertTrue(try value(prefix + "PolicyMatches").boolValue, "\(result)")
            XCTAssertTrue(try value(prefix + "ExactDrain").boolValue, "\(result)")
            XCTAssertFalse(try value(prefix + "InputBusEnabled").boolValue)
            XCTAssertTrue(try value(prefix + "Playing").boolValue, "\(result)")
            XCTAssertTrue(try value(prefix + "SessionActive").boolValue, "\(result)")
            XCTAssertEqual(try value(prefix + "DelegateRetryCount").intValue, attempt)
        }
        let firstConfigurations = try value("attempt1ConfigurationCount").intValue
        XCTAssertGreaterThan(
            firstConfigurations,
            initialConfigurations,
            "An exact retry after failed initialization must attempt configuration, not only retire its tag. \(result)"
        )
        XCTAssertGreaterThanOrEqual(
            try value("attempt2ConfigurationCount").intValue,
            firstConfigurations
        )
    }

    func testExactRecoveryMissingVendorHookClosesNativeOnlyPlayback() throws {
        let result = try assertExactRetryFailure(.missingHook)
        XCTAssertTrue(try retryValue("initialPlaying", in: result).boolValue)
        XCTAssertEqual(try retryValue("delegateRetryCount", in: result).intValue, 0)
        XCTAssertEqual(try retryValue("failureCode", in: result).intValue, 1)
        XCTAssertEqual(try retryValue("failureStatus", in: result).intValue, Int(kAudio_ParamError))
    }

    func testExactRecoveryRejectedVendorHookRollsBackNativeStart() throws {
        let result = try assertExactRetryFailure(.rejectedAfterNativeStart)
        XCTAssertFalse(try retryValue("initialPlaying", in: result).boolValue)
        XCTAssertTrue(try retryValue("nativePlayingInsideHook", in: result).boolValue)
        XCTAssertEqual(try retryValue("delegateRetryCount", in: result).intValue, 1)
        XCTAssertGreaterThan(try retryValue("configurationDelta", in: result).intValue, 0)
        XCTAssertEqual(try retryValue("failureCode", in: result).intValue, 1)
    }

    func testExactRecoveryPreservesNativeInitializationFailureDetails() throws {
        let result = try assertExactRetryFailure(.nativeInitializationFailure)
        XCTAssertEqual(try retryValue("delegateRetryCount", in: result).intValue, 1)
        XCTAssertGreaterThan(try retryValue("configurationDelta", in: result).intValue, 0)
        XCTAssertGreaterThan(try retryValue("failureCode", in: result).intValue, 1)
        XCTAssertTrue(try retryValue("nativeFailurePreserved", in: result).boolValue)
    }

    func testRealSessionPolicyAPIKeepsExactCanonicalTargetsThroughOutputActivationWithoutAudioIO() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugProbeRealSessionPolicySetterForTesting()
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "real-session-policy-api-output-activation-scalars"
        attachment.lifetime = .keepAlways
        add(attachment)
        for key in ["configurationLockAcquired", "ownershipLockAcquired", "initiallyQuiescent",
                    "initialTupleRestorable", "restored", "restoredTupleExact", "nativeRemainedQuiescent"] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, "\(key): \(result)")
        }
        XCTAssertEqual(try retryValue("restoreError", in: result).intValue, 0)
        for prior in 0...1 {
            for target in ["output", "input"] {
                let prefix = "prior\(prior).\(target)."
                for key in ["priorApplied", "applied", "categoryMatches", "modeMatches", "optionsMatch",
                            "exactTupleAccepted", "oppositePolicyRejected"] {
                    XCTAssertTrue(try retryValue(prefix + key, in: result).boolValue,
                                  "\(prefix + key): \(result)")
                }
                for key in ["priorError", "error"] {
                    XCTAssertEqual(try retryValue(prefix + key, in: result).intValue, 0,
                                   "\(prefix + key): \(result)")
                }
                for key in ["requestedRaw", "observedRaw"] {
                    XCTAssertEqual(try retryValue(prefix + key, in: result).intValue,
                                   target == "output" ? 1 : 0, "\(prefix + key): \(result)")
                }
                XCTAssertEqual(try retryValue(prefix + "priorRequestedRaw", in: result).intValue, prior)
                XCTAssertEqual(try retryValue(prefix + "priorObservedRaw", in: result).intValue, prior,
                               "\(prefix): \(result)")
                if target == "output" {
                    for key in ["activated", "activeTupleExact", "deactivated"] {
                        XCTAssertTrue(try retryValue(prefix + key, in: result).boolValue,
                                      "\(prefix + key): \(result)")
                    }
                    for key in ["activationError", "deactivationError"] {
                        XCTAssertEqual(try retryValue(prefix + key, in: result).intValue, 0,
                                       "\(prefix + key): \(result)")
                    }
                    for key in ["activeObservedRaw", "inactiveObservedRaw"] {
                        XCTAssertEqual(try retryValue(prefix + key, in: result).intValue, 1,
                                       "\(prefix + key): \(result)")
                    }
                    XCTAssertEqual(try retryValue(prefix + "activationCount", in: result).intValue, 1)
                    XCTAssertEqual(try retryValue(prefix + "deactivationCount", in: result).intValue, 1)
                } else {
                    XCTAssertNil(result[prefix + "activationCount"])
                    XCTAssertNil(result[prefix + "deactivationCount"])
                }
            }
        }
    }

    func testPhysicalPolicyScenarioOriginalOrder() throws {
        try checkPhysicalPolicyScenario(0)
    }

    func testPhysicalPolicyScenarioInitialIdle() throws {
        try checkPhysicalPolicyScenario(1)
    }

    func testPhysicalPolicyScenarioPostInputRead() throws {
        try checkPhysicalPolicyScenario(2)
    }

    func testPhysicalPolicyScenarioColdDuplexFirst() throws {
        try checkPhysicalPolicyScenario(3)
    }

    func testPhysicalPolicyScenarioProductionOrder() throws {
        try checkPhysicalPolicyScenario(4)
    }

    private func checkPhysicalPolicyScenario(_ scenario: UInt) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This comparison requires one selected scenario per fresh physical test-host process.")
        #else
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugProbeRealSessionPolicySetterScenarioForTesting(scenario)
        let attachment = XCTAttachment(
            data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "physical-policy-scenario-\(scenario)"
        attachment.lifetime = .keepAlways
        add(attachment)
        for key in ["scenarioIsValid", "firstScenarioInvocation", "sequenceCompleted",
                    "configurationLockAcquired", "ownershipLockAcquired", "initiallyQuiescent",
                    "initialTupleRestorable", "cleanupOutputDeactivated", "restored", "nativeRemainedQuiescent"] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, "\(key): \(result)")
        }
        XCTAssertEqual(try retryValue("inputActivationCount", in: result).intValue, 0)
        // These experiments characterize the actual result; attachment values, not test
        // success, establish whether a sequence obtained the canonical policy.
        #endif
    }

    func testPhysicalInertPolicyAfterRemoteCommandCenterShared() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.remoteCommandCenterShared)
    }

    func testPhysicalInertPolicyAfterDisabledPlayCommandTarget() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.disabledPlayCommandTarget)
    }

    func testPhysicalInertPolicyAfterNowPlayingInfoCenterDefault() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.nowPlayingInfoCenterDefault)
    }

    func testPhysicalInertPolicyAfterClearingNowPlayingInfo() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.clearingNowPlayingInfo)
    }

    func testPhysicalInertPolicyAfterStoppedPlaybackState() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.stoppedPlaybackState)
    }

    func testPhysicalInertPolicyAfterPlayCommandTargetOnly() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.playCommandTargetOnly)
    }

    func testPhysicalInertPolicyAfterDisablingPlayCommandOnly() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.disablingPlayCommandOnly)
    }

    func testPhysicalInertPolicyAfterDisabledPlayTargetRemoval() async throws {
        try await checkPhysicalInertMediaPlayerPolicy(.disabledPlayTargetRemoval)
    }

    func testPhysicalInertPolicyRestoresCapturedDefaultAfterTargetRemoval() async throws {
        try await checkPhysicalInertMediaPlayerSetterPolicy(.restoreAfterTargetRemoval)
    }

    func testPhysicalInertPolicyRegistersTargetAfterInactiveDuplexSetter() async throws {
        try await checkPhysicalInertMediaPlayerSetterPolicy(.duplexBeforeTarget)
    }

    func testPhysicalInertPolicySetsInactiveDuplexWhileTargetIsRegistered() async throws {
        try await checkPhysicalInertMediaPlayerSetterPolicy(.duplexWhileTargetRegistered)
    }

    /// Characterizes only UIApplication's legacy remote-control registration boundary.
    /// No MediaPlayer objects, responders, audio I/O, or native audio devices are touched.
    func testPhysicalInertPolicyAfterBeginReceivingRemoteControlEvents() async throws {
        executionTimeAllowance = 90
        #if !DEBUG
        throw XCTSkip("Remote-control registration characterization requires a DEBUG test host.")
        #elseif targetEnvironment(simulator)
        throw XCTSkip("This characterization requires a fresh physical inert development host.")
        #else
        var result: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": OpensteamerAppRootMode.isPhysicalUpdateValidationHost,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "applicationStateAtStartRaw": UIApplication.shared.applicationState.rawValue,
            "mediaPlayerAccessed": false, "firstResponderChanged": false,
            "audioActivationCount": 0, "captureAttempted": false,
            "nativeAudioDeviceCreated": false,
        ]
        var ownsRemoteControlRegistration = false
        var beginCount = 0
        var endCount = 0
        var restoreCount = 0
        func endOwnedRegistration() {
            guard ownsRemoteControlRegistration else { return }
            ownsRemoteControlRegistration = false
            UIApplication.shared.endReceivingRemoteControlEvents()
            endCount += 1
        }
        defer {
            endOwnedRegistration()
            result["beginReceivingCount"] = beginCount
            result["endReceivingCount"] = endCount
            result["capturedInitialRestoreCount"] = restoreCount
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-inert-begin-receiving-remote-control-events-policy"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTFail("Could not encode remote-control registration scalar evidence.")
            }
        }
        guard OpensteamerAppRootMode.isPhysicalUpdateValidationHost else {
            return XCTFail("The actual app root is not the inert physical update-validation host.")
        }
        guard Bundle.main.bundleIdentifier == "org.example.AudioStreamer.dev" else {
            return XCTFail("The experiment is restricted to the distinct spare-phone development app.")
        }
        guard !Self.physicalMediaPlayerPolicyExperimentWasInvoked else {
            return XCTFail("Select exactly one experiment per fresh test-host process.")
        }
        Self.physicalMediaPlayerPolicyExperimentWasInvoked = true
        let clock = ContinuousClock()
        let activationDeadline = clock.now.advanced(by: .seconds(2))
        while UIApplication.shared.applicationState != .active, clock.now < activationDeadline {
            try await clock.sleep(until: min(activationDeadline, clock.now.advanced(by: .milliseconds(25))))
        }
        result["applicationStateAfterActivationWaitRaw"] = UIApplication.shared.applicationState.rawValue
        guard UIApplication.shared.applicationState == .active else {
            return XCTFail("The experiment host did not become active within two seconds.")
        }
        let session = AVAudioSession.sharedInstance()
        let initialCategory = session.category
        let initialMode = session.mode
        let initialOptions = session.categoryOptions
        let initialPolicy = session.routeSharingPolicy
        func readTuple() -> [String: Any] {
            ["category": session.category.rawValue, "mode": session.mode.rawValue,
             "optionsRaw": session.categoryOptions.rawValue, "policyRaw": session.routeSharingPolicy.rawValue,
             "matchesCapturedInitial": session.category == initialCategory && session.mode == initialMode
                && session.categoryOptions == initialOptions && session.routeSharingPolicy == initialPolicy]
        }
        result["beforeAPI"] = readTuple()
        guard initialCategory == .soloAmbient, initialMode == .default,
              initialOptions.isEmpty, initialPolicy == .default else {
            return XCTFail("A supported pre-registration soloAmbient/default/options0/policy0 baseline is required; no APIs or setters ran.")
        }
        let registrationStart = clock.now
        let registrationUptime = ProcessInfo.processInfo.systemUptime
        UIApplication.shared.beginReceivingRemoteControlEvents()
        ownsRemoteControlRegistration = true
        beginCount += 1
        result["afterAPI"] = readTuple()
        result["afterAPIElapsedMilliseconds"] =
            (ProcessInfo.processInfo.systemUptime - registrationUptime) * 1_000
        do {
            for milliseconds in [100, 250, 1_000] {
                try await clock.sleep(until: registrationStart.advanced(by: .milliseconds(milliseconds)))
                result["after\(milliseconds)Milliseconds"] = readTuple()
                result["after\(milliseconds)MillisecondsActualElapsed"] =
                    (ProcessInfo.processInfo.systemUptime - registrationUptime) * 1_000
            }
        } catch {
            result["measurementWaitCancelled"] = true
            result["measurementWaitErrorCode"] = (error as NSError).code
            XCTFail("The bounded remote-control observation was interrupted: \(error)")
        }
        endOwnedRegistration()
        result["afterEndReceiving"] = readTuple()
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { result["endReceivingSettleWaitCancelled"] = true }
        result["afterEndReceiving100Milliseconds"] = readTuple()
        restoreCount += 1
        do {
            try session.setCategory(initialCategory, mode: initialMode,
                                    policy: initialPolicy, options: initialOptions)
            result["capturedInitialRestoreApplied"] = true
        } catch {
            result["capturedInitialRestoreApplied"] = false
            result["capturedInitialRestoreErrorCode"] = (error as NSError).code
            result["capturedInitialRestoreErrorDomain"] = (error as NSError).domain
            XCTFail("The single captured-baseline restoration attempt failed: \(error)")
        }
        result["afterCapturedInitialRestore"] = readTuple()
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { result["restoreReadWaitCancelled"] = true }
        result["afterCapturedInitialRestore100Milliseconds"] = readTuple()
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 1)
        XCTAssertEqual(restoreCount, 1)
        XCTAssertEqual(session.category, initialCategory)
        XCTAssertEqual(session.mode, initialMode)
        XCTAssertEqual(session.categoryOptions, initialOptions)
        XCTAssertEqual(session.routeSharingPolicy, initialPolicy)
        // API-time tuples are observations, not expectations of policy0 or proof of input.
        #endif
    }

    /// Explicit setup only: the operator approves the real system prompt on the spare dev phone.
    /// This test does not configure, activate, or capture audio, and is separate from every probe.
    func testPhysicalInertDevelopmentHostMicrophonePermissionSetup() async throws {
        executionTimeAllowance = 90
        #if !DEBUG
        throw XCTSkip("Permission setup is available only in a DEBUG test host.")
        #elseif targetEnvironment(simulator)
        throw XCTSkip("This setup requires the authorized spare physical development phone.")
        #else
        var result: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": OpensteamerAppRootMode.isPhysicalUpdateValidationHost,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "applicationStateAtStartRaw": UIApplication.shared.applicationState.rawValue,
            "permissionBeforeRaw": AVAudioApplication.shared.recordPermission.rawValue,
            "permissionRequestCount": 0,
            "audioConfigurationAttempted": false, "audioActivationAttempted": false,
            "captureAttempted": false, "mediaPlayerAccessed": false,
            "nativeAudioDeviceCreated": false,
        ]
        defer {
            result["permissionAfterRaw"] = AVAudioApplication.shared.recordPermission.rawValue
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-inert-development-microphone-permission-setup"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTFail("Could not encode permission-setup scalar evidence.")
            }
        }
        guard OpensteamerAppRootMode.isPhysicalUpdateValidationHost else {
            return XCTFail("The actual app root is not the inert physical update-validation host.")
        }
        guard Bundle.main.bundleIdentifier == "org.example.AudioStreamer.dev" else {
            return XCTFail("Permission setup is restricted to the distinct spare-phone development app.")
        }
        let activationClock = ContinuousClock()
        let activationDeadline = activationClock.now.advanced(by: .seconds(2))
        while UIApplication.shared.applicationState != .active,
              activationClock.now < activationDeadline {
            try await activationClock.sleep(until: min(
                activationDeadline, activationClock.now.advanced(by: .milliseconds(25))
            ))
        }
        result["applicationStateAfterActivationWaitRaw"] = UIApplication.shared.applicationState.rawValue
        guard UIApplication.shared.applicationState == .active else {
            return XCTFail("The permission-setup host did not become active within two seconds.")
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            result["alreadyGranted"] = true
        case .denied:
            return XCTFail("Microphone permission is denied; setup will not retry or change Settings.")
        case .undetermined:
            result["permissionRequestCount"] = 1
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            result["permissionCallbackGranted"] = granted
            XCTAssertTrue(granted, "The real system permission prompt was not approved.")
        @unknown default:
            return XCTFail("Unknown microphone permission state; no permission request was made.")
        }
        XCTAssertEqual(AVAudioApplication.shared.recordPermission, .granted,
                       "Permission setup alone must leave the spare development app granted.")
        #endif
    }

    func testPhysicalInertInputTapCharacterizesRegisteredMediaCommandPolicy() async throws {
        executionTimeAllowance = 90
        #if targetEnvironment(simulator)
        throw XCTSkip("This bounded microphone characterization requires a fresh physical inert development host.")
        #else
        var result: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": OpensteamerAppRootMode.isPhysicalUpdateValidationHost,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "applicationStateAtStartRaw": UIApplication.shared.applicationState.rawValue,
            "permissionWasAlreadyGranted": false,
            "productionAdmissionWasExercised": false, "storedPCMBufferCount": 0,
            "nativeScenario4Invoked": false, "captureWithPolicyOneProved": false,
        ]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-inert-input-tap-registered-media-command-policy"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTFail("Could not encode input-tap scalar evidence.")
            }
        }
        guard OpensteamerAppRootMode.isPhysicalUpdateValidationHost else {
            return XCTFail("The actual app root is not the inert physical update-validation host.")
        }
        guard Bundle.main.bundleIdentifier == "org.example.AudioStreamer.dev" else {
            return XCTFail("The test host is not the distinct development app: \(Bundle.main.bundleIdentifier ?? "<missing>").")
        }
        // Hosted XCTest may enter just before the real scene becomes active. Yield only
        // for that startup boundary; do not activate audio or manufacture scene activation.
        let activationClock = ContinuousClock()
        let activationDeadline = activationClock.now.advanced(by: .seconds(2))
        let activationWaitStart = ProcessInfo.processInfo.systemUptime
        while UIApplication.shared.applicationState != .active,
              activationClock.now < activationDeadline {
            try await activationClock.sleep(until: min(
                activationDeadline, activationClock.now.advanced(by: .milliseconds(25))
            ))
        }
        result["activationWaitMilliseconds"] =
            (ProcessInfo.processInfo.systemUptime - activationWaitStart) * 1_000
        result["applicationStateAfterActivationWaitRaw"] = UIApplication.shared.applicationState.rawValue
        guard UIApplication.shared.applicationState == .active else {
            return XCTFail("The test host scene did not become active within the two-second startup wait; state=\(UIApplication.shared.applicationState.rawValue).")
        }
        guard !Self.physicalMediaPlayerPolicyExperimentWasInvoked else {
            return XCTFail("Select exactly one experiment per fresh test-host process.")
        }
        Self.physicalMediaPlayerPolicyExperimentWasInvoked = true
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return XCTFail("Microphone permission must already be granted; this test never requests it.")
        }
        result["permissionWasAlreadyGranted"] = true
        let calls = CXCallObserver()
        guard calls.calls.allSatisfy(\.hasEnded) else {
            return XCTFail("A nonended system call forbids this standalone input probe.")
        }
        let session = AVAudioSession.sharedInstance()
        let initialCategory = session.category
        let initialMode = session.mode
        let initialOptions = session.categoryOptions
        let initialPolicy = session.routeSharingPolicy
        let duplexOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        func readTuple() -> [String: Any] {
            ["category": session.category.rawValue, "mode": session.mode.rawValue,
             "optionsRaw": session.categoryOptions.rawValue, "policyRaw": session.routeSharingPolicy.rawValue,
             "inputChannels": session.inputNumberOfChannels, "sampleRate": session.sampleRate,
             "builtInInput": session.currentRoute.inputs.contains { $0.portType == .builtInMic }]
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PhysicalInputTapProbeError.requirement(message) }
        }
        result["beforeMediaPlayer"] = readTuple()
        guard initialCategory == .soloAmbient, initialMode == .default,
              initialOptions.isEmpty, initialPolicy == .default else {
            return XCTFail("The captured pre-MediaPlayer tuple must be soloAmbient/default/options0/policy0.")
        }

        let quiescence = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = quiescence.debugTerminateForTesting() }
        guard quiescence.debugRealSessionIsQuiescentForTesting() else {
            return XCTFail("A native audio owner or configuration operation is present.")
        }
        var engine: AVAudioEngine?
        var input: AVAudioInputNode?
        var tapWasInstalled = false
        var journal: PhysicalInputTapJournal?
        var callFence: PhysicalInputTapCallFence?
        var interruptionObserver: NSObjectProtocol?
        var installedTarget: (command: MPRemoteCommand, target: Any)?
        var activationAttemptCount = 0
        var activationSuccessCount = 0
        var deactivationAttemptCount = 0
        var targetRemovalCount = 0
        var phase = "register target"
        do {
            let play = MPRemoteCommandCenter.shared().playCommand
            let target = play.addTarget { @Sendable _ in .commandFailed }
            installedTarget = (play, target)
            result["afterRegistration"] = readTuple()
            try await Task.sleep(for: .milliseconds(100))
            result["afterRegistration100Milliseconds"] = readTuple()
            phase = "set inactive canonical duplex"
            try session.setCategory(.playAndRecord, mode: .default,
                                    policy: .default, options: duplexOptions)
            result["afterDuplexSetter"] = readTuple()
            try require(UIApplication.shared.applicationState == .active, "App became inactive before activation.")
            try require(calls.calls.allSatisfy(\.hasEnded), "Call state changed before activation.")
            try require(quiescence.debugRealSessionIsQuiescentForTesting(), "Native ownership changed before activation.")
            phase = "activate once"
            result["beforeActivation"] = readTuple()
            activationAttemptCount += 1
            try session.setActive(true)
            activationSuccessCount += 1
            result["afterActivation"] = readTuple()
            try require(calls.calls.allSatisfy(\.hasEnded), "Call state changed during activation.")
            try require(session.currentRoute.inputs.contains { $0.portType == .builtInMic }, "The selected route is not built-in input; do not force a route.")

            phase = "construct sole engine and verify raw input"
            let ownedEngine = AVAudioEngine()
            engine = ownedEngine
            let ownedInput = ownedEngine.inputNode
            input = ownedInput
            func recordRawInput(_ label: String) throws {
                result[label + "VoiceProcessingEnabled"] = ownedInput.isVoiceProcessingEnabled
                try require(!ownedInput.isVoiceProcessingEnabled, "Voice processing was enabled.")
                let unit = try XCTUnwrap(ownedInput.audioUnit, "Input node has no AudioUnit.")
                let component = try XCTUnwrap(AudioComponentInstanceGetComponent(unit))
                var description = AudioComponentDescription()
                let status = AudioComponentGetDescription(component, &description)
                result[label + "ComponentStatus"] = status
                result[label + "ComponentType"] = description.componentType
                result[label + "ComponentSubType"] = description.componentSubType
                try require(status == noErr && description.componentType == kAudioUnitType_Output
                    && description.componentSubType == kAudioUnitSubType_RemoteIO, "The engine input is not raw RemoteIO.")
            }
            try recordRawInput("beforeStart")
            let format = ownedInput.outputFormat(forBus: 0)
            result["tapFormatSampleRate"] = format.sampleRate
            result["tapFormatChannels"] = format.channelCount
            result["tapFormatInterleaved"] = format.isInterleaved
            try require(format.sampleRate.isFinite && format.sampleRate > 0
                && format.channelCount > 0 && format.channelCount <= 8
                && format.commonFormat == .pcmFormatFloat32, "The actual input-node format is unavailable or unsupported by this scalar probe.")
            let measurements = PhysicalInputTapJournal(sampleRate: format.sampleRate, channels: format.channelCount)
            journal = measurements
            let fence = PhysicalInputTapCallFence(journal: measurements)
            callFence = fence
            calls.setDelegate(fence, queue: .main)
            try require(calls.calls.allSatisfy(\.hasEnded), "Call state changed before tap installation.")
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: nil
            ) { @Sendable notification in
                if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   raw == AVAudioSession.InterruptionType.began.rawValue {
                    measurements.closeForPrivacyBoundary()
                }
            }
            ownedInput.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, time in
                measurements.observe(buffer, when: time)
            }
            tapWasInstalled = true
            phase = "start engine once"
            ownedEngine.prepare()
            try ownedEngine.start()
            try recordRawInput("afterStart")
            result["afterStart"] = readTuple()
            var policyOneAtCaptureBoundaries = session.routeSharingPolicy == .longFormAudio
            var previous = measurements.snapshot
            result["windowBaseline"] = previous.scalars
            var bothWindowsAdvanced = true
            for window in 1...2 {
                phase = "capture window \(window)"
                try await Task.sleep(for: .milliseconds(500))
                let current = measurements.snapshot
                result["window\(window)"] = current.scalars
                result["afterWindow\(window)"] = readTuple()
                let advanced = current.advanced(since: previous)
                result["window\(window)Advanced"] = advanced
                bothWindowsAdvanced = bothWindowsAdvanced && advanced
                policyOneAtCaptureBoundaries = policyOneAtCaptureBoundaries && session.routeSharingPolicy == .longFormAudio
                try require(calls.calls.allSatisfy(\.hasEnded) && !current.privacyBoundaryObserved,
                            "Call or interruption invalidated this capture window.")
                try require(ownedEngine.isRunning && !ownedInput.isVoiceProcessingEnabled
                    && session.currentRoute.inputs.contains { $0.portType == .builtInMic }
                    && session.category == .playAndRecord && session.mode == .default
                    && session.categoryOptions == duplexOptions,
                    "The engine, built-in input route, or requested category tuple changed during capture.")
                previous = current
            }
            result["policyOneAtCaptureBoundaries"] = policyOneAtCaptureBoundaries
            result["bothCaptureWindowsAdvanced"] = bothWindowsAdvanced
            result["captureWithPolicyOneProved"] = policyOneAtCaptureBoundaries && bothWindowsAdvanced
            XCTAssertTrue(policyOneAtCaptureBoundaries, "Engine startup or capture changed the observed policy; do not claim capture under policy1.")
            XCTAssertTrue(bothWindowsAdvanced, "Both independent 500 ms windows require real, finite, nonzero input and advancing sample times.")
        } catch {
            result["failurePhase"] = phase
            result["failureErrorCode"] = (error as NSError).code
            result["failureErrorDomain"] = (error as NSError).domain
            XCTFail("Standalone input characterization failed during \(phase): \(error)")
        }

        journal?.closeForPrivacyBoundary()
        engine?.stop()
        if tapWasInstalled { input?.removeTap(onBus: 0) }
        engine?.reset()
        result["engineStopped"] = engine?.isRunning != true
        result["tapRemoved"] = !tapWasInstalled || input != nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        calls.setDelegate(nil, queue: nil)
        withExtendedLifetime(callFence) {}
        input = nil
        engine = nil
        if activationSuccessCount == 1 {
            deactivationAttemptCount += 1
            do {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                result["deactivationSucceeded"] = true
            } catch {
                result["deactivationSucceeded"] = false
                result["deactivationErrorCode"] = (error as NSError).code
                XCTFail("The single activation-release attempt failed: \(error)")
            }
        }
        if let installedTarget {
            installedTarget.command.removeTarget(installedTarget.target)
            targetRemovalCount += 1
        }
        result["afterTargetRemoval"] = readTuple()
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { result["targetRemovalWaitCancelled"] = true }
        result["afterTargetRemovalWait"] = readTuple()
        result["capturedInitialRestoreAttemptCount"] = 1
        do {
            try session.setCategory(initialCategory, mode: initialMode,
                                    policy: initialPolicy, options: initialOptions)
            result["capturedInitialRestoreSucceeded"] = true
        } catch {
            result["capturedInitialRestoreSucceeded"] = false
            result["capturedInitialRestoreErrorCode"] = (error as NSError).code
            XCTFail("The single captured-baseline restoration attempt failed: \(error)")
        }
        result["afterCapturedInitialRestore"] = readTuple()
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { result["restoreReadWaitCancelled"] = true }
        result["afterCapturedInitialRestoreWait"] = readTuple()
        result["activationAttemptCount"] = activationAttemptCount
        result["activationSuccessCount"] = activationSuccessCount
        result["deactivationAttemptCount"] = deactivationAttemptCount
        result["targetRemovalCount"] = targetRemovalCount
        XCTAssertEqual(deactivationAttemptCount, activationSuccessCount)
        XCTAssertEqual(targetRemovalCount, 1)
        XCTAssertEqual(session.category, initialCategory)
        XCTAssertEqual(session.mode, initialMode)
        XCTAssertEqual(session.categoryOptions, initialOptions)
        XCTAssertEqual(session.routeSharingPolicy, initialPolicy)
        #endif
    }

    private enum PhysicalMediaPlayerSetterOperation: String {
        case restoreAfterTargetRemoval
        case duplexBeforeTarget
        case duplexWhileTargetRegistered
    }

    /// These inactive-only experiments restore the supported tuple captured before registration,
    /// never the potentially unsupported tuple that MediaPlayer later reports. No ADM is created.
    private func checkPhysicalInertMediaPlayerSetterPolicy(
        _ operation: PhysicalMediaPlayerSetterOperation
    ) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Inactive MediaPlayer setter characterization requires a fresh physical inert test host.")
        #else
        guard OpensteamerAppRootMode.isPhysicalUpdateValidationHost else {
            return XCTFail("Run only with OPENSTEAMER_UPDATE_VALIDATION_HOST.")
        }
        guard !Self.physicalMediaPlayerPolicyExperimentWasInvoked else {
            return XCTFail("Select exactly one MediaPlayer experiment per fresh test-host process.")
        }
        Self.physicalMediaPlayerPolicyExperimentWasInvoked = true
        let session = AVAudioSession.sharedInstance()
        let initialCategory = session.category
        let initialMode = session.mode
        let initialOptions = session.categoryOptions
        let initialPolicy = session.routeSharingPolicy
        let duplexOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        func readTuple() -> [String: Any] {
            [
                "category": session.category.rawValue,
                "mode": session.mode.rawValue,
                "optionsRaw": session.categoryOptions.rawValue,
                "policyRaw": session.routeSharingPolicy.rawValue,
                "matchesCapturedInitial": session.category == initialCategory && session.mode == initialMode
                    && session.categoryOptions == initialOptions && session.routeSharingPolicy == initialPolicy,
                "matchesCanonicalDuplex": session.category == .playAndRecord && session.mode == .default
                    && session.categoryOptions == duplexOptions && session.routeSharingPolicy == .default,
            ]
        }
        var result: [String: Any] = [
            "operation": operation.rawValue,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": true,
            "firstExperimentInvocation": true,
            "inputActivationCount": 0,
            "outputActivationCount": 0,
            "nativeScenario4Invoked": false,
            "beforeAPI": readTuple(),
        ]
        var installedTarget: (command: MPRemoteCommand, target: Any)?
        var targetRegistrationCount = 0
        var targetRemovalCount = 0
        var duplexSetterCount = 0
        var capturedInitialRestoreCount = 0
        func removeExactTarget() {
            guard let owned = installedTarget else { return }
            installedTarget = nil
            owned.command.removeTarget(owned.target)
            targetRemovalCount += 1
        }
        func applyDuplex(prefix: String) {
            duplexSetterCount += 1
            do {
                try session.setCategory(.playAndRecord, mode: .default,
                                        policy: .default, options: duplexOptions)
                result[prefix + "Applied"] = true
                result[prefix + "ErrorCode"] = 0
            } catch {
                result[prefix + "Applied"] = false
                result[prefix + "ErrorCode"] = (error as NSError).code
                result[prefix + "ErrorDomain"] = (error as NSError).domain
            }
            result[prefix + "Immediate"] = readTuple()
        }
        defer {
            removeExactTarget()
            result["targetRegistrationCount"] = targetRegistrationCount
            result["targetRemovalCount"] = targetRemovalCount
            result["duplexSetterCount"] = duplexSetterCount
            result["capturedInitialRestoreCount"] = capturedInitialRestoreCount
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-inert-mediaplayer-setter-\(operation.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTFail("Could not encode inactive setter characterization evidence.")
            }
        }
        guard initialCategory == .soloAmbient, initialMode == .default,
              initialOptions.isEmpty, initialPolicy == .default else {
            result["skipReason"] = "Required pre-registration soloAmbient/default/options0/policy0 baseline was absent; no APIs or setters ran."
            return
        }
        do {
            if operation == .duplexBeforeTarget {
                applyDuplex(prefix: "duplexBeforeTarget")
            }
            let play = MPRemoteCommandCenter.shared().playCommand
            let target = play.addTarget { @Sendable _ in .commandFailed }
            installedTarget = (play, target)
            targetRegistrationCount += 1
            result["afterRegistration"] = readTuple()
            try await Task.sleep(for: .milliseconds(100))
            result["afterRegistration100Milliseconds"] = readTuple()
            if operation == .duplexWhileTargetRegistered {
                result["targetRegisteredDuringDuplexSetter"] = installedTarget != nil
                applyDuplex(prefix: "duplexWhileTargetRegistered")
                try await Task.sleep(for: .milliseconds(100))
                result["duplexWhileTargetRegistered100Milliseconds"] = readTuple()
            }
            removeExactTarget()
            result["afterRemoval"] = readTuple()
            if operation == .restoreAfterTargetRemoval {
                try await Task.sleep(for: .milliseconds(100))
                result["afterRemoval100Milliseconds"] = readTuple()
            }
        } catch {
            result["measurementWaitCancelled"] = true
            result["measurementWaitErrorCode"] = (error as NSError).code
        }
        removeExactTarget()
        // This is A's sole measured restoration and B/C's sole final restoration, even if
        // an earlier setter failed. A failed restoration is recorded, never retried.
        capturedInitialRestoreCount += 1
        do {
            try session.setCategory(initialCategory, mode: initialMode,
                                    policy: initialPolicy, options: initialOptions)
            result["capturedInitialRestoreApplied"] = true
            result["capturedInitialRestoreErrorCode"] = 0
        } catch {
            result["capturedInitialRestoreApplied"] = false
            result["capturedInitialRestoreErrorCode"] = (error as NSError).code
            result["capturedInitialRestoreErrorDomain"] = (error as NSError).domain
        }
        result["afterCapturedInitialRestore"] = readTuple()
        do {
            try await Task.sleep(for: .milliseconds(100))
            result["afterCapturedInitialRestore100Milliseconds"] = readTuple()
        } catch {
            result["restoreReadWaitCancelled"] = true
            result["afterCancelledRestoreReadWait"] = readTuple()
        }
        XCTAssertEqual(targetRegistrationCount, 1)
        XCTAssertEqual(targetRemovalCount, 1)
        XCTAssertEqual(capturedInitialRestoreCount, 1)
        XCTAssertEqual(duplexSetterCount, operation == .restoreAfterTargetRemoval ? 0 : 1)
        // Test completion proves only the bounded experiment ran. Setter errors and tuple
        // readbacks in the attachment determine the result; no microphone capture was attempted.
        #endif
    }

    private enum PhysicalMediaPlayerPolicyOperation: String {
        case remoteCommandCenterShared
        case disabledPlayCommandTarget
        case nowPlayingInfoCenterDefault
        case clearingNowPlayingInfo
        case stoppedPlaybackState
        case playCommandTargetOnly
        case disablingPlayCommandOnly
        case disabledPlayTargetRemoval
    }

    private static var physicalMediaPlayerPolicyExperimentWasInvoked = false

    /// One selected API in an otherwise inert, fresh physical process. A contaminated tuple is
    /// evidence, not permission to try setters that cannot restore the original session state.
    private func checkPhysicalInertMediaPlayerPolicy(
        _ operation: PhysicalMediaPlayerPolicyOperation
    ) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("MediaPlayer policy characterization requires a fresh physical inert test host.")
        #else
        guard OpensteamerAppRootMode.isPhysicalUpdateValidationHost else {
            return XCTFail("Run only with OPENSTEAMER_UPDATE_VALIDATION_HOST; production startup contaminates this experiment.")
        }
        guard !Self.physicalMediaPlayerPolicyExperimentWasInvoked else {
            return XCTFail("Select exactly one MediaPlayer experiment per fresh test-host process.")
        }
        Self.physicalMediaPlayerPolicyExperimentWasInvoked = true
        let session = AVAudioSession.sharedInstance()
        func readTuple() -> [String: Any] {
            [
                "category": session.category.rawValue,
                "mode": session.mode.rawValue,
                "optionsRaw": session.categoryOptions.rawValue,
                "policyRaw": session.routeSharingPolicy.rawValue,
            ]
        }
        func tupleAllowsSafeNativeScenario() -> Bool {
            let categories: [AVAudioSession.Category] = [.soloAmbient, .ambient, .playback]
            return categories.contains(session.category)
                && session.mode == .default
                && session.categoryOptions.isEmpty
                && session.routeSharingPolicy == .default
        }
        var result: [String: Any] = [
            "operation": operation.rawValue,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": true,
            "firstExperimentInvocation": true,
            "apiExecuted": false,
            "nativeScenario4Invoked": false,
            "inputActivationCount": 0,
            "beforeAPI": readTuple(),
        ]
        var removeInstalledTarget: (() -> Void)?
        defer {
            removeInstalledTarget?()
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-inert-mediaplayer-policy-\(operation.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else {
                XCTFail("Could not encode MediaPlayer policy characterization evidence.")
            }
        }
        guard tupleAllowsSafeNativeScenario() else {
            result["skipReason"] = "Initial tuple is not a known restorable default-policy tuple; neither the selected API nor native setters ran."
            return
        }

        switch operation {
        case .remoteCommandCenterShared:
            _ = MPRemoteCommandCenter.shared()
        case .disabledPlayCommandTarget, .playCommandTargetOnly, .disabledPlayTargetRemoval:
            let play = MPRemoteCommandCenter.shared().playCommand
            let target = play.addTarget { @Sendable _ in .commandFailed }
            removeInstalledTarget = { play.removeTarget(target) }
            if operation != .playCommandTargetOnly { play.isEnabled = false }
        case .disablingPlayCommandOnly:
            MPRemoteCommandCenter.shared().playCommand.isEnabled = false
        case .nowPlayingInfoCenterDefault:
            _ = MPNowPlayingInfoCenter.default()
        case .clearingNowPlayingInfo:
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        case .stoppedPlaybackState:
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        result["apiExecuted"] = true
        result["afterAPI"] = readTuple()
        try await Task.sleep(for: .milliseconds(100))
        result["after100Milliseconds"] = readTuple()
        if operation == .disabledPlayTargetRemoval {
            XCTAssertNotNil(removeInstalledTarget)
            removeInstalledTarget?()
            removeInstalledTarget = nil
            result["exactTargetRemovedBeforeNativeScenario"] = true
            result["afterRemoval"] = readTuple()
            try await Task.sleep(for: .milliseconds(100))
            result["afterRemoval100Milliseconds"] = readTuple()
        }
        guard tupleAllowsSafeNativeScenario() else {
            result["skipReason"] = "The selected API left a nonrestorable or nondefault tuple; no native scenario or restoration setters ran."
            return
        }

        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        result["nativeScenario4Invoked"] = true
        let native = harness.debugProbeRealSessionPolicySetterScenarioForTesting(4)
        result["nativeScenario4"] = native
        if try retryValue("initialTupleRejectedBeforeMutation", in: native).boolValue {
            XCTAssertFalse(try retryValue("restoreAttempted", in: native).boolValue)
            result["skipReason"] = "The tuple changed before native entry; the native guard rejected it without mutation or restoration."
            return
        }
        for key in ["scenarioIsValid", "firstScenarioInvocation", "sequenceCompleted",
                    "configurationLockAcquired", "ownershipLockAcquired", "initiallyQuiescent",
                    "initialTupleRestorable", "cleanupOutputDeactivated", "restored",
                    "restoredTupleExact", "nativeRemainedQuiescent"] {
            XCTAssertTrue(try retryValue(key, in: native).boolValue, "\(key): \(native)")
        }
        XCTAssertEqual(try retryValue("inputActivationCount", in: native).intValue, 0)
        XCTAssertTrue(try retryValue("restoreAttempted", in: native).boolValue)
        XCTAssertEqual(try retryValue("restoreError", in: native).intValue, 0)
        // Success only means this selected experiment completed safely. The attachment's
        // inputImmediate tuple reports the setter outcome; this is never microphone proof.
        #endif
    }

    func testNativeFailureContextRetainsRouteFactsBeforeInnerRollback() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugRetainedFailureContextForTesting()
        for key in [
            "initiallyAbsent", "innerFailure", "routeChangedDuringInnerCleanup",
            "innerSessionAvailable", "innerSessionActive", "innerOwnsActivation",
            "innerInputRequired", "innerHasOutputRoute", "innerCategoryRecord",
            "innerDefaultMode", "innerMicrophoneOptions", "originalIdentityPreserved",
            "liveRolledBack", "healthyStateIsSeparate",
        ] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, "\(key): \(result)")
        }
        XCTAssertEqual(try retryValue("activationCount", in: result).intValue, 1)
        XCTAssertEqual(try retryValue("deactivationCount", in: result).intValue, 1)
        XCTAssertEqual(try retryValue("innerStage", in: result).intValue, 3)
        XCTAssertEqual(try retryValue("innerReason", in: result).intValue, 2)
        XCTAssertEqual(try retryValue("innerCode", in: result).intValue, 4)
        XCTAssertEqual(try retryValue("innerStatus", in: result).intValue, Int(kAudio_ParamError))
        XCTAssertEqual(try retryValue("innerRate", in: result).doubleValue, 44100)
        XCTAssertEqual(try retryValue("innerDuration", in: result).doubleValue, 0.02)
        XCTAssertEqual(try retryValue("innerInputChannels", in: result).intValue, 0)
        XCTAssertEqual(try retryValue("innerOutputChannels", in: result).intValue, 1)
    }

    func testNativeFailureContextSeparatesInitStartAndRejectsOlderEvents() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugRetainedFailureContextForTesting()
        XCTAssertEqual(try retryValue("initializationStage", in: result).intValue, 7)
        XCTAssertEqual(try retryValue("initializationStatus", in: result).intValue, -10868)
        XCTAssertEqual(try retryValue("initializationRate", in: result).doubleValue, 48000)
        XCTAssertTrue(try retryValue("initializationActive", in: result).boolValue)
        XCTAssertEqual(try retryValue("startStage", in: result).intValue, 10)
        XCTAssertEqual(try retryValue("startStatus", in: result).intValue, -66635)
        for key in ["monotonicEvents", "staleRecordRejected", "laterHealthyRetainsLastFailure"] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, "\(key): \(result)")
        }
    }

    func testOptionalNativeDiagnosticsRejectsContentionWithoutPartialSnapshot() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugBoundedDiagnosticsReadForTesting()
        for key in [
            "ownershipUnavailable", "ownershipOutputUntouched",
            "failureUnavailable", "failureOutputUntouched",
            "publicationUnavailable", "publicationOutputUntouched",
            "generationUnavailable", "generationOutputUntouched",
            "healthyReadAccepted", "healthyPlaying", "healthySessionActive",
        ] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, key)
        }
        XCTAssertEqual(try retryValue("boundedAttempts", in: result).intValue, 8)
        XCTAssertEqual(try retryValue("healthyAttempts", in: result).intValue, 1)
        XCTAssertEqual(try retryValue("healthyCallbackCount", in: result).uint64Value, 0)
    }

    func testExactRecoveryRevokedWhileQueuedNeverInvokesVendorHook() throws {
        let result = try assertExactRetryFailure(.revokedWhileQueued)
        XCTAssertEqual(try retryValue("delegateRetryCount", in: result).intValue, 0)
        XCTAssertEqual(try retryValue("configurationDelta", in: result).intValue, 0)
    }

    func testExactRecoveryRetiredTagWhileQueuedNeverInvokesVendorHook() throws {
        let result = try assertExactRetryFailure(.retiredTagWhileQueued)
        XCTAssertEqual(try retryValue("delegateRetryCount", in: result).intValue, 0)
        XCTAssertEqual(try retryValue("configurationDelta", in: result).intValue, 0)
    }

    private func assertExactRetryFailure(
        _ scenario: WebRTCIOSPlayoutRetryFailureTestScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: NSNumber] {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugPlayoutRetryFailureForTesting(scenario)
        for key in [
            "initialInitializeFailed", "staged", "queued", "boundaryApplied",
            "ranRecovery", "exactTerminal", "exactDrain", "nextOperationCanStage",
            "nextOperationRetired",
        ] {
            XCTAssertTrue(try retryValue(key, in: result).boolValue, "\(key): \(result)", file: file, line: line)
        }
        XCTAssertEqual(
            try retryValue("revoked", in: result).boolValue,
            scenario == .revokedWhileQueued,
            "\(result)", file: file, line: line
        )
        XCTAssertEqual(
            try retryValue("rejected", in: result).boolValue,
            scenario != .revokedWhileQueued,
            "\(result)", file: file, line: line
        )
        for key in ["policyMatches", "playing", "sessionActive", "ownsSessionActivation", "inputBusEnabled"] {
            XCTAssertFalse(try retryValue(key, in: result).boolValue, "\(key): \(result)", file: file, line: line)
        }
        return result
    }

    private func retryValue(_ key: String, in result: [String: NSNumber]) throws -> NSNumber {
        try XCTUnwrap(result[key], "Missing native result: \(key)")
    }

    func testRecoveryAuthorizationPublishesExactTerminalOutcomeAndGeneration() {
        let accepted = WebRTCIOSPlayoutRecoveryAuthorization()
        let rejected = WebRTCIOSPlayoutRecoveryAuthorization()
        let revoked = WebRTCIOSPlayoutRecoveryAuthorization()

        XCTAssertNotEqual(accepted.generation, 0)
        XCTAssertNotEqual(accepted.generation, rejected.generation)
        XCTAssertEqual(accepted.terminalGeneration, 0)
        XCTAssertEqual(accepted.terminalOutcome, .pending)

        XCTAssertTrue(accepted.performIfValidForTesting {})
        XCTAssertEqual(accepted.terminalGeneration, accepted.generation)
        XCTAssertEqual(accepted.terminalOutcome, .accepted)
        XCTAssertTrue(accepted.hasAcceptedTerminalOutcome)

        XCTAssertFalse(rejected.rejectIfValidForTesting())
        XCTAssertEqual(rejected.terminalGeneration, rejected.generation)
        XCTAssertEqual(rejected.terminalOutcome, .rejected)
        XCTAssertFalse(rejected.hasAcceptedTerminalOutcome)

        revoked.revoke()
        XCTAssertEqual(revoked.terminalGeneration, revoked.generation)
        XCTAssertEqual(revoked.terminalOutcome, .revoked)
        XCTAssertFalse(revoked.hasAcceptedTerminalOutcome)
        revoked.revoke()
        XCTAssertEqual(revoked.terminalOutcome, .revoked)
    }

    func testRecoveryAuthorizationRejectsSideEffectsAfterRevocation() {
        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        let counter = LockedInteger()

        authorization.revoke()

        XCTAssertFalse(
            authorization.performIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 0)
        XCTAssertFalse(authorization.isValid)
    }

    func testMicrophoneAuthorizationRejectsSideEffectsAfterRevocation() {
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let counter = LockedInteger()

        authorization.revoke()

        XCTAssertFalse(
            authorization.performIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 0)
    }

    func testExactNativeAudioPolicyEffectsRejectMissingTransactionTag() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugExactAudioPolicyEffectsRejectMissingTagForTesting()
        )
    }

    func testInitializedMicrophoneCloseFailsClosedWithoutDelegate() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugInitializedMicrophoneCloseFailsClosedWithoutDelegateForTesting()
        )
    }

    func testMicrophoneRealtimeGateRevocationDrainsExactAdmission() {
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let revokeFinished = DispatchSemaphore(value: 0)

        XCTAssertTrue(authorization.debugBeginRealtimeAdmissionForTesting())
        DispatchQueue.global(qos: .userInitiated).async {
            authorization.revoke()
            revokeFinished.signal()
        }

        authorization.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(revokeFinished.wait(timeout: .now()), .timedOut)

        authorization.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
    }

    func testMicrophoneRealtimeGateRejectsAdmissionAfterRevokeReturns() {
        let authorization = WebRTCIOSMicrophoneAuthorization()

        authorization.revoke()

        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.debugBeginRealtimeAdmissionForTesting())
    }

    func testDeviceRealtimeGateClosureDrainsExactAdmissionBeforeReset() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let closeFinished = DispatchSemaphore(value: 0)
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            harness.debugCloseAndFenceRealtimeGateForTesting()
            closeFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(closeFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(authorization.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testInvalidMicrophoneAuthorizationCannotOpenDeviceGate() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        authorization.revoke()
        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)

        XCTAssertFalse(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testReplacingAuthorizationPreservesExactAdmittedGateIdentity() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let first = WebRTCIOSMicrophoneAuthorization()
        let second = WebRTCIOSMicrophoneAuthorization()
        let replacementFinished = DispatchSemaphore(value: 0)
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugInstallMicrophoneAuthorizationForTesting(first)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            harness.debugInstallMicrophoneAuthorizationForTesting(second)
            replacementFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(replacementFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(first.isValid)
        XCTAssertTrue(second.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(replacementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(first.isValid)
        XCTAssertTrue(second.isValid)

        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()
    }

    func testTerminalDebugTeardownFencesAdmissionThenRevokesAuthorization() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        let terminateFinished = DispatchSemaphore(value: 0)

        harness.debugInstallMicrophoneAuthorizationForTesting(authorization)
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())

        DispatchQueue.global(qos: .userInitiated).async {
            _ = harness.debugTerminateForTesting()
            terminateFinished.signal()
        }

        harness.waitForRealtimeGateClosureForTesting()
        XCTAssertEqual(terminateFinished.wait(timeout: .now()), .timedOut)
        XCTAssertTrue(authorization.isValid)

        harness.debugEndRealtimeAdmissionForTesting()
        XCTAssertEqual(terminateFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertTrue(harness.debugTerminateForTesting())
    }

    func testDevicePublicationStartsClosedAndOpensOnlyCurrentAuthorization() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let first = WebRTCIOSMicrophoneAuthorization()
        let second = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        harness.debugInstallMicrophoneAuthorizationForTesting(first)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()

        harness.debugInstallMicrophoneAuthorizationForTesting(second)
        XCTAssertFalse(first.isValid)
        XCTAssertTrue(second.isValid)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        XCTAssertTrue(harness.debugPublishCurrentMicrophoneAuthorizationForTesting())
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()
    }

    func testMicrophoneStageKeepsPCMClosedUntilExactOneShotGenerationApproval() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(true)
        let before = harness.diagnostics
        XCTAssertFalse(before.inputBusEnabled)
        XCTAssertFalse(before.captureRouteIsBuiltInMicrophone)
        XCTAssertTrue(before.outputBusEnabled)
        XCTAssertTrue(before.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(before.microphoneAuthorizationGatePublished)

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )

        let staged = harness.diagnostics
        let generation = authorization.recordingGeneration
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(staged.microphoneRecordingGeneration, generation)
        XCTAssertEqual(staged.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(staged.inputBusEnabled)
        XCTAssertTrue(staged.outputBusEnabled)
        XCTAssertTrue(staged.categoryIsMediaPlayAndRecord)
        XCTAssertTrue(staged.modeIsDefault)
        XCTAssertEqual(
            harness.lastConfiguredCategory,
            AVAudioSession.Category.playAndRecord.rawValue
        )
        XCTAssertEqual(
            AVAudioSession.CategoryOptions(
                rawValue: harness.lastConfiguredCategoryOptions
            ),
            [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        XCTAssertFalse(staged.categoryOptionsAreEmpty)
        XCTAssertTrue(staged.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(staged.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(staged.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(staged.microphoneAuthorizationGatePublished)
        XCTAssertEqual(
            staged.microphoneRealtimeAdmissionCount,
            before.microphoneRealtimeAdmissionCount
        )
        XCTAssertEqual(
            staged.microphoneDeliveryCallbackCount,
            before.microphoneDeliveryCallbackCount
        )
        XCTAssertEqual(
            staged.microphoneDeliveredFrameCount,
            before.microphoneDeliveredFrameCount
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())

        XCTAssertTrue(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )

        let approved = harness.diagnostics
        XCTAssertEqual(approved.microphoneRecordingGeneration, generation)
        XCTAssertEqual(
            approved.approvedMicrophoneRecordingGeneration,
            generation
        )
        XCTAssertFalse(approved.microphoneDeviceGateClosedAndDrained)
        XCTAssertTrue(approved.microphoneAuthorizationGatePublished)
        XCTAssertTrue(
            approved.captureRouteIsBuiltInMicrophone,
            "An approved generation may publish only the privacy-minimal live built-in-mic route proof."
        )
        XCTAssertTrue(harness.debugBeginRealtimeAdmissionForTesting())
        harness.debugEndRealtimeAdmissionForTesting()

        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(false)
        XCTAssertFalse(
            harness.diagnostics.captureRouteIsBuiltInMicrophone,
            "A live capture-route mutation must clear the proof without exposing a port identity."
        )
        harness.debugSetCaptureRouteBuiltInMicrophoneForTesting(true)
        XCTAssertFalse(
            harness.diagnostics.captureRouteIsBuiltInMicrophone,
            "Returning to the built-in route cannot revive a retired proof without fresh exact publication."
        )

        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting(),
            "A generation approval must be consumed exactly once."
        )

        let duplicate = harness.diagnostics
        XCTAssertEqual(duplicate.microphoneRecordingGeneration, generation)
        XCTAssertEqual(duplicate.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(duplicate.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(duplicate.microphoneAuthorizationGatePublished)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testInactiveA2DPRouteCannotIssueChannelPreferenceRequests() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: false,
                maximumInputChannels: 0,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(harness.lastChannelPreferenceOperations, [])
    }

    func testActiveDuplexRouteAppliesStereoThenMonoPreferences() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: true,
                maximumInputChannels: 1,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(
            harness.lastChannelPreferenceOperations,
            ["output=2", "input=1"]
        )
    }

    func testActiveOutputOnlyRouteRejectsMicrophoneBeforeAnyPreferenceRequest() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness.debugApplyActiveChannelPreferencesForTesting(
                sessionActive: true,
                maximumInputChannels: 0,
                maximumOutputChannels: 2,
                microphoneEnabled: true
            )
        )
        XCTAssertEqual(harness.lastChannelPreferenceOperations, [])
    }

    func testExpectedRouteTransactionConsumesActivationAndBoundConfigurationEvents() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingActivation
            ),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingBound
            ),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .pendingCategory
            ),
            .unrelated
        )
    }

    func testExpectedRouteTransactionRejectsWrongProvenanceAndOutputOverride() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .pendingOverride,
            .pendingWrongPreviousRoute,
            .pendingWrongGeneration,
            .pendingWrongOwnership,
            .pendingCoalescedSkippedIntermediate,
            .pendingExpired,
            .pendingSequenceNotAdvanced,
            .pendingWrongSystemGeneration,
            .pendingWrongPolicy,
            .pendingMissingFingerprint,
            .pendingOutputChanged,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .rejectTransaction,
                "Scenario \(scenario.rawValue) was not rejected."
            )
        }
    }

    func testConvergedRouteTransactionIsIdempotentOnlyForExactBoundedDuplicates() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedDuplicate
            ),
            .consume
        )
        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .convergedChangedRoute,
            .convergedRecoveryRequired,
            .convergedExpired,
            .convergedWrongOwnership,
            .convergedInactive,
            .convergedOutputMissing,
            .convergedChannelMismatch,
            .convergedTargetMismatch,
            .convergedPreferredMismatch,
            .convergedWrongSystemGeneration,
            .convergedWrongGeneration,
            .convergedPreviousUnseen,
            .convergedExplicitResumeRequired,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .unrelated,
                "Scenario \(scenario.rawValue) was incorrectly consumed."
            )
        }
    }

    func testRemoteIOStartRouteTransactionAcceptsOnlyExactReasonEightEvidence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(.preparedExact),
            .consume
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .startingCoalescedExactRoute
            ),
            .consume,
            "A delayed/coalesced reason-8 event is harmless only when the complete prepared route remains exact."
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedStartSettlementCoalescedExactRoute
            ),
            .consume,
            "A previous-unseen coalesced reason-8 may be consumed after publication only while the exact native-start settlement claim owns it."
        )
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(
                .convergedStartSettlementExpired
            ),
            .unrelated,
            "An expired native-start claim must not lend provenance to a previous-unseen route event."
        )

        for scenario: WebRTCIOSExpectedRouteChangeTestScenario in [
            .preparedChangedRoute,
            .startingChangedRoute,
            .startingOutputChanged,
            .startingWrongOwnership,
            .startingRecoveryRequired,
            .startingOldDeviceUnavailable,
            .startingChannelMismatch,
            .startingInactive,
            .startingWrongGeneration,
            .startingWrongSystemGeneration,
            .startingTargetMismatch,
            .startingPreferredMismatch,
            .startingExplicitResumeRequired,
        ] {
            XCTAssertEqual(
                harness.debugClassifyExpectedRouteChangeForTesting(scenario),
                .rejectTransaction,
                "Start-time scenario \(scenario.rawValue) was not rejected."
            )
        }
        XCTAssertEqual(
            harness.debugClassifyExpectedRouteChangeForTesting(.startingCategory),
            .unrelated
        )
    }

    func testRemoteIOStartSettlementProductionStateIsOneShotAcrossCommit() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRemoteIOStartSettlementAcceptsDelayedObservationForTesting(),
            "The production transaction state must retire a claim consumed while Starting at commit (including a synchronous pre-stamp ingress), preserve an unused claim for one exact +250 ms post-commit ingress, and reject replay, expiry, wrong transaction, and the stamp sequence."
        )
    }

    func testOnlySupersededReasonEightCanBeAbsorbedByNewerTransaction() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugSupersededRouteObservationIsSuppressedForTesting(
                oldDeviceUnavailable: false
            )
        )
        XCTAssertFalse(
            harness.debugSupersededRouteObservationIsSuppressedForTesting(
                oldDeviceUnavailable: true
            ),
            "Physical device loss must always reach explicit-resume policy."
        )
    }

    func testOnlyReasonEightFromRetiredSystemAudioGenerationIsSuppressed() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
                    oldDeviceUnavailable: false
                )
        )
        XCTAssertFalse(
            harness
                .debugRetiredSystemGenerationRouteObservationIsSuppressedForTesting(
                    oldDeviceUnavailable: true
                ),
            "A generation change must never hide physical device loss."
        )
    }

    func testReasonEightArbitrationSupportsSwiftFirstAndNativeFirstDelivery() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .consumed,
            .liveRejectionOwnedByWaiter,
            .staleSuppressed,
            .generic,
            .uninitialized,
        ] {
            XCTAssertTrue(
                harness.debugWaiterFirstResolvesForTesting(disposition),
                "Swift-first arbitration lost disposition \(disposition)."
            )
            XCTAssertTrue(
                harness.debugNativeFirstResolvesForTesting(disposition),
                "Native-first arbitration lost disposition \(disposition)."
            )
        }
    }

    func testReasonEightNativeFirstDispositionSurvivesResolverReplacement() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        for disposition: WebRTCRouteConfigurationChangeDisposition in [
            .consumed,
            .staleSuppressed,
        ] {
            XCTAssertTrue(
                harness
                    .debugNativeFirstResolverReplacementPreservesDispositionForTesting(
                        disposition
                    ),
                "Resolver replacement overwrote exact disposition \(disposition)."
            )
        }
    }

    func testReasonEightArbitrationIsExactAndTimeoutCompletesOnce() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        XCTAssertTrue(
            harness
                .debugExactNotificationIdentityRejectsStaleResolutionForTesting(),
            "A replacement notification must not borrow a retired notification's native disposition."
        )
        XCTAssertTrue(
            harness.debugTimeoutCompletesExactlyOnceForTesting(),
            "A late native resolution after timeout must not deliver a second generic recovery."
        )
    }

    func testReasonEightTimeoutBeforeLateNativeBindCompletesOnceAndCleansRecord() {
        let harness =
            WebRTCRouteConfigurationChangeArbitrationTestHarness()

        XCTAssertTrue(
            harness
                .debugTimeoutBeforeNativeBindThenLateResolutionCompletesExactlyOnceForTesting(),
            "A late native bind after timeout must neither redeliver nor recreate arbitration state."
        )
        XCTAssertEqual(
            harness.debugArbitrationRecordCountForTesting(),
            0,
            "Timeout followed by late native resolution must leave no arbitration records."
        )
    }

    func testExplicitResumeFailureRemainsStickyWhileLatched() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkRouteLossForTesting()
        let explicitResume = harness.diagnostics
        XCTAssertTrue(explicitResume.explicitResumeRequired)
        XCTAssertEqual(explicitResume.failureCode, 19)

        harness.debugAttemptFailureOverwriteForTesting()
        let afterOverwriteAttempt = harness.diagnostics
        XCTAssertTrue(afterOverwriteAttempt.explicitResumeRequired)
        XCTAssertEqual(afterOverwriteAttempt.failureCode, 19)
        XCTAssertEqual(
            afterOverwriteAttempt.lastLifecycleStatus,
            explicitResume.lastLifecycleStatus
        )
    }

    func testRunningButUnpublishedAudioUnitIsStoppedDuringRollback() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRunningUnpublishedAudioUnitStopInvariantHoldsForTesting()
        )
    }

    func testOnlyRouteEvidenceThatClosedTheGateRetainsMicrophonePublicationClosure() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertFalse(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: false,
                    inFlightCount: 0
                )
        )
        XCTAssertTrue(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: true,
                    inFlightCount: 0
                )
        )
        // An in-flight count cannot fabricate ownership if ingress never
        // recorded a closure (for example, while playout was stopped).
        XCTAssertFalse(
            harness
                .debugRouteEvidenceOwnsMicrophonePublicationClosureForTesting(
                    recordedClosure: false,
                    inFlightCount: 1
                )
        )
        XCTAssertTrue(
            harness
                .debugRecordedConsumedRouteClosureSchedulesFreshResolutionForTesting(),
            "A drained recorded closure must always reach fresh device-queue resolution."
        )
    }

    func testCategoryObservationClosesOnlyWhenTrackedResolutionOwnsIt() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugTrackedCategoryObservationOwnsRouteClosureForTesting(),
            "Category/options evidence racing approval must keep microphone publication closed."
        )
        XCTAssertTrue(
            harness
                .debugUntrackedCategoryObservationAvoidsUnownedRouteClosureForTesting(),
            "Output-only or hosted category evidence must not strand gates without a transaction-owned resolver."
        )
        XCTAssertTrue(
            harness
                .debugConsumedPublicationQueuesRecordedRouteClosureResolutionForTesting(),
            "A closure drained before commit must remain closed at publication and queue fresh resolution once the transaction is consumed."
        )
    }

    func testExpectedCategoryObservationUsesCapturedTransactionPolicy() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                .microphoneExact
            ),
            "The exact playAndRecord/default/40 notification must remain tied to the microphone transaction that authored it."
        )
        XCTAssertTrue(
            harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                .outputOnlyExact
            ),
            "The exact playback/default-mode/empty/longFormAudio notification must remain tied to its output-only transaction."
        )
    }

    func testUnexpectedCategoryObservationStillFailsExactPolicyFence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        for scenario: WebRTCIOSExpectedCategoryObservationTestScenario in [
            .untracked,
            .wrongOptions,
            .wrongMode,
            .wrongSharingPolicy,
            .wrongConfigurationGeneration,
            .wrongSystemAudioGeneration,
            .sequenceNotAdvanced,
            .expired,
        ] {
            XCTAssertFalse(
                harness.debugExpectedCategoryObservationIsAbsorbedForTesting(
                    scenario
                ),
                "Unexpected category scenario \(scenario.rawValue) bypassed fail-closed validation."
            )
        }
    }

    func testRetiredExpectedCategoryObservationUsesProductionAsyncPipeline() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugDriveRetiredExpectedCategoryObservationForTesting(
                exactPolicy: true
            )
        )
        XCTAssertEqual(harness.queuedOperationCount, 0)
        XCTAssertEqual(harness.diagnostics.failureCode, 0)
        XCTAssertFalse(harness.diagnostics.recoveryRequired)
    }

    func testRetiredMismatchedCategoryObservationStillReachesNativeFailClose() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness.debugDriveRetiredExpectedCategoryObservationForTesting(
                exactPolicy: false
            )
        )
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.diagnostics.failureCode, 20)
        XCTAssertTrue(harness.diagnostics.recoveryRequired)
    }

    func testFinalMicrophonePublicationRejectsDelayedRouteIngressAndUsesSnapshotOwnership() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugFinalMicrophonePublicationRejectsDelayedRouteIngressForTesting(),
            "Category or route ingress after the final fresh session sample must block microphone gate publication."
        )
        XCTAssertTrue(
            harness
                .debugRouteLockedOwnershipSnapshotComparatorForTesting(),
            "Route-locked gate publication must use the atomic ownership snapshot without acquiring the ownership lock."
        )
        XCTAssertTrue(
            harness
                .debugImmutableRouteRejectionSnapshotSurvivesLaterRouteForTesting(),
            "Failure diagnostics must retain the redacted immutable ingress that rejected the transaction, not a later live route."
        )
    }

    func testClearRetiresInFlightExpectedRouteObservationIdentity() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugClearRetiresInFlightExpectedRouteObservationForTesting()
        )
    }

    func testOldQueuedRouteCompletionCannotMutateRearmedTransaction() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugOldQueuedRouteObservationCannotMutateRearmedTransactionForTesting(),
            "A completion carrying a retired transaction ID must leave the new transaction's state and in-flight count untouched."
        )
    }

    func testRecordedClosureResolutionUsesFreshRouteEvidence() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugRecordedConsumedRouteClosureUsesFreshRouteForTesting(),
            "A recorded consumed closure must resolve from the fresh device-queue route, not the stale final ingress snapshot."
        )
    }

    func testNotificationSequenceChangeBlocksFreshRouteReopen() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        XCTAssertTrue(
            harness
                .debugNotificationSequenceChangeBlocksFreshRouteReopenForTesting(),
            "A notification admitted after fresh validation must retain the fail-closed gate instead of reopening it."
        )
    }

    func testRouteTransactionFailureSnapshotIsStructuredAndRedactsUIDs() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }

        let first =
            harness.debugStructuredRouteTransactionFailureSnapshotForTesting()
        let second =
            harness.debugStructuredRouteTransactionFailureSnapshotForTesting()

        XCTAssertEqual(first, second, "Redacted fingerprints must correlate across snapshots.")
        XCTAssertTrue(first.contains("routeTxn{phase=fresh-reopen state=consumed"))
        XCTAssertTrue(first.contains("txn=71 expectedTxn=71"))
        XCTAssertTrue(
            first.contains(
                "notification={current=73 baseline=68 required=72 inFlight=0}"
            )
        )
        XCTAssertTrue(
            first.contains("generation={configuration=11/12 system=41/42}")
        )
        XCTAssertTrue(first.contains("ownership={bound=91 current=92}"))
        XCTAssertTrue(
            first.contains(
                "failed=[notificationSequence,configurationGeneration,systemAudioGeneration,ownershipToken]"
            )
        )
        XCTAssertTrue(first.contains("targetInputUID=sha256/128:"))
        XCTAssertTrue(first.contains("inputUID=sha256/128:"))
        XCTAssertTrue(first.contains("preferredInputUID=sha256/128:"))
        XCTAssertFalse(first.contains("PRIVATE-INPUT-UID"))
        XCTAssertFalse(first.contains("PRIVATE-OUTPUT-UID"))
    }

    func testMicrophoneApprovalRejectsZeroWrongStaleRevokedAndRetiredGenerations() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let firstGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(firstGeneration, 0)
        authorization.debugSetRecordingGenerationForTesting(0)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertTrue(
            harness.diagnostics.microphoneDeviceGateClosedAndDrained
        )
        XCTAssertFalse(
            harness.diagnostics.microphoneAuthorizationGatePublished
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let secondGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(secondGeneration, 0)
        XCTAssertNotEqual(secondGeneration, firstGeneration)
        authorization.debugSetRecordingGenerationForTesting(
            secondGeneration &+ 1
        )
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertEqual(
            harness.diagnostics.microphoneRecordingGeneration,
            secondGeneration
        )
        XCTAssertEqual(
            harness.diagnostics.approvedMicrophoneRecordingGeneration,
            0
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let thirdGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(thirdGeneration, 0)
        XCTAssertNotEqual(thirdGeneration, secondGeneration)
        authorization.debugSetRecordingGenerationForTesting(secondGeneration)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting(),
            "An authorization carrying a prior nonzero generation must fail closed."
        )
        XCTAssertEqual(
            harness.diagnostics.microphoneRecordingGeneration,
            thirdGeneration
        )

        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )
        let fourthGeneration = authorization.recordingGeneration
        XCTAssertGreaterThan(fourthGeneration, 0)
        authorization.revoke()
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertTrue(
            harness.diagnostics.microphoneDeviceGateClosedAndDrained
        )
        XCTAssertFalse(
            harness.diagnostics.microphoneAuthorizationGatePublished
        )

        let replacement = WebRTCIOSMicrophoneAuthorization()
        XCTAssertTrue(
            harness.setMicrophoneAuthorizationForTesting(replacement)
        )
        let replacementGeneration = replacement.recordingGeneration
        XCTAssertGreaterThan(replacementGeneration, 0)
        XCTAssertTrue(harness.setMicrophoneAuthorizationForTesting(nil))

        let retired = harness.diagnostics
        XCTAssertFalse(replacement.isValid)
        XCTAssertEqual(retired.microphoneRecordingGeneration, 0)
        XCTAssertEqual(retired.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(retired.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(retired.microphoneAuthorizationGatePublished)
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testMicrophoneStageFailureDoesNotRebuildOrRepublishStaleInput() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        let before = harness.diagnostics
        let configurationCount = harness.configurationOperationCount
        harness.debugSetOutputRouteAvailableForTesting(false)

        XCTAssertFalse(
            harness.setMicrophoneAuthorizationForTesting(authorization)
        )

        let failed = harness.diagnostics
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(failed.microphoneRecordingGeneration, 0)
        XCTAssertEqual(failed.approvedMicrophoneRecordingGeneration, 0)
        XCTAssertTrue(failed.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(failed.microphoneAuthorizationGatePublished)
        XCTAssertFalse(failed.inputBusEnabled)
        XCTAssertFalse(failed.outputBusEnabled)
        XCTAssertFalse(failed.sessionActive)
        XCTAssertEqual(
            failed.microphoneRealtimeAdmissionCount,
            before.microphoneRealtimeAdmissionCount
        )
        XCTAssertEqual(
            failed.microphoneDeliveryCallbackCount,
            before.microphoneDeliveryCallbackCount
        )
        XCTAssertEqual(
            failed.microphoneDeliveredFrameCount,
            before.microphoneDeliveredFrameCount
        )
        XCTAssertEqual(
            harness.configurationOperationCount,
            configurationCount + 1,
            "A failed duplex stage must not trigger an ordinary second rebuild."
        )
        XCTAssertFalse(
            harness.debugPublishCurrentMicrophoneAuthorizationForTesting()
        )
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
    }

    func testRecoveryAuthorizationRevocationWaitsForAuthorizedNativeBoundary() {
        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            authorization.performIfValidForTesting {
                operationStarted.signal()
                _ = allowOperationToFinish.wait(timeout: .now() + 2)
            }
            operationFinished.signal()
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            revokeStarted.signal()
            authorization.revoke()
            revokeFinished.signal()
        }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            revokeFinished.wait(timeout: .now() + 0.25),
            .timedOut,
            "Synchronous revocation must wait for an authorized native operation to linearize."
        )

        allowOperationToFinish.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
    }

    func testHostedCallAuthorizationRevocationWaitsForAuthorizedRecoveryBoundary() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let operationStarted = DispatchSemaphore(value: 0)
        let allowOperationToFinish = DispatchSemaphore(value: 0)
        let operationReachedEnd = DispatchSemaphore(value: 0)
        let recoveryFinished = DispatchSemaphore(value: 0)
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)
        let revocationRecorder = HostedCallTestingRevocationRecorder()
        let systemAudioGeneration: UInt64 = 0xCA11_1001

        DispatchQueue.global(qos: .userInitiated).async {
            _ = authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: systemAudioGeneration,
                revocationHandler: {
                    revocationRecorder.record()
                }
            ) {
                operationStarted.signal()
                _ = allowOperationToFinish.wait(timeout: .now() + 2)
                operationReachedEnd.signal()
            }
            recoveryFinished.signal()
        }
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            revokeStarted.signal()
            authorization.revoke()
            revokeFinished.signal()
        }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            revokeFinished.wait(timeout: .now() + 0.25),
            .timedOut,
            "Hosted-call revocation must wait for the in-flight authorized operation."
        )
        XCTAssertEqual(authorization.systemAudioGeneration, systemAudioGeneration)
        XCTAssertEqual(revocationRecorder.count, 0)

        allowOperationToFinish.signal()
        XCTAssertEqual(operationReachedEnd.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(recoveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, systemAudioGeneration)
        XCTAssertEqual(revocationRecorder.count, 1)
        authorization.revoke()
        XCTAssertEqual(revocationRecorder.count, 1)
        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting {
                XCTFail("No hosted recovery operation may begin after revoke returns.")
            }
        )
    }

    func testHostedCallAuthorizationTestingRecoveryInstallsGenerationAndRevokesSynchronouslyOnce() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let rejectedRevocation = HostedCallTestingRevocationRecorder()
        let acceptedRevocation = HostedCallTestingRevocationRecorder()
        var operationCount = 0
        let generation: UInt64 = 0xCA11_2001

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0,
                revocationHandler: { rejectedRevocation.record() }
            ) {
                operationCount += 1
            }
        )
        XCTAssertEqual(operationCount, 0)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: generation,
                revocationHandler: { acceptedRevocation.record() }
            ) {
                operationCount += 1
            }
        )
        XCTAssertEqual(operationCount, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, generation)
        XCTAssertEqual(rejectedRevocation.count, 0)
        XCTAssertEqual(acceptedRevocation.count, 0)

        authorization.revoke()
        XCTAssertFalse(authorization.isValid)
        XCTAssertEqual(authorization.systemAudioGeneration, generation)
        XCTAssertEqual(rejectedRevocation.count, 0)
        XCTAssertEqual(acceptedRevocation.count, 1)

        authorization.revoke()
        XCTAssertEqual(acceptedRevocation.count, 1)
    }

    func testHostedCallAuthorizationTestingRecoveryRejectsReuseAndPreservesFirstInstall() {
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let firstRevocation = HostedCallTestingRevocationRecorder()
        let sameGenerationRevocation = HostedCallTestingRevocationRecorder()
        let replacementRevocation = HostedCallTestingRevocationRecorder()
        var rejectedOperationCount = 0
        let firstGeneration: UInt64 = 0xCA11_2002
        let replacementGeneration: UInt64 = 0xCA11_2003

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: firstGeneration,
                revocationHandler: { firstRevocation.record() }
            )
        )
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, firstGeneration)

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: firstGeneration,
                revocationHandler: { sameGenerationRevocation.record() }
            ) {
                rejectedOperationCount += 1
            }
        )
        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: replacementGeneration,
                revocationHandler: { replacementRevocation.record() }
            ) {
                rejectedOperationCount += 1
            }
        )
        XCTAssertEqual(rejectedOperationCount, 0)
        XCTAssertEqual(authorization.systemAudioGeneration, firstGeneration)

        authorization.revoke()
        XCTAssertEqual(firstRevocation.count, 1)
        XCTAssertEqual(sameGenerationRevocation.count, 0)
        XCTAssertEqual(replacementRevocation.count, 0)
    }

    func testHostedCallAuthorizationTestingRecoveryRejectsConsumedAndRevokedClaims() {
        let consumedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        var bareOperationCount = 0
        XCTAssertTrue(
            consumedAuthorization.performRecoveryIfValidForTesting {
                bareOperationCount += 1
            }
        )
        XCTAssertEqual(bareOperationCount, 1)
        XCTAssertFalse(consumedAuthorization.isRecoveryPending)
        XCTAssertEqual(consumedAuthorization.systemAudioGeneration, 0)
        let consumedRevocation = HostedCallTestingRevocationRecorder()
        var consumedOperationCount = 0
        XCTAssertFalse(
            consumedAuthorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0xCA11_2004,
                revocationHandler: { consumedRevocation.record() }
            ) {
                consumedOperationCount += 1
            }
        )
        XCTAssertEqual(consumedOperationCount, 0)
        consumedAuthorization.revoke()
        XCTAssertEqual(consumedRevocation.count, 0)

        let revokedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        let revokedRevocation = HostedCallTestingRevocationRecorder()
        var revokedOperationCount = 0
        revokedAuthorization.revoke()
        XCTAssertFalse(
            revokedAuthorization.performRecoveryIfValidForTesting(
                systemAudioGeneration: 0xCA11_2005,
                revocationHandler: { revokedRevocation.record() }
            ) {
                revokedOperationCount += 1
            }
        )
        XCTAssertEqual(revokedOperationCount, 0)
        XCTAssertFalse(revokedAuthorization.isValid)
        XCTAssertFalse(revokedAuthorization.isRecoveryPending)
        XCTAssertEqual(revokedAuthorization.systemAudioGeneration, 0)
        XCTAssertEqual(revokedRevocation.count, 0)
    }

    private final class HostedCallTestingRevocationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        func record() {
            lock.lock()
            storage += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testQueuedNativeRecoveryRejectsRevokedAttemptBeforeRebuild() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let retiredAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()

        harness.queueRecovery(authorization: retiredAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertEqual(harness.diagnostics.requestCount, 1)
        XCTAssertEqual(harness.diagnostics.rebuildCount, 0)

        retiredAuthorization.revoke()
        XCTAssertTrue(harness.runNextQueuedOperation())

        let rejected = harness.diagnostics
        XCTAssertEqual(rejected.requestCount, 1)
        XCTAssertEqual(rejected.authorizationRejectionCount, 1)
        XCTAssertEqual(rejected.rebuildCount, 0)
        XCTAssertFalse(rejected.sessionActive)
        XCTAssertFalse(rejected.remoteIOCreated)

        let currentAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: currentAuthorization)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let accepted = harness.diagnostics
        XCTAssertEqual(accepted.requestCount, 2)
        XCTAssertEqual(accepted.authorizationRejectionCount, 1)
        XCTAssertEqual(accepted.rebuildCount, 1)
        XCTAssertTrue(accepted.sessionActive)
        XCTAssertFalse(accepted.inputBusEnabled)
        XCTAssertFalse(accepted.remoteIOCreated)
    }

    func testRecoveryBeforeNativeInterruptionEndNeedsFreshAuthorizationAfterEnd() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        harness.debugMarkHealthyPlayoutForTesting()
        harness.debugMarkInterruptedFailClosedForTesting()
        let baseline = harness.diagnostics
        let configurationCount = harness.configurationOperationCount
        XCTAssertEqual(baseline.failureCode, 17)
        XCTAssertFalse(baseline.sessionActive)

        // Inject an adverse native queue order directly. This characterizes
        // fail-closed behavior, not production AVAudioSession notification order.
        let earlyAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: earlyAuthorization)
        harness.debugQueueInterruptionEndedForTesting()
        XCTAssertEqual(harness.queuedOperationCount, 2)

        XCTAssertTrue(harness.runNextQueuedOperation())
        let rejected = harness.diagnostics
        XCTAssertEqual(earlyAuthorization.terminalOutcome, .rejected)
        XCTAssertEqual(earlyAuthorization.terminalGeneration, earlyAuthorization.generation)
        XCTAssertEqual(rejected.failureCode, 17)
        XCTAssertEqual(rejected.authorizationRejectionCount, baseline.authorizationRejectionCount + 1)
        XCTAssertEqual(rejected.rebuildCount, baseline.rebuildCount)
        XCTAssertEqual(harness.configurationOperationCount, configurationCount)
        XCTAssertFalse(rejected.sessionActive)
        XCTAssertFalse(rejected.inputBusEnabled)

        XCTAssertTrue(harness.runNextQueuedOperation())
        let ended = harness.diagnostics
        XCTAssertEqual(ended.failureCode, 18)
        XCTAssertTrue(ended.recoveryRequired)
        XCTAssertFalse(ended.sessionActive)
        XCTAssertFalse(ended.inputBusEnabled)
        XCTAssertEqual(harness.queuedOperationCount, 0)
        XCTAssertEqual(earlyAuthorization.terminalOutcome, .rejected)

        let freshAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: freshAuthorization)
        XCTAssertTrue(harness.runNextQueuedOperation())
        let recovered = harness.diagnostics
        XCTAssertTrue(freshAuthorization.hasAcceptedTerminalOutcome)
        XCTAssertEqual(recovered.rebuildCount, baseline.rebuildCount + 1)
        XCTAssertTrue(recovered.sessionActive)
        XCTAssertFalse(recovered.inputBusEnabled)
        XCTAssertEqual(recovered.failureCode, 0)
    }

    func testRecoveryStagedBeforeNativeInterruptionEndLosesExactTagBeforeExecution() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugRecoveryStagedBeforeInterruptionEndForTesting()
        func value(_ key: String) throws -> NSNumber {
            try XCTUnwrap(result[key], "Missing native result: \(key)")
        }
        for key in ["targetBound", "endedRan", "recoveryRan", "rejected",
                    "terminalMatchesAuthorization", "noRebuild", "remainedClosed",
                    "freshTargetBound", "freshRecoveryRan", "freshAccepted",
                    "freshPolicyMatches", "freshSessionActive", "inputRemainedClosed"] {
            XCTAssertTrue(try value(key).boolValue, key)
        }
        XCTAssertGreaterThan(try value("tagGeneration").uint64Value, 0)
        XCTAssertEqual(try value("afterEndFailure").intValue, 18)
        XCTAssertEqual(try value("rejectionCountDelta").intValue, 1)
        XCTAssertGreaterThan(try value("freshTagGeneration").uint64Value,
                             try value("tagGeneration").uint64Value)
    }

    func testSystemAudioEventFenceIsFIFOObservationalAndBoundToLiveDevice() throws {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let result = harness.debugSystemAudioEventFenceForTesting()
        for key in ["fifoQueued", "endedBeforeCompletion", "completionOutsideLock", "fenceCompletedOnce",
                    "fenceNoAudioSideEffects", "freshStagingAfterFenceSurvives", "pendingTagPreserved",
                    "preservedTagStillUsable", "wrongDevice", "wrongRegistration", "missingDelegate",
                    "uninitialized", "invalidRegistration", "queuedDeviceChange", "queuedRegistrationReplacement",
                    "queuedRegistrationInvalidation", "queuedDelegateReplacement", "queuedTermination",
                    "queuedReinitialization"] {
            XCTAssertTrue(try XCTUnwrap(result[key], "Missing native result: \(key)").boolValue, key)
        }
    }

    // MARK: - Connected hosted-call playout recovery

    func testStartupConnectedCallArmIsQuiescentUntilFirstStartPlayout() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .startupConnectedCall
        )
        defer { _ = harness.debugTerminateForTesting() }

        let before = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertFalse(before.sessionActive)
        XCTAssertFalse(before.remoteIOCreated)
        XCTAssertFalse(before.inputBusEnabled)
        XCTAssertFalse(before.outputBusEnabled)
        XCTAssertFalse(before.hostedCallMode)
        XCTAssertTrue(before.microphoneDeviceGateClosedAndDrained)
        XCTAssertFalse(before.microphoneAuthorizationGatePublished)
        XCTAssertEqual(before.microphoneRecordingGeneration, 0)
        XCTAssertEqual(before.approvedMicrophoneRecordingGeneration, 0)

        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )

        let armed = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
        XCTAssertFalse(armed.sessionActive)
        XCTAssertFalse(armed.remoteIOCreated)
        XCTAssertFalse(armed.inputBusEnabled)
        XCTAssertFalse(armed.outputBusEnabled)
        XCTAssertFalse(armed.recoveryRequired)
        XCTAssertFalse(armed.explicitResumeRequired)
        XCTAssertTrue(armed.hostedCallMode)
        XCTAssertTrue(armed.hostedCallAuthorizationValid)
        XCTAssertFalse(armed.hostedCallRecoveryPending)
        XCTAssertEqual(armed.hostedCallOrigin, .startupConnectedCall)
        XCTAssertEqual(
            armed.hostedCallAuthorizationGeneration,
            authorization.systemAudioGeneration
        )
        XCTAssertEqual(
            armed.systemAudioGeneration,
            authorization.systemAudioGeneration
        )

        // Exact duplicate arming is idempotent and still has no AVAudioSession side effects.
        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )
        XCTAssertEqual(harness.configurationOperationCount, 0)

        XCTAssertTrue(harness.debugStartPlayoutForTesting())

        let started = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertTrue(started.sessionActive)
        XCTAssertFalse(
            started.remoteIOCreated,
            "The deterministic harness records production policy selection without claiming hardware RemoteIO creation."
        )
        XCTAssertFalse(started.inputBusEnabled)
        XCTAssertTrue(started.outputBusEnabled)
        XCTAssertFalse(started.recoveryRequired)
        XCTAssertFalse(started.explicitResumeRequired)
        XCTAssertFalse(started.categoryOptionsAreEmpty)
        XCTAssertTrue(started.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(started.routeSharingPolicyIsDefault)
        XCTAssertTrue(started.hostedCallMode)
        XCTAssertEqual(started.hostedCallOrigin, .startupConnectedCall)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )
    }

    func testStartupConnectedCallArmRejectsEveryNonquiescentOrStaleClaim() {
        struct RejectionCase {
            let name: String
            let origin: WebRTCIOSHostedCallPlayoutOrigin
            let arrange: (
                WebRTCIOSPlayoutRecoveryTestHarness,
                WebRTCIOSHostedCallPlayoutAuthorization
            ) -> Void
        }

        let cases: [RejectionCase] = [
            RejectionCase(
                name: "wrong origin",
                origin: .interruption,
                arrange: { _, _ in }
            ),
            RejectionCase(
                name: "interrupted",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkInterruptedFailClosedForTesting()
                }
            ),
            RejectionCase(
                name: "stale consumed generation",
                origin: .startupConnectedCall,
                arrange: { _, authorization in
                    XCTAssertTrue(
                        authorization.performRecoveryIfValidForTesting(
                            systemAudioGeneration: 0xCA11_6001,
                            revocationHandler: {}
                        )
                    )
                }
            ),
            RejectionCase(
                name: "live microphone authorization",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugInstallMicrophoneAuthorizationForTesting(
                        WebRTCIOSMicrophoneAuthorization()
                    )
                }
            ),
            RejectionCase(
                name: "live playout topology",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkHealthyPlayoutForTesting()
                }
            ),
            RejectionCase(
                name: "recovery and explicit resume",
                origin: .startupConnectedCall,
                arrange: { harness, _ in
                    harness.debugMarkRouteLossForTesting()
                    harness.debugSetOutputRouteAvailableForTesting(true)
                }
            ),
        ]

        for testCase in cases {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: testCase.origin
            )
            defer { _ = harness.debugTerminateForTesting() }
            testCase.arrange(harness, authorization)
            let configurationCount = harness.configurationOperationCount

            XCTAssertFalse(
                harness.armStartupConnectedCallPlayout(
                    authorization: authorization
                ),
                testCase.name
            )
            XCTAssertFalse(authorization.isValid, testCase.name)
            XCTAssertNil(harness.hostedCallPolicyID, testCase.name)
            XCTAssertFalse(harness.diagnostics.hostedCallMode, testCase.name)
            XCTAssertNil(harness.diagnostics.hostedCallOrigin, testCase.name)
            XCTAssertEqual(
                harness.configurationOperationCount,
                configurationCount,
                testCase.name
            )
        }
    }

    func testStartupConnectedCallArmDefersRouteValidationUntilActivation() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .startupConnectedCall
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugSetOutputRouteAvailableForTesting(false)

        XCTAssertTrue(
            harness.armStartupConnectedCallPlayout(
                authorization: authorization
            )
        )
        XCTAssertEqual(harness.configurationOperationCount, 0)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertFalse(harness.debugStartPlayoutForTesting())

        let failed = harness.diagnostics
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertFalse(authorization.isValid)
        XCTAssertNil(harness.hostedCallPolicyID)
        XCTAssertFalse(failed.sessionActive)
        XCTAssertFalse(failed.inputBusEnabled)
        XCTAssertFalse(failed.outputBusEnabled)
        XCTAssertTrue(failed.recoveryRequired)
        XCTAssertFalse(failed.hasOutputRoute)
        XCTAssertFalse(failed.hostedCallMode)
    }

    func testStartupHostedRevocationAndGenerationAdvanceRemainQuiescent() {
        for revoke in [true, false] {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .startupConnectedCall
            )
            defer { _ = harness.debugTerminateForTesting() }

            XCTAssertTrue(
                harness.armStartupConnectedCallPlayout(
                    authorization: authorization
                )
            )
            XCTAssertEqual(harness.configurationOperationCount, 0)

            if revoke {
                authorization.revoke()
            } else {
                harness.debugAdvanceSystemAudioGenerationForTesting()
            }

            let revoked = harness.diagnostics
            XCTAssertFalse(authorization.isValid)
            XCTAssertNil(harness.hostedCallPolicyID)
            XCTAssertFalse(revoked.sessionActive)
            XCTAssertFalse(revoked.remoteIOCreated)
            XCTAssertFalse(revoked.inputBusEnabled)
            XCTAssertFalse(revoked.outputBusEnabled)
            XCTAssertTrue(revoked.recoveryRequired)
            XCTAssertFalse(revoked.hostedCallMode)
            XCTAssertNil(revoked.hostedCallOrigin)
            XCTAssertEqual(harness.configurationOperationCount, 0)
            XCTAssertFalse(harness.debugStartPlayoutForTesting())
            XCTAssertEqual(harness.configurationOperationCount, 0)
        }
    }

    func testHostedCallAuthorizationSeparatesPersistentOwnershipFromOneShotRecovery() {
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        let counter = LockedInteger()

        XCTAssertEqual(authorization.policyID, policyID)
        XCTAssertEqual(authorization.origin, .interruption)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertTrue(
            authorization.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.systemAudioGeneration, 0)

        XCTAssertFalse(
            authorization.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)

        authorization.revoke()
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(authorization.policyID, policyID)

        let revokedPolicyID = UUID()
        let revoked = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: revokedPolicyID,
            origin: .interruption
        )
        revoked.revoke()

        XCTAssertEqual(revoked.policyID, revokedPolicyID)
        XCTAssertEqual(revoked.origin, .interruption)
        XCTAssertFalse(revoked.isValid)
        XCTAssertFalse(revoked.isRecoveryPending)
        XCTAssertEqual(revoked.systemAudioGeneration, 0)
        XCTAssertFalse(
            revoked.performRecoveryIfValidForTesting {
                counter.increment()
            }
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testHostedCallRequestWaitsForInterruptedFailCloseAndRejectsOrdinaryRecovery() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let hostedAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkHealthyPlayoutForTesting()
        let healthy = harness.diagnostics
        XCTAssertTrue(healthy.sessionActive)
        XCTAssertFalse(
            healthy.remoteIOCreated,
            "The deterministic harness must not claim hardware AudioUnit creation."
        )
        XCTAssertFalse(healthy.inputBusEnabled)
        XCTAssertTrue(healthy.outputBusEnabled)
        XCTAssertFalse(healthy.recoveryRequired)
        XCTAssertFalse(healthy.explicitResumeRequired)
        XCTAssertTrue(healthy.categoryOptionsAreEmpty)
        XCTAssertFalse(healthy.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(healthy.categoryOptionsAreMixWithOthers)
        XCTAssertFalse(healthy.routeSharingPolicyIsDefault)
        XCTAssertTrue(healthy.hasOutputRoute)
        XCTAssertFalse(healthy.hostedCallMode)
        assertLastRecordedAudioConfiguration(
            harness,
            options: [],
            expectedOperationCount: 1
        )

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let afterHealthyRequest = harness.diagnostics
        XCTAssertEqual(afterHealthyRequest.requestCount, 1)
        XCTAssertEqual(afterHealthyRequest.authorizationRejectionCount, 0)
        XCTAssertEqual(afterHealthyRequest.rebuildCount, 0)
        XCTAssertTrue(afterHealthyRequest.sessionActive)
        XCTAssertFalse(afterHealthyRequest.remoteIOCreated)
        XCTAssertTrue(afterHealthyRequest.outputBusEnabled)
        XCTAssertFalse(afterHealthyRequest.hostedCallMode)
        XCTAssertFalse(afterHealthyRequest.hostedCallAuthorizationValid)
        XCTAssertFalse(afterHealthyRequest.hostedCallRecoveryPending)
        XCTAssertNil(harness.hostedCallPolicyID)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        XCTAssertEqual(harness.configurationOperationCount, 1)

        harness.debugMarkInterruptedFailClosedForTesting()
        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        harness.debugInstallMicrophoneAuthorizationForTesting(
            microphoneAuthorization
        )
        XCTAssertTrue(microphoneAuthorization.isValid)

        let ordinaryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: ordinaryAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let afterOrdinaryRecovery = harness.diagnostics
        XCTAssertEqual(afterOrdinaryRecovery.requestCount, 2)
        XCTAssertEqual(afterOrdinaryRecovery.authorizationRejectionCount, 1)
        XCTAssertEqual(afterOrdinaryRecovery.rebuildCount, 0)
        XCTAssertFalse(ordinaryAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let whileInterrupted = harness.diagnostics
        XCTAssertEqual(whileInterrupted.requestCount, 3)
        XCTAssertEqual(whileInterrupted.authorizationRejectionCount, 1)
        XCTAssertEqual(whileInterrupted.rebuildCount, 0)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(hostedAuthorization.systemAudioGeneration, 0)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        harness.debugMarkInterruptionEndedFailClosedForTesting()

        harness.queueHostedCallRecovery(authorization: hostedAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let live = harness.diagnostics
        XCTAssertEqual(live.requestCount, 4)
        XCTAssertEqual(live.authorizationRejectionCount, 1)
        XCTAssertEqual(live.rebuildCount, 1)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertFalse(microphoneAuthorization.isValid)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        XCTAssertTrue(live.sessionActive)
        XCTAssertFalse(
            live.remoteIOCreated,
            "The hosted deterministic boundary records configuration but creates no AudioUnit."
        )
        XCTAssertFalse(live.inputBusEnabled)
        XCTAssertTrue(live.outputBusEnabled)
        XCTAssertFalse(live.recoveryRequired)
        XCTAssertFalse(live.explicitResumeRequired)
        XCTAssertFalse(live.categoryOptionsAreEmpty)
        XCTAssertTrue(live.categoryOptionsAreMixWithOthers)
        XCTAssertTrue(live.routeSharingPolicyIsDefault)
        XCTAssertTrue(live.hasOutputRoute)
        XCTAssertTrue(live.hostedCallMode)
        XCTAssertTrue(live.hostedCallAuthorizationValid)
        XCTAssertFalse(live.hostedCallRecoveryPending)
        XCTAssertGreaterThan(live.systemAudioGeneration, 0)
        XCTAssertEqual(
            live.hostedCallAuthorizationGeneration,
            live.systemAudioGeneration
        )
        XCTAssertEqual(
            hostedAuthorization.systemAudioGeneration,
            live.systemAudioGeneration
        )
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 2
        )
    }

    func testDuplicateQueuedHostedRequestCoalescesWithoutRetiringInstalledPolicy() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let policyID = UUID()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )
        defer { _ = harness.debugTerminateForTesting() }

        harness.debugMarkInterruptedFailClosedForTesting()
        harness.debugMarkInterruptionEndedFailClosedForTesting()
        harness.queueHostedCallRecovery(authorization: authorization)
        harness.queueHostedCallRecovery(authorization: authorization)

        XCTAssertEqual(harness.queuedOperationCount, 2)
        XCTAssertEqual(harness.diagnostics.requestCount, 2)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let installed = harness.diagnostics
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertEqual(installed.requestCount, 2)
        XCTAssertEqual(installed.authorizationRejectionCount, 0)
        XCTAssertEqual(installed.rebuildCount, 1)
        XCTAssertTrue(installed.hostedCallMode)
        XCTAssertTrue(installed.hostedCallAuthorizationValid)
        XCTAssertFalse(installed.hostedCallRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        let installedGeneration = installed.systemAudioGeneration
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertEqual(harness.queuedOperationCount, 0)

        let coalesced = harness.diagnostics
        XCTAssertEqual(coalesced.requestCount, 2)
        XCTAssertEqual(coalesced.authorizationRejectionCount, 0)
        XCTAssertEqual(coalesced.rebuildCount, 1)
        XCTAssertEqual(coalesced.systemAudioGeneration, installedGeneration)
        XCTAssertTrue(coalesced.hostedCallMode)
        XCTAssertTrue(coalesced.hostedCallAuthorizationValid)
        XCTAssertFalse(coalesced.hostedCallRecoveryPending)
        XCTAssertTrue(coalesced.sessionActive)
        XCTAssertFalse(coalesced.remoteIOCreated)
        XCTAssertFalse(coalesced.inputBusEnabled)
        XCTAssertTrue(coalesced.outputBusEnabled)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
        XCTAssertEqual(
            authorization.systemAudioGeneration,
            coalesced.systemAudioGeneration
        )
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        let differentAuthorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: UUID(),
            origin: .interruption
        )
        harness.queueHostedCallRecovery(authorization: differentAuthorization)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let differentRejected = harness.diagnostics
        XCTAssertEqual(differentRejected.requestCount, 3)
        XCTAssertEqual(differentRejected.authorizationRejectionCount, 1)
        XCTAssertEqual(differentRejected.rebuildCount, 1)
        XCTAssertFalse(differentAuthorization.isValid)
        XCTAssertFalse(differentAuthorization.isRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertTrue(differentRejected.hostedCallMode)
        XCTAssertTrue(differentRejected.hostedCallAuthorizationValid)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )
    }

    func testHostedPolicyRejectsNewMicrophoneAuthorizationWithoutRetiringPlayout() {
        let (harness, hostedAuthorization) = makeLiveHostedCallHarness()
        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        defer { _ = harness.debugTerminateForTesting() }
        let before = harness.diagnostics
        let configurationCount = harness.configurationOperationCount

        XCTAssertFalse(
            harness.setMicrophoneAuthorizationForTesting(
                microphoneAuthorization
            )
        )

        let after = harness.diagnostics
        XCTAssertFalse(microphoneAuthorization.isValid)
        XCTAssertTrue(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(after.requestCount, before.requestCount)
        XCTAssertEqual(
            after.authorizationRejectionCount,
            before.authorizationRejectionCount
        )
        XCTAssertEqual(after.rebuildCount, before.rebuildCount)
        XCTAssertEqual(
            after.unexpectedRecordingRequestCount,
            before.unexpectedRecordingRequestCount + 1
        )
        XCTAssertTrue(after.hostedCallMode)
        XCTAssertTrue(after.hostedCallAuthorizationValid)
        XCTAssertFalse(after.inputBusEnabled)
        XCTAssertTrue(after.outputBusEnabled)
        XCTAssertFalse(harness.debugBeginRealtimeAdmissionForTesting())
        XCTAssertEqual(
            harness.configurationOperationCount,
            configurationCount
        )
        XCTAssertEqual(
            harness.hostedCallPolicyID,
            hostedAuthorization.policyID
        )
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: configurationCount
        )
    }

    func testHostedRecoveryRejectsRevokedStaleMissingRouteAndActivationFailure() {
        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertEqual(harness.queuedOperationCount, 1)

            authorization.revoke()
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 0)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(authorization.systemAudioGeneration, 0)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            let queuedGeneration = harness.diagnostics.systemAudioGeneration
            harness.queueHostedCallRecovery(authorization: authorization)
            harness.debugAdvanceSystemAudioGenerationForTesting()

            XCTAssertGreaterThan(
                harness.diagnostics.systemAudioGeneration,
                queuedGeneration
            )
            XCTAssertTrue(authorization.isValid)
            XCTAssertTrue(authorization.isRecoveryPending)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 0)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertEqual(authorization.systemAudioGeneration, 0)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.debugMarkInterruptionEndedFailClosedForTesting()
            harness.debugSetOutputRouteAvailableForTesting(false)
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 1)
            XCTAssertFalse(rejected.hasOutputRoute)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
            XCTAssertNotEqual(
                authorization.systemAudioGeneration,
                rejected.systemAudioGeneration
            )
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let harness = WebRTCIOSPlayoutRecoveryTestHarness()
            let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
                policyID: UUID(),
                origin: .interruption
            )
            defer { _ = harness.debugTerminateForTesting() }

            harness.debugMarkInterruptedFailClosedForTesting()
            harness.debugMarkInterruptionEndedFailClosedForTesting()
            harness.debugFailNextHostedCallActivationForTesting()
            harness.queueHostedCallRecovery(authorization: authorization)
            XCTAssertTrue(harness.runNextQueuedOperation())

            let rejected = harness.diagnostics
            XCTAssertEqual(rejected.requestCount, 1)
            XCTAssertEqual(rejected.authorizationRejectionCount, 1)
            XCTAssertEqual(rejected.rebuildCount, 1)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            XCTAssertGreaterThan(authorization.systemAudioGeneration, 0)
            XCTAssertNotEqual(
                authorization.systemAudioGeneration,
                rejected.systemAudioGeneration
            )
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }
    }

    func testHostedPolicyRetiresOnRouteLossGenerationAdvanceAndTeardown() {
        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            defer { _ = harness.debugTerminateForTesting() }
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            harness.debugMarkRouteLossForTesting()

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertFalse(retired.hasOutputRoute)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: true
            )
        }

        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            defer { _ = harness.debugTerminateForTesting() }
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            harness.debugAdvanceSystemAudioGenerationForTesting()

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertTrue(retired.hasOutputRoute)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: true,
                explicitResumeRequired: false
            )
        }

        do {
            let (harness, authorization) = makeLiveHostedCallHarness()
            let liveGeneration = harness.diagnostics.systemAudioGeneration

            XCTAssertTrue(harness.debugTerminateForTesting())

            let retired = harness.diagnostics
            XCTAssertEqual(retired.requestCount, 1)
            XCTAssertEqual(retired.authorizationRejectionCount, 0)
            XCTAssertEqual(retired.rebuildCount, 1)
            XCTAssertGreaterThan(retired.systemAudioGeneration, liveGeneration)
            XCTAssertFalse(authorization.isValid)
            XCTAssertFalse(authorization.isRecoveryPending)
            assertQuiescentWithoutHostedCallPolicy(
                harness,
                recoveryRequired: false,
                explicitResumeRequired: false
            )
        }
    }

    func testRevokingLiveHostedAuthorizationSynchronouslyRestoresFailClosedState() {
        let (harness, authorization) = makeLiveHostedCallHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let live = harness.diagnostics

        authorization.revoke()

        let revoked = harness.diagnostics
        XCTAssertFalse(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertGreaterThan(revoked.systemAudioGeneration, live.systemAudioGeneration)
        XCTAssertEqual(revoked.requestCount, live.requestCount)
        XCTAssertEqual(
            revoked.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(revoked.rebuildCount, live.rebuildCount)
        XCTAssertEqual(harness.configurationOperationCount, 1)
        XCTAssertTrue(revoked.hasOutputRoute)
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )
    }

    func testInterruptionEndedRetiresHostedPolicyAndOrdinaryRecoveryRestoresNormalConfiguration() {
        let (harness, hostedAuthorization) = makeLiveHostedCallHarness()
        defer { _ = harness.debugTerminateForTesting() }
        let live = harness.diagnostics
        let hostedConfigurationCount = harness.configurationOperationCount

        harness.debugMarkInterruptionEndedFailClosedForTesting()

        let ended = harness.diagnostics
        XCTAssertFalse(hostedAuthorization.isValid)
        XCTAssertFalse(hostedAuthorization.isRecoveryPending)
        XCTAssertEqual(ended.requestCount, live.requestCount)
        XCTAssertEqual(
            ended.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(ended.rebuildCount, live.rebuildCount)
        XCTAssertEqual(
            harness.configurationOperationCount,
            hostedConfigurationCount
        )
        assertQuiescentWithoutHostedCallPolicy(
            harness,
            recoveryRequired: true,
            explicitResumeRequired: false
        )

        let ordinaryAuthorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: ordinaryAuthorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let normal = harness.diagnostics
        XCTAssertFalse(ordinaryAuthorization.isValid)
        XCTAssertEqual(normal.requestCount, live.requestCount + 1)
        XCTAssertEqual(
            normal.authorizationRejectionCount,
            live.authorizationRejectionCount
        )
        XCTAssertEqual(normal.rebuildCount, live.rebuildCount + 1)
        XCTAssertTrue(normal.sessionActive)
        XCTAssertFalse(
            normal.remoteIOCreated,
            "Simulator recovery records the production operation without creating RemoteIO."
        )
        XCTAssertFalse(normal.inputBusEnabled)
        XCTAssertTrue(normal.outputBusEnabled)
        XCTAssertFalse(normal.recoveryRequired)
        XCTAssertFalse(normal.explicitResumeRequired)
        XCTAssertTrue(normal.categoryOptionsAreEmpty)
        XCTAssertFalse(normal.categoryOptionsAreIPhoneMicrophoneRouting)
        XCTAssertFalse(normal.categoryOptionsAreMixWithOthers)
        XCTAssertFalse(normal.routeSharingPolicyIsDefault)
        XCTAssertTrue(normal.hasOutputRoute)
        XCTAssertFalse(normal.hostedCallMode)
        XCTAssertFalse(normal.hostedCallAuthorizationValid)
        XCTAssertFalse(normal.hostedCallRecoveryPending)
        XCTAssertEqual(normal.hostedCallAuthorizationGeneration, 0)
        XCTAssertNil(harness.hostedCallPolicyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: [],
            expectedOperationCount: hostedConfigurationCount + 1
        )
    }

    func testNativeCountersRemainCumulativeAndCallbackPublishesLast() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.publishCallback(frameCount: 480, status: noErr)
        let firstPrePublication = harness.prePublicationSnapshot
        XCTAssertEqual(firstPrePublication.callbackCount, 0)
        XCTAssertEqual(firstPrePublication.frameCount, 480)
        XCTAssertEqual(firstPrePublication.failureCount, 0)
        XCTAssertEqual(firstPrePublication.lastFrameCount, 480)
        XCTAssertEqual(firstPrePublication.lastStatus, noErr)

        let firstPublished = harness.snapshot
        XCTAssertEqual(firstPublished.callbackCount, 1)
        XCTAssertEqual(firstPublished.frameCount, 480)
        XCTAssertEqual(firstPublished.failureCount, 0)

        harness.markRecoveryBoundary()
        harness.publishCallback(frameCount: 240, status: -50)
        let secondPrePublication = harness.prePublicationSnapshot
        XCTAssertEqual(secondPrePublication.callbackCount, 1)
        XCTAssertEqual(secondPrePublication.frameCount, 720)
        XCTAssertEqual(secondPrePublication.failureCount, 1)
        XCTAssertEqual(secondPrePublication.lastFrameCount, 240)
        XCTAssertEqual(secondPrePublication.lastStatus, -50)

        let secondPublished = harness.snapshot
        XCTAssertEqual(secondPublished.callbackCount, 2)
        XCTAssertEqual(secondPublished.frameCount, 720)
        XCTAssertEqual(secondPublished.failureCount, 1)
    }

    func testProductionPCMAnalyzerDistinguishesStereoContentSilenceAndClipping() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let stereo: [Int16] = [
            1_000, -2_000,
            .max, .min,
            300, 300,
            -400, 500,
        ]

        harness.analyzePCM16(samples: stereo)
        let content = harness.snapshot
        XCTAssertEqual(content.pcmSampleCount, 8)
        XCTAssertEqual(content.pcmNonzeroSampleCount, 8)
        XCTAssertEqual(content.pcmAbsoluteSampleSum, 70_035)
        XCTAssertEqual(content.pcmLeftAbsoluteSampleSum, 34_467)
        XCTAssertEqual(content.pcmRightAbsoluteSampleSum, 35_568)
        XCTAssertEqual(content.pcmStereoDifferenceAbsoluteSampleSum, 69_435)
        XCTAssertEqual(content.pcmClippedSampleCount, 2)
        XCTAssertEqual(content.explicitSilenceCallbackCount, 0)
        XCTAssertEqual(content.nearSilenceCallbackCount, 0)
        XCTAssertEqual(content.currentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(content.maximumConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(content.pcmLeftZeroCrossingCount, 1)
        XCTAssertEqual(content.pcmRightZeroCrossingCount, 1)
        XCTAssertEqual(content.pcmEnvelopeTransitionCount, 0)
        XCTAssertEqual(content.lastCallbackMeanMagnitude, 8_754)
        XCTAssertEqual(content.lastPeakMagnitude, 32_768)

        harness.analyzePCM16(
            samples: [Int16](repeating: 0, count: 8),
            outputIsSilence: true
        )
        let silence = harness.snapshot
        XCTAssertEqual(silence.pcmSampleCount, 16)
        XCTAssertEqual(silence.pcmNonzeroSampleCount, 8)
        XCTAssertEqual(silence.pcmAbsoluteSampleSum, 70_035)
        XCTAssertEqual(silence.pcmLeftAbsoluteSampleSum, 34_467)
        XCTAssertEqual(silence.pcmRightAbsoluteSampleSum, 35_568)
        XCTAssertEqual(silence.pcmStereoDifferenceAbsoluteSampleSum, 69_435)
        XCTAssertEqual(silence.pcmClippedSampleCount, 2)
        XCTAssertEqual(silence.explicitSilenceCallbackCount, 1)
        XCTAssertEqual(silence.nearSilenceCallbackCount, 1)
        XCTAssertEqual(silence.currentConsecutiveNearSilenceFrameCount, 4)
        XCTAssertEqual(silence.maximumConsecutiveNearSilenceFrameCount, 4)
        XCTAssertEqual(silence.pcmLeftZeroCrossingCount, 1)
        XCTAssertEqual(silence.pcmRightZeroCrossingCount, 1)
        XCTAssertEqual(silence.pcmEnvelopeTransitionCount, 0)
        XCTAssertEqual(silence.lastCallbackMeanMagnitude, 0)
        XCTAssertEqual(silence.lastPeakMagnitude, 0)
    }

    func testProductionPCMAnalyzerTracksAndResetsConsecutiveNearSilence() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.analyzePCM16(samples: [Int16](repeating: 0, count: 960))
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 1)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 480)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 480)

        // Fully nonzero dither is still near-silence because its mean magnitude is below 256.
        harness.analyzePCM16(samples: [Int16](repeating: 1, count: 480))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 2)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 720)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        // The deterministic physical tone is comfortably above both density and mean gates.
        harness.analyzePCM16(samples: [Int16](repeating: 2_000, count: 960))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 2)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        // Two loud impulses put mean magnitude above 256 but cannot pass the independent 90%
        // nonzero-density gate.
        var sparseImpulse = [Int16](repeating: 0, count: 240)
        sparseImpulse[0] = .max
        sparseImpulse[1] = .max
        harness.analyzePCM16(samples: sparseImpulse)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 3)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 120)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)

        harness.analyzePCM16(samples: [Int16](repeating: 2_000, count: 240))
        harness.analyzePCM16(
            samples: [Int16](repeating: 0, count: 240),
            outputIsSilence: true
        )
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 4)
        XCTAssertEqual(snapshot.currentConsecutiveNearSilenceFrameCount, 120)
        XCTAssertEqual(snapshot.maximumConsecutiveNearSilenceFrameCount, 720)
    }

    func testProductionPCMAnalyzerEnforcesExactDensityAndMeanMagnitudeBoundaries() {
        let densityHarness = WebRTCIOSPlayoutPublicationTestHarness()
        let exactlyNinetyPercentNonzero =
            [Int16](repeating: 1_000, count: 180) + [Int16](repeating: 0, count: 20)
        densityHarness.analyzePCM16(samples: exactlyNinetyPercentNonzero)
        XCTAssertEqual(densityHarness.snapshot.nearSilenceCallbackCount, 0)

        let eightyNinePercentNonzero =
            [Int16](repeating: 1_000, count: 178) + [Int16](repeating: 0, count: 22)
        densityHarness.analyzePCM16(samples: eightyNinePercentNonzero)
        XCTAssertEqual(densityHarness.snapshot.nearSilenceCallbackCount, 1)

        let magnitudeHarness = WebRTCIOSPlayoutPublicationTestHarness()
        magnitudeHarness.analyzePCM16(samples: [Int16](repeating: 256, count: 200))
        XCTAssertEqual(magnitudeHarness.snapshot.nearSilenceCallbackCount, 0)
        magnitudeHarness.analyzePCM16(samples: [Int16](repeating: 255, count: 200))
        XCTAssertEqual(magnitudeHarness.snapshot.nearSilenceCallbackCount, 1)
    }

    func testProductionPCMAnalyzerIdentifiesIndependent997And1499HertzToneChannels() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let sampleRate = 48_000.0
        let frameCount = 4_800
        var interleaved = [Int16]()
        interleaved.reserveCapacity(frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            interleaved.append(
                Int16((sin(2 * .pi * 997 * time) * 8_000).rounded())
            )
            interleaved.append(
                Int16((sin(2 * .pi * 1_499 * time) * 8_000).rounded())
            )
        }

        harness.analyzePCM16(samples: interleaved)
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmLeftZeroCrossingCount, 199)
        XCTAssertEqual(snapshot.pcmRightZeroCrossingCount, 299)
        XCTAssertEqual(snapshot.nearSilenceCallbackCount, 0)

        // Both generated tones end negative. A positive frame proves signs persist across the
        // callback boundary rather than each buffer being counted independently.
        harness.analyzePCM16(samples: [100, 100])
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmLeftZeroCrossingCount, 200)
        XCTAssertEqual(snapshot.pcmRightZeroCrossingCount, 300)
    }

    func testProductionPCMAnalyzerDetectsCodedBandTransitionsAndRapidGainFlicker() {
        let coded = WebRTCIOSPlayoutPublicationTestHarness()
        let sampleRate = 48_000.0
        let framesPerCallback = 480
        let callbackCount = 200
        for callback in 0..<callbackCount {
            let highBand = (callback / 50).isMultiple(of: 2) == false
            let amplitude = highBand ? 3_000.0 : 9_000.0
            let leftFrequency = highBand ? 8_003.0 : 997.0
            let rightFrequency = highBand ? 11_003.0 : 1_499.0
            var interleaved = [Int16]()
            interleaved.reserveCapacity(framesPerCallback * 2)
            for localFrame in 0..<framesPerCallback {
                let frame = callback * framesPerCallback + localFrame
                let time = Double(frame) / sampleRate
                interleaved.append(
                    Int16((sin(2 * .pi * leftFrequency * time) * amplitude).rounded())
                )
                interleaved.append(
                    Int16((sin(2 * .pi * rightFrequency * time) * amplitude).rounded())
                )
            }
            coded.analyzePCM16(samples: interleaved)
        }
        let codedSnapshot = coded.snapshot
        XCTAssertEqual(codedSnapshot.nearSilenceCallbackCount, 0)
        XCTAssertEqual(codedSnapshot.pcmEnvelopeTransitionCount, 3)
        XCTAssertEqual(codedSnapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(
            codedSnapshot.pcmBoundaryDiscontinuityCallbackCount,
            0,
            "The intentional 500 ms level/frequency transitions must not look like phase resets."
        )
        XCTAssertEqual(codedSnapshot.pcmLeftZeroCrossingCount, 17_999, accuracy: 2)
        XCTAssertEqual(codedSnapshot.pcmRightZeroCrossingCount, 25_003, accuracy: 2)

        let flicker = WebRTCIOSPlayoutPublicationTestHarness()
        for callback in 0..<20 {
            let magnitude: Int16 = callback.isMultiple(of: 2) ? 8_000 : 1_000
            flicker.analyzePCM16(samples: [Int16](repeating: magnitude, count: 960))
        }
        XCTAssertEqual(
            flicker.snapshot.pcmEnvelopeTransitionCount,
            19,
            "Every alternating 10 ms gain step must be machine-visible."
        )

        let boundary = WebRTCIOSPlayoutPublicationTestHarness()
        boundary.analyzePCM16(samples: [Int16](repeating: 2_000, count: 960))
        boundary.analyzePCM16(samples: [Int16](repeating: 2_800, count: 960))
        XCTAssertEqual(
            boundary.snapshot.pcmEnvelopeTransitionCount,
            0,
            "The exact 40% tolerance boundary is not a violation."
        )
        boundary.analyzePCM16(samples: [Int16](repeating: 2_801, count: 960))
        XCTAssertEqual(boundary.snapshot.pcmEnvelopeTransitionCount, 0)
        boundary.analyzePCM16(samples: [Int16](repeating: 1_999, count: 960))
        XCTAssertEqual(boundary.snapshot.pcmEnvelopeTransitionCount, 1)
    }

    func testProductionPCMAnalyzerAcceptsContinuousToneAcrossCallbackBoundaries() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let framesPerCallback = 480

        for callback in 0..<100 {
            harness.analyzePCM16(
                samples: Self.stereoChallengeTone(
                    frames: (callback * framesPerCallback)..<((callback + 1) * framesPerCallback)
                )
            )
        }

        let snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(snapshot.pcmBoundaryDiscontinuityCallbackCount, 0)
    }

    func testProductionPCMAnalyzerCountsRepeatedPhaseResetBlocksCumulatively() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()
        let resetBlock = Self.stereoChallengeTone(frames: 0..<480)

        for _ in 0..<20 {
            harness.analyzePCM16(samples: resetBlock)
        }

        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(
            snapshot.pcmBoundaryDiscontinuityCallbackCount,
            19,
            "Each 10 ms phase reset after the first callback must remain machine-visible."
        )

        // This block is phase-continuous with the immediately preceding reset block. It proves a
        // final healthy callback cannot clear the lifetime-cumulative evidence already observed.
        harness.analyzePCM16(samples: Self.stereoChallengeTone(frames: 480..<960))
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.pcmShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(snapshot.pcmBoundaryDiscontinuityCallbackCount, 19)
    }

    func testProductionPCMAnalyzerCountsShapeMutantsCumulatively() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        let flat = [Int16](repeating: 2_000, count: 960)
        harness.analyzePCM16(samples: flat)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 1)

        var square = [Int16]()
        square.reserveCapacity(960)
        for frame in 0..<480 {
            let sample: Int16 = frame.isMultiple(of: 2) ? 8_000 : -8_000
            square.append(sample)
            square.append(sample)
        }
        harness.analyzePCM16(samples: square)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 2)

        var impulse = [Int16](repeating: 0, count: 960)
        impulse[240] = .max
        impulse[241] = .min
        harness.analyzePCM16(samples: impulse)
        XCTAssertEqual(harness.snapshot.pcmShapeAnomalyCallbackCount, 3)

        harness.analyzePCM16(samples: Self.stereoChallengeTone(frames: 0..<480))
        let finalSnapshot = harness.snapshot
        XCTAssertEqual(
            finalSnapshot.pcmShapeAnomalyCallbackCount,
            3,
            "A final clean callback must not erase prior flat, square, or impulse evidence."
        )
    }

    func testProductionSuccessfulCallbackTimingDetectsOnlyGapsBeyond25Milliseconds() {
        let harness = WebRTCIOSPlayoutPublicationTestHarness()

        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_000_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_010_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_035_000_000)
        var snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 0)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_000)

        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_060_000_001)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 1)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_001)

        // A regressed clock reading is ignored and cannot lower the cadence baseline.
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_050_000_000)
        harness.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 1_070_000_001)
        snapshot = harness.snapshot
        XCTAssertEqual(snapshot.callbackGapViolationCount, 1)
        XCTAssertEqual(snapshot.maximumCallbackGapNanoseconds, 25_000_001)

        let recurring = WebRTCIOSPlayoutPublicationTestHarness()
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_000_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_020_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_050_000_000)
        recurring.recordSuccessfulCallback(atMonotonicTimeNanoseconds: 2_090_000_000)
        XCTAssertEqual(
            recurring.snapshot.callbackGapViolationCount,
            2,
            "Recurring 30 ms and 40 ms disruptions must both be counted; 20 ms remains tolerated."
        )
        XCTAssertEqual(recurring.snapshot.maximumCallbackGapNanoseconds, 40_000_000)
    }

    func testProductionRecoveryPreservesNativeLifetimeCounters() {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        harness.publishCallback(frameCount: 480, status: noErr)
        harness.publishCallback(frameCount: 240, status: -50)

        let beforeRecovery = harness.diagnostics
        XCTAssertEqual(beforeRecovery.playoutCallbackCount, 2)
        XCTAssertEqual(beforeRecovery.playoutFrameCount, 720)
        XCTAssertEqual(beforeRecovery.playoutFailureCount, 1)
        XCTAssertEqual(beforeRecovery.lastPlayoutFrameCount, 240)
        XCTAssertEqual(beforeRecovery.lastPlayoutStatus, -50)

        let authorization = WebRTCIOSPlayoutRecoveryAuthorization()
        harness.queueRecovery(authorization: authorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())
        XCTAssertFalse(authorization.isValid)

        let afterRecovery = harness.diagnostics
        XCTAssertEqual(afterRecovery.rebuildCount, 1)
        XCTAssertEqual(afterRecovery.playoutCallbackCount, 2)
        XCTAssertEqual(afterRecovery.playoutFrameCount, 720)
        XCTAssertEqual(afterRecovery.playoutFailureCount, 1)
        XCTAssertEqual(afterRecovery.lastPlayoutFrameCount, 240)
        XCTAssertEqual(afterRecovery.lastPlayoutStatus, -50)
    }

    func testActivationOpensOnlyTheManualWebRTCGate() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()
        try playback.recover()

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 2)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)
    }

    func testManualDisabledPreparationNeverActivatesOrConfiguresAudioSession() {
        let native = WebRTCAudioSessionStub()
        native.isAudioEnabled = true
        let playback = WebRTCAudioPlaybackSession(session: native)

        playback.prepareManualAudioDisabled()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 1)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)
    }

    func testHostedCallInterruptionPreparationPreservesButNeverOpensTheManualGate() {
        let native = WebRTCAudioSessionStub()
        native.isAudioEnabled = true
        let playback = WebRTCAudioPlaybackSession(session: native)

        playback.prepareForHostedCallInterruption()
        playback.prepareForHostedCallInterruption()

        XCTAssertTrue(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 2)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)

        playback.prepareManualAudioDisabled()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 3)

        // Hosted-capable preparation preserves the current gate; it must not reopen a gate that a
        // route, media-services, failure, or terminal boundary already closed.
        playback.prepareForHostedCallInterruption()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertEqual(native.prepareCount, 4)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
        XCTAssertEqual(native.lockCount, 0)
        XCTAssertEqual(native.unlockCount, 0)
    }

    func testDeactivationClosesTheGateWithoutCompetingForAVAudioSessionOwnership() throws {
        let native = WebRTCAudioSessionStub()
        let playback = WebRTCAudioPlaybackSession(session: native)

        try playback.activate()
        playback.deactivate()
        playback.deactivate()

        XCTAssertFalse(native.isAudioEnabled)
        XCTAssertTrue(native.configuredModes.isEmpty)
        XCTAssertTrue(native.setActiveValues.isEmpty)
    }

    func testDeclaredMediaConfigurationMatchesCustomDeviceContract() {
        let configuration = WebRTCAudioPlaybackSession.playbackConfiguration()

        XCTAssertEqual(configuration.category, AVAudioSession.Category.playback.rawValue)
        XCTAssertEqual(configuration.mode, AVAudioSession.Mode.default.rawValue)
        XCTAssertEqual(configuration.categoryOptions, [])
        XCTAssertFalse(configuration.categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.ioBufferDuration, 0.010)
        XCTAssertEqual(configuration.outputNumberOfChannels, 2)
    }

    func testViewerBeginsWithNoMicrophoneOrAudioSessionLease() async throws {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )

        let initialDiagnostics = await viewer.iOSPlayoutDiagnostics()
        let value = try XCTUnwrap(initialDiagnostics)
        XCTAssertFalse(value.playing)
        XCTAssertFalse(value.sessionActive)
        XCTAssertFalse(value.ownsSessionActivation)
        XCTAssertFalse(value.remoteIOCreated)
        XCTAssertFalse(value.inputBusEnabled)
        XCTAssertFalse(value.outputBusEnabled)
        XCTAssertFalse(value.recoveryRequired)
        XCTAssertFalse(value.explicitResumeRequired)
        XCTAssertEqual(value.failureCode, 0)
        XCTAssertEqual(value.lastLifecycleStatus, noErr)
        XCTAssertNil(value.failureMessage)
        XCTAssertEqual(value.playoutCallbackGapViolationCount, 0)
        XCTAssertEqual(value.playoutMaximumCallbackGapNanoseconds, 0)
        XCTAssertEqual(value.playoutNearSilenceCallbackCount, 0)
        XCTAssertEqual(value.playoutCurrentConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(value.playoutMaximumConsecutiveNearSilenceFrameCount, 0)
        XCTAssertEqual(value.playoutPCMLeftZeroCrossingCount, 0)
        XCTAssertEqual(value.playoutPCMRightZeroCrossingCount, 0)
        XCTAssertEqual(value.playoutPCMEnvelopeTransitionCount, 0)
        XCTAssertEqual(value.playoutPCMShapeAnomalyCallbackCount, 0)
        XCTAssertEqual(value.playoutPCMBoundaryDiscontinuityCallbackCount, 0)
        XCTAssertEqual(value.playoutLastCallbackMeanMagnitude, 0)
        XCTAssertEqual(value.unexpectedRecordingRequestCount, 0)

        await viewer.close()
    }

    func testPublicMicrophonePolicyRejectsUnboundCapabilitiesBeforeNativeEffect()
        async throws
    {
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .viewer,
                iceServers: []
            )
        )
        let nativePolicyCallCount = LockedInteger()
        await viewer.debugInstallIPhoneMicrophonePolicyApplier { _ in
            nativePolicyCallCount.increment()
            return true
        }

        let microphoneAuthorization = WebRTCIOSMicrophoneAuthorization()
        do {
            try await viewer.enableIPhoneMicrophone(
                authorization: microphoneAuthorization
            )
            XCTFail("An unbound public microphone authorization must fail closed.")
        } catch {
            XCTAssertFalse(microphoneAuthorization.isValid)
            XCTAssertNil(
                microphoneAuthorization.stagedTransactionTagGeneration
            )
        }

        let outputOnlyToken = WebRTCIOSOutputOnlyMicrophoneToken(
            ownerEpoch: UUID(),
            lifecycleGeneration: 1,
            target: WebRTCIOSOutputOnlyMicrophoneTarget(
                category: AVAudioSession.Category.playback.rawValue,
                mode: AVAudioSession.Mode.default.rawValue
            )
        )
        let outputOnlyApplied = await viewer.disableIPhoneMicrophone(
            outputOnlyToken: outputOnlyToken
        )

        XCTAssertFalse(outputOnlyApplied)
        XCTAssertEqual(outputOnlyToken.state, .revoked)
        XCTAssertNil(outputOnlyToken.stagedTransactionTagGeneration)
        XCTAssertEqual(nativePolicyCallCount.value, 0)
        let closeResult = await viewer.close()
        XCTAssertTrue(closeResult)
    }

    /// Only the viewer touches hardware. The second peer negotiates normally but its injected
    /// device has no audio I/O; this proves native capture and sender RTP, not a Mac consumer.
    func testPhysicalSoleViewerRemoteIOCapturesMicrophoneAcrossPublicAdmissionCycles() async throws {
        executionTimeAllowance = 90
        #if !DEBUG
        throw XCTSkip("The no-hardware host fixture is DEBUG-only.")
        #elseif targetEnvironment(simulator)
        throw XCTSkip("Real RemoteIO microphone capture requires the authorized spare physical phone.")
        #else
        var result: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "inertAppRoot": OpensteamerAppRootMode.isPhysicalUpdateValidationHost,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "<missing>",
            "storedPCMBufferCount": 0, "macConsumptionProved": false,
            "networkTraversalProved": false, "productionViewModelExercised": false,
            "completedCycles": 0,
        ]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-sole-viewer-remoteio-public-microphone-cycles"
                attachment.lifetime = .keepAlways
                add(attachment)
            } else { XCTFail("Could not encode sole-viewer microphone evidence.") }
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw PhysicalInputTapProbeError.requirement(message) }
        }
        try require(OpensteamerAppRootMode.isPhysicalUpdateValidationHost, "The actual app root must be inert.")
        try require(Bundle.main.bundleIdentifier == "org.example.AudioStreamer.dev", "The distinct spare development app is required.")
        try require(!Self.physicalMediaPlayerPolicyExperimentWasInvoked, "Select one experiment per fresh host process.")
        Self.physicalMediaPlayerPolicyExperimentWasInvoked = true
        let clock = ContinuousClock()
        let activeDeadline = clock.now.advanced(by: .seconds(2))
        while UIApplication.shared.applicationState != .active, clock.now < activeDeadline {
            try await clock.sleep(until: min(activeDeadline, clock.now.advanced(by: .milliseconds(25))))
        }
        result["applicationStateRaw"] = UIApplication.shared.applicationState.rawValue
        result["permissionRaw"] = AVAudioApplication.shared.recordPermission.rawValue
        try require(UIApplication.shared.applicationState == .active, "The real test app did not become active within two seconds.")
        try require(AVAudioApplication.shared.recordPermission == .granted, "Permission must already be granted; this test never requests it.")
        let calls = CXCallObserver()
        try require(calls.calls.allSatisfy(\.hasEnded), "A nonended call forbids microphone testing.")
        let session = AVAudioSession.sharedInstance()
        let initialCategory = session.category
        let initialMode = session.mode
        let initialOptions = session.categoryOptions
        let initialPolicy = session.routeSharingPolicy
        func tuple() -> [String: Any] {
            ["category": session.category.rawValue, "mode": session.mode.rawValue,
             "optionsRaw": session.categoryOptions.rawValue, "policyRaw": session.routeSharingPolicy.rawValue]
        }
        result["beforeRegistration"] = tuple()
        try require(initialCategory == .soloAmbient && initialMode == .default
            && initialOptions.isEmpty && initialPolicy == .default, "A supported untouched initial tuple is required.")
        let quiescence = WebRTCIOSPlayoutRecoveryTestHarness()
        defer { _ = quiescence.debugTerminateForTesting() }
        try require(quiescence.debugRealSessionIsQuiescentForTesting(), "Another native audio owner is present.")

        let privacy = PhysicalMicrophoneAuthorizationFence()
        calls.setDelegate(privacy, queue: .main)
        let interruptions = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { @Sendable notification in
            if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue { privacy.close() }
        }
        let inactive = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: nil
        ) { @Sendable _ in privacy.close() }
        let playback = WebRTCAudioPlaybackSession()
        let noHardware = PhysicalNoHardwareAudioDevice()
        let forwardingFailures = LockedFailures()
        var host: WebRTCPeer?
        var viewer: WebRTCPeer?
        var forwarders: [Task<Void, Never>] = []
        var authorityJournal: PhysicalMicrophoneAuthorityJournal?
        var authorityEvents: Task<Void, Never>?
        var installedTarget: (MPRemoteCommand, Any)?
        var manualGateOpened = false
        var phase = "register actual media command"
        let ownerEpoch = UUID()
        func requirePrivacy() throws {
            try require(privacy.isOpen && UIApplication.shared.applicationState == .active
                && calls.calls.allSatisfy(\.hasEnded), "App, call, or interruption privacy boundary ended the test.")
        }
        func scalars(_ stats: WebRTCIPhoneMicrophoneSenderStatistics) -> [String: Any] {
            let sender = stats.sender
            return ["recordingGeneration": sender.recordingGeneration,
                    "approvedRecordingGeneration": sender.approvedRecordingGeneration,
                    "policyGeneration": sender.microphonePolicyGeneration,
                    "renderSuccessCallbacks": sender.deliveryCallbackCount,
                    "renderedFrames": sender.deliveredFrameCount,
                    "realtimeAdmissions": sender.realtimeAdmissionCount,
                    "packetsSent": stats.packetsSent, "bytesSent": stats.bytesSent,
                    "sourceLinked": stats.sourceReportWasLinked,
                    "sourceEnergy": stats.totalAudioEnergy.map { $0 as Any } ?? NSNull(),
                    "sourceDuration": stats.totalSamplesDuration.map { $0 as Any } ?? NSNull(),
                    "rawProcessingLive": sender.rawProcessingIsLive,
                    "usesRemoteIO": sender.usesRemoteIO,
                    "builtInInput": sender.captureRouteIsBuiltInMicrophone,
                    "captureRouteProofGeneration": sender.captureRouteProofGeneration,
                    "senderAdmitted": sender.senderIsAdmitted,
                    "sharingDefault": sender.routeSharingPolicyIsDefault,
                    "sharingLongForm": sender.routeSharingPolicyIsLongFormAudio,
                    "ordinaryProfileMatches": sender.ordinaryRawMicrophonePolicyMatches]
        }
        do {
            let play = MPRemoteCommandCenter.shared().playCommand
            installedTarget = (play, play.addTarget { @Sendable _ in .commandFailed })
            try await Task.sleep(for: .milliseconds(100))
            result["afterRegistration100Milliseconds"] = tuple()
            try requirePrivacy()
            try require(quiescence.debugRealSessionIsQuiescentForTesting(), "Native ownership changed before constructing the viewer.")
            try playback.activate()
            manualGateOpened = true
            let fixtureHost = try WebRTCPeer.makeNoHardwareHostForTesting(
                configuration: .init(role: .host, iceServers: []), audioDevice: noHardware
            )
            host = fixtureHost
            let physicalViewer = try WebRTCPeer(configuration: .init(role: .viewer, iceServers: []))
            viewer = physicalViewer
            let authority = try PhysicalMicrophoneAuthorityJournal(
                binding: XCTUnwrap(physicalViewer.iOSAudioTransactionDeviceBinding), privacy: privacy
            )
            authorityJournal = authority
            // Attach before negotiation: even an early output-only observation must be recorded
            // and reduced, not silently discarded before the first microphone operation.
            authorityEvents = Task {
                for await event in physicalViewer.iOSAudioTransactionEvents {
                    guard !Task.isCancelled else { return }
                    authority.consume(event)
                }
            }
            try require(fixtureHost.externalAudioCapturer == nil, "The fixture host must not expose an audio source capturer.")
            forwarders.append(Task {
                for await event in fixtureHost.events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .outboundSignal(let payload):
                        do { try await physicalViewer.receive(payload) }
                        catch { forwardingFailures.append(error) }
                    case .remoteAudioTrack(let track): track.setEnabled(false)
                    default: break
                    }
                }
            })
            forwarders.append(Task {
                for await event in physicalViewer.events {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .outboundSignal(let payload):
                        do { try await fixtureHost.receive(payload) }
                        catch { forwardingFailures.append(error) }
                    case .remoteAudioTrack(let track):
                        track.setEnabled(privacy.isOpen && track.logicalLane == .systemAudio)
                    default: break
                    }
                }
            })
            phase = "normal full peer negotiation and output startup"
            try await fixtureHost.start()
            let readyDeadline = clock.now.advanced(by: .seconds(8))
            var outputReady = false
            while clock.now < readyDeadline {
                try requirePrivacy()
                if let state = await physicalViewer.iPhoneMicrophoneSenderState(),
                   let output = await physicalViewer.iOSPlayoutDiagnostics(),
                   state.transportIsHealthy, state.senderOwnsMID, state.senderOwnsLocalTrack,
                   output.playing, output.remoteIOCreated, output.playoutCallbackCount > 0,
                   !output.inputBusEnabled, output.routeSharingPolicyIsLongFormAudio,
                   !output.routeSharingPolicyIsDefault, output.failureCode == 0 {
                    outputReady = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(outputReady, "Normal negotiated viewer output did not start; no host audio or admission bypass is permitted.")
            let deviceBinding = physicalViewer.iOSAudioTransactionDeviceBinding
            var previousRecordingGeneration: UInt64 = 0
            func readStatistics() async throws -> WebRTCIPhoneMicrophoneSenderStatistics {
                let deadline = clock.now.advanced(by: .seconds(3))
                repeat {
                    try requirePrivacy()
                    if let stats = await physicalViewer.iPhoneMicrophoneSenderStatistics() { return stats }
                    try await Task.sleep(for: .milliseconds(50))
                } while clock.now < deadline
                throw PhysicalInputTapProbeError.requirement("Exact production microphone sender statistics did not become available.")
            }
            for cycle in 1...3 {
                phase = "public microphone admission cycle \(cycle)"
                try requirePrivacy()
                let microphoneOperation = try authority.arm(inputRequired: true)
                let authorization = WebRTCIOSMicrophoneAuthorization(transaction: microphoneOperation.nativeContext)
                try require(privacy.install(authorization), "Privacy changed before microphone admission.")
                try await physicalViewer.enableIPhoneMicrophone(authorization: authorization)
                try requirePrivacy()
                var previous = try await readStatistics()
                try require(previous.sender.recordingGeneration > previousRecordingGeneration,
                            "Re-admission must own a fresh native recording generation.")
                previousRecordingGeneration = previous.sender.recordingGeneration
                result["cycle\(cycle)Baseline"] = scalars(previous)
                for window in 1...2 {
                    try await Task.sleep(for: .milliseconds(500))
                    let current = try await readStatistics()
                    result["cycle\(cycle)Window\(window)"] = scalars(current)
                    let old = previous.sender
                    let new = current.sender
                    try require(new.recordingGeneration == old.recordingGeneration
                        && new.approvedRecordingGeneration == new.recordingGeneration
                        && new.microphonePolicyGeneration == old.microphonePolicyGeneration
                        && new.rawProcessingIsLive && new.usesRemoteIO && new.captureRouteIsBuiltInMicrophone
                        && new.senderIsAdmitted && new.authorizationIsCurrent && new.authorizationIsValid
                        && new.ordinaryRawMicrophonePolicyMatches
                        && !new.routeSharingPolicyIsDefault && new.routeSharingPolicyIsLongFormAudio,
                        "The exact authorized raw microphone/effective-policy1 proof changed.")
                    try require(new.deliveryCallbackCount > old.deliveryCallbackCount
                        && new.deliveredFrameCount > old.deliveredFrameCount
                        && current.packetsSent > previous.packetsSent && current.bytesSent > previous.bytesSent
                        && current.sourceReportWasLinked,
                        "Real AudioUnitRender-success counters and the exact sender's RTP must advance together.")
                    let oldEnergy = try XCTUnwrap(previous.totalAudioEnergy)
                    let energy = try XCTUnwrap(current.totalAudioEnergy)
                    let oldDuration = try XCTUnwrap(previous.totalSamplesDuration)
                    let duration = try XCTUnwrap(current.totalSamplesDuration)
                    try require(oldEnergy.isFinite && energy.isFinite && energy > oldEnergy
                        && oldDuration.isFinite && duration.isFinite && duration > oldDuration,
                        "Linked raw microphone source energy and duration must advance; clocks alone are insufficient.")
                    previous = current
                }
                try await authority.retire(
                    microphoneOperation, tagGeneration: XCTUnwrap(authorization.stagedTransactionTagGeneration),
                    peer: physicalViewer
                )
                phase = "public output-only disable cycle \(cycle)"
                let outputOperation = try authority.arm(inputRequired: false)
                let context = outputOperation.nativeContext
                let token = WebRTCIOSOutputOnlyMicrophoneToken(
                    operationID: context.operationID, ownerEpoch: ownerEpoch,
                    lifecycleGeneration: UInt64(cycle),
                    target: .init(category: AVAudioSession.Category.playback.rawValue,
                                  mode: AVAudioSession.Mode.default.rawValue), transaction: context
                )
                let disabled = await physicalViewer.disableIPhoneMicrophone(
                    authorization: authorization, outputOnlyToken: token
                )
                result["cycle\(cycle)DisableSucceeded"] = disabled
                result["cycle\(cycle)DisableTokenState"] = token.state.rawValue
                try require(disabled && token.state == .succeeded && !authorization.isValid,
                            "The exact one-shot output-only operation did not finish.")
                try await Task.sleep(for: .milliseconds(100))
                let beforeDisabledState = await physicalViewer.iPhoneMicrophoneSenderState()
                let stopped = try XCTUnwrap(beforeDisabledState)
                try await Task.sleep(for: .milliseconds(200))
                let afterDisabledState = await physicalViewer.iPhoneMicrophoneSenderState()
                let stillStopped = try XCTUnwrap(afterDisabledState)
                try require(!stillStopped.inputBusEnabled && !stillStopped.senderIsAdmitted
                    && !stillStopped.nativeAuthorizationGateIsOpen
                    && stillStopped.routeSharingPolicyIsLongFormAudio && !stillStopped.routeSharingPolicyIsDefault
                    && stopped.deliveryCallbackCount == stillStopped.deliveryCallbackCount
                    && stopped.deliveredFrameCount == stillStopped.deliveredFrameCount,
                    "Microphone delivery advanced after output-only disable.")
                try require(physicalViewer.iOSAudioTransactionDeviceBinding == deviceBinding,
                            "The test must reuse the same production native device.")
                result["cycle\(cycle)DisabledRenderCallbacks"] = stillStopped.deliveryCallbackCount
                result["cycle\(cycle)DisabledRenderedFrames"] = stillStopped.deliveredFrameCount
                try await authority.retire(
                    outputOperation, tagGeneration: XCTUnwrap(token.stagedTransactionTagGeneration),
                    peer: physicalViewer
                )
                result["completedCycles"] = cycle
            }
            try require(forwardingFailures.values.isEmpty, "Peer signaling forwarding failed.")
        } catch {
            result["failurePhase"] = phase
            result["failureErrorCode"] = (error as NSError).code
            result["failureErrorDomain"] = (error as NSError).domain
            XCTFail("Sole-viewer microphone proof failed during \(phase): \(error)")
        }

        privacy.close()
        for task in forwarders { task.cancel() }
        for task in forwarders { await task.value }
        let viewerClosed = await viewer?.close() ?? true
        let hostClosed = await host?.close() ?? true
        if let authorityEvents { await authorityEvents.value }
        authorityEvents = nil
        forwarders.removeAll()
        viewer = nil
        host = nil
        result["viewerClosed"] = viewerClosed
        result["hostClosed"] = hostClosed
        result["realCategoryReceiptAuthority"] = authorityJournal?.scalars
        if manualGateOpened { playback.deactivate() }
        result["manualGateOpenCount"] = manualGateOpened ? 1 : 0
        result["manualGateCloseCount"] = manualGateOpened ? 1 : 0
        calls.setDelegate(nil, queue: nil)
        NotificationCenter.default.removeObserver(interruptions)
        NotificationCenter.default.removeObserver(inactive)
        if let installedTarget { installedTarget.0.removeTarget(installedTarget.1) }
        result["mediaCommandRemovalCount"] = installedTarget == nil ? 0 : 1
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { result["removalWaitCancelled"] = true }
        let isQuiescent = quiescence.debugRealSessionIsQuiescentForTesting()
        result["nativeQuiescentAfterClose"] = isQuiescent
        result["noHardwareHost"] = noHardware.snapshot.scalars
        if viewerClosed && hostClosed && isQuiescent {
            result["capturedInitialRestoreAttemptCount"] = 1
            do {
                try session.setCategory(initialCategory, mode: initialMode,
                                        policy: initialPolicy, options: initialOptions)
                try await Task.sleep(for: .milliseconds(100))
                result["afterCapturedInitialRestore"] = tuple()
                XCTAssertEqual(session.category, initialCategory)
                XCTAssertEqual(session.mode, initialMode)
                XCTAssertEqual(session.categoryOptions, initialOptions)
                XCTAssertEqual(session.routeSharingPolicy, initialPolicy)
            } catch { XCTFail("The single owned-baseline cleanup failed: \(error)") }
        } else { XCTFail("Native teardown did not prove quiescence; no cleanup setter is permitted.") }
        XCTAssertEqual(result["completedCycles"] as? Int, 3)
        XCTAssertEqual(noHardware.snapshot.initializations, 1)
        XCTAssertEqual(noHardware.snapshot.terminations, 1)
        XCTAssertFalse(noHardware.snapshot.delegateBound)
        XCTAssertFalse(noHardware.snapshot.wrongWorker)
        XCTAssertEqual(authorityJournal?.failureCount, 0)
        XCTAssertEqual(authorityJournal?.garbageCollectionCount, 6)
        XCTAssertTrue(authorityJournal?.deviceRetired == true)
        #endif
    }

    /// Runtime—not a direct protocol invocation—proof that a real peer connection initializes
    /// and clocks the injected output-only RemoteIO device on physical iOS hardware.
    func testPeerUsesStereoRemoteIOAndReceivesNativePlayoutCallbacks() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip(
            "iOS 26.5 Simulator has no registered RemoteIO component factory and aborts "
                + "AudioComponentInstanceNew after its CoreAudio RPC timeout; run on iPhone."
        )
        #else
        let playback = WebRTCAudioPlaybackSession()
        try playback.activate()
        defer { playback.deactivate() }

        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [])
        )
        let viewer = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [])
        )
        let forwardingFailures = LockedFailures()
        let remoteAudioExpectationGate = LockedOnce()
        let remoteAudio = expectation(description: "viewer received native remote audio track")

        let hostForwarder = Task {
            for await event in host.events {
                guard !Task.isCancelled else { return }
                if case .outboundSignal(let payload) = event {
                    do { try await viewer.receive(payload) }
                    catch { forwardingFailures.append(error) }
                }
            }
        }
        let viewerForwarder = Task {
            for await event in viewer.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .outboundSignal(let payload):
                    do { try await host.receive(payload) }
                    catch { forwardingFailures.append(error) }
                case .remoteAudioTrack(let track):
                    track.setEnabled(true)
                    if remoteAudioExpectationGate.claim() {
                        remoteAudio.fulfill()
                    }
                default:
                    break
                }
            }
        }

        try await host.start()
        await fulfillment(of: [remoteAudio], timeout: 10)

        for _ in 0..<200 where !(await host.isTransportHealthyForCapture()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let authorization = WebRTCAudioAuthorization()
        try await host.enableSystemAudioIfTransportHealthy(authorization: authorization)

        var diagnostics = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<500 where (diagnostics?.playoutCallbackCount ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
            diagnostics = await viewer.iOSPlayoutDiagnostics()
        }

        let value = try XCTUnwrap(diagnostics)
        XCTAssertTrue(value.initialized)
        XCTAssertTrue(value.playoutInitialized)
        XCTAssertTrue(value.playing)
        XCTAssertTrue(value.sessionActive)
        XCTAssertTrue(value.ownsSessionActivation)
        XCTAssertTrue(value.remoteIOCreated)
        XCTAssertFalse(value.inputBusEnabled, "The custom viewer device must never open a mic bus.")
        XCTAssertTrue(value.outputBusEnabled)
        XCTAssertFalse(value.recoveryRequired)
        XCTAssertFalse(value.explicitResumeRequired)
        XCTAssertTrue(value.categoryIsMediaPlayback)
        XCTAssertTrue(value.modeIsDefault)
        XCTAssertFalse(AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(value.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(
            value.outputIOBufferDuration,
            AVAudioSession.sharedInstance().ioBufferDuration,
            accuracy: 0.000_001
        )
        XCTAssertEqual(value.outputChannelCount, 2)
        XCTAssertEqual(value.audioUnitSubType, kAudioUnitSubType_RemoteIO)
        XCTAssertEqual(value.failureCode, 0)
        XCTAssertEqual(value.lastLifecycleStatus, noErr)
        XCTAssertNil(value.failureMessage)
        XCTAssertGreaterThan(value.playoutCallbackCount, 0)
        XCTAssertGreaterThan(value.playoutFrameCount, 0)
        XCTAssertEqual(value.playoutFailureCount, 0)
        XCTAssertEqual(value.unexpectedRecordingRequestCount, 0)
        XCTAssertEqual(value.lastPlayoutStatus, noErr)
        XCTAssertTrue(forwardingFailures.values.isEmpty, forwardingFailures.values.joined(separator: "\n"))

        // A normal app-lifecycle recovery signal must be idempotent while this exact device owns
        // healthy playout. In particular, it must not tear down RemoteIO and produce an audible gap.
        let healthyRecoveryTransaction = WebRTCIOSAudioTransactionContext(
            operationID: try XCTUnwrap(
                UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")
            ),
            authorityEpoch: 1,
            operationRevision: 1
        )
        let healthyRecoveryAuthorization =
            WebRTCIOSPlayoutRecoveryAuthorization(
                transaction: healthyRecoveryTransaction
            )
        XCTAssertTrue(
            viewer.stageIOSPlayoutRecoveryTransaction(
                authorization: healthyRecoveryAuthorization,
                inputRequired: false
            )
        )
        XCTAssertNotNil(
            healthyRecoveryAuthorization.stagedTransactionTagGeneration
        )
        let healthyRecoveryWasRequested =
            await viewer.requestIOSPlayoutRecovery(
                authorization: healthyRecoveryAuthorization
            )
        XCTAssertTrue(healthyRecoveryWasRequested)
        try await Task.sleep(for: .milliseconds(50))
        let healthyRecoveryReceipt = try XCTUnwrap(
            healthyRecoveryAuthorization.terminalReceipt
        )
        XCTAssertEqual(
            healthyRecoveryReceipt.transaction,
            healthyRecoveryTransaction
        )
        XCTAssertEqual(healthyRecoveryReceipt.outcome, .accepted)
        XCTAssertTrue(
            healthyRecoveryReceipt.policyMatchesRequestedTarget
        )
        XCTAssertEqual(
            healthyRecoveryReceipt.authorizationGeneration,
            healthyRecoveryReceipt.terminalGeneration
        )
        let healthyRecoveryDiagnostics = await viewer.iOSPlayoutDiagnostics()
        let afterHealthyRecoveryRequest = try XCTUnwrap(healthyRecoveryDiagnostics)
        XCTAssertTrue(afterHealthyRecoveryRequest.playing)
        XCTAssertTrue(afterHealthyRecoveryRequest.sessionActive)
        XCTAssertTrue(afterHealthyRecoveryRequest.ownsSessionActivation)
        XCTAssertFalse(afterHealthyRecoveryRequest.recoveryRequired)
        XCTAssertFalse(afterHealthyRecoveryRequest.explicitResumeRequired)
        XCTAssertEqual(afterHealthyRecoveryRequest.failureCode, 0)
        XCTAssertGreaterThan(
            afterHealthyRecoveryRequest.playoutCallbackCount,
            value.playoutCallbackCount
        )

        // The old-output-device path deliberately fails closed so a removed headset cannot leak
        // remote audio through the speaker. Only an explicit recovery request may resume it.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
        var routeFailure = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<200 where !Self.hasCompletedFailClosedRouteTransition(routeFailure) {
            try await Task.sleep(for: .milliseconds(10))
            routeFailure = await viewer.iOSPlayoutDiagnostics()
        }
        let failedClosed = try XCTUnwrap(routeFailure)
        XCTAssertFalse(failedClosed.playing)
        XCTAssertFalse(failedClosed.sessionActive)
        XCTAssertFalse(failedClosed.ownsSessionActivation)
        XCTAssertFalse(failedClosed.remoteIOCreated)
        XCTAssertTrue(failedClosed.recoveryRequired)
        XCTAssertTrue(failedClosed.explicitResumeRequired)
        XCTAssertEqual(failedClosed.failureCode, 19)
        XCTAssertNotNil(failedClosed.failureMessage)

        let routeRecoveryTransaction = WebRTCIOSAudioTransactionContext(
            operationID: try XCTUnwrap(
                UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F")
            ),
            authorityEpoch: 1,
            operationRevision: 2
        )
        let routeRecoveryAuthorization =
            WebRTCIOSPlayoutRecoveryAuthorization(
                transaction: routeRecoveryTransaction
            )
        XCTAssertTrue(
            viewer.stageIOSPlayoutRecoveryTransaction(
                authorization: routeRecoveryAuthorization,
                inputRequired: false
            )
        )
        XCTAssertNotNil(
            routeRecoveryAuthorization.stagedTransactionTagGeneration
        )
        let routeRecoveryWasRequested =
            await viewer.requestIOSPlayoutRecovery(
                authorization: routeRecoveryAuthorization
            )
        XCTAssertTrue(routeRecoveryWasRequested)
        var recovered = await viewer.iOSPlayoutDiagnostics()
        for _ in 0..<500 where recovered?.playing != true {
            try await Task.sleep(for: .milliseconds(10))
            recovered = await viewer.iOSPlayoutDiagnostics()
        }
        let recoveredValue = try XCTUnwrap(recovered)
        XCTAssertTrue(recoveredValue.playing)
        XCTAssertTrue(recoveredValue.sessionActive)
        XCTAssertTrue(recoveredValue.ownsSessionActivation)
        XCTAssertFalse(recoveredValue.recoveryRequired)
        XCTAssertFalse(recoveredValue.explicitResumeRequired)
        XCTAssertEqual(recoveredValue.failureCode, 0)
        XCTAssertNil(recoveredValue.failureMessage)
        let routeRecoveryReceipt = try XCTUnwrap(
            routeRecoveryAuthorization.terminalReceipt
        )
        XCTAssertEqual(
            routeRecoveryReceipt.transaction,
            routeRecoveryTransaction
        )
        XCTAssertEqual(routeRecoveryReceipt.outcome, .accepted)
        XCTAssertTrue(routeRecoveryReceipt.policyMatchesRequestedTarget)
        XCTAssertEqual(
            routeRecoveryReceipt.authorizationGeneration,
            routeRecoveryReceipt.terminalGeneration
        )

        await host.close()
        await viewer.close()
        hostForwarder.cancel()
        viewerForwarder.cancel()
        #endif
    }

    // MARK: - Native diagnostics fixtures

    private func makeLiveHostedCallHarness(
        policyID: UUID = UUID()
    ) -> (
        harness: WebRTCIOSPlayoutRecoveryTestHarness,
        authorization: WebRTCIOSHostedCallPlayoutAuthorization
    ) {
        let harness = WebRTCIOSPlayoutRecoveryTestHarness()
        let authorization = WebRTCIOSHostedCallPlayoutAuthorization(
            policyID: policyID,
            origin: .interruption
        )

        harness.debugMarkInterruptedFailClosedForTesting()
        harness.debugMarkInterruptionEndedFailClosedForTesting()
        harness.queueHostedCallRecovery(authorization: authorization)
        XCTAssertEqual(harness.queuedOperationCount, 1)
        XCTAssertTrue(harness.runNextQueuedOperation())

        let live = harness.diagnostics
        XCTAssertEqual(live.requestCount, 1)
        XCTAssertEqual(live.authorizationRejectionCount, 0)
        XCTAssertEqual(live.rebuildCount, 1)
        XCTAssertTrue(live.sessionActive)
        XCTAssertFalse(
            live.remoteIOCreated,
            "The deterministic harness is not a hardware RemoteIO oracle."
        )
        XCTAssertFalse(live.inputBusEnabled)
        XCTAssertTrue(live.outputBusEnabled)
        XCTAssertTrue(live.hostedCallMode)
        XCTAssertTrue(live.hostedCallAuthorizationValid)
        XCTAssertFalse(live.hostedCallRecoveryPending)
        XCTAssertTrue(authorization.isValid)
        XCTAssertFalse(authorization.isRecoveryPending)
        XCTAssertEqual(harness.hostedCallPolicyID, policyID)
        assertLastRecordedAudioConfiguration(
            harness,
            options: .mixWithOthers,
            expectedOperationCount: 1
        )

        return (harness, authorization)
    }

    private func assertQuiescentWithoutHostedCallPolicy(
        _ harness: WebRTCIOSPlayoutRecoveryTestHarness,
        recoveryRequired: Bool,
        explicitResumeRequired: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let diagnostics = harness.diagnostics

        XCTAssertFalse(diagnostics.sessionActive, file: file, line: line)
        XCTAssertFalse(diagnostics.remoteIOCreated, file: file, line: line)
        XCTAssertFalse(diagnostics.inputBusEnabled, file: file, line: line)
        XCTAssertFalse(diagnostics.outputBusEnabled, file: file, line: line)
        XCTAssertEqual(
            diagnostics.recoveryRequired,
            recoveryRequired,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.explicitResumeRequired,
            explicitResumeRequired,
            file: file,
            line: line
        )
        XCTAssertFalse(diagnostics.hostedCallMode, file: file, line: line)
        XCTAssertFalse(
            diagnostics.hostedCallAuthorizationValid,
            file: file,
            line: line
        )
        XCTAssertFalse(
            diagnostics.hostedCallRecoveryPending,
            file: file,
            line: line
        )
        XCTAssertEqual(
            diagnostics.hostedCallAuthorizationGeneration,
            0,
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            diagnostics.systemAudioGeneration,
            0,
            file: file,
            line: line
        )
        XCTAssertNil(harness.hostedCallPolicyID, file: file, line: line)
    }

    private func assertLastRecordedAudioConfiguration(
        _ harness: WebRTCIOSPlayoutRecoveryTestHarness,
        options: AVAudioSession.CategoryOptions,
        expectedOperationCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            harness.configurationOperationCount,
            expectedOperationCount,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredCategory,
            AVAudioSession.Category.playback.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredMode,
            AVAudioSession.Mode.default.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredRouteSharingPolicy,
            Int((options == .mixWithOthers ? AVAudioSession.RouteSharingPolicy.default : .longFormAudio).rawValue),
            file: file,
            line: line
        )
        XCTAssertEqual(
            harness.lastConfiguredCategoryOptions,
            UInt(options.rawValue),
            file: file,
            line: line
        )
        XCTAssertFalse(
            harness.lastConfiguredInputBusEnabled,
            file: file,
            line: line
        )
        XCTAssertTrue(
            harness.lastConfiguredOutputBusEnabled,
            file: file,
            line: line
        )

        let format = harness.lastConfiguredOutputStreamFormat
        XCTAssertEqual(
            format.mSampleRate,
            48_000,
            accuracy: 0.001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            format.mFormatID,
            kAudioFormatLinearPCM,
            file: file,
            line: line
        )
        XCTAssertEqual(
            format.mFormatFlags,
            kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            file: file,
            line: line
        )
        XCTAssertEqual(format.mBytesPerPacket, 4, file: file, line: line)
        XCTAssertEqual(format.mFramesPerPacket, 1, file: file, line: line)
        XCTAssertEqual(format.mBytesPerFrame, 4, file: file, line: line)
        XCTAssertEqual(format.mChannelsPerFrame, 2, file: file, line: line)
        XCTAssertEqual(format.mBitsPerChannel, 16, file: file, line: line)
        XCTAssertEqual(format.mReserved, 0, file: file, line: line)
    }

    private static func hasCompletedFailClosedRouteTransition(
        _ diagnostics: WebRTCIOSPlayoutDiagnostics?
    ) -> Bool {
        guard let diagnostics else { return false }
        return diagnostics.explicitResumeRequired
            && diagnostics.recoveryRequired
            && !diagnostics.playing
            && !diagnostics.sessionActive
            && !diagnostics.ownsSessionActivation
            && !diagnostics.remoteIOCreated
    }

    private static func stereoChallengeTone(frames: Range<Int>) -> [Int16] {
        let sampleRate = 48_000.0
        var samples = [Int16]()
        samples.reserveCapacity(frames.count * 2)
        for frame in frames {
            let time = Double(frame) / sampleRate
            samples.append(
                Int16((sin(2 * .pi * 997 * time) * 9_000).rounded())
            )
            samples.append(
                Int16((sin(2 * .pi * 1_499 * time) * 9_000).rounded())
            )
        }
        return samples
    }
}

// MARK: - Thread-safe test probes

/// One-second physical characterization retains only scalars, never tap buffers or PCM copies.
private final class PhysicalInputTapJournal: @unchecked Sendable {
    struct Snapshot: Sendable {
        var callbacks: UInt64 = 0
        var frames: UInt64 = 0
        var finiteSamples: UInt64 = 0
        var nonzeroSamples: UInt64 = 0
        var nonfiniteSamples: UInt64 = 0
        var formatErrors: UInt64 = 0
        var timestampErrors: UInt64 = 0
        var energy: Double = 0
        var peak: Double = 0
        var firstSampleTime: Int64?
        var lastSampleTime: Int64?
        var privacyBoundaryObserved = false

        var scalars: [String: Any] {
            [
                "callbacks": callbacks, "frames": frames,
                "finiteSamples": finiteSamples, "nonzeroSamples": nonzeroSamples,
                "nonfiniteSamples": nonfiniteSamples, "formatErrors": formatErrors,
                "timestampErrors": timestampErrors, "energy": energy, "peak": peak,
                "firstSampleTime": firstSampleTime.map { $0 as Any } ?? NSNull(),
                "lastSampleTime": lastSampleTime.map { $0 as Any } ?? NSNull(),
                "privacyBoundaryObserved": privacyBoundaryObserved,
            ]
        }

        func advanced(since previous: Snapshot) -> Bool {
            callbacks > previous.callbacks && frames > previous.frames
                && finiteSamples > previous.finiteSamples && nonzeroSamples > previous.nonzeroSamples
                && energy.isFinite && energy > previous.energy && peak.isFinite && peak > 0
                && nonfiniteSamples == 0 && formatErrors == 0 && timestampErrors == 0
                && !privacyBoundaryObserved
                && lastSampleTime.map { last in
                    previous.lastSampleTime.map { last > $0 }
                        ?? firstSampleTime.map { last > $0 } ?? false
                } == true
        }
    }

    private let lock = NSLock()
    private var value = Snapshot()
    private let sampleRate: Double
    private let channels: AVAudioChannelCount

    init(sampleRate: Double, channels: AVAudioChannelCount) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func closeForPrivacyBoundary() {
        lock.lock()
        value.privacyBoundaryObserved = true
        lock.unlock()
    }

    func observe(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !value.privacyBoundaryObserved else { return }
        value.callbacks += 1
        value.frames += UInt64(buffer.frameLength)
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.sampleRate == sampleRate,
              buffer.format.channelCount == channels,
              let samples = buffer.floatChannelData else {
            value.formatErrors += 1
            return
        }
        if when.isSampleTimeValid {
            if let previous = value.lastSampleTime, when.sampleTime <= previous {
                value.timestampErrors += 1
            }
            if value.firstSampleTime == nil { value.firstSampleTime = when.sampleTime }
            value.lastSampleTime = when.sampleTime
        } else {
            value.timestampErrors += 1
        }
        for frame in 0..<Int(buffer.frameLength) {
            for channel in 0..<Int(channels) {
                let sample = Double(buffer.format.isInterleaved
                    ? samples[0][frame * Int(channels) + channel]
                    : samples[channel][frame])
                guard sample.isFinite else {
                    value.nonfiniteSamples += 1
                    continue
                }
                value.finiteSamples += 1
                if sample != 0 { value.nonzeroSamples += 1 }
                value.energy += sample * sample
                value.peak = max(value.peak, abs(sample))
            }
        }
    }
}

/// Only aggregate ended/nonended status affects the capture gate; no call identity is retained.
private final class PhysicalInputTapCallFence: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    let journal: PhysicalInputTapJournal

    init(journal: PhysicalInputTapJournal) { self.journal = journal }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasEnded { journal.closeForPrivacyBoundary() }
    }
}

private enum PhysicalInputTapProbeError: Error {
    case requirement(String)
}

/// One-shot claim primitive used to assert native callback serialization under contention.
private final class LockedOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var wasClaimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !wasClaimed else { return false }
            wasClaimed = true
            return true
        }
    }
}

/// Real reducer integration for the physical fixture, without claiming the app's full lifecycle.
/// Actual measurements stay independent: no synthetic native ack or accepted proof is supplied.
@MainActor
private final class PhysicalMicrophoneAuthorityJournal {
    private let authority = AudioTransactionAuthority()
    private let privacy: PhysicalMicrophoneAuthorizationFence
    private var currentTarget: AudioTransactionTarget?
    private var observations: [[String: Any]] = []
    private(set) var failureCount = 0
    private var unownedFailedClosedCount = 0
    private(set) var garbageCollectionCount = 0
    private(set) var deviceRetired = false
    private var retiredOperation: AudioTransactionOperationReceipt?

    init(binding: WebRTCIOSAudioTransactionDeviceBinding, privacy: PhysicalMicrophoneAuthorizationFence) throws {
        self.privacy = privacy
        let snapshot = try XCTUnwrap(authority.snapshot)
        guard case .deviceBound = authority.bindDevice(binding, expectedReducerRevision: snapshot.reducerRevision) else {
            throw PhysicalInputTapProbeError.requirement("The real Rust authority did not bind the viewer device.")
        }
    }

    var scalars: [String: Any] {
        ["observationCount": observations.count, "observations": observations,
         "failureCount": failureCount, "garbageCollectionCount": garbageCollectionCount,
         "unownedFailedClosedCount": unownedFailedClosedCount,
         "deviceRetired": deviceRetired, "syntheticAcknowledgementCount": 0,
         "syntheticAcceptedProofCount": 0]
    }

    func arm(inputRequired: Bool) throws -> AudioTransactionOperationReceipt {
        guard failureCount == 0, privacy.isOpen else {
            throw PhysicalInputTapProbeError.requirement("A prior real category receipt or privacy boundary failed closed.")
        }
        let snapshot = try XCTUnwrap(authority.snapshot)
        let target = AudioTransactionTarget(
            category: inputRequired ? AVAudioSession.Category.playAndRecord.rawValue : AVAudioSession.Category.playback.rawValue,
            mode: AVAudioSession.Mode.default.rawValue,
            categoryOptionsRawValue: inputRequired ? 40 : 0,
            routeSharingPolicyRawValue: inputRequired ? 0 : 1, inputRequired: inputRequired
        )
        guard snapshot.currentOperation == nil, snapshot.tombstoneCount == 0,
              case let .armed(operation, _, _) = authority.arm(
                operationID: UUID(), target: target, expectedReducerRevision: snapshot.reducerRevision,
                observationHead: snapshot.lastObservationSequence
              ) else {
            throw PhysicalInputTapProbeError.requirement("The real Rust authority refused the next physical audio transaction.")
        }
        currentTarget = target
        return operation
    }

    func consume(_ event: WebRTCIOSAudioTransactionEvent) {
        let ownedOperationBefore = authority.snapshot?.currentOperation
        let decision: AudioTransactionDecision
        switch event {
        case .observation(let receipt):
            let before = authority.snapshot
            decision = authority.observe(receipt)
            var row: [String: Any] = [
                "sequence": receipt.notificationSequence, "requestedPolicy": receipt.expectedRouteSharingPolicyRawValue,
                "observedPolicy": receipt.observedRouteSharingPolicyRawValue, "inputRequired": receipt.inputRequired,
                "profileMatches": receipt.policyTupleIsExact, "transactionEvidenceExact": receipt.transactionEvidenceIsExact,
                "hadCurrentOperation": before?.currentOperation != nil,
                "decision": Self.kind(decision), "disposition": String(describing: receipt.disposition),
            ]
            if case .failedClosed = decision {
                row["failureCode"] = AudioTransactionAuthority.categoryObservationFailureCode(
                    receipt: receipt, snapshot: before, target: currentTarget
                )
            }
            guard observations.count < 128 else { failClosed(); return }
            observations.append(row)
        case .drain(let receipt): decision = authority.collectRetired(receipt)
        case .deviceTeardown(let receipt):
            guard let snapshot = authority.snapshot else { failClosed(); return }
            decision = authority.retireDevice(receipt, expectedReducerRevision: snapshot.reducerRevision)
        }
        switch decision {
        case .failedClosed(let operation):
            // Like the production controller, there is no current transition to fail at
            // untouched startup or after completed retirement. Retain these real receipts
            // without granting authority; any failure of an owned operation still revokes.
            if ownedOperationBefore != nil || operation != nil {
                failClosed()
            } else {
                unownedFailedClosedCount += 1
            }
        case .rejected, .runtimeFailure: failClosed()
        case .garbageCollected(_, let operation):
            garbageCollectionCount += 1
            if retiredOperation == operation { retiredOperation = nil; currentTarget = nil }
        case .deviceRetired(let snapshot, _):
            deviceRetired = snapshot.currentOperation == nil && snapshot.tombstoneCount == 0
                && snapshot.deviceInstanceGeneration == 0 && snapshot.observationRegistrationGeneration == 0
        default: break
        }
    }

    func retire(_ operation: AudioTransactionOperationReceipt, tagGeneration: UInt64, peer: WebRTCPeer) async throws {
        let snapshot = try XCTUnwrap(authority.snapshot)
        guard failureCount == 0, snapshot.currentOperation == operation, tagGeneration != 0,
              case .boundaryApplied = authority.applyBoundary(
                expectedReducerRevision: snapshot.reducerRevision, observationHead: snapshot.lastObservationSequence
              ) else {
            throw PhysicalInputTapProbeError.requirement("The real audio operation could not enter its retirement boundary.")
        }
        retiredOperation = operation
        guard peer.requestIOSAudioCategoryDrain(transaction: operation.nativeContext, tagGeneration: tagGeneration) else {
            throw PhysicalInputTapProbeError.requirement("The exact native audio tag did not accept its drain request.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while retiredOperation != nil, failureCount == 0, clock.now < deadline {
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(25))))
        }
        guard failureCount == 0, retiredOperation == nil, authority.snapshot?.tombstoneCount == 0 else {
            throw PhysicalInputTapProbeError.requirement("The real native drain did not garbage-collect its exact Rust tombstone.")
        }
    }

    private func failClosed() { failureCount += 1; privacy.close() }

    private static func kind(_ decision: AudioTransactionDecision) -> String {
        switch decision {
        case .observationAccepted: "observationAccepted"
        case .failedClosed: "failedClosed"
        case .ignored: "ignored"
        case .rejected: "rejected"
        case .runtimeFailure: "runtimeFailure"
        default: "other"
        }
    }
}

/// The test's current microphone carrier is revoked at the first call, interruption, or inactive
/// boundary. No identity/handle is retained, and an ended event never reopens this test lifetime.
private final class PhysicalMicrophoneAuthorizationFence: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    private var authorization: WebRTCIOSMicrophoneAuthorization?

    var isOpen: Bool { lock.withLock { open } }

    func install(_ value: WebRTCIOSMicrophoneAuthorization) -> Bool {
        let accepted = lock.withLock {
            guard open else { return false }
            authorization = value
            return true
        }
        if !accepted { value.revoke() }
        return accepted
    }

    func close() {
        let retired = lock.withLock {
            open = false
            let value = authorization
            authorization = nil
            return value
        }
        retired?.revoke()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if !call.hasEnded { close() }
    }
}

/// Negotiation-only fixture device. These flags describe ADM requests, never hardware state.
/// There is no session, engine, AudioUnit, timer, renderer, input producer, PCM or audio callback.
private final class PhysicalNoHardwareAudioDevice: NSObject, LKRTCAudioDevice, Sendable {
    struct Snapshot: Sendable {
        var initialized = false
        var playoutInitialized = false
        var playing = false
        var delegateBound = false
        var initializations = 0
        var terminations = 0
        var playoutStarts = 0
        var recordingInitializations = 0
        var recordingStarts = 0
        var wrongWorker = false
        var scalars: [String: Any] {
            ["initialized": initialized, "playoutInitialized": playoutInitialized,
             "playing": playing, "delegateBound": delegateBound,
             "initializations": initializations, "terminations": terminations,
             "playoutStarts": playoutStarts, "recordingInitializations": recordingInitializations,
             "recordingStarts": recordingStarts, "wrongWorker": wrongWorker,
             "hardwareAPICalls": 0, "getPlayoutDataCalls": 0, "deliverRecordedDataCalls": 0]
        }
    }
    private struct State {
        var delegate: (any LKRTCAudioDeviceDelegate)?
        var snapshot = Snapshot()
        var worker: mach_port_t?
        mutating func checkWorker() {
            snapshot.wrongWorker = snapshot.wrongWorker
                || worker != pthread_mach_thread_np(pthread_self())
        }
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var snapshot: Snapshot { state.withLock { $0.snapshot } }
    var deviceInputSampleRate: Double { 48_000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { 48_000 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 2 }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { snapshot.initialized }
    var isPlayoutInitialized: Bool { snapshot.playoutInitialized }
    var isPlaying: Bool { snapshot.playing }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }

    func initialize(with delegate: any LKRTCAudioDeviceDelegate) -> Bool {
        state.withLockUnchecked {
            $0.worker = pthread_mach_thread_np(pthread_self())
            $0.delegate = delegate
            $0.snapshot.delegateBound = true
            $0.snapshot.initializations += 1
            $0.snapshot.initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.delegate = nil
            $0.snapshot.terminations += 1
            $0.snapshot.delegateBound = false
            $0.snapshot.initialized = false
            $0.snapshot.playoutInitialized = false
            $0.snapshot.playing = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.playoutInitialized = true }
        return true
    }

    func startPlayout() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.snapshot.playoutStarts += 1
            $0.snapshot.playing = $0.snapshot.playoutInitialized
            return $0.snapshot.playing
        }
    }

    func stopPlayout() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.playing = false }
        return true
    }

    func initializeRecording() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.recordingInitializations += 1 }
        return false
    }

    func startRecording() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.recordingStarts += 1 }
        return false
    }

    func stopRecording() -> Bool {
        state.withLock { $0.checkWorker() }
        return true
    }
}

// Only this test device is fake. Its delegate, ADM, audio buffer and transport come from the
// packaged dynamic framework. No method creates an audio session, AudioUnit, track or socket.
private final class DynamicFrameworkRetryDevice: NSObject, LKRTCAudioDevice, Sendable {
    struct Snapshot: Sendable {
        var initialized = false
        var playoutInitialized = false
        var playing = false
        var delegateBound = false
        var initializations = 0
        var terminations = 0
        var playoutInitializations = 0
        var playoutStarts = 0
        var recordingInitializations = 0
        var recordingStarts = 0
        var recordingStops = 0
        var wrongWorker = false
    }

    struct PCMObservation: Sendable {
        let status: OSStatus
        let flags: AudioUnitRenderActionFlags
        let allZero: Bool
    }

    struct Proof: Sendable {
        var supportsRetry = false
        var imagePath: String?
        var accepted: [Bool] = []
        var snapshots: [Snapshot] = []
        var inactivePCM: PCMObservation?
        var activePCM: PCMObservation?
    }

    private struct State {
        var delegate: (any LKRTCAudioDeviceDelegate)?
        var snapshot = Snapshot()
        var worker: mach_port_t?

        mutating func checkWorker() {
            snapshot.wrongWorker = snapshot.wrongWorker
                || worker != pthread_mach_thread_np(pthread_self())
        }
    }

    // Every mutable value is lock-owned. A copied delegate is used only to dispatch onto its
    // worker; no lock is held while framework code can reenter this device.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    var snapshot: Snapshot { state.withLock { $0.snapshot } }
    var deviceInputSampleRate: Double { 48_000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { 48_000 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 2 }
    var outputLatency: TimeInterval { 0 }
    var isInitialized: Bool { snapshot.initialized }
    var isPlayoutInitialized: Bool { snapshot.playoutInitialized }
    var isPlaying: Bool { snapshot.playing }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }

    func initialize(with delegate: any LKRTCAudioDeviceDelegate) -> Bool {
        state.withLockUnchecked {
            $0.worker = pthread_mach_thread_np(pthread_self())
            $0.delegate = delegate
            $0.snapshot.delegateBound = true
            $0.snapshot.initializations += 1
            $0.snapshot.initialized = true
        }
        return true
    }

    func terminateDevice() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.delegate = nil
            $0.snapshot.delegateBound = false
            $0.snapshot.terminations += 1
            $0.snapshot.initialized = false
            $0.snapshot.playoutInitialized = false
            $0.snapshot.playing = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.snapshot.playoutInitializations += 1
            $0.snapshot.playoutInitialized = $0.snapshot.playoutInitializations > 1
            return $0.snapshot.playoutInitialized
        }
    }

    func startPlayout() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.snapshot.playoutStarts += 1
            $0.snapshot.playing = $0.snapshot.playoutInitialized
            return $0.snapshot.playing
        }
    }

    func stopPlayout() -> Bool {
        state.withLock {
            $0.checkWorker()
            $0.snapshot.playing = false
        }
        return true
    }

    func initializeRecording() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.recordingInitializations += 1 }
        return false
    }

    func startRecording() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.recordingStarts += 1 }
        return false
    }

    func stopRecording() -> Bool {
        state.withLock { $0.checkWorker(); $0.snapshot.recordingStops += 1 }
        return true
    }

    func exerciseRetry() -> Proof? {
        guard let delegate = state.withLockUnchecked({ $0.delegate }) else { return nil }
        let result = OSAllocatedUnfairLock(initialState: Proof?.none)
        delegate.dispatchSync { [self] in
            guard let current = state.withLockUnchecked({ $0.delegate }) else { return }
            var proof = Proof()
            let selector = NSSelectorFromString("retryPlayoutForAudioDevice:")
            proof.supportsRetry = current.responds(to: selector)
            guard proof.supportsRetry,
                  let implementation = class_getMethodImplementation(object_getClass(current), selector)
            else {
                let incomplete = proof
                result.withLock { $0 = incomplete }
                return
            }
            var image = Dl_info()
            let address = unsafeBitCast(implementation, to: UnsafeRawPointer.self)
            if dladdr(address, &image) != 0, let path = image.dli_fname {
                proof.imagePath = String(cString: path)
            }
            for attempt in 0..<3 {
                proof.accepted.append(current.retryPlayout?(for: self) ?? false)
                proof.snapshots.append(snapshot)
                if attempt == 0 { proof.inactivePCM = Self.readPCM(current) }
                if attempt == 1 { proof.activePCM = Self.readPCM(current) }
            }
            let completed = proof
            result.withLock { $0 = completed }
        }
        return result.withLock { $0 }
    }

    private static func readPCM(_ delegate: any LKRTCAudioDeviceDelegate) -> PCMObservation {
        var samples = [Int16](repeating: 123, count: 480 * 2)
        var flags: AudioUnitRenderActionFlags = []
        var timestamp = AudioTimeStamp()
        let status = samples.withUnsafeMutableBytes { bytes in
            var data = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress
            ))
            return delegate.getPlayoutData(&flags, &timestamp, 0, 480, &data)
        }
        return PCMObservation(status: status, flags: flags, allZero: samples.allSatisfy { $0 == 0 })
    }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ error: any Error) {
        lock.withLock { storage.append(String(describing: error)) }
    }
}

private final class LockedInteger: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

@MainActor
private final class WebRTCAudioSessionStub: WebRTCAudioSessionControlling {
    var isActive = false
    var isAudioEnabled = false
    private(set) var configuredModes: [String] = []
    private(set) var setActiveValues: [Bool] = []
    private(set) var prepareCount = 0
    private(set) var lockCount = 0
    private(set) var unlockCount = 0

    func prepareForManualAudio() { prepareCount += 1 }
    func lockForConfiguration() { lockCount += 1 }
    func unlockForConfiguration() { unlockCount += 1 }
    func configurePlayback(mode: AVAudioSession.Mode) throws {
        configuredModes.append(mode.rawValue)
    }
    func setActive(_ active: Bool) throws {
        setActiveValues.append(active)
        isActive = active
    }
}
