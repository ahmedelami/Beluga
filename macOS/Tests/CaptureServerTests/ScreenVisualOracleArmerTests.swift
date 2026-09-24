import Foundation
import XCTest

final class ScreenVisualOracleArmerTests: XCTestCase {
    private let deviceID = "00000000-0000-4000-8000-000000000000"
    private let hardwareUDID = "00000000-0000000000000000"

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var armer: URL {
        repositoryRoot.appendingPathComponent(
            "iOS/opensteamer/scripts/arm-testflight-screen-visual-oracle.sh"
        )
    }

    private var armerSource: String {
        get throws {
            try String(contentsOf: armer, encoding: .utf8)
        }
    }

    func testArmerRequiresExactStatusIdentityAndNeverTreatsBareSessionAsSuccess()
        throws {
        let source = try armerSource

        for required in [
            ".schema == \"opensteamer.screen-visual-oracle-run.v1\"",
            ".deviceId == $deviceId",
            ".hardwareUDID == $hardwareUDID",
            ".deviceModelName == $deviceModelName",
            ".bundleId == $bundleId",
            ".build == $build",
            ".hostIdentityManifestSHA256Path == $hostIdentityManifestSHA256Path",
            ".hostIdentityManifestSHA256 == $hostIdentityManifestSHA256",
            ".pid == (.pid | floor)",
            "[[ \"$command\" == *\"${RUNNER} ${DEVICE_ID} ${HARDWARE_UDID} ${EXPECTED_BUILD}\" ]]",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(
            source.contains(
                "${RUNNER} ${DEVICE_ID} ${HARDWARE_UDID} ${EXPECTED_BUILD}\"* ]]"
            )
        )

        let existingSessionStart = try XCTUnwrap(
            source.range(of: "\nif screen_session_is_live; then\n")
        )
        let existingSessionEnd = try XCTUnwrap(
            source.range(
                of: "\nfi\n",
                range: existingSessionStart.upperBound..<source.endIndex
            )
        )
        let existingSession = String(
            source[existingSessionStart.lowerBound..<existingSessionEnd.upperBound]
        )
        XCTAssertTrue(existingSession.contains("exit 1"))
        XCTAssertFalse(existingSession.contains("exit 0"))
        XCTAssertTrue(
            source.contains(
                "Screen visual oracle session did not publish a matching live runner:"
            )
        )
        XCTAssertEqual(source.split(separator: "\n").last.map(String.init), "exit 1")
    }

    func testArmerRejectsIPhone15BeforeAnyProductionPreflight() throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            armer.path,
            "10B6E5EE-D3B9-5334-99C1-EA12EFA34447",
            "00008120-0000242E3E32201E",
            "84",
        ]
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
            "stdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        )
        XCTAssertTrue(
            standardError.contains(
                "exact pinned iPhone 17 Pro CoreDevice and hardware UDID"
            )
        )
    }

    func testArmerReconciliationRejectsDeadWrongAndUnpublishedRunners() throws {
        let source = try armerSource
        let reconciliationStart = try XCTUnwrap(
            source.range(of: "\nfunction active_runner_pid() {\n")
        )
        let reconciliation = String(source[reconciliationStart.lowerBound...])
        XCTAssertEqual(
            reconciliation.components(separatedBy: "/usr/bin/screen").count - 1,
            2
        )
        XCTAssertEqual(
            reconciliation.components(separatedBy: "/bin/sleep 0.1").count - 1,
            1
        )
        let testReconciliation = reconciliation
            .replacingOccurrences(of: "/usr/bin/screen", with: "screen")
            .replacingOccurrences(of: "/bin/sleep 0.1", with: ":")

        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "screen-armer-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let harness = root.appendingPathComponent("armer-reconciliation.zsh")
        try harnessSource(reconciliation: testReconciliation).write(
            to: harness,
            atomically: true,
            encoding: .utf8
        )

        let cases: [(
            name: String,
            status: Int32,
            message: String,
            bootoutExpected: Bool
        )] = [
            ("exact", 0, "already armed", false),
            ("dead", 1, "has no matching live runner", false),
            ("wrong-status-build", 1, "has no matching live runner", false),
            ("wrong-command-build-prefix", 1, "has no matching live runner", false),
            ("preexisting-no-status", 1, "has no matching live runner", false),
            ("launched-no-status", 1, "did not publish a matching live runner", false),
            ("inert-launchd", 1, "did not publish a matching live runner", true),
            ("launchd-live-wrong-build", 1, "left intact", false),
            ("launchd-live-unpublished", 1, "left intact", false),
        ]
        for testCase in cases {
            let caseRoot = root.appendingPathComponent(testCase.name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: caseRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let result = try runHarness(
                harness,
                caseName: testCase.name,
                root: caseRoot
            )
            XCTAssertEqual(
                result.status,
                testCase.status,
                "\(testCase.name) stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
            XCTAssertTrue(
                (result.stdout + result.stderr).contains(testCase.message),
                "\(testCase.name) stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
            XCTAssertEqual(
                FileManager.default.fileExists(
                    atPath: caseRoot.appendingPathComponent("bootout.called").path
                ),
                testCase.bootoutExpected,
                "\(testCase.name) unexpectedly changed launchd state"
            )
        }
    }

    private func harnessSource(reconciliation: String) -> String {
        """
        #!/bin/zsh
        set -euo pipefail
        readonly DEVICE_ID='\(deviceID)'
        readonly HARDWARE_UDID='\(hardwareUDID)'
        readonly PRODUCTION_DEVICE_MODEL_NAME='iPhone 17 Pro'
        readonly EXPECTED_BUILD=84
        readonly APP_BUNDLE_ID=com.elamin.opensteamer
        readonly HOST_IDENTITY_MANIFEST="${TEST_ROOT}/host-identity.json"
        readonly HOST_IDENTITY_MANIFEST_SHA256_PATH="${HOST_IDENTITY_MANIFEST}.sha256"
        readonly HOST_IDENTITY_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        readonly RUNNER="${TEST_ROOT}/validate-testflight-screen-visual-oracle.sh"
        readonly RUN_STATUS="${TEST_ROOT}/status.json"
        readonly RUN_LOG="${TEST_ROOT}/runner.log"
        readonly RUN_ERROR_LOG="${TEST_ROOT}/runner.error.log"
        readonly LAUNCH_AGENT_PLIST="${TEST_ROOT}/launch-agent.plist"
        readonly JOB_TARGET=gui/501/test.screen-oracle
        readonly LABEL=test.screen-oracle
        readonly SCREEN_SESSION=test-screen-oracle
        readonly LAUNCH_PATH=/usr/bin:/bin:/usr/sbin:/sbin
        readonly SCREEN_STATE="${TEST_ROOT}/screen.live"
        readonly BOOTOUT_LOG="${TEST_ROOT}/bootout.called"
        typeset -g COMMAND_BUILD=84
        typeset -g LAUNCHD_STATE=absent

        function write_status() {
          local status_pid=$1 status_build=$2
          jq -n \
            --arg schema opensteamer.screen-visual-oracle-run.v1 \
            --arg phase armed \
            --argjson pid "$status_pid" \
            --arg deviceId "$DEVICE_ID" \
            --arg hardwareUDID "$HARDWARE_UDID" \
            --arg deviceModelName "$PRODUCTION_DEVICE_MODEL_NAME" \
            --arg bundleId "$APP_BUNDLE_ID" \
            --arg build "$status_build" \
            --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
            --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" \
            '{schema:$schema,phase:$phase,pid:$pid,deviceId:$deviceId,
              hardwareUDID:$hardwareUDID,deviceModelName:$deviceModelName,
              bundleId:$bundleId,build:$build,
              hostIdentityManifestSHA256Path:$hostIdentityManifestSHA256Path,
              hostIdentityManifestSHA256:$hostIdentityManifestSHA256}' \
            > "$RUN_STATUS"
        }
        function ps() {
          print -r -- "/bin/zsh ${RUNNER} ${DEVICE_ID} ${HARDWARE_UDID} ${COMMAND_BUILD}"
        }
        function launchctl() {
          if [[ "${1:-}" == print ]]; then
            case "$LAUNCHD_STATE" in
              absent) return 1 ;;
              inert)
                print -r -- 'gui/501/test.screen-oracle = {'
                print -r -- '  active count = 0'
                print -r -- '  state = not running'
                print -r -- '}'
                return 0
                ;;
              running)
                print -r -- 'gui/501/test.screen-oracle = {'
                print -r -- '  active count = 1'
                print -r -- '  state = running'
                print -r -- "  pid = $$"
                print -r -- '}'
                return 0
                ;;
              *) return 98 ;;
            esac
          fi
          if [[ "${1:-}" == bootout ]]; then
            print -r -- "$*" > "$BOOTOUT_LOG"
            LAUNCHD_STATE=absent
            return 0
          fi
          return 98
        }
        function screen() {
          if [[ "${1:-}" == -ls ]]; then
            [[ -f "$SCREEN_STATE" ]] || return 1
            print -r -- "4242.${SCREEN_SESSION} (Detached)"
            return 0
          fi
          if [[ "${1:-}" == -dmS ]]; then
            : > "$SCREEN_STATE"
            return 0
          fi
          return 1
        }

        case "$ARMER_CASE" in
          exact) write_status $$ 84 ;;
          dead) write_status 999999 84; : > "$SCREEN_STATE" ;;
          wrong-status-build) write_status $$ 85; : > "$SCREEN_STATE" ;;
          wrong-command-build-prefix)
            COMMAND_BUILD=840
            write_status $$ 84
            : > "$SCREEN_STATE"
            ;;
          preexisting-no-status) : > "$SCREEN_STATE" ;;
          launched-no-status) ;;
          inert-launchd) LAUNCHD_STATE=inert ;;
          launchd-live-wrong-build)
            write_status $$ 85
            LAUNCHD_STATE=running
            ;;
          launchd-live-unpublished) LAUNCHD_STATE=running ;;
          *) exit 98 ;;
        esac
        \(reconciliation)
        """
    }

    private func runHarness(
        _ harness: URL,
        caseName: String,
        root: URL
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [harness.path]
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"]
                ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "ARMER_CASE": caseName,
            "TEST_ROOT": root.path,
        ]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}
