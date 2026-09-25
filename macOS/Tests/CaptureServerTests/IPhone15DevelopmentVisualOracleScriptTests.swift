import Foundation
import XCTest

/// Static safety contract for the dedicated iPhone 15 development visual-oracle runner.
final class IPhone15DevelopmentVisualOracleScriptTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var source: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "iOS/opensteamer/scripts/validate-iphone15-dev-screen-visual-oracle.sh"
                ),
                encoding: .utf8
            )
        }
    }

    private var uiTestSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "iOS/opensteamer/UITests/IPhone15SecondaryViewerDevelopmentPhysicalUITests.swift"
                ),
                encoding: .utf8
            )
        }
    }

    private var unlockAcknowledgementSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "iOS/opensteamer/scripts/ack-iphone15-dev-screen-visual-oracle-unlock.sh"
                ),
                encoding: .utf8
            )
        }
    }

    private var powerAssertionSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "iOS/opensteamer/scripts/iphone15-dev-power-assertion.py"
                ),
                encoding: .utf8
            )
        }
    }

    private var runner: URL {
        repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/validate-iphone15-dev-screen-visual-oracle.sh"
        )
    }

    func testRunnerBuildsCurrentSourcesBeforePublishingUnlockGate() throws {
        let source = try source
        let build = try XCTUnwrap(
            source.range(of: "\nbuild_current_development_test_products\n")
        )
        let seal = try XCTUnwrap(source.range(of: "\nprepare_signed_products\n"))
        let lockedIdentity = try XCTUnwrap(
            source.range(of: "\ncapture_device_identity before-unlock any\n")
        )
        let gate = try XCTUnwrap(
            source.range(
                of: "\nwait_for_exact_device_unlocked_state_acknowledgement\n"
            )
        )
        let install = try XCTUnwrap(source.range(of: "\nSTAGE=dev-app-install\n"))

        XCTAssertLessThan(build.lowerBound, seal.lowerBound)
        XCTAssertLessThan(seal.lowerBound, lockedIdentity.lowerBound)
        XCTAssertLessThan(lockedIdentity.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, install.lowerBound)
        XCTAssertTrue(source.contains("xcodebuild build-for-testing \\\n"))
        XCTAssertTrue(source.contains("-destination 'generic/platform=iOS'"))
        XCTAssertTrue(source.contains("clean_development_test_cache_with_xcode"))
        XCTAssertTrue(source.contains("verify_prepared_products_unchanged after-unlock"))
        XCTAssertTrue(
            source.contains(
                "readonly DEVELOPMENT_RENDEZVOUS_URL='wss://" +
                    "audiostreamer-rendezvous.elaminahmed03.workers.dev'"
            )
        )
        XCTAssertTrue(source.contains("plutil -extract OpensteamerRendezvousURL raw"))
        XCTAssertTrue(
            source.contains(
                "OPENSTEAMER_RENDEZVOUS_URL=\"$DEVELOPMENT_RENDEZVOUS_URL\""
            )
        )
        XCTAssertTrue(
            source.contains(
                "== \"$DEVELOPMENT_RENDEZVOUS_URL\""
            )
        )
        XCTAssertFalse(source.contains("already-built development test products"))
    }

    func testReleaseSealedLiveHostIdentityRejectsBeforeAndRechecksAfterChallenge() throws {
        let source = try source
        let before = try XCTUnwrap(
            source.range(of: "\nverify_sealed_host_identity before-challenge\n")
        )
        let challenge = try XCTUnwrap(
            source.range(of: "\nSTAGE=challenge\n", range: before.upperBound..<source.endIndex)
        )
        let after = try XCTUnwrap(
            source.range(
                of: "\nverify_sealed_host_identity after-challenge\n",
                range: challenge.upperBound..<source.endIndex
            )
        )

        XCTAssertLessThan(before.lowerBound, challenge.lowerBound)
        XCTAssertLessThan(challenge.lowerBound, after.lowerBound)
        for required in [
            "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST",
            "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH",
            "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256",
            "verify-sealed-live-mac-host-identity.sh",
            "\"$HOST_PID\" \"$HOST_EXECUTABLE\" \"$HOST_MEDIA_FRAMEWORK_EXECUTABLE\"",
            "installed_bundle_verified=true",
            "cmp -s \"$HOST_IDENTITY_SEALED_BASELINE\" \"$snapshot\"",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
    }

    func testEveryHostManagementChildIsBracketedBySealAndRejectsReplacement() throws {
        let source = try source
        let wrapperStart = try XCTUnwrap(
            source.range(of: "\nfunction run_sealed_host_management_child() {\n")
        )
        let wrapperEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction host_elapsed_seconds() {\n",
                range: wrapperStart.upperBound..<source.endIndex
            )
        )
        let wrapper = String(source[wrapperStart.lowerBound..<wrapperEnd.lowerBound])
        let before = try XCTUnwrap(
            wrapper.range(of: "verify_sealed_host_identity \"${prefix}-client-before\"")
        )
        let execute = try XCTUnwrap(
            wrapper.range(of: "elif \"$HOST_EXECUTABLE\" \"$@\"")
        )
        let after = try XCTUnwrap(
            wrapper.range(
                of: "verify_sealed_host_identity \"${prefix}-client-after\"",
                range: execute.upperBound..<wrapper.endIndex
            )
        )
        XCTAssertLessThan(before.lowerBound, execute.lowerBound)
        XCTAssertLessThan(execute.lowerBound, after.lowerBound)
        for callSite in [
            "run_sealed_host_management_child \\\n      \"${prefix}-secondary-manager\"",
            "run_sealed_host_management_child invitation-mint",
            "run_sealed_host_management_child \\\n      secondary-generation-stop",
        ] {
            XCTAssertTrue(source.contains(callSite), callSite)
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sealed-management-child-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let expected = root.appendingPathComponent("expected.zsh")
        let executable = root.appendingPathComponent("management-client.zsh")
        let replacement = root.appendingPathComponent("replacement.zsh")
        let marker = root.appendingPathComponent("executed.marker")
        let stdout = root.appendingPathComponent("child.stdout")
        let stderr = root.appendingPathComponent("child.stderr")
        let expectedSource = """
        #!/bin/zsh
        print -r -- expected > "$TEST_MARKER"
        if [[ "$TEST_REPLACE_DURING_CHILD" == 1 ]]; then
          /bin/cp "$TEST_REPLACEMENT" "${0}.replacement"
          /bin/chmod 755 "${0}.replacement"
          /bin/mv "${0}.replacement" "$0"
        fi

        """
        let replacementSource = "#!/bin/zsh\nprint -r -- replacement > \"$TEST_MARKER\"\n"
        try expectedSource.write(to: expected, atomically: true, encoding: .utf8)
        try replacementSource.write(to: replacement, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: expected.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)

        let harness = """
        set -euo pipefail
        HOST_EXECUTABLE="$TEST_EXECUTABLE"
        EXPECTED_STUB="$TEST_EXPECTED"
        function fail() { print -u2 -- "$1"; exit 97 }
        function require_same_host() { : }
        function verify_sealed_host_identity() {
          /usr/bin/cmp -s "$HOST_EXECUTABLE" "$EXPECTED_STUB" \
            || fail "sealed management client changed at $1"
        }
        \(wrapper)
        run_sealed_host_management_child fixture "$TEST_STDOUT" "$TEST_STDERR" 0
        """
        for replacementTiming in ["none", "before", "during"] {
            try? fileManager.removeItem(at: executable)
            try? fileManager.removeItem(at: marker)
            try fileManager.copyItem(
                at: replacementTiming == "before" ? replacement : expected,
                to: executable
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
            let process = Process()
            let processError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TEST_EXECUTABLE": executable.path,
                "TEST_EXPECTED": expected.path,
                "TEST_MARKER": marker.path,
                "TEST_REPLACEMENT": replacement.path,
                "TEST_REPLACE_DURING_CHILD": replacementTiming == "during" ? "1" : "0",
                "TEST_STDOUT": stdout.path,
                "TEST_STDERR": stderr.path,
            ]
            process.standardError = processError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: processError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                replacementTiming == "none" ? 0 : 97,
                "replacementTiming=\(replacementTiming): \(errorText)"
            )
            XCTAssertEqual(
                fileManager.fileExists(atPath: marker.path),
                replacementTiming != "before"
            )
        }
    }

    func testUnlockRendezvousIsPrivateNonceBoundAndIndependentlyRechecked() throws {
        let source = try source
        let acknowledgement = try unlockAcknowledgementSource
        let publish = try XCTUnwrap(source.range(of: "\n  publish_unlock_request\n"))
        let validate = try XCTUnwrap(source.range(of: "\n      validate_unlock_ack \\\n"))
        let controllerRelease = try XCTUnwrap(
            source.range(of: "\n      require_no_unlock_controller\n")
        )
        let identity = try XCTUnwrap(
            source.range(of: "\n      capture_device_identity after-unlock unlocked\n")
        )

        XCTAssertLessThan(publish.lowerBound, validate.lowerBound)
        XCTAssertLessThan(validate.lowerBound, controllerRelease.lowerBound)
        XCTAssertLessThan(controllerRelease.lowerBound, identity.lowerBound)
        XCTAssertTrue(source.contains("opensteamer.iphone15-dev-unlock-request.v1"))
        XCTAssertTrue(source.contains("opensteamer.iphone15-dev-unlock-ack.v1"))
        XCTAssertTrue(source.contains(".runNonce == $nonce"))
        XCTAssertTrue(source.contains(".runnerPid == $pid"))
        XCTAssertTrue(source.contains("age <= UNLOCK_ACK_MAX_AGE_SECONDS"))
        XCTAssertTrue(source.contains("write_run_status armed"))
        XCTAssertTrue(source.contains("readonly UNLOCK_GATE_TIMEOUT_SECONDS=1800"))
        XCTAssertTrue(source.contains("runnerProcessStart:$runnerProcessStart"))
        XCTAssertTrue(source.contains("updatedAtEpoch:$updatedAtEpoch"))
        XCTAssertFalse(source.contains("UNLOCK_GATE_TIMEOUT_SECONDS=604800"))
        XCTAssertFalse(source.contains("OPENSTEAMER_SKIP"))
        XCTAssertFalse(source.contains("codex.iphone-usb-unlock"))
        XCTAssertFalse(source.contains("unlock_saved_once"))

        for exactValue in [
            "10B6E5EE-D3B9-5334-99C1-EA12EFA34447",
            "00008120-0000242E3E32201E",
            "org.example.AudioStreamer.dev",
        ] {
            XCTAssertTrue(acknowledgement.contains(exactValue), exactValue)
        }
        XCTAssertTrue(acknowledgement.contains("device info details --device \"$DEVICE_ID\""))
        XCTAssertTrue(acknowledgement.contains("device info lockState --device \"$DEVICE_ID\""))
        XCTAssertTrue(acknowledgement.contains(".result.passcodeRequired == false"))
        XCTAssertTrue(
            acknowledgement.contains("matchingUnlockControllerAbsent:true")
        )
        XCTAssertFalse(acknowledgement.contains("unlockControllerReleased"))
        XCTAssertFalse(acknowledgement.contains("screenshot-verified"))
        XCTAssertFalse(source.contains("awaiting-screenshot-verified-unlock"))
        XCTAssertTrue(acknowledgement.contains("require_runner_lock_held"))
        XCTAssertTrue(acknowledgement.contains("require_runner_lock_metadata"))
        XCTAssertTrue(
            acknowledgement.contains(
                "opensteamer.iphone15-dev-screen-visual-oracle-lock.v1"
            )
        )
        XCTAssertTrue(acknowledgement.contains(".updatedAtEpoch"))
        XCTAssertTrue(acknowledgement.contains("runnerProcessStart"))
        XCTAssertTrue(acknowledgement.contains("request_sha256"))
        XCTAssertTrue(acknowledgement.contains("/bin/mv -n \"$temporary_ack\" \"$ack_path\""))
        XCTAssertFalse(acknowledgement.contains("find-generic-password"))
        XCTAssertFalse(acknowledgement.contains("unlock_saved_once"))

        let unlockedProof = try XCTUnwrap(
            acknowledgement.range(of: ".result.passcodeRequired == false")
        )
        let observedTime = try XCTUnwrap(
            acknowledgement.range(of: "observed_unlocked_at=$(/bin/date '+%s')")
        )
        let finalArmedCheck = try XCTUnwrap(
            acknowledgement.range(
                of: "The development run stopped being armed during verification."
            )
        )
        let publication = try XCTUnwrap(
            acknowledgement.range(of: "/bin/mv -n \"$temporary_ack\" \"$ack_path\"")
        )
        XCTAssertLessThan(unlockedProof.lowerBound, observedTime.lowerBound)
        XCTAssertLessThan(observedTime.lowerBound, finalArmedCheck.lowerBound)
        XCTAssertLessThan(finalArmedCheck.lowerBound, publication.lowerBound)
    }

    func testFinalPassedStatusFailurePublishesNoPassBearingEvidence() throws {
        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "iphone15-pass-commit-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [runner.path]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST"] = "final-status-failure"
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT"] = root.path
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let standardOutput = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            1,
            "stdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        )
        XCTAssertFalse(
            standardOutput.contains("iPhone 15 development screen oracle passed:")
        )

        let statusURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(
                "10B6E5EE-D3B9-5334-99C1-EA12EFA34447-org.example.AudioStreamer.dev.json"
            )
        let statusData = try Data(contentsOf: statusURL)
        let status = try XCTUnwrap(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any]
        )
        XCTAssertEqual(status["phase"] as? String, "failed")
        XCTAssertTrue(
            (status["reason"] as? String)?.contains(
                "could not commit its final passed status"
            ) == true
        )
        let summaryPath = try XCTUnwrap(status["summary"] as? String)
        let summaryData = try Data(contentsOf: URL(fileURLWithPath: summaryPath))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: summaryData) as? [String: Any]
        )
        XCTAssertEqual(summary["status"] as? String, "failed")
    }

    func testLockStateTransportRetryIsExactBoundedAndFailClosed() throws {
        let source = try source
        let classifierStart = try XCTUnwrap(
            source.range(
                of: "\nfunction lock_state_failure_is_retryable_service_start_transport() {\n"
            )
        )
        let identityStart = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_device_identity() {\n",
                range: classifierStart.lowerBound..<source.endIndex
            )
        )
        let lockStateSource = String(
            source[classifierStart.lowerBound..<identityStart.lowerBound]
        )

        XCTAssertTrue(source.contains("readonly LOCK_STATE_TRANSPORT_ATTEMPTS=3"))
        XCTAssertTrue(source.contains("readonly LOCK_STATE_RETRY_DELAY_SECONDS=0.25"))
        for exactClassifierTerm in [
            ".info.outcome == \"failed\"",
            ".info.commandType == \"devicectl.device.info.lockState\"",
            ".error.domain == \"com.apple.dt.CoreDeviceError\"",
            ".error.code == -1",
            ".error.userInfo.NSUnderlyingError.error.domain == \"com.apple.mobiledevice\"",
            ".error.userInfo.NSUnderlyingError.error.code == -402653149",
        ] {
            XCTAssertTrue(lockStateSource.contains(exactClassifierTerm), exactClassifierTerm)
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-lock-state-retry-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        let deviceID = "10B6E5EE-D3B9-5334-99C1-EA12EFA34447"
        let fixtures: [String: String] = [
            "retryable": """
            {"info":{"outcome":"failed","commandType":"devicectl.device.info.lockState"},
             "error":{"domain":"com.apple.dt.CoreDeviceError","code":-1,"userInfo":{
               "NSUnderlyingError":{"error":{"domain":"com.apple.mobiledevice",
               "code":-402653149}}}}}
            """,
            "success": """
            {"info":{"outcome":"success"},"result":{"deviceIdentifier":"\(deviceID)",
             "passcodeRequired":false}}
            """,
            "locked": """
            {"info":{"outcome":"success"},"result":{"deviceIdentifier":"\(deviceID)",
             "passcodeRequired":true}}
            """,
            "wrong-device": """
            {"info":{"outcome":"success"},"result":{"deviceIdentifier":"wrong-device",
             "passcodeRequired":false}}
            """,
            "nonboolean": """
            {"info":{"outcome":"success"},"result":{"deviceIdentifier":"\(deviceID)",
             "passcodeRequired":"false"}}
            """,
            "unknown": """
            {"info":{"outcome":"failed","commandType":"devicectl.device.info.lockState"},
             "error":{"domain":"com.apple.dt.CoreDeviceError","code":-2}}
            """,
            "malformed": "not-json",
        ]
        for (name, contents) in fixtures {
            try contents.write(
                to: root.appendingPathComponent("\(name).json"),
                atomically: true,
                encoding: .utf8
            )
        }

        let harness = root.appendingPathComponent("lock-state-harness.zsh")
        let harnessSource = """
        #!/bin/zsh
        set -euo pipefail
        readonly DEVICE_ID='\(deviceID)'
        readonly LOCK_STATE_TRANSPORT_ATTEMPTS=3
        readonly LOCK_STATE_RETRY_DELAY_SECONDS=0
        readonly ARTIFACT_DIR="$TEST_ARTIFACT_DIR"
        typeset -gi TEST_CALLS=0
        function fail() {
          print -u2 -- "$1"
          exit 97
        }
        function xcrun() {
          TEST_CALLS=$(( TEST_CALLS + 1 ))
          local output_path="${@[-1]}"
          local fixture return_code
          case "$LOCK_CASE" in
            retry-then-success)
              if (( TEST_CALLS == 1 )); then fixture=retryable; return_code=1
              else fixture=success; return_code=0; fi
              ;;
            retry-exhausted) fixture=retryable; return_code=1 ;;
            locked) fixture=locked; return_code=0 ;;
            malformed-success) fixture=malformed; return_code=0 ;;
            wrong-device) fixture=wrong-device; return_code=0 ;;
            nonboolean) fixture=nonboolean; return_code=0 ;;
            unknown-nonzero) fixture=unknown; return_code=1 ;;
            malformed-nonzero) fixture=malformed; return_code=1 ;;
            *) exit 98 ;;
          esac
          /bin/cp "$FIXTURE_DIR/${fixture}.json" "$output_path"
          return "$return_code"
        }
        trap 'print -r -- "$TEST_CALLS" > "$CALLS_FILE"' EXIT
        \(lockStateSource)
        capture_device_lock_state test unlocked
        """
        try harnessSource.write(to: harness, atomically: true, encoding: .utf8)

        let cases: [(name: String, expectedStatus: Int32, expectedCalls: String)] = [
            ("retry-then-success", 0, "2"),
            ("retry-exhausted", 97, "3"),
            ("locked", 97, "1"),
            ("malformed-success", 97, "1"),
            ("wrong-device", 97, "1"),
            ("nonboolean", 97, "1"),
            ("unknown-nonzero", 97, "1"),
            ("malformed-nonzero", 97, "1"),
        ]
        for testCase in cases {
            let artifactDirectory = root.appendingPathComponent(
                "artifacts-\(testCase.name)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false
            )
            let callsFile = root.appendingPathComponent("calls-\(testCase.name).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [harness.path]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LOCK_CASE": testCase.name,
                "FIXTURE_DIR": root.path,
                "TEST_ARTIFACT_DIR": artifactDirectory.path,
                "CALLS_FILE": callsFile.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.expectedStatus,
                "\(testCase.name): \(errorText)"
            )
            XCTAssertEqual(
                try String(contentsOf: callsFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                testCase.expectedCalls,
                testCase.name
            )
        }
    }

    func testQuiescentPrimaryMicrophoneBaselineIsExactAndFailClosed() throws {
        let source = try source
        let diagnosticStart = try XCTUnwrap(
            source.range(of: "\nfunction diagnostic_field() {\n")
        )
        let diagnosticEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction require_unsigned_diagnostic_field() {\n",
                range: diagnosticStart.lowerBound..<source.endIndex
            )
        )
        let classifierStart = try XCTUnwrap(
            source.range(
                of: "\nfunction primary_microphone_quiescent_source_is_exact() {\n"
            )
        )
        let classifierEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction parse_primary_microphone_diagnostic() {\n",
                range: classifierStart.lowerBound..<source.endIndex
            )
        )
        let diagnosticSource = String(
            source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]
        )
        let classifierSource = String(
            source[classifierStart.lowerBound..<classifierEnd.lowerBound]
        )
        XCTAssertTrue(source.contains("microphone_mode=quiescentInactiveSource"))
        XCTAssertTrue(source.contains("PRIMARY_MIC_BASELINE_MODE=$microphone_mode"))
        XCTAssertTrue(
            source.contains(
                "primary microphone quiescent baseline changed during development validation"
            )
        )

        let audioLine = "Worldwide audio client diagnostics appActive=false micIntent=true"
        let exactFields = [
            "phase=sourceMediaStalled",
            "monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "deviceGeneration=2", "peerGeneration=1",
            "transportAuthorizationEpoch=7", "trackGeneration=3",
            "attemptGeneration=11",
            "lastAttemptedKeyMatchesSnapshot=true",
            "inputEndpointAvailable=true", "hiddenSinkAvailable=true",
            "hiddenWriterSelectionProven=false", "transport=true",
            "trackAdmitted=false", "queueRunning=false",
            "callbacks=0", "pulls=0", "frames=0", "silenceFallbacks=0",
            "enqueueFailures=0", "pcmLifecycleGeneration=0", "pcmWindowSequence=0",
            "pcmCompletedFrames=0", "pcmSourceStartFrame=0", "pcmSourceEndFrame=0",
            "pcmWindowFrames=0", "pcmWindowBytes=0", "boundDecGeneration=0",
            "boundDecRenderFloor=0", "pcmRMS=0.000000", "pcmRMSdBFS=-160.00",
            "pcmPeak=0.000000", "pcmPeakdBFS=-160.00", "pcmDC=0.000000",
            "pcmZeroFraction=0.000000", "pcmClippingFraction=0.000000",
            "decGeneration=0", "decCalls=0", "decRequestedFrames=0",
            "decRequestedBytes=0", "decReturnedBytes=0", "decNativeSuccess=0",
            "decNativeFailure=0", "decExactContracts=0", "decAnalyzedCalls=0",
            "decAnalyzedFrames=0", "decAnalyzedBytes=0", "decDropped=0",
            "decContractMismatch=0", "decPendingFrames=0", "decLatestCall=0",
            "decLatestStatus=0", "decLatestRequestedFrames=0",
            "decLatestRequestedBytes=0", "decLatestReturnedBytes=0",
            "decLatestExact=false", "decHasWindow=false", "decWindowSequence=0",
            "decWindowGeneration=0", "decSourceStartFrame=0", "decSourceEndFrame=0",
            "decWindowFrames=0", "decWindowBytes=0", "decRMS=0.000000",
            "decRMSdBFS=-160.00", "decPeak=0.000000", "decPeakdBFS=-160.00",
            "decDC=0.000000", "decZeroFraction=0.000000",
            "decClippingFraction=0.000000", "decAllZero=false",
            "decFrozenBlocks=0", "decLongestFrozenRun=0",
            "contentWindowsAlign=false", "contentFingerprintsMatch=false",
            "mediaSample=3891", "mediaAdvances=0", "mediaStale=0",
            "mediaFresh=false", "failure=sourceMediaStalled",
        ]
        let exactForwardingLine = exactFields.joined(separator: " ")
        let cases: [(String, String, String, Int32)] = [
            ("exact", audioLine, exactForwardingLine, 0),
            (
                "active-production-app",
                audioLine.replacingOccurrences(of: "appActive=false", with: "appActive=true"),
                exactForwardingLine,
                1
            ),
            (
                "wrong-phase",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "phase=sourceMediaStalled",
                    with: "phase=waitingForTransport"
                ),
                1
            ),
            (
                "unexpected-track-admission",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "trackAdmitted=false",
                    with: "trackAdmitted=true"
                ),
                1
            ),
            (
                "missing-forwarding-identity",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: " monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    with: ""
                ),
                1
            ),
            (
                "replaced-forwarding-key",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "lastAttemptedKeyMatchesSnapshot=true",
                    with: "lastAttemptedKeyMatchesSnapshot=false"
                ),
                1
            ),
            (
                "unexpected-progress",
                audioLine,
                exactForwardingLine.replacingOccurrences(of: "callbacks=0", with: "callbacks=1"),
                1
            ),
            (
                "nonzero-sample-content",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "pcmRMS=0.000000",
                    with: "pcmRMS=0.010000"
                ),
                1
            ),
            (
                "stale-diagnostic",
                audioLine,
                exactForwardingLine.replacingOccurrences(of: "mediaSample=3891", with: "mediaSample=0"),
                1
            ),
            (
                "missing-attempt-generation",
                audioLine,
                exactForwardingLine.replacingOccurrences(of: " attemptGeneration=11", with: ""),
                1
            ),
            (
                "zero-attempt-generation",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "attemptGeneration=11",
                    with: "attemptGeneration=0"
                ),
                1
            ),
            (
                "malformed-attempt-generation",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "attemptGeneration=11",
                    with: "attemptGeneration=invalid"
                ),
                1
            ),
            (
                "missing-contract-field",
                audioLine,
                exactForwardingLine.replacingOccurrences(of: " decLatestStatus=0", with: ""),
                1
            ),
            (
                "wrong-failure",
                audioLine,
                exactForwardingLine.replacingOccurrences(
                    of: "failure=sourceMediaStalled",
                    with: "failure=startFailed"
                ),
                1
            ),
        ]
        let harness = """
        set -euo pipefail
        \(diagnosticSource)
        \(classifierSource)
        primary_microphone_quiescent_source_is_exact "$AUDIO_LINE" "$FORWARDING_LINE"
        """
        for testCase in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "AUDIO_LINE": testCase.1,
                "FORWARDING_LINE": testCase.2,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.3,
                "\(testCase.0): \(errorText)"
            )
        }
    }

    func testForwardingHealthyAttemptKeyIsExactAndBoundToRoutingSelection() throws {
        let source = try source
        let diagnosticStart = try XCTUnwrap(
            source.range(of: "\nfunction diagnostic_field() {\n")
        )
        let diagnosticEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction inactive_primary_lifecycle_is_terminal() {\n",
                range: diagnosticStart.lowerBound..<source.endIndex
            )
        )
        let stickyStart = try XCTUnwrap(
            source.range(of: "\nfunction require_primary_interval_sticky() {\n")
        )
        let stickyEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction write_inactive_primary_append_window() {\n",
                range: stickyStart.lowerBound..<source.endIndex
            )
        )
        let diagnosticSource = String(
            source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]
        )
        let stickySource = String(
            source[stickyStart.lowerBound..<stickyEnd.lowerBound]
        )

        let selection = [
            "Worldwide iPhone microphone hidden writer selected",
            "routingEpoch=0123456789abcdef0123456789abcdef",
            "peerGeneration=1", "deviceGeneration=2", "pid=321",
        ].joined(separator: " ")
        let forwarding = [
            "Worldwide iPhone microphone forwarding phase=forwardingHealthy",
            "failure=none",
            "monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "deviceGeneration=2", "peerGeneration=1",
            "transportAuthorizationEpoch=7", "trackGeneration=3",
            "attemptGeneration=11", "lastAttemptedKeyMatchesSnapshot=true",
            "inputEndpointAvailable=true", "hiddenSinkAvailable=true",
            "hiddenWriterSelectionProven=true", "transport=true",
            "trackAdmitted=true", "queueRunning=true", "decLatestExact=true",
            "decHasWindow=true", "contentWindowsAlign=true",
            "contentFingerprintsMatch=true", "mediaFresh=true",
            "decAllZero=false", "silenceFallbacks=0", "enqueueFailures=0",
            "decNativeFailure=0", "decDropped=0", "decContractMismatch=0",
            "decLatestStatus=0", "mediaStale=0",
            "pcmLifecycleGeneration=4", "boundDecGeneration=4",
            "decGeneration=4", "callbacks=21", "frames=22",
            "pcmWindowSequence=23", "decCalls=24", "decAnalyzedFrames=25",
            "mediaSample=101", "mediaAdvances=6",
        ].joined(separator: " ")
        let audio = [
            "Worldwide audio client diagnostics pid=321",
            "peerGeneration=1", "negotiationEpoch=1",
            "status=renderingNonzero",
            "session=01234567-89AB-4CDE-8FAB-0123456789AB",
            "build=0.1.0(85)", "appActive=false",
            "playback=playing", "peerConnected=true", "iceConnected=true",
            "controlOpen=true", "trackAvailable=true", "micIntent=true",
            "micPermission=true", "initialized=true", "playoutInitialized=true",
            "nativePlaying=true", "nativeActive=true", "nativeOwnsActivation=true",
            "outputRoute=true", "micCallBlocked=false", "proof=complete",
            "authorization=valid", "targetMatched=true", "failureCode=0",
            "lifecycleStatus=0", "playoutStatus=0",
            "nativeAgeMs=100", "inboundAgeMs=100",
            "sequence=11", "inboundPackets=11", "inboundBytes=11",
            "callbacks=11", "frames=11", "nonzeroSamples=11",
        ].joined(separator: " ")

        let parserHarness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        \(diagnosticSource)
        HOST_PID=321
        PRIMARY_PEER_GENERATION=1
        ARTIFACT_DIR="$TEST_ARTIFACT_DIR"
        parse_primary_microphone_diagnostic before \
          "$SELECTION_LINE" "$FORWARDING_LINE" "$AUDIO_LINE"
        """
        let parserCases: [(name: String, line: String, expectedStatus: Int32)] = [
            ("exact", forwarding, 0),
            (
                "missing-attempt-generation",
                forwarding.replacingOccurrences(of: " attemptGeneration=11", with: ""),
                97
            ),
            (
                "zero-attempt-generation",
                forwarding.replacingOccurrences(
                    of: "attemptGeneration=11",
                    with: "attemptGeneration=0"
                ),
                97
            ),
            (
                "malformed-attempt-generation",
                forwarding.replacingOccurrences(
                    of: "attemptGeneration=11",
                    with: "attemptGeneration=invalid"
                ),
                97
            ),
            (
                "attempt-key-does-not-match-snapshot",
                forwarding.replacingOccurrences(
                    of: "lastAttemptedKeyMatchesSnapshot=true",
                    with: "lastAttemptedKeyMatchesSnapshot=false"
                ),
                97
            ),
            (
                "non-lowercase-monitor-epoch",
                forwarding.replacingOccurrences(
                    of: "monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    with: "monitorEpoch=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
                ),
                97
            ),
            (
                "device-disagrees-with-routing-selection",
                forwarding.replacingOccurrences(
                    of: "deviceGeneration=2",
                    with: "deviceGeneration=3"
                ),
                97
            ),
            (
                "peer-disagrees-with-routing-selection",
                forwarding.replacingOccurrences(
                    of: "peerGeneration=1",
                    with: "peerGeneration=2"
                ),
                97
            ),
        ]

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-forwarding-attempt-key-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        for testCase in parserCases {
            let artifactDirectory = root.appendingPathComponent(
                "parser-\(testCase.name)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", parserHarness]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["TEST_ARTIFACT_DIR"] = artifactDirectory.path
            environment["SELECTION_LINE"] = selection
            environment["FORWARDING_LINE"] = testCase.line
            environment["AUDIO_LINE"] = audio
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.expectedStatus,
                "\(testCase.name): \(errorText)"
            )
        }

        let stickyHarness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        \(diagnosticSource)
        \(stickySource)
        HOST_PID=321
        EXPECTED_PRIMARY_BUILD=85
        PRIMARY_SESSION_ID=01234567-89ab-4cde-8fab-0123456789ab
        PRIMARY_PEER_GENERATION=1
        PRIMARY_NEGOTIATION_EPOCH=1
        PRIMARY_AUDIO_APP_ACTIVE=false
        PRIMARY_AUDIO_SEQUENCE_BEFORE=10
        PRIMARY_INBOUND_PACKETS_BEFORE=10
        PRIMARY_INBOUND_BYTES_BEFORE=10
        PRIMARY_AUDIO_CALLBACKS_BEFORE=10
        PRIMARY_AUDIO_FRAMES_BEFORE=10
        PRIMARY_AUDIO_NONZERO_BEFORE=10
        PRIMARY_MIC_BASELINE_MODE=forwardingHealthy
        PRIMARY_MIC_ROUTING_EPOCH=0123456789abcdef0123456789abcdef
        PRIMARY_MIC_MONITOR_EPOCH=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
        PRIMARY_MIC_DEVICE_GENERATION=2
        PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH=7
        PRIMARY_MIC_TRACK_GENERATION=3
        PRIMARY_MIC_ATTEMPT_GENERATION=11
        PRIMARY_MIC_MEDIA_SAMPLE_BEFORE=100
        print -r -- "$SELECTION_LINE" > "$FILTERED"
        print -r -- "$FORWARDING_LINE" >> "$FILTERED"
        print -r -- "$AUDIO_LINE" >> "$FILTERED"
        require_primary_interval_sticky premint "$FILTERED" "$AUDIO_LINE"
        """
        let stickyCases: [(name: String, line: String, expectedStatus: Int32)] = [
            ("exact", forwarding, 0),
            (
                "monitor-generation-drift",
                forwarding.replacingOccurrences(
                    of: "monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                    with: "monitorEpoch=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
                ),
                97
            ),
            (
                "device-generation-drift",
                forwarding.replacingOccurrences(
                    of: "deviceGeneration=2",
                    with: "deviceGeneration=3"
                ),
                97
            ),
            (
                "peer-generation-drift",
                forwarding.replacingOccurrences(
                    of: "peerGeneration=1",
                    with: "peerGeneration=2"
                ),
                97
            ),
            (
                "transport-authorization-drift",
                forwarding.replacingOccurrences(
                    of: "transportAuthorizationEpoch=7",
                    with: "transportAuthorizationEpoch=8"
                ),
                97
            ),
            (
                "track-generation-drift",
                forwarding.replacingOccurrences(
                    of: "trackGeneration=3",
                    with: "trackGeneration=4"
                ),
                97
            ),
        ]
        for testCase in stickyCases {
            let filtered = root.appendingPathComponent("sticky-\(testCase.name).log")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", stickyHarness]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["FILTERED"] = filtered.path
            environment["SELECTION_LINE"] = selection
            environment["FORWARDING_LINE"] = testCase.line
            environment["AUDIO_LINE"] = audio
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.expectedStatus,
                "\(testCase.name): \(errorText)"
            )
        }
    }

    func testPrimaryContinuityUsesFreshNonOverlappingSequentialEvidence() throws {
        let source = try source
        let diagnosticStart = try XCTUnwrap(
            source.range(of: "\nfunction diagnostic_field() {\n")
        )
        let helperEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction parse_primary_audio_diagnostic() {\n",
                range: diagnosticStart.lowerBound..<source.endIndex
            )
        )
        let helperSource = String(
            source[diagnosticStart.lowerBound..<helperEnd.lowerBound]
        )
        let continuityStart = try XCTUnwrap(
            source.range(of: "\nfunction write_primary_continuity_window() {\n")
        )
        let continuityEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_host_generation_identity() {\n",
                range: continuityStart.lowerBound..<source.endIndex
            )
        )
        let continuitySource = String(
            source[continuityStart.lowerBound..<continuityEnd.lowerBound]
        )

        for required in [
            "== renderingNonzero",
            "native_age <= 5000 && inbound_age <= 5000",
            "HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_CONTINUITY_PENDING_CURSOR",
            "audio_sequence > PRIMARY_AUDIO_SEQUENCE_PREMINT",
            "callbacks > PRIMARY_MIC_CALLBACKS_PREMINT",
            "media_sample > PRIMARY_MIC_MEDIA_SAMPLE_PREMINT",
            "primary microphone left quiescent mode within ${prefix} interval",
            "primary microphone routing selection was not freshly proven at ${prefix}",
            "primary microphone quiescent baseline lacks two consecutive samples",
            "primary_audio_operational_fields_are_exact \"$line\"",
            "PRIMARY_CONTINUITY_ASSURANCE=exactAttemptBound",
            "assurance:$primaryContinuityAssurance",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("legacySampledHealthy"))
        XCTAssertFalse(continuitySource.contains("HOST_LOG_BASE_SIZE + 1"))
        XCTAssertFalse(continuitySource.contains("head -c \"$current_size\""))
        XCTAssertTrue(source.contains("HOST_BASELINE_TAIL_BYTES=16777216"))
        XCTAssertTrue(source.contains("start_offset > 1"))
        XCTAssertTrue(continuitySource.contains("$HOST_LOG_DEVICE"))
        XCTAssertTrue(continuitySource.contains("$HOST_LOG_INODE"))

        let harness = """
        set -euo pipefail
        function fail() { return 97 }
        \(helperSource)
        primary_audio_diagnostic_is_current_healthy "$AUDIO_LINE"
        primary_audio_operational_fields_are_exact "$AUDIO_LINE"
        """
        let exactAudio = [
            "status=renderingNonzero", "nativeAgeMs=1001", "inboundAgeMs=921",
            "playback=playing", "peerConnected=true", "iceConnected=true",
            "controlOpen=true", "trackAvailable=true", "micIntent=true",
            "micPermission=true", "initialized=true", "playoutInitialized=true",
            "nativePlaying=true", "nativeActive=true", "nativeOwnsActivation=true",
            "outputRoute=true", "micCallBlocked=false", "proof=complete",
            "authorization=valid", "targetMatched=true", "failureCode=0",
            "lifecycleStatus=0", "playoutStatus=0",
        ].joined(separator: " ")
        let cases: [(String, String, Int32)] = [
            ("fresh", exactAudio, 0),
            (
                "stale-status",
                exactAudio.replacingOccurrences(of: "status=renderingNonzero", with: "status=stale"),
                1
            ),
            (
                "unavailable-status",
                exactAudio.replacingOccurrences(
                    of: "status=renderingNonzero",
                    with: "status=nativeEvidenceUnavailable"
                ),
                1
            ),
            (
                "native-too-old",
                exactAudio.replacingOccurrences(of: "nativeAgeMs=1001", with: "nativeAgeMs=5001"),
                1
            ),
            (
                "inbound-too-old",
                exactAudio.replacingOccurrences(of: "inboundAgeMs=921", with: "inboundAgeMs=5001"),
                1
            ),
            (
                "unknown-age",
                exactAudio.replacingOccurrences(of: "nativeAgeMs=1001", with: "nativeAgeMs=unknown"),
                1
            ),
            (
                "microphone-intent-lost",
                exactAudio.replacingOccurrences(of: "micIntent=true", with: "micIntent=false"),
                1
            ),
            (
                "call-blocked",
                exactAudio.replacingOccurrences(of: "micCallBlocked=false", with: "micCallBlocked=true"),
                1
            ),
        ]
        for testCase in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "AUDIO_LINE": testCase.1,
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(
                process.terminationStatus,
                testCase.2,
                testCase.0
            )
        }
    }

    func testQuiescentPrimaryContinuityCommitsOnlyExactSequentialEvidence() throws {
        let source = try source
        let diagnosticStart = try XCTUnwrap(
            source.range(of: "\nfunction diagnostic_field() {\n")
        )
        let diagnosticEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction inactive_primary_lifecycle_is_terminal() {\n",
                range: diagnosticStart.lowerBound..<source.endIndex
            )
        )
        let continuityStart = try XCTUnwrap(
            source.range(of: "\nfunction write_primary_continuity_window() {\n")
        )
        let continuityEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_host_generation_identity() {\n",
                range: continuityStart.lowerBound..<source.endIndex
            )
        )
        let executableSource = String(
            source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]
        ) + String(source[continuityStart.lowerBound..<continuityEnd.lowerBound])

        let audio = [
            "Worldwide audio client diagnostics pid=321",
            "peerGeneration=1", "negotiationEpoch=1",
            "status=renderingNonzero",
            "session=01234567-89AB-4CDE-8FAB-0123456789AB",
            "build=0.1.0(85)", "appActive=false",
            "playback=playing", "peerConnected=true", "iceConnected=true",
            "controlOpen=true", "trackAvailable=true", "micIntent=true",
            "micPermission=true", "initialized=true", "playoutInitialized=true",
            "nativePlaying=true", "nativeActive=true", "nativeOwnsActivation=true",
            "outputRoute=true", "micCallBlocked=false", "proof=complete",
            "authorization=valid", "targetMatched=true", "failureCode=0",
            "lifecycleStatus=0", "playoutStatus=0",
            "nativeAgeMs=100", "inboundAgeMs=100",
            "sequence=11", "inboundPackets=11", "inboundBytes=11",
            "callbacks=11", "frames=11", "nonzeroSamples=11",
        ].joined(separator: " ")
        let forwardingFields = [
            "Worldwide iPhone microphone forwarding phase=sourceMediaStalled",
            "monitorEpoch=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "deviceGeneration=2", "peerGeneration=1",
            "transportAuthorizationEpoch=7", "trackGeneration=3",
            "attemptGeneration=11", "lastAttemptedKeyMatchesSnapshot=true",
            "inputEndpointAvailable=true", "hiddenSinkAvailable=true",
            "hiddenWriterSelectionProven=false", "transport=true",
            "trackAdmitted=false", "queueRunning=false",
            "callbacks=0", "pulls=0", "frames=0", "silenceFallbacks=0",
            "enqueueFailures=0", "pcmLifecycleGeneration=0", "pcmWindowSequence=0",
            "pcmCompletedFrames=0", "pcmSourceStartFrame=0", "pcmSourceEndFrame=0",
            "pcmWindowFrames=0", "pcmWindowBytes=0", "boundDecGeneration=0",
            "boundDecRenderFloor=0", "pcmRMS=0.000000", "pcmRMSdBFS=-160.00",
            "pcmPeak=0.000000", "pcmPeakdBFS=-160.00", "pcmDC=0.000000",
            "pcmZeroFraction=0.000000", "pcmClippingFraction=0.000000",
            "decGeneration=0", "decCalls=0", "decRequestedFrames=0",
            "decRequestedBytes=0", "decReturnedBytes=0", "decNativeSuccess=0",
            "decNativeFailure=0", "decExactContracts=0", "decAnalyzedCalls=0",
            "decAnalyzedFrames=0", "decAnalyzedBytes=0", "decDropped=0",
            "decContractMismatch=0", "decPendingFrames=0", "decLatestCall=0",
            "decLatestStatus=0", "decLatestRequestedFrames=0",
            "decLatestRequestedBytes=0", "decLatestReturnedBytes=0",
            "decLatestExact=false", "decHasWindow=false", "decWindowSequence=0",
            "decWindowGeneration=0", "decSourceStartFrame=0", "decSourceEndFrame=0",
            "decWindowFrames=0", "decWindowBytes=0", "decRMS=0.000000",
            "decRMSdBFS=-160.00", "decPeak=0.000000", "decPeakdBFS=-160.00",
            "decDC=0.000000", "decZeroFraction=0.000000",
            "decClippingFraction=0.000000", "decAllZero=false",
            "decFrozenBlocks=0", "decLongestFrozenRun=0",
            "contentWindowsAlign=false", "contentFingerprintsMatch=false",
            "mediaAdvances=0", "mediaStale=0", "mediaFresh=false",
            "failure=sourceMediaStalled",
        ]
        func forwarding(mediaSample: Int, attemptGeneration: Int = 11) -> String {
            (forwardingFields + ["mediaSample=\(mediaSample)"])
                .joined(separator: " ")
                .replacingOccurrences(
                    of: "attemptGeneration=11",
                    with: "attemptGeneration=\(attemptGeneration)"
                )
        }

        let selection = [
            "Worldwide iPhone microphone hidden writer selected",
            "routingEpoch=0123456789abcdef0123456789abcdef",
            "peerGeneration=1", "deviceGeneration=2", "pid=321",
        ].joined(separator: " ")
        let exactFirst = forwarding(mediaSample: 101)
        let exactSecond = forwarding(mediaSample: 102)
        let arithmeticIntermediateAudio = audio.replacingOccurrences(
            of: "sequence=11",
            with: "sequence=10+2"
        )
        let finalAudio = [
            "sequence", "inboundPackets", "inboundBytes", "callbacks", "frames",
            "nonzeroSamples",
        ].reduce(audio) { line, field in
            line.replacingOccurrences(of: "\(field)=11", with: "\(field)=13")
        }
        let cases: [(name: String, lines: [String], expectedStatus: Int32)] = [
            ("exact", [exactFirst, exactSecond, audio], 0),
            (
                "attempt-generation-drift",
                [
                    forwarding(mediaSample: 101, attemptGeneration: 12),
                    forwarding(mediaSample: 102, attemptGeneration: 12),
                    audio,
                ],
                97
            ),
            ("non-advancing-media-sample", [exactFirst, exactFirst, audio], 97),
            (
                "arithmetic-expression-in-intermediate-audio-sequence",
                [exactFirst, arithmeticIntermediateAudio, exactSecond, finalAudio],
                97
            ),
            ("hidden-writer-transition", [exactFirst, selection, exactSecond, audio], 97),
            (
                "foreign-pid-audio",
                [
                    exactFirst,
                    exactSecond,
                    audio,
                    audio.replacingOccurrences(of: "pid=321", with: "pid=999"),
                ],
                97
            ),
        ]

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-primary-continuity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let baselinePrefix = "baseline\n"
        let baselineCursor = baselinePrefix.utf8.count
        let harness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        \(executableSource)
        ARTIFACT_DIR="$TEST_ARTIFACT_DIR"
        HOST_LOG="$TEST_HOST_LOG"
        HOST_PID=321
        EXPECTED_PRIMARY_BUILD=85
        HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG")
        HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG")
        HOST_LOG_CONTINUITY_CURSOR="$INITIAL_CURSOR"
        HOST_LOG_CONTINUITY_PENDING_CURSOR=''
        PRIMARY_BASELINE_MODE=activePrimary
        PRIMARY_SESSION_ID=01234567-89ab-4cde-8fab-0123456789ab
        PRIMARY_PEER_GENERATION=1
        PRIMARY_NEGOTIATION_EPOCH=1
        PRIMARY_AUDIO_APP_ACTIVE=false
        PRIMARY_AUDIO_SEQUENCE_BEFORE=10
        PRIMARY_INBOUND_PACKETS_BEFORE=10
        PRIMARY_INBOUND_BYTES_BEFORE=10
        PRIMARY_AUDIO_CALLBACKS_BEFORE=10
        PRIMARY_AUDIO_FRAMES_BEFORE=10
        PRIMARY_AUDIO_NONZERO_BEFORE=10
        PRIMARY_MIC_BASELINE_MODE=quiescentInactiveSource
        PRIMARY_CONTINUITY_ASSURANCE=exactAttemptBound
        PRIMARY_MIC_FORWARDING_PHASE=sourceMediaStalled
        PRIMARY_MIC_ROUTING_EPOCH=0123456789abcdef0123456789abcdef
        PRIMARY_MIC_DEVICE_GENERATION=2
        PRIMARY_MIC_PCM_GENERATION=0
        PRIMARY_MIC_BOUND_DEC_GENERATION=0
        PRIMARY_MIC_DEC_GENERATION=0
        PRIMARY_MIC_MONITOR_EPOCH=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
        PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH=7
        PRIMARY_MIC_TRACK_GENERATION=3
        PRIMARY_MIC_ATTEMPT_GENERATION=11
        PRIMARY_MIC_CALLBACKS_BEFORE=0
        PRIMARY_MIC_FRAMES_BEFORE=0
        PRIMARY_MIC_PCM_WINDOWS_BEFORE=0
        PRIMARY_MIC_DEC_CALLS_BEFORE=0
        PRIMARY_MIC_DEC_FRAMES_BEFORE=0
        PRIMARY_MIC_MEDIA_SAMPLE_BEFORE=100
        trap 'print -r -- "$HOST_LOG_CONTINUITY_CURSOR" > "$CURSOR_FILE"' EXIT
        capture_primary_continuity premint
        [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$(/usr/bin/stat -f '%z' "$HOST_LOG")" ]]
        [[ "$HOST_LOG_CONTINUITY_PENDING_CURSOR" == "$HOST_LOG_CONTINUITY_CURSOR" ]]
        """

        for testCase in cases {
            let artifactDirectory = root.appendingPathComponent(
                "artifacts-\(testCase.name)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false
            )
            try (selection + "\n").write(
                to: artifactDirectory.appendingPathComponent("before-host-baseline.log"),
                atomically: true,
                encoding: .utf8
            )
            let hostLog = root.appendingPathComponent("host-\(testCase.name).log")
            try (baselinePrefix + testCase.lines.joined(separator: "\n") + "\n").write(
                to: hostLog,
                atomically: true,
                encoding: .utf8
            )
            let cursorFile = root.appendingPathComponent("cursor-\(testCase.name).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["TEST_ARTIFACT_DIR"] = artifactDirectory.path
            environment["TEST_HOST_LOG"] = hostLog.path
            environment["INITIAL_CURSOR"] = String(baselineCursor)
            environment["CURSOR_FILE"] = cursorFile.path
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.expectedStatus,
                "\(testCase.name): \(errorText)"
            )
            let recordedCursor = try String(contentsOf: cursorFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalLogSize = try Data(contentsOf: hostLog).count
            let expectedCursor = testCase.expectedStatus == 0
                ? String(finalLogSize)
                : String(baselineCursor)
            XCTAssertEqual(recordedCursor, expectedCursor, testCase.name)
        }
    }

    func testInactivePrimaryTerminalLifecycleIsExactRepeatableAndFailClosed() throws {
        let source = try source
        let diagnosticStart = try XCTUnwrap(
            source.range(of: "\nfunction diagnostic_field() {\n")
        )
        let diagnosticEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction require_unsigned_diagnostic_field() {\n",
                range: diagnosticStart.lowerBound..<source.endIndex
            )
        )
        let terminalStart = try XCTUnwrap(
            source.range(
                of: "\nfunction primary_audio_diagnostic_is_terminal_inactive() {\n"
            )
        )
        let terminalEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction primary_audio_operational_fields_are_exact() {\n",
                range: terminalStart.lowerBound..<source.endIndex
            )
        )
        let lifecycleStart = try XCTUnwrap(
            source.range(of: "\nfunction inactive_primary_lifecycle_is_terminal() {\n")
        )
        let lifecycleEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction write_host_baseline_snapshot() {\n",
                range: lifecycleStart.lowerBound..<source.endIndex
            )
        )
        let helperSource = String(
            source[diagnosticStart.lowerBound..<diagnosticEnd.lowerBound]
        ) + String(source[terminalStart.lowerBound..<terminalEnd.lowerBound])
            + String(source[lifecycleStart.lowerBound..<lifecycleEnd.lowerBound])

        let exactStopped = [
            "Worldwide audio client diagnostics pid=321",
            "peerGeneration=1", "negotiationEpoch=1",
            "status=unavailable.stopped",
            "session=01234567-89AB-4CDE-8FAB-0123456789AB",
            "build=0.1.0(85)",
            // These are retained heartbeat fields. Terminal truth comes from the
            // stopped status plus the ordered host lifecycle, not these values.
            "playback=playing", "peerConnected=true", "appActive=false",
        ].joined(separator: " ")
        let terminalPrefix = [
            "Worldwide WebRTC peer state: connected pid=321",
            "Starting screen video capture",
            "Stopping screen video capture",
            "Worldwide viewer disconnected; the media rendezvous is consumed",
            exactStopped,
            "Worldwide media ended; the Mac remains available for the paired iPhone",
        ].joined(separator: "\n") + "\n"
        let completedSecondary = [
            "Worldwide WebRTC peer state: connecting pid=321",
            "Worldwide WebRTC peer state: connected pid=321",
            "Starting screen video capture",
            "Worldwide viewer disconnected; the media rendezvous is consumed",
            "Stopping screen video capture",
        ].joined(separator: "\n") + "\n"
        let cases: [(String, String, Int32)] = [
            ("exact-terminal", terminalPrefix, 0),
            ("completed-secondary-history", terminalPrefix + completedSecondary, 0),
            (
                "wrong-terminal-status",
                terminalPrefix.replacingOccurrences(
                    of: "status=unavailable.stopped",
                    with: "status=routeUnavailable"
                ),
                1
            ),
            (
                "active-primary-app",
                terminalPrefix.replacingOccurrences(
                    of: "appActive=false",
                    with: "appActive=true"
                ),
                1
            ),
            (
                "wrong-primary-build",
                terminalPrefix.replacingOccurrences(of: "build=0.1.0(85)", with: "build=0.1.0(84)"),
                1
            ),
            (
                "stale-connected-after-terminal",
                terminalPrefix + "Worldwide WebRTC peer state: connected pid=321\n",
                1
            ),
            (
                "capture-restarted-after-terminal",
                terminalPrefix + "Starting screen video capture\n",
                1
            ),
            (
                "primary-rendezvous-after-terminal",
                terminalPrefix + "A fresh encrypted media rendezvous is ready for the paired iPhone\n",
                1
            ),
            (
                "primary-left-availability-after-terminal",
                terminalPrefix + "The paired iPhone left the availability exchange\n",
                1
            ),
        ]

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-inactive-primary-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let harness = """
        set -euo pipefail
        HOST_PID=321
        EXPECTED_PRIMARY_BUILD=85
        \(helperSource)
        inactive_primary_lifecycle_is_terminal "$LOG_PATH"
        """
        for testCase in cases {
            let log = root.appendingPathComponent("\(testCase.0).log")
            try testCase.1.write(to: log, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["LOG_PATH"] = log.path
            process.environment = environment
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.2,
                "\(testCase.0): \(errorText)"
            )
        }
    }

    func testHostBaselineUsesBoundedCompleteLineTailAndExactAppendCursor() throws {
        let source = try source
        let functionStart = try XCTUnwrap(
            source.range(of: "\nfunction write_host_baseline_snapshot() {\n")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction write_primary_continuity_window() {\n",
                range: functionStart.lowerBound..<source.endIndex
            )
        )
        let functionSource = String(
            source[functionStart.lowerBound..<functionEnd.lowerBound]
        )

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "opensteamer-bounded-host-baseline-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let hostLog = temporaryDirectory.appendingPathComponent("host.log")
        let output = temporaryDirectory.appendingPathComponent("baseline.log")
        let oldPrefix = String(repeating: "x", count: 4096) + "\n"
        let audio = "[info] Worldwide audio client diagnostics pid=321 "
            + "status=renderingNonzero playback=playing\n"
        let forwarding = "[debug] Worldwide iPhone microphone forwarding "
            + "phase=forwardingHealthy\n"
        try (oldPrefix + audio + forwarding).write(
            to: hostLog,
            atomically: true,
            encoding: .utf8
        )

        let harness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        function primary_audio_diagnostic_is_current_healthy() {
          [[ "$1" == *"status=renderingNonzero"* ]]
        }
        function primary_audio_operational_fields_are_exact() {
          [[ "$1" == *"playback=playing"* ]]
        }
        function primary_audio_diagnostic_is_terminal_inactive() {
          return 1
        }
        \(functionSource)
        HOST_LOG="$HOST_LOG_PATH"
        HOST_PID=321
        HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG")
        HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG")
        HOST_BASELINE_TAIL_BYTES=1024
        HOST_LOG_BASE_SIZE=''
        HOST_LOG_CONTINUITY_CURSOR=''
        write_host_baseline_snapshot "$OUTPUT_PATH"
        [[ "$HOST_LOG_BASE_SIZE" == "$(/usr/bin/stat -f '%z' "$HOST_LOG")" ]]
        [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$HOST_LOG_BASE_SIZE" ]]
        (( $(/usr/bin/stat -f '%z' "$OUTPUT_PATH") < HOST_BASELINE_TAIL_BYTES ))
        [[ "$(/usr/bin/head -n 1 "$OUTPUT_PATH")" == *"audio client diagnostics"* ]]
        /usr/bin/grep -Fq 'phase=forwardingHealthy' "$OUTPUT_PATH"
        [[ "$(/usr/bin/tail -c 1 "$OUTPUT_PATH" | /usr/bin/od -An -tuC \
          | /usr/bin/tr -d '[:space:]')" == 10 ]]
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", harness]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOST_LOG_PATH": hostLog.path,
            "OUTPUT_PATH": output.path,
        ]
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    func testInactiveHostBaselineWaitsForCompleteTerminalLifecycle() throws {
        let source = try source
        let functionStart = try XCTUnwrap(
            source.range(of: "\nfunction write_host_baseline_snapshot() {\n")
        )
        let functionEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction write_primary_continuity_window() {\n",
                range: functionStart.lowerBound..<source.endIndex
            )
        )
        let functionSource = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        XCTAssertTrue(
            functionSource.contains("inactive_primary_lifecycle_is_terminal \"$output\"")
        )

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-terminal-baseline-wait-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let hostLog = root.appendingPathComponent("host.log")
        let output = root.appendingPathComponent("baseline.log")
        try """
        Worldwide viewer disconnected;
        Worldwide audio client diagnostics pid=321 status=unavailable.stopped
        """.write(to: hostLog, atomically: true, encoding: .utf8)

        let harness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        function primary_audio_diagnostic_is_current_healthy() { return 1 }
        function primary_audio_operational_fields_are_exact() { return 1 }
        function primary_audio_diagnostic_is_terminal_inactive() {
          [[ "$1" == *"status=unavailable.stopped"* ]]
        }
        function inactive_primary_lifecycle_is_terminal() {
          /usr/bin/grep -Fq 'Worldwide media ended;' "$1"
        }
        function capture_inactive_primary_stopped_report() { return 1 }
        \(functionSource)
        HOST_LOG="$HOST_LOG_PATH"
        HOST_PID=321
        HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG")
        HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG")
        HOST_BASELINE_TAIL_BYTES=4096
        HOST_LOG_BASE_SIZE=''
        HOST_LOG_CONTINUITY_CURSOR=''
        ( /bin/sleep 0.20; print -r -- 'Worldwide media ended;' >> "$HOST_LOG" ) &
        writer_pid=$!
        write_host_baseline_snapshot "$OUTPUT_PATH"
        wait "$writer_pid"
        /usr/bin/grep -Fq 'Worldwide media ended;' "$OUTPUT_PATH"
        [[ "$HOST_LOG_BASE_SIZE" == "$(/usr/bin/stat -f '%z' "$HOST_LOG")" ]]
        [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$HOST_LOG_BASE_SIZE" ]]
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", harness]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOST_LOG_PATH": hostLog.path,
            "OUTPUT_PATH": output.path,
        ]
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    func testSecondaryManagerGenerationChainIsExactAndFailClosed() throws {
        let source = try source
        let receiptStart = try XCTUnwrap(
            source.range(
                of: "\nfunction secondary_manager_receipt_generation_is_expected() {\n"
            )
        )
        let receiptEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction validate_host_generation_receipt() {\n",
                range: receiptStart.lowerBound..<source.endIndex
            )
        )
        let probeStart = try XCTUnwrap(
            source.range(
                of: "\nfunction secondary_manager_probe_generation_is_expected() {\n"
            )
        )
        let probeEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_secondary_manager_idle_probe() {\n",
                range: probeStart.lowerBound..<source.endIndex
            )
        )
        let helperSource = String(source[receiptStart.lowerBound..<receiptEnd.lowerBound])
            + String(source[probeStart.lowerBound..<probeEnd.lowerBound])

        for required in [
            "--probe-secondary-test-viewer-status",
            "SECONDARY_MANAGER_PROBE_TIMEOUT_SECONDS=6",
            "secondaryTestViewerStatusProbeResult",
            ".managerPhase == \"idle\"",
            ".managerIsIdle == true",
            ".requestNonce | test(\"^[0-9a-f]{32}$\")",
            "jq --stream -e -s",
            "SECONDARY_MANAGER_GENERATION_BASELINE=$manager_generation",
            "manager_generation\" == \"$SECONDARY_MANAGER_GENERATION_BASELINE",
            "manager_generation\" == \"$SECONDARY_MANAGER_GENERATION",
            "SECONDARY_MANAGER_GENERATION_BASELINE + 1",
            "inactivePrimaryNoAudioProof",
            "Worldwide authenticated media route selected virtual microphone",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }

        let harness = """
        set -euo pipefail
        SECONDARY_MANAGER_GENERATION_BASELINE=''
        SECONDARY_MANAGER_GENERATION=''
        HOST_GENERATION_RECEIPT_VALIDATED=0
        \(helperSource)
        secondary_manager_probe_generation_is_expected baseline 7
        case "$CHAIN_CASE" in
          exact)
            secondary_manager_probe_generation_is_expected premint 7
            secondary_manager_receipt_generation_is_expected 8
            SECONDARY_MANAGER_GENERATION=8
            HOST_GENERATION_RECEIPT_VALIDATED=1
            secondary_manager_probe_generation_is_expected after 8
            ;;
          premint-advanced)
            secondary_manager_probe_generation_is_expected premint 8
            ;;
          skipped-receipt-generation)
            secondary_manager_probe_generation_is_expected premint 7
            secondary_manager_receipt_generation_is_expected 9
            ;;
          stale-after-stop)
            secondary_manager_probe_generation_is_expected premint 7
            secondary_manager_receipt_generation_is_expected 8
            SECONDARY_MANAGER_GENERATION=8
            HOST_GENERATION_RECEIPT_VALIDATED=1
            secondary_manager_probe_generation_is_expected after 7
            ;;
          repeated-baseline)
            secondary_manager_probe_generation_is_expected baseline 7
            ;;
          *) exit 98 ;;
        esac
        """
        let cases: [(String, Int32)] = [
            ("exact", 0),
            ("premint-advanced", 1),
            ("skipped-receipt-generation", 1),
            ("stale-after-stop", 1),
            ("repeated-baseline", 1),
        ]
        for testCase in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CHAIN_CASE": testCase.0,
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, testCase.1, testCase.0)
        }
    }

    func testSecondaryManagerIdleProbeEvidenceIsExecutableAndFailClosed() throws {
        let source = try source
        let helperStart = try XCTUnwrap(
            source.range(of: "\nfunction secondary_manager_probe_generation_is_expected() {\n")
        )
        let helperEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_host_baseline() {\n",
                range: helperStart.lowerBound..<source.endIndex
            )
        )
        let helperSource = String(source[helperStart.lowerBound..<helperEnd.lowerBound])

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-secondary-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        let fakeHost = root.appendingPathComponent("fake-host.zsh")
        let fakeHostSource = """
        #!/bin/zsh
        set -euo pipefail
        [[ "$1" == '--probe-secondary-test-viewer-status' ]]
        output=$2
        umask 077
        function emit_record() {
          local pid=$1 phase=${2:-idle} idle=${3:-true}
          /usr/bin/jq -ncS \
            --arg generation "$HOST_GENERATION" \
            --argjson pid "$pid" \
            --argjson idle "$idle" \
            --arg phase "$phase" \
            '{hostGeneration:$generation,hostProcessIdentifier:$pid,
              managerGeneration:7,managerIsIdle:$idle,managerPhase:$phase,
              requestNonce:"0123456789abcdef0123456789abcdef",
              type:"secondaryTestViewerStatusProbeResult",v:1}' > "$output"
        }
        case "$PROBE_CASE" in
          exact) emit_record "$HOST_PID" ;;
          duplicate-key)
            print -r -- '{"hostGeneration":"'"$HOST_GENERATION"'","hostProcessIdentifier":'"$HOST_PID"',"managerGeneration":7,"managerIsIdle":true,"managerPhase":"idle","requestNonce":"0123456789abcdef0123456789abcdef","type":"secondaryTestViewerStatusProbeResult","v":1,"v":1}' > "$output"
            ;;
          wrong-host) emit_record "$(( HOST_PID + 1 ))" ;;
          wrong-phase) emit_record "$HOST_PID" running false ;;
          bad-mode) emit_record "$HOST_PID"; /bin/chmod 0644 "$output" ;;
          stale-time) emit_record "$HOST_PID"; /usr/bin/touch -t 202001010000 "$output" ;;
          noncanonical)
            print -r -- '{"v":1,"type":"secondaryTestViewerStatusProbeResult","requestNonce":"0123456789abcdef0123456789abcdef","managerPhase":"idle","managerIsIdle":true,"managerGeneration":7,"hostProcessIdentifier":'"$HOST_PID"',"hostGeneration":"'"$HOST_GENERATION"'"}' > "$output"
            ;;
          trailing-data) emit_record "$HOST_PID"; print >> "$output" ;;
          symlink)
            target="${output}.target"
            output="$target" emit_record "$HOST_PID"
            /bin/ln -s "$target" "$2"
            ;;
          *) exit 98 ;;
        esac
        """
        try fakeHostSource.write(to: fakeHost, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: fakeHost.path
        )

        let harness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        function require_same_host() { return 0 }
        function capture_host_generation_identity() { return 0 }
        function run_sealed_host_management_child() {
          local prefix=$1 stdout=$2 stderr=$3 timeout_seconds=$4
          shift 4
          "$HOST_EXECUTABLE" "$@" > "$stdout" 2> "$stderr"
        }
        SECONDARY_MANAGER_GENERATION_BASELINE=''
        SECONDARY_MANAGER_GENERATION=''
        HOST_GENERATION_RECEIPT_VALIDATED=0
        HOST_GENERATION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        HOST_PID=321
        SECONDARY_MANAGER_PROBE_TIMEOUT_SECONDS=2
        HOST_EXECUTABLE="$FAKE_HOST"
        ARTIFACT_DIR="$TEST_ARTIFACT_DIR"
        \(helperSource)
        capture_secondary_manager_idle_probe baseline
        """
        let cases: [(String, Int32)] = [
            ("exact", 0),
            ("duplicate-key", 97),
            ("wrong-host", 97),
            ("wrong-phase", 97),
            ("bad-mode", 97),
            ("stale-time", 97),
            ("noncanonical", 97),
            ("trailing-data", 97),
            ("symlink", 97),
        ]
        for testCase in cases {
            let artifactDirectory = root.appendingPathComponent(
                "artifacts-\(testCase.0)",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_HOST": fakeHost.path,
                "HOST_GENERATION":
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "HOST_PID": "321",
                "PROBE_CASE": testCase.0,
                "TEST_ARTIFACT_DIR": artifactDirectory.path,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.1,
                "\(testCase.0): \(errorText)"
            )
        }
    }

    func testInactivePrimaryAppendWindowsRejectReactivationAndRequireOneClosedSecondary() throws {
        let source = try source
        let inactiveStart = try XCTUnwrap(
            source.range(of: "\nfunction write_inactive_primary_append_window() {\n")
        )
        let inactiveEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction capture_primary_continuity() {\n",
                range: inactiveStart.lowerBound..<source.endIndex
            )
        )
        let deltaStart = try XCTUnwrap(source.range(of: "\nfunction write_host_delta() {\n"))
        let deltaEnd = try XCTUnwrap(
            source.range(
                of: "\nfunction wait_for_host_delta() {\n",
                range: deltaStart.lowerBound..<source.endIndex
            )
        )
        let onlineStart = try XCTUnwrap(source.range(of: "\nfunction inactive_primary_online_announcements_are_exact() {\n"))
        let onlineEnd = try XCTUnwrap(source.range(of: "\nfunction stopped_audio_report_directory_identity() {\n"))
        let helperSource = String(source[onlineStart.lowerBound..<onlineEnd.lowerBound])
            + String(source[inactiveStart.lowerBound..<inactiveEnd.lowerBound])
            + String(source[deltaStart.lowerBound..<deltaEnd.lowerBound])

        let harness = """
        set -euo pipefail
        function fail() { print -u2 -- "$1"; exit 97 }
        function require_same_host() { return 0 }
        HOST_PID=321
        HOST_LOG="$HOST_LOG_PATH"
        ARTIFACT_DIR="$TEST_ARTIFACT_DIR"
        PRIMARY_CONTINUITY_ASSURANCE=inactivePrimaryNoAudioProof
        HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG")
        HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG")
        HOST_LOG_BASE_SIZE=$(/usr/bin/stat -f '%z' "$HOST_LOG")
        HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_BASE_SIZE
        HOST_LOG_CONTINUITY_PENDING_CURSOR=''
        \(helperSource)
        phase=premint
        case "$WINDOW_CASE" in
          zero) ;;
          unrelated) print -r -- 'unrelated bounded diagnostic' >> "$HOST_LOG" ;;
          primary-audio) print -r -- 'Worldwide audio client diagnostics pid=321' >> "$HOST_LOG" ;;
          microphone) print -r -- 'Worldwide iPhone microphone forwarding phase=sourceMediaStalled' >> "$HOST_LOG" ;;
          hidden-writer) print -r -- 'Worldwide iPhone microphone hidden writer selected' >> "$HOST_LOG" ;;
          virtual-mic) print -r -- 'Worldwide authenticated media route selected virtual microphone' >> "$HOST_LOG" ;;
          media-ended) print -r -- 'Worldwide media ended;' >> "$HOST_LOG" ;;
          peer-transition) print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG" ;;
          capture-transition) print -r -- 'Starting screen video capture' >> "$HOST_LOG" ;;
          viewer-disconnect) print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG" ;;
          after-exact)
            phase=after
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG"
            print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
            ;;
          after-duplicate)
            phase=after
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG"
            print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG"
            print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
            ;;
          after-missing-stop)
            phase=after
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG"
            ;;
          after-missing-disconnect)
            phase=after
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
            ;;
          after-trailing-connecting)
            phase=after
            print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
            print -r -- 'Starting screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide viewer disconnected;' >> "$HOST_LOG"
            print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
            print -r -- 'Worldwide WebRTC peer state: connecting pid=321' >> "$HOST_LOG"
            ;;
          *) exit 98 ;;
        esac
        capture_inactive_primary_continuity "$phase"
        [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$(/usr/bin/stat -f '%z' "$HOST_LOG")" ]]
        """
        let cases: [(String, Int32)] = [
            ("zero", 0),
            ("unrelated", 0),
            ("primary-audio", 97),
            ("microphone", 97),
            ("hidden-writer", 97),
            ("virtual-mic", 97),
            ("media-ended", 97),
            ("peer-transition", 97),
            ("capture-transition", 97),
            ("viewer-disconnect", 97),
            ("after-exact", 0),
            ("after-duplicate", 97),
            ("after-missing-stop", 97),
            ("after-missing-disconnect", 97),
            ("after-trailing-connecting", 97),
        ]
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-inactive-append-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }
        for testCase in cases {
            let hostLog = root.appendingPathComponent("\(testCase.0).log")
            try "baseline complete line\n".write(
                to: hostLog,
                atomically: true,
                encoding: .utf8
            )
            let artifactDirectory = root.appendingPathComponent(
                "artifacts-\(testCase.0)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", harness]
            process.environment = [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOST_LOG_PATH": hostLog.path,
                "TEST_ARTIFACT_DIR": artifactDirectory.path,
                "WINDOW_CASE": testCase.0,
            ]
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let errorText = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                testCase.1,
                "\(testCase.0): \(errorText)"
            )
        }
    }

    func testCredentialFreePowerLeaseSpansEveryPostCopyCleanupExit() throws {
        let source = try source
        let powerAssertion = try powerAssertionSource
        let start = try XCTUnwrap(
            source.range(of: "\nstart_device_power_assertion\n")
        )
        let copyArmed = try XCTUnwrap(
            source.range(of: "\nDEVICE_SECRET_CLEANUP_REQUIRED=1\n")
        )
        let normalCleanup = try XCTUnwrap(
            source.range(of: "\nrun_device_secret_cleanup post-test-cleanup \\\n")
        )
        let normalStop = try XCTUnwrap(
            source.range(
                of: "\nstop_device_power_assertion after-device-secret-cleanup \\\n"
            )
        )
        let finalizerCleanup = try XCTUnwrap(
            source.range(of: "\n  if (( DEVICE_SECRET_CLEANUP_REQUIRED != 0 )); then\n")
        )
        let finalizerStop = try XCTUnwrap(
            source.range(of: "\n  if [[ -n \"$POWER_ASSERTION_PID\" ]]; then\n")
        )

        XCTAssertLessThan(start.lowerBound, copyArmed.lowerBound)
        XCTAssertLessThan(normalCleanup.lowerBound, normalStop.lowerBound)
        XCTAssertLessThan(finalizerCleanup.lowerBound, finalizerStop.lowerBound)
        XCTAssertTrue(
            source.contains("require_device_power_assertion_healthy before-invitation-copy")
        )
        XCTAssertTrue(source.contains("require_device_power_assertion_healthy before-test"))
        XCTAssertTrue(
            source.contains("require_device_power_assertion_healthy after-device-secret-cleanup")
        )
        XCTAssertTrue(source.contains("POWER_ASSERTION_STOPPED == 1"))

        XCTAssertTrue(powerAssertion.contains("PreventUserIdleSystemSleep"))
        XCTAssertTrue(powerAssertion.contains("tunnel_type(serial=args.udid)"))
        XCTAssertTrue(
            powerAssertion.contains("class ExistingPairingOnlyNativeRemotedTunnel")
        )
        XCTAssertTrue(powerAssertion.contains("if rsd.udid != args.udid:"))
        XCTAssertTrue(
            powerAssertion.contains(
                "EXACT_HARDWARE_UDID = \"00008120-0000242E3E32201E\""
            )
        )
        XCTAssertTrue(powerAssertion.contains("LEASE_SECONDS = 45"))
        XCTAssertTrue(powerAssertion.contains("RENEW_AFTER_SECONDS = 15"))
        XCTAssertTrue(powerAssertion.contains("os.getppid() != args.owner_pid"))
        XCTAssertTrue(powerAssertion.contains("EXPECTED_PYMOBILEDEVICE3_VERSION = \"11.12.5\""))
        XCTAssertTrue(powerAssertion.contains("os.lstat(current)"))
        XCTAssertTrue(powerAssertion.contains("stat.S_ISLNK(metadata.st_mode)"))
        XCTAssertTrue(powerAssertion.contains("await asyncio.wait_for("))
        XCTAssertTrue(powerAssertion.contains("service.close()"))
        XCTAssertTrue(powerAssertion.contains("tunnel.aclose()"))
        XCTAssertTrue(powerAssertion.contains("residualLeaseExpiresAt"))
        XCTAssertFalse(powerAssertion.contains("InitiatePairingCommand"))
        XCTAssertTrue(
            source.contains(
                "\"$IPHONE_CONTROL_PYTHON\" -I -S -B \"$POWER_ASSERTION_HELPER\""
            )
        )
        XCTAssertTrue(source.contains("/usr/bin/env -i HOME=\"$HOME\""))
        XCTAssertTrue(source.contains("capture_device_identity power-assertion-start unlocked"))
        XCTAssertTrue(source.contains("while (( now <= residual_lease )); do"))
        XCTAssertTrue(source.contains("residual_lease=$(( now + 45 ))"))
        XCTAssertTrue(powerAssertion.contains("EXPECTED_SITE_PACKAGES_TREE_SHA256"))
        XCTAssertTrue(powerAssertion.contains("_site_packages_tree_identity()"))
        XCTAssertTrue(
            powerAssertion.contains("_install_source_and_extension_only_site_loader()")
        )
        XCTAssertTrue(powerAssertion.contains("class SourceOnlyFileLoader"))
        XCTAssertTrue(
            powerAssertion.contains(
                "return self.source_to_code(self.get_data(source_path), source_path)"
            )
        )
        XCTAssertTrue(powerAssertion.contains("sys.flags.no_site != 1"))
        XCTAssertTrue(powerAssertion.contains("\"_virtualenv\","))

        let serviceClose = try XCTUnwrap(powerAssertion.range(of: "service.close()"))
        let tunnelClose = try XCTUnwrap(powerAssertion.range(of: "tunnel.aclose()"))
        XCTAssertLessThan(serviceClose.lowerBound, tunnelClose.lowerBound)
        for forbidden in [
            "find-generic-password",
            "codex.iphone-usb-unlock",
            "unlock_saved_once",
            "IndigoHIDService",
            "touch_session",
        ] {
            XCTAssertFalse(powerAssertion.contains(forbidden), forbidden)
        }
    }

    func testPowerRuntimeRejectsPythonStartupInjectionBeforeThirdPartyImport() throws {
        let fileManager = FileManager.default
        let hostileDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "opensteamer-hostile-python-startup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: hostileDirectory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: hostileDirectory) }

        let marker = hostileDirectory.appendingPathComponent("startup-executed")
        let markerLiteral = String(reflecting: marker.path)
        let payload = "import pathlib; pathlib.Path(\(markerLiteral)).write_text('executed')\n"
        try payload.write(
            to: hostileDirectory.appendingPathComponent("sitecustomize.py"),
            atomically: true,
            encoding: .utf8
        )
        try payload.write(
            to: hostileDirectory.appendingPathComponent("_virtualenv.py"),
            atomically: true,
            encoding: .utf8
        )
        try "import sitecustomize\n".write(
            to: hostileDirectory.appendingPathComponent("hostile.pth"),
            atomically: true,
            encoding: .utf8
        )

        let helper = repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/iphone15-dev-power-assertion.py"
        )
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: "/Users/ahmed/.local/share/uv/python/" +
                "cpython-3.13.14-macos-aarch64-none/bin/python3.13"
        )
        process.arguments = ["-I", "-S", "-B", helper.path, "--verify-runtime"]
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PYTHONPATH": hostileDirectory.path,
            "PYTHONHOME": hostileDirectory.path,
            "PYMOBILEDEVICE3_NATIVE_TARGET_UID": "999999",
        ]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let errorText = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, errorText)
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path))
    }

    func testRunnerMintsInvitationLateWithoutExternalCapabilityInput() throws {
        let source = try source
        XCTAssertFalse(source.contains("OPENSTEAMER_DEV_SECONDARY_INVITATION_FILE"))
        XCTAssertTrue(
            source.contains(
                "readonly INVITATION_SOURCE=\"${ARTIFACT_DIR}/secondary-viewer-invitation.txt\""
            )
        )

        let monitor = try XCTUnwrap(source.range(of: "\nstart_audio_route_monitor\n"))
        let install = try XCTUnwrap(source.range(of: "\nSTAGE=dev-app-install\n"))
        let mint = try XCTUnwrap(source.range(of: "\nSTAGE=invitation-mint\n"))
        let request = try XCTUnwrap(
            source.range(of: "\nif run_sealed_host_management_child invitation-mint \\\n")
        )
        XCTAssertTrue(
            source[request.lowerBound...].hasPrefix(
                "\nif run_sealed_host_management_child invitation-mint \\\n" +
                    "    \"${ARTIFACT_DIR}/invitation-request.stdout.log\" \\\n" +
                    "    \"${ARTIFACT_DIR}/invitation-request.stderr.log\" 0 \\\n" +
                    "    --request-secondary-test-viewer-invitation \"$INVITATION_SOURCE\"; then"
            )
        )
        let validate = try XCTUnwrap(
            source.range(
                of: "\nvalidate_invitation_source\n",
                options: .backwards
            )
        )
        let validateReceipt = try XCTUnwrap(
            source.range(
                of: "\nvalidate_host_generation_receipt \\\n",
                options: .backwards
            )
        )
        let copy = try XCTUnwrap(source.range(of: "\nSTAGE=invitation-copy\n"))
        let test = try XCTUnwrap(
            source.range(of: "\nxcodebuild test-without-building \\\n")
        )

        XCTAssertLessThan(monitor.lowerBound, install.lowerBound)
        XCTAssertLessThan(install.lowerBound, mint.lowerBound)
        XCTAssertLessThan(mint.lowerBound, request.lowerBound)
        XCTAssertLessThan(request.lowerBound, validateReceipt.lowerBound)
        XCTAssertLessThan(validateReceipt.lowerBound, validate.lowerBound)
        XCTAssertLessThan(validate.lowerBound, copy.lowerBound)
        XCTAssertLessThan(copy.lowerBound, test.lowerBound)
    }

    func testPhysicalTestSelectsBuiltArm64Architecture() throws {
        let source = try source
        let start = try XCTUnwrap(source.range(of: "\nxcodebuild test-without-building \\\n"))
        let end = try XCTUnwrap(source.range(
            of: "\nPHYSICAL_TEST_PID=$!", range: start.upperBound..<source.endIndex
        ))
        let invocation = String(source[start.lowerBound..<end.lowerBound])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iphone15-test-destination-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        func capturedDestination(_ command: String) throws -> String {
            let argumentsFile = root.appendingPathComponent("arguments.txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-f", "-c", """
            set -euo pipefail
            HARDWARE_UDID=00008120-0000242E3E32201E
            XCTESTRUN_FILE=/fixture/prepared.xctestrun
            TEST_ID=fixture/selectedTest
            RESULT_BUNDLE="$ARTIFACT_DIR/result.xcresult"
            function xcodebuild() { printf '%s\\n' "$@" > "$CAPTURED_ARGS" }
            \(command)
            wait $!
            """]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "ARTIFACT_DIR": root.path,
                "CAPTURED_ARGS": argumentsFile.path,
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(arguments.filter { $0 == "-destination" }.count, 1)
            let index = try XCTUnwrap(arguments.firstIndex(of: "-destination"))
            return arguments[index + 1]
        }

        let expected = "platform=iOS,arch=arm64,id=00008120-0000242E3E32201E"
        XCTAssertEqual(try capturedDestination(invocation), expected)
        let unpinned = invocation.replacingOccurrences(of: "platform=iOS,arch=arm64,id=",
                                                       with: "platform=iOS,id=")
        XCTAssertNotEqual(try capturedDestination(unpinned), expected)
    }

    func testPhysicalTestIsSupervisedAndStoppedBeforeFinalizerDeviceCleanup() throws {
        let source = try source
        let launch = try XCTUnwrap(
            source.range(of: "\nxcodebuild test-without-building \\\n")
        )
        let publishPID = try XCTUnwrap(
            source.range(of: "\nPHYSICAL_TEST_PID=$!\n", range: launch.lowerBound..<source.endIndex)
        )
        let healthLoop = try XCTUnwrap(
            source.range(
                of: "\nwhile owned_child_is_alive \"$PHYSICAL_TEST_PID\"; do\n",
                range: publishPID.lowerBound..<source.endIndex
            )
        )
        XCTAssertLessThan(launch.lowerBound, publishPID.lowerBound)
        XCTAssertLessThan(publishPID.lowerBound, healthLoop.lowerBound)
        XCTAssertTrue(
            source.contains("if ! power_assertion_status_is_valid active; then")
        )
        XCTAssertTrue(
            source.contains("stop_physical_test_process power-assertion-heartbeat-failure")
        )

        let finalizerStop = try XCTUnwrap(
            source.range(
                of: "stop_physical_test_process finalizer-before-device-secret-cleanup"
            )
        )
        let finalizerCleanup = try XCTUnwrap(
            source.range(of: "\n  if (( DEVICE_SECRET_CLEANUP_REQUIRED != 0 )); then\n")
        )
        XCTAssertLessThan(finalizerStop.lowerBound, finalizerCleanup.lowerBound)
    }

    func testDevelopmentPixelMarkerRequiresDecodedTerminalComposite() throws {
        let source = try uiTestSource
        let terminalDeadline = try XCTUnwrap(
            source.range(of: "let terminalDeadline = Date().addingTimeInterval(")
        )
        let terminalSymbol = try XCTUnwrap(
            source.range(of: "var terminalSymbol: PhysicalScreenSequenceSymbol?")
        )
        let terminalAssertion = try XCTUnwrap(
            source.range(
                of: "XCTAssertNotNil(\n      terminalSymbol,"
            )
        )
        let marker = try XCTUnwrap(
            source.range(
                of: "OPENSTEAMER_IPHONE15_DEV_SCREEN_VISUAL_ORACLE_V1"
            )
        )

        XCTAssertLessThan(terminalDeadline.lowerBound, terminalSymbol.lowerBound)
        XCTAssertLessThan(terminalSymbol.lowerBound, terminalAssertion.lowerBound)
        XCTAssertLessThan(terminalAssertion.lowerBound, marker.lowerBound)
        XCTAssertTrue(
            source.contains("let symbol = frame.decode(nonce: nonce)")
        )
        XCTAssertTrue(
            source.contains("tracker.observeUndecodableFrame()")
        )
    }

    func testRunnerOwnsCleanupForMintedButInvalidCapability() throws {
        let source = try source
        XCTAssertTrue(
            source.contains(
                "INVITATION_SOURCE_MINT_ATTEMPTED=1\ntypeset -i invitation_request_status=0"
            )
        )
        XCTAssertTrue(
            source.contains(
                "INVITATION_SOURCE_MINT_ATTEMPTED != 0 && INVITATION_SOURCE_DELETED == 0"
            )
        )
        XCTAssertTrue(source.contains("/bin/rm -f \"$INVITATION_SOURCE\""))
        XCTAssertTrue(
            source.contains(
                "[[ ! -s \"${ARTIFACT_DIR}/invitation-request.stdout.log\""
            )
        )
        XCTAssertTrue(
            source.contains(
                "--stop-secondary-test-viewer-generation \"$HOST_GENERATION_RECEIPT\""
            )
        )
        XCTAssertTrue(
            source.contains(
                "stop_secondary_generation || { result=1; cleanup_teardown_clean=0; }"
            )
        )
    }

    func testRunnerRevalidatesContinuityImmediatelyBeforeMint() throws {
        let source = try source
        let stage = try XCTUnwrap(source.range(of: "\nSTAGE=invitation-mint\n"))
        let request = try XCTUnwrap(
            source.range(of: "\nif run_sealed_host_management_child invitation-mint \\\n")
        )
        for required in [
            "capture_host_generation_identity before-invitation-mint",
            "capture_device_identity before-invitation-mint",
            "require_no_host_lifecycle_delta before-invitation-mint-initial",
            "capture_primary_continuity premint",
            "capture_secondary_manager_idle_probe premint",
            "require_no_host_lifecycle_delta before-invitation-mint-final",
        ] {
            let check = try XCTUnwrap(
                source.range(of: required, range: stage.lowerBound..<request.lowerBound),
                required
            )
            XCTAssertLessThan(stage.lowerBound, check.lowerBound)
            XCTAssertLessThan(check.lowerBound, request.lowerBound)
        }

        let continuity = try XCTUnwrap(
            source.range(of: "capture_primary_continuity premint", range: stage.lowerBound..<request.lowerBound)
        )
        let probe = try XCTUnwrap(
            source.range(of: "capture_secondary_manager_idle_probe premint", range: stage.lowerBound..<request.lowerBound)
        )
        let finalLifecycleFence = try XCTUnwrap(
            source.range(
                of: "require_no_host_lifecycle_delta before-invitation-mint-final",
                range: stage.lowerBound..<request.lowerBound
            )
        )
        XCTAssertLessThan(continuity.lowerBound, probe.lowerBound)
        XCTAssertLessThan(probe.lowerBound, finalLifecycleFence.lowerBound)
        XCTAssertLessThan(finalLifecycleFence.lowerBound, request.lowerBound)

        let postflight = try XCTUnwrap(source.range(of: "\nSTAGE=postflight\n"))
        let routeMonitorTeardown = try XCTUnwrap(
            source.range(
                of: "\nSTAGE=audio-route-monitor-teardown\n",
                range: postflight.lowerBound..<source.endIndex
            )
        )
        let afterContinuity = try XCTUnwrap(
            source.range(
                of: "capture_primary_continuity after",
                range: postflight.lowerBound..<routeMonitorTeardown.lowerBound
            )
        )
        let afterProbe = try XCTUnwrap(
            source.range(
                of: "capture_secondary_manager_idle_probe after",
                range: postflight.lowerBound..<routeMonitorTeardown.lowerBound
            )
        )
        let finalPostflightFence = try XCTUnwrap(
            source.range(
                of: "host_delta_is_complete ",
                range: afterProbe.lowerBound..<routeMonitorTeardown.lowerBound
            )
        )
        XCTAssertLessThan(afterContinuity.lowerBound, afterProbe.lowerBound)
        XCTAssertLessThan(afterProbe.lowerBound, finalPostflightFence.lowerBound)
        XCTAssertLessThan(finalPostflightFence.lowerBound, routeMonitorTeardown.lowerBound)
    }

    func testRunnerRetainsValidatedGenerationIdentityAfterReceiptConsumption() throws {
        let source = try source
        let validator = try XCTUnwrap(
            source.range(of: "\nfunction validate_host_generation_receipt() {\n")
        )
        let stop = try XCTUnwrap(source.range(of: "\nfunction stop_secondary_generation() {\n"))
        let validatorSource = String(source[validator.lowerBound..<stop.lowerBound])

        XCTAssertTrue(validatorSource.contains("validated_receipt_json=$(jq -c -e -S -s"))
        XCTAssertTrue(validatorSource.contains(".receipt.hostGeneration"))
        XCTAssertTrue(validatorSource.contains(".receipt.managerGeneration | tostring"))
        XCTAssertTrue(validatorSource.contains(".receipt.renewalRequestNonce"))
        XCTAssertTrue(
            validatorSource.contains(
                "SECONDARY_HOST_GENERATION=$validated_host_generation"
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "SECONDARY_MANAGER_GENERATION=$validated_manager_generation"
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "SECONDARY_RENEWAL_REQUEST_NONCE=$validated_renewal_request_nonce"
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "SECONDARY_VALIDATED_RECEIPT_SHA256=$validated_receipt_sha256"
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "if (( HOST_GENERATION_RECEIPT_VALIDATED != 0 )); then"
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "\"$validated_receipt_sha256\" == \"$SECONDARY_VALIDATED_RECEIPT_SHA256\""
            )
        )
        XCTAssertTrue(
            validatorSource.contains(
                "validated_receipt_sha256=$(print -rn -- \"$validated_receipt_json\""
            )
        )
        XCTAssertFalse(validatorSource.contains("$(<\"$INVITATION_SOURCE\")"))

        let cleanup = try XCTUnwrap(
            source.range(
                of: "\n  stop_secondary_generation || { result=1; cleanup_teardown_clean=0; }\n"
            )
        )
        let summary = try XCTUnwrap(
            source.range(of: "\n    --arg secondaryHostGeneration \"$SECONDARY_HOST_GENERATION\" \\\n")
        )
        XCTAssertLessThan(cleanup.lowerBound, summary.lowerBound)
        for retainedField in [
            "--arg secondaryManagerGenerationBaseline \"$SECONDARY_MANAGER_GENERATION_BASELINE\"",
            "--arg secondaryManagerGeneration \"$SECONDARY_MANAGER_GENERATION\"",
            "--arg secondaryRenewalRequestNonce \"$SECONDARY_RENEWAL_REQUEST_NONCE\"",
            "--arg secondaryValidatedReceiptSHA256 \"$SECONDARY_VALIDATED_RECEIPT_SHA256\"",
            "--argjson secondaryGenerationReceiptValidated \"$HOST_GENERATION_RECEIPT_VALIDATED\"",
            "receiptValidated:($secondaryGenerationReceiptValidated == 1)",
            "hostGeneration:(if $secondaryHostGeneration == \"\" then null",
            "baselineManagerGeneration:(if $secondaryManagerGenerationBaseline == \"\"",
            "managerGeneration:(if $secondaryManagerGeneration == \"\" then null",
            "renewalRequestNonce:(if $secondaryRenewalRequestNonce == \"\" then null",
            "validatedReceiptSHA256:(if $secondaryValidatedReceiptSHA256 == \"\" then null",
            "stopped:($secondaryGenerationStopped == 1)",
        ] {
            XCTAssertTrue(source.contains(retainedField), retainedField)
        }
        XCTAssertTrue(
            validatorSource.contains(
                "secondary_manager_receipt_generation_is_expected"
            )
        )
        XCTAssertFalse(source.contains("--arg invitation \"$INVITATION_SOURCE\""))
    }

    func testRunnerProvesDeviceSecretCleanupBeforeMintAndOnEveryPostCopyExit() throws {
        let source = try source
        let preclean = try XCTUnwrap(
            source.range(of: "\nrun_device_secret_cleanup pre-mint-cleanup \\\n")
        )
        let mint = try XCTUnwrap(source.range(of: "\nSTAGE=invitation-mint\n"))
        let copyArmed = try XCTUnwrap(
            source.range(of: "\nDEVICE_SECRET_CLEANUP_REQUIRED=1\n")
        )
        let copyCommand = try XCTUnwrap(
            source.range(of: "\nxcrun devicectl device copy to \\\n")
        )
        let finalizerCleanup = try XCTUnwrap(
            source.range(of: "\n  if (( DEVICE_SECRET_CLEANUP_REQUIRED != 0 )); then\n")
        )
        let monitorFinalizer = try XCTUnwrap(
            source.range(of: "\n  if [[ -n \"$AUDIO_ROUTE_MONITOR_PID\" ]]; then\n")
        )

        XCTAssertLessThan(preclean.lowerBound, mint.lowerBound)
        XCTAssertLessThan(copyArmed.lowerBound, copyCommand.lowerBound)
        XCTAssertLessThan(finalizerCleanup.lowerBound, monitorFinalizer.lowerBound)
        XCTAssertTrue(
            source.contains(
                "elif [[ -n \"$SIGNAL_NAME\" ]] && (( monitor_teardown_clean == 1 \\\n      && cleanup_teardown_clean == 1 )); then"
            )
        )
        XCTAssertTrue(
            source.contains(
                "verify_device_secret_cleanup_receipt \"$NONCE\" viewer-import"
            )
        )
    }

    func testRunnerCannotRestartHostOrResetProductionPairing() throws {
        let source = try source
        for forbidden in [
            "launchctl kickstart",
            "launchctl bootout",
            "--reset-worldwide-pairing",
            "kill -TERM \"$HOST_PID\"",
            "kill -KILL \"$HOST_PID\"",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        XCTAssertTrue(
            source.contains(
                "readonly HOST_EXECUTABLE='/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer'"
            )
        )
    }
}
