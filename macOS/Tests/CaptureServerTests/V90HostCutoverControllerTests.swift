import Foundation
import XCTest

/// Offline-only contract tests for the one-shot V90 host cutover controller. These tests use the
/// controller's fake adapter and never invoke either live mode.
final class V90HostCutoverControllerTests: XCTestCase {
    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var controller: URL {
        repositoryRoot.appendingPathComponent(
            "macOS/scripts/opensteamer-host-v90-cutover-controller.rb"
        )
    }

    private var launcher: URL {
        repositoryRoot.appendingPathComponent(
            "macOS/scripts/run-opensteamer-host-v90-cutover.sh"
        )
    }

    private var routeMonitor: URL {
        repositoryRoot.appendingPathComponent(
            "macOS/scripts/opensteamer-v90-coreaudio-route-monitor.swift"
        )
    }

    func testPureSelfTestCoversCommitAndRollbackStateMachine() throws {
        let result = try run(["--self-test-v90-cutover"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "opensteamer V90 cutover self-test: PASS\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testLiveModesRejectIncompleteInvocationBeforeHostObservation() throws {
        for mode in [
            "--verify-v90-cutover-preflight",
            "--execute-authorized-v90-cutover",
        ] {
            let result = try run([mode])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(
                result.stderr.contains(
                    "mode requires capsule root and exactly two external digests"
                ),
                result.stderr
            )
            XCTAssertEqual(result.stdout, "")
        }
    }

    func testDirectLiveModeRejectsLauncherBypassBeforeCapsuleObservation() throws {
        let digest = String(repeating: "0", count: 64)
        let result = try run([
            "--verify-v90-cutover-preflight", "/does/not/exist", digest, digest,
        ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertTrue(
            result.stderr.contains("live V90 modes require the independently pinned launcher"),
            result.stderr
        )
    }

    func testPinnedLauncherCanRunOnlyOfflineSelfTestWhileApprovalPinIsInvalid() throws {
        let selfTest = try runExecutable(launcher, arguments: ["--self-test-v90-cutover"])
        XCTAssertEqual(selfTest.status, 0, selfTest.stderr)
        XCTAssertEqual(selfTest.stdout, "opensteamer V90 cutover self-test: PASS\n")
        XCTAssertEqual(selfTest.stderr, "")

        let digest = String(repeating: "0", count: 64)
        let blocked = try runExecutable(
            launcher,
            arguments: ["--verify-v90-cutover-preflight", "/does/not/exist", digest, digest]
        )
        XCTAssertNotEqual(blocked.status, 0)
        XCTAssertTrue(
            blocked.stderr.contains("explicit Ahmed approval"),
            blocked.stderr
        )
    }

    func testStickyCoreAudioMonitorTypechecksWithoutExecution() throws {
        let swiftc = URL(fileURLWithPath:
            "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        )
        let sdk = "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
        let result = try runExecutable(swiftc, arguments: [
            "-sdk", sdk, "-typecheck", routeMonitor.path,
            "-framework", "CoreAudio", "-framework", "Foundation",
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }

    func testSourcePinsExactV90AndTenArgumentLaunchContract() throws {
        let source = try String(contentsOf: controller, encoding: .utf8)
        XCTAssertTrue(source.contains("229eabc22b9990891c5e5b2a5cfa27111f0a6b3e"))
        XCTAssertTrue(source.contains("0192ef02be478f094afe1f66b50fe3b14717d0ea"))
        XCTAssertTrue(source.contains("--virtual-phone-display"))
        XCTAssertTrue(source.contains("--secondary-test-viewer"))
        XCTAssertTrue(source.contains("STOP_INTENT"))
        XCTAssertTrue(source.contains("READY_VERIFIED"))
        XCTAssertTrue(source.contains("COMMIT_INTENT"))
        XCTAssertTrue(source.contains("V90_COMMIT_IRREVERSIBLE"))
        XCTAssertTrue(source.contains("COMMITTED_V90"))
        XCTAssertTrue(source.contains("COMMITTED_V90_UNVERIFIED"))
        XCTAssertTrue(source.contains("ROLLED_BACK_EXACT_V86"))
        XCTAssertTrue(source.contains("UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL"))
        XCTAssertTrue(source.contains("v90-candidate-app-copy-manifest.txt"))
        XCTAssertTrue(source.contains("sticky-coreaudio-route-monitor"))
        XCTAssertTrue(source.contains("\"TMPDIR\" => compiler_tmp"))
        XCTAssertTrue(source.contains("Thread.handle_interrupt(Interrupt => :never)"))
        XCTAssertTrue(source.contains("result=pending-terminal"))
        XCTAssertTrue(source.contains("commit-safety-proof.txt"))
        XCTAssertTrue(source.contains("result=committed-but-unverified"))
        XCTAssertTrue(source.contains("rollback-result.txt"))
        XCTAssertTrue(source.contains("ls-remote"))
        XCTAssertTrue(source.contains("hash-object"))
        XCTAssertTrue(source.contains("+#{pid}"))
        XCTAssertTrue(source.contains("renamex_np"))
        XCTAssertTrue(source.contains("RENAME_EXCL"))
        XCTAssertTrue(source.contains("durably_sync_staged_candidate!"))
        XCTAssertTrue(source.contains("durably_sync_transaction_topology!"))
        XCTAssertTrue(source.contains("strict_fsync_regular!"))
        XCTAssertTrue(source.contains("strict_fsync_directory!"))
        XCTAssertTrue(source.contains("after_directory_create_before_identity!"))
        XCTAssertTrue(source.contains("after_file_create_before_identity!"))
        XCTAssertTrue(source.contains("set_durable_mode!"))
        XCTAssertTrue(source.contains("host quiescent-session boundary changed"))
        XCTAssertTrue(source.contains("host stdout log historical bytes changed"))
        XCTAssertTrue(source.contains("verify_candidate_stability_sample!"))
        XCTAssertTrue(source.contains("managerGeneration"))
        XCTAssertTrue(source.contains("journal torn-record rollback"))
        XCTAssertFalse(source.contains("rm_rf"))
        XCTAssertFalse(source.contains("finalize_commit!"))
        XCTAssertFalse(source.contains("4b353f"))
        XCTAssertFalse(source.contains("/Applications/AudioStreamer Host.app"))
        XCTAssertFalse(source.contains("SwitchAudioSource\", \"-s"))
    }

    func testLauncherRequiresCanonicalCleanFreshTrackedToolingForLiveModes() throws {
        let source = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(source.contains("verify_regular_metadata \"$LAUNCHER\" 501 755 0"))
        XCTAssertTrue(source.contains("status --porcelain=v1 --untracked-files=all"))
        XCTAssertTrue(source.contains("ls-remote --exit-code --refs --heads"))
        XCTAssertTrue(source.contains("remote get-url --push --all origin"))
        XCTAssertTrue(source.contains("hash-object --no-filters"))
        XCTAssertTrue(source.contains("OPENSTEAMER_V90_TOOLING_COMMIT"))
        XCTAssertTrue(source.contains("OPENSTEAMER_V90_LAUNCHER_BLOB"))
        XCTAssertTrue(source.contains("UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL"))
    }

    private func run(_ arguments: [String]) throws -> Result {
        try runExecutable(
            URL(fileURLWithPath: "/usr/bin/ruby"),
            arguments: [controller.path] + arguments
        )
    }

    private func runExecutable(_ executable: URL, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            stderr: String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}
