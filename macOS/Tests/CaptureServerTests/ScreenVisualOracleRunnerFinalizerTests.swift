import Foundation
import XCTest

/// Fail-closed finalizer contract for the production/TestFlight physical screen oracle.
final class ScreenVisualOracleRunnerFinalizerTests: XCTestCase {
    private let selfTestDeviceID = "00000000-0000-4000-8000-000000000000"
    private let selfTestHardwareUDID = "00000000-0000000000000000"
    private let productionDeviceID = "7694F11E-D66D-5632-9A0D-462C980130A5"
    private let productionHardwareUDID = "00008150-0002581C3E3A401C"
    private let productionModelName = "iPhone 17 Pro"

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
                    "iOS/opensteamer/scripts/validate-testflight-screen-visual-oracle.sh"
                ),
                encoding: .utf8
            )
        }
    }

    private var runner: URL {
        repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/validate-testflight-screen-visual-oracle.sh"
        )
    }

    private var armerSource: String {
        get throws {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "iOS/opensteamer/scripts/arm-testflight-screen-visual-oracle.sh"
                ),
                encoding: .utf8
            )
        }
    }

    func testProductionDeviceBoundaryPinsIPhone17ProAndRejectsOtherIdentitiesBeforePreflight()
        throws {
        let source = try source
        let armer = try armerSource
        for required in [
            "readonly PRODUCTION_DEVICE_ID=\(productionDeviceID)",
            "readonly PRODUCTION_HARDWARE_UDID=\(productionHardwareUDID)",
            "readonly PRODUCTION_DEVICE_MODEL_NAME='\(productionModelName)'",
            #".result.hardwareProperties.marketingName == $model"#,
            #".device.deviceId == $udid and .device.modelName == $model"#,
            #".devicesAndConfigurations | type == "array" and length == 1"#,
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(
            source.contains(
                #".result.hardwareProperties.marketingName | startswith("iPhone")"#
            )
        )
        XCTAssertTrue(
            armer.contains("readonly PRODUCTION_DEVICE_ID=\(productionDeviceID)")
        )
        XCTAssertTrue(
            armer.contains("readonly PRODUCTION_HARDWARE_UDID=\(productionHardwareUDID)")
        )

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENSTEAMER_SCREEN_ORACLE_SELF_TEST")
        environment.removeValue(forKey: "OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT")
        environment.removeValue(
            forKey: "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST"
        )
        environment.removeValue(
            forKey: "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH"
        )
        environment.removeValue(
            forKey: "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256"
        )
        for identity in [
            (
                "iPhone15",
                "10B6E5EE-D3B9-5334-99C1-EA12EFA34447",
                "00008120-0000242E3E32201E",
                "84"
            ),
            ("reserved-self-test", selfTestDeviceID, selfTestHardwareUDID, "0"),
        ] {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [runner.path, identity.1, identity.2, identity.3]
            process.currentDirectoryURL = repositoryRoot
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
                2,
                "\(identity.0) stdout:\n\(standardOutput)\nstderr:\n\(standardError)"
            )
            XCTAssertTrue(
                standardError.contains(
                    "exact pinned iPhone 17 Pro CoreDevice and hardware UDID"
                ),
                identity.0
            )
            XCTAssertFalse(
                standardError.contains("release-sealed Mac host identity"),
                identity.0
            )
        }
    }

    func testPassedVerdictRequiresCleanChallengeAndCoreAudioTeardown() throws {
        let source = try source
        let finishStart = try XCTUnwrap(source.range(of: "\nfunction finish() {\n"))
        let signalHandler = try XCTUnwrap(
            source.range(
                of: "\nfunction handle_signal() {\n",
                range: finishStart.lowerBound..<source.endIndex
            )
        )
        let finish = String(source[finishStart.lowerBound..<signalHandler.lowerBound])

        for required in [
            "append_failure_reason 'visual challenge required forced finalizer teardown'\n        monitor_teardown_clean=0\n        result=1",
            "append_failure_reason 'visual challenge was not live at finalizer entry'\n      monitor_teardown_clean=0\n      result=1",
            "monitor_teardown_clean=0\n    result=1\n    append_failure_reason \\\n      'CoreAudio route monitor finalizer teardown was not clean with zero notifications'",
            "if (( result == 0 && VERIFIED == 1 && monitor_teardown_clean == 1 )); then",
        ] {
            XCTAssertTrue(finish.contains(required), required)
        }
    }

    func testSuccessfulPostflightRequiresUnchangedLiveScreenPresentation() throws {
        let source = try source
        let functionStart = try XCTUnwrap(
            source.range(of: "\nfunction require_existing_connected_session() {\n")
        )
        let nextFunction = try XCTUnwrap(
            source.range(
                of: "\nfunction ",
                range: functionStart.upperBound..<source.endIndex
            )
        )
        let continuityFence = String(
            source[functionStart.lowerBound..<nextFunction.lowerBound]
        )

        XCTAssertFalse(continuityFence.contains("allow_terminal_stop"))
        XCTAssertTrue(
            continuityFence.contains(
                "[[ \"$capture_stop_count\" == \"$CAPTURE_STOP_COUNT\" ]] \\\n      || fail \"screen presentation stopped at ${prefix}\""
            )
        )
        XCTAssertTrue(
            continuityFence.contains(
                "if [[ \"$capture_event\" != *'Starting screen video capture'* ]]; then"
            )
        )
        XCTAssertFalse(
            continuityFence.contains("Stopping screen video capture'* \\")
        )
        XCTAssertTrue(source.contains("require_existing_connected_session after\n"))
        XCTAssertTrue(source.contains("require_existing_connected_session final\n"))
        XCTAssertFalse(source.contains("require_existing_connected_session after 0"))
        XCTAssertFalse(source.contains("require_existing_connected_session final 0"))
    }

    func testReleaseSealedLiveHostIdentityBracketsChallengeLaunch() throws {
        let source = try source
        let armer = try armerSource
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
            "cmp -s \"$HOST_IDENTITY_BEFORE_CHALLENGE\" \"$snapshot\"",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertTrue(
            armer.contains(
                "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST=\"$HOST_IDENTITY_MANIFEST\""
            )
        )
        XCTAssertTrue(
            armer.contains(
                "OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH=\"$HOST_IDENTITY_MANIFEST_SHA256_PATH\""
            )
        )
        XCTAssertTrue(
            armer.contains(
                ".hostIdentityManifestSHA256 == $hostIdentityManifestSHA256"
            )
        )
    }

    func testForcedChallengeSelfTestPersistsFailClosedFinalizerOutcome() throws {
        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "screen-finalizer-\(UUID().uuidString.prefix(8))",
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
        process.arguments = [
            runner.path,
            selfTestDeviceID,
            selfTestHardwareUDID,
            "0",
        ]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST"] =
            "forced-challenge-cleanup"
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT"] = root.path
        environment["OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS"] = "1"
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

        let runStatusURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(
                "\(selfTestDeviceID)-com.elamin.opensteamer.json"
            )
        let runStatus = try jsonObject(at: runStatusURL)
        XCTAssertEqual(runStatus["phase"] as? String, "failed")
        XCTAssertEqual(
            runStatus["stage"] as? String,
            "self-test-forced-challenge-cleanup"
        )
        XCTAssertTrue(
            (runStatus["reason"] as? String)?.contains(
                "visual challenge required forced finalizer teardown"
            ) == true
        )

        let artifactDirectory = try XCTUnwrap(runStatus["artifactDir"] as? String)
        XCTAssertTrue(
            artifactDirectory.hasPrefix(root.path + "/opensteamer-screen-visual-oracle.")
        )
        let summaryPath = try XCTUnwrap(runStatus["summary"] as? String)
        XCTAssertTrue(summaryPath.hasPrefix(artifactDirectory + "/"))
        let summary = try jsonObject(at: URL(fileURLWithPath: summaryPath))
        XCTAssertEqual(summary["status"] as? String, "failed")
        XCTAssertEqual(
            summary["stage"] as? String,
            "self-test-forced-challenge-cleanup"
        )
        XCTAssertTrue(
            (summary["reason"] as? String)?.contains(
                "visual challenge required forced finalizer teardown"
            ) == true
        )
        XCTAssertEqual(summary["signal"] as? String, "")
        XCTAssertEqual(summary["nonce"] as? String, "")
        XCTAssertEqual(summary["visualMarker"] as? String, "")
    }

    func testFinalPassedStatusFailurePublishesNoPassBearingEvidence() throws {
        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "screen-pass-commit-\(UUID().uuidString.prefix(8))",
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
        process.arguments = [
            runner.path,
            selfTestDeviceID,
            selfTestHardwareUDID,
            "0",
        ]
        process.currentDirectoryURL = repositoryRoot
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST"] = "final-status-failure"
        environment["OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT"] = root.path
        environment["OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS"] = "1"
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
        XCTAssertFalse(standardOutput.contains("Screen visual oracle passed:"))

        let runStatusURL = root
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(
                "\(selfTestDeviceID)-com.elamin.opensteamer.json"
            )
        let runStatus = try jsonObject(at: runStatusURL)
        XCTAssertEqual(runStatus["phase"] as? String, "failed")
        XCTAssertTrue(
            (runStatus["reason"] as? String)?.contains(
                "could not commit its final passed status"
            ) == true
        )
        let summaryPath = try XCTUnwrap(runStatus["summary"] as? String)
        let summary = try jsonObject(at: URL(fileURLWithPath: summaryPath))
        XCTAssertEqual(summary["status"] as? String, "failed")
        XCTAssertNotEqual(summary["status"] as? String, "passed")
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
