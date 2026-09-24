import Foundation
import XCTest

final class IPhone15UnlockAcknowledgementTests: XCTestCase {
    private var scripts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/opensteamer/scripts")
    }

    private func validate(_ mutation: String = ".", changeRequest: Bool = false) throws -> (Int32, String) {
        let runner = try String(contentsOf: scripts.appendingPathComponent(
            "validate-iphone15-dev-screen-visual-oracle.sh"
        ), encoding: .utf8)
        let start = try XCTUnwrap(runner.range(of: "\nfunction publish_unlock_request() {\n"))
        let end = try XCTUnwrap(runner.range(
            of: "\nfunction wait_for_exact_device_unlocked_state_acknowledgement() {\n",
            range: start.upperBound..<runner.endIndex
        ))
        let functions = String(runner[start.lowerBound..<end.lowerBound])
        let helper = try String(contentsOf: scripts.appendingPathComponent(
            "ack-iphone15-dev-screen-visual-oracle-unlock.sh"
        ), encoding: .utf8)
        let serializerStart = try XCTUnwrap(helper.range(
            of: "jq -n --arg schema 'opensteamer.iphone15-dev-unlock-ack.v1'"
        ))
        let serializerEnd = try XCTUnwrap(helper.range(
            of: "\n/bin/chmod 600 \"$temporary_ack\"",
            range: serializerStart.upperBound..<helper.endIndex
        ))
        let serializer = String(helper[serializerStart.lowerBound..<serializerEnd.lowerBound])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iphone15-unlock-ack-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", """
        set -euo pipefail
        umask 077
        ARTIFACT_DIR="$FIXTURE_ROOT"
        UNLOCK_REQUEST="$ARTIFACT_DIR/unlock-request.json"
        UNLOCK_ACK="$ARTIFACT_DIR/unlock-ack.json"
        UNLOCK_REQUEST_PUBLISHED=0
        UNLOCK_GATE_TIMEOUT_SECONDS=120
        UNLOCK_ACK_MAX_AGE_SECONDS=30
        NONCE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        DEVICE_ID=10B6E5EE-D3B9-5334-99C1-EA12EFA34447
        HARDWARE_UDID=00008120-0000242E3E32201E
        APP_BUNDLE_ID=org.example.AudioStreamer.dev
        RUN_PROCESS_START='fixture process start'
        function fail() { print -u2 -- "$1"; exit 97 }
        \(functions)
        publish_unlock_request
        nonce=$NONCE
        runner_pid=$$
        runner_process_start=$RUN_PROCESS_START
        request_sha256=$UNLOCK_REQUEST_SHA256
        observed_unlocked_at=$(/bin/date '+%s')
        temporary_ack=$UNLOCK_ACK
        \(serializer)
        /bin/chmod 600 "$UNLOCK_ACK"
        jq "$FIXTURE_MUTATION" "$UNLOCK_ACK" > "$ARTIFACT_DIR/mutated-ack.json"
        /bin/mv "$ARTIFACT_DIR/mutated-ack.json" "$UNLOCK_ACK"
        if [[ "$FIXTURE_CHANGE_REQUEST" == yes ]]; then
          print -r -- 'changed request bytes' >> "$UNLOCK_REQUEST"
        fi
        validate_unlock_ack
        """]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "FIXTURE_ROOT": root.path,
            "FIXTURE_MUTATION": mutation,
            "FIXTURE_CHANGE_REQUEST": changeRequest ? "yes" : "no",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testProductionValidatorAcceptsHelperAcknowledgementRegardlessOfKeyOrder() throws {
        for mutation in [".", "to_entries | reverse | from_entries"] {
            let result = try validate(mutation)
            XCTAssertEqual(result.0, 0, result.1)
        }
    }

    func testProductionValidatorRejectsIdentityDigestAndControllerAbsenceMismatches() throws {
        for mutation in [
            ".schema = \"wrong\"", ".runNonce = \"wrong\"", ".runnerPid += 1",
            ".runnerProcessStart = \"wrong\"", ".deviceId = \"wrong\"",
            ".hardwareUDID = \"wrong\"", ".bundleId = \"wrong\"",
            ".unlockRequestSHA256 = \"wrong\"", ".matchingUnlockControllerAbsent = false",
        ] {
            let result = try validate(mutation)
            XCTAssertEqual(result.0, 1, "\(mutation): \(result.1)")
        }
    }

    func testProductionValidatorStillRequiresExactKeys() throws {
        for mutation in ["del(.matchingUnlockControllerAbsent)", ".unexpected = true"] {
            let result = try validate(mutation)
            XCTAssertEqual(result.0, 1, "\(mutation): \(result.1)")
        }
    }

    func testProductionValidatorRejectsInvalidOrStaleObservationTimes() throws {
        for mutation in [
            ".observedUnlockedAt |= tostring", ".observedUnlockedAt += 0.5",
            ".observedUnlockedAt -= 120", ".observedUnlockedAt += 60",
        ] {
            let result = try validate(mutation)
            XCTAssertEqual(result.0, 1, "\(mutation): \(result.1)")
        }
    }

    func testProductionValidatorRejectsChangedPublishedRequestBytes() throws {
        let result = try validate(changeRequest: true)
        XCTAssertEqual(result.0, 1, result.1)
    }
}
