import Foundation
import XCTest

final class IPhone15NeverConnectedPrimaryOracleTests: XCTestCase {
    private let generation = String(repeating: "a", count: 64)

    private var runnerSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(
                "iOS/opensteamer/scripts/validate-iphone15-dev-screen-visual-oracle.sh"
            ), encoding: .utf8)
        }
    }

    private func functions(from first: String, throughBefore next: String) throws -> String {
        let source = try runnerSource
        let start = try XCTUnwrap(source.range(of: "\nfunction \(first)() {\n"))
        let end = try XCTUnwrap(source.range(
            of: "\nfunction \(next)() {\n", range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private var freshLog: String {
        """
        [info] Loaded the paired iPhone and started worldwide availability
        [debug] Worldwide availability is waiting for the paired iPhone
        [info] Worldwide paired-device availability is online pid=321 nonce=\(generation)

        """
    }

    private func run(_ harness: String, log: String, idleGeneration: String = "0") throws -> (Int32, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iphone15-never-connected-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let hostLog = root.appendingPathComponent("host.log")
        try log.write(to: hostLog, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", """
        set -euo pipefail
        HOST_PID=321
        HOST_GENERATION=\(generation)
        HOST_LOG="$FIXTURE_LOG"
        ARTIFACT_DIR="$FIXTURE_ROOT"
        SECONDARY_MANAGER_GENERATION_BASELINE="$FIXTURE_IDLE_GENERATION"
        function fail() { print -u2 -- "$1"; exit 97 }
        \(harness)
        """]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "FIXTURE_LOG": hostLog.path,
            "FIXTURE_ROOT": root.path,
            "FIXTURE_IDLE_GENERATION": idleGeneration,
        ]
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testFreshGenerationProofRejectsMissingIdentityAndAnyPrimaryActivity() throws {
        let parser = try functions(
            from: "never_connected_primary_baseline_is_exact",
            throughBefore: "record_never_connected_primary_baseline"
        )
        let harness = parser + "\nnever_connected_primary_baseline_is_exact \"$HOST_LOG\"\n"
        let cases: [(String, String, String, Int32)] = [
            ("fresh", freshLog, "0", 0),
            ("historical-primary", "Worldwide audio client diagnostics pid=222\n" + freshLog, "0", 0),
            ("no-idle-probe", freshLog, "", 1),
            ("missing-startup", freshLog.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), "0", 1),
            ("missing-waiting", freshLog.replacingOccurrences(of: "[debug] Worldwide availability is waiting for the paired iPhone\n", with: ""), "0", 1),
            ("foreign-pid", freshLog.replacingOccurrences(of: "pid=321", with: "pid=322"), "0", 1),
            ("foreign-nonce", freshLog.replacingOccurrences(of: generation, with: String(repeating: "b", count: 64)), "0", 1),
            ("primary-audio", freshLog + "Worldwide audio client diagnostics pid=321 status=unavailable.stopped\n", "0", 1),
            ("connected-peer", freshLog + "Worldwide WebRTC peer state: connected pid=321\n", "0", 1),
            ("screen-started", freshLog + "Starting screen video capture\n", "0", 1),
            ("microphone", freshLog + "Worldwide iPhone microphone forwarding phase=forwardingHealthy\n", "0", 1),
            ("authenticated-route", freshLog + "Worldwide authenticated media route selected virtual microphone\n", "0", 1),
            ("primary-rendezvous-before-diagnostics", freshLog + "A fresh encrypted media rendezvous is ready for the paired iPhone\n", "0", 1),
            ("primary-left-availability-before-diagnostics", freshLog + "The paired iPhone left the availability exchange\n", "0", 1),
            ("late-waiting-does-not-erase-peer", freshLog + "Worldwide WebRTC peer state: connected pid=321\nWorldwide availability is waiting for the paired iPhone\n", "0", 1),
            ("completed-session-is-not-never-connected", freshLog + "Worldwide viewer disconnected;\nWorldwide media ended;\n", "0", 1),
            ("second-startup-cannot-erase-primary", freshLog + "Worldwide audio client diagnostics pid=321\n" + freshLog, "0", 1),
        ]
        for (name, log, idleGeneration, expected) in cases {
            let result = try run(harness, log: log, idleGeneration: idleGeneration)
            XCTAssertEqual(result.0, expected, "\(name): \(result.1)")
        }
    }

    func testFreshBaselineRunsExactIdleGateAndDoesNotFabricatePrimaryDiagnostics() throws {
        let helpers = try functions(
            from: "never_connected_primary_baseline_is_exact", throughBefore: "write_primary_continuity_window"
        )
        let capture = try functions(from: "capture_host_baseline", throughBefore: "write_host_delta")
        let harness = """
        \(helpers)
        \(capture)
        PRIMARY_SESSION_ID=''
        PRIMARY_PEER_GENERATION=''
        PRIMARY_NEGOTIATION_EPOCH=''
        PRIMARY_AUDIO_APP_ACTIVE=''
        SECONDARY_MANAGER_GENERATION_BASELINE=''
        HOST_BASELINE_TAIL_BYTES=4096
        function require_same_host() { return 0 }
        function capture_host_generation_identity() { [[ "$HOST_GENERATION" == \(generation) ]] }
        function capture_secondary_manager_idle_probe() {
          [[ "$1" == baseline && -z "$SECONDARY_MANAGER_GENERATION_BASELINE" ]]
          SECONDARY_MANAGER_GENERATION_BASELINE=0
        }
        function host_elapsed_seconds() { print 10 }
        capture_host_baseline
        [[ "$PRIMARY_BASELINE_MODE" == neverConnectedPrimary ]]
        [[ "$PRIMARY_CONTINUITY_ASSURANCE" == neverConnectedPrimaryNoAudioProof ]]
        [[ -z "$PRIMARY_SESSION_ID$PRIMARY_PEER_GENERATION$PRIMARY_NEGOTIATION_EPOCH$PRIMARY_AUDIO_APP_ACTIVE" ]]
        [[ "$HOST_LOG_BASE_SIZE" == "$(/usr/bin/stat -f '%z' "$HOST_LOG")" ]]
        [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$HOST_LOG_BASE_SIZE" ]]
        jq -e '.proof == "no-primary-since-host-generation-start" and
          .hostPid == 321 and .session == null and .build == null and
          .audioProof == false and .microphoneProof == false' \
          "$ARTIFACT_DIR/before-never-connected-primary-continuity.json" >/dev/null
        """
        let result = try run(harness, log: freshLog)
        XCTAssertEqual(result.0, 0, result.1)
    }

    func testNeverConnectedModeKeepsExistingNoReactivationContinuityFence() throws {
        let continuity = try functions(from: "capture_primary_continuity", throughBefore: "capture_host_generation_identity")
        let harness = """
        \(continuity)
        PRIMARY_BASELINE_MODE=neverConnectedPrimary
        function capture_inactive_primary_continuity() {
          [[ "$1" == premint || "$1" == after ]] || exit 93
          print -r -- "$1" >> "$ARTIFACT_DIR/continuity-calls"
        }
        function write_primary_continuity_window() { exit 94 }
        capture_primary_continuity premint
        capture_primary_continuity after
        [[ "$(<"$ARTIFACT_DIR/continuity-calls")" == $'premint\\nafter' ]]
        """
        let result = try run(harness, log: freshLog)
        XCTAssertEqual(result.0, 0, result.1)
    }

    func testPrimaryLifecycleBeforeDiagnosticsIsRejectedAtPremintAndAfter() throws {
        let continuity = try functions(
            from: "inactive_primary_online_announcements_are_exact",
            throughBefore: "stopped_audio_report_directory_identity"
        ) + functions(
            from: "inactive_primary_append_has_no_primary_activity",
            throughBefore: "capture_host_generation_identity"
        )
        let markers = [
            "A fresh encrypted media rendezvous is ready for the paired iPhone",
            "The paired iPhone left the availability exchange",
            "Worldwide screen host is waiting for the paired iPhone media session",
            "Fresh paired media rendezvous expires in about 60 seconds",
        ]
        for mode in ["neverConnectedPrimary", "inactivePrimary"] {
            for phase in ["premint", "after"] {
                let harness = """
                \(continuity)
                PRIMARY_BASELINE_MODE=\(mode)
                PRIMARY_CONTINUITY_ASSURANCE=fixtureNoAudioProof
                HOST_LOG_CONTINUITY_CURSOR=0
                function write_inactive_primary_append_window() {
                  /bin/cp "$HOST_LOG" "$1"
                  HOST_LOG_CONTINUITY_PENDING_CURSOR=$(/usr/bin/stat -f '%z' "$HOST_LOG")
                }
                function host_delta_is_complete() { return 0 }
                function write_primary_continuity_window() { exit 94 }
                capture_primary_continuity \(phase)
                [[ "$HOST_LOG_CONTINUITY_CURSOR" == "$HOST_LOG_CONTINUITY_PENDING_CURSOR" ]]
                """
                let safe = try run(harness, log: "[debug] benign fixture event\n")
                XCTAssertEqual(safe.0, 0, "\(mode)/\(phase): \(safe.1)")
                for marker in markers {
                    let result = try run(harness, log: "[info] \(marker)\n")
                    XCTAssertEqual(result.0, 97, "\(mode)/\(phase)/\(marker): \(result.1)")
                    XCTAssertTrue(result.1.contains("lifecycle reactivated at \(phase)"), result.1)
                }
            }
        }
    }
}
