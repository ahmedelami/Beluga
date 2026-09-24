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

    func testPinnedLauncherRunsOfflineSelfTestWithExactApprovedReferencePin() throws {
        let selfTest = try runExecutable(launcher, arguments: ["--self-test-v90-cutover"])
        XCTAssertEqual(selfTest.status, 0, selfTest.stderr)
        XCTAssertEqual(selfTest.stdout, "opensteamer V90 cutover self-test: PASS\n")
        XCTAssertEqual(selfTest.stderr, "")
    }

    func testReadinessObserverPreservesCapsuleAndPrivateStagingModes() throws {
        let source = try String(contentsOf: controller, encoding: .utf8)
        XCTAssertTrue(source.contains("READINESS_SOURCE_MODE = 0o755"))
        XCTAssertTrue(source.contains("READINESS_STAGED_MODE = 0o500"))

        let stageStart = try XCTUnwrap(
            source.range(of: "    def stage_post_stop_evidence!(capsule)")
        )
        let stageEnd = try XCTUnwrap(
            source.range(
                of: "      @post_stop_copy_manifest =",
                range: stageStart.upperBound..<source.endIndex
            )
        )
        let stageContract = String(source[stageStart.lowerBound..<stageEnd.lowerBound])
        XCTAssertTrue(stageContract.contains("mode: Pins::READINESS_SOURCE_MODE"))
        XCTAssertTrue(stageContract.contains("Pins::READINESS_STAGED_MODE"))
        XCTAssertFalse(stageContract.contains("0o500"))

        let verifyStart = try XCTUnwrap(
            source.range(of: "    def verify_post_stop_evidence!(capsule)")
        )
        let verifyEnd = try XCTUnwrap(
            source.range(
                of: "      copy_sha =",
                range: verifyStart.upperBound..<source.endIndex
            )
        )
        let verifyContract = String(source[verifyStart.lowerBound..<verifyEnd.lowerBound])
        XCTAssertTrue(verifyContract.contains("mode: Pins::READINESS_SOURCE_MODE"))
        XCTAssertTrue(verifyContract.contains("mode: Pins::READINESS_STAGED_MODE"))
        XCTAssertFalse(verifyContract.contains("mode: 0o500"))
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
        XCTAssertTrue(source.contains("553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66"))
        XCTAssertTrue(source.contains("11_442_304"))
        XCTAssertTrue(source.contains("11_401_072"))
        XCTAssertTrue(source.contains("41_232"))
        XCTAssertTrue(source.contains("a7885a8d1ffef70f5a747eaed984a6cb70fe382491fcc6fbf8505aa0ad47ff5b"))
        XCTAssertTrue(source.contains("e41c23322912104a648e791bfb0d3a5714323b26b1b299ae5f0cfa225f68aba0"))
        XCTAssertTrue(source.contains("APPROVED_PREDECESSOR_REFERENCE_TEAM_ID = TEAM_ID"))
        XCTAssertTrue(
            source.contains(
                "APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER = EXECUTABLE_IDENTIFIER"
            )
        )
        XCTAssertTrue(
            source.contains(
                "APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT = V86_DESIGNATED_REQUIREMENT"
            )
        )
        XCTAssertTrue(source.contains("TEAM_ID = \"MSMG8CJLB3\""))
        XCTAssertTrue(
            source.contains(
                "EXECUTABLE_IDENTIFIER = \"com.elamin.AudioStreamer.CaptureServer\""
            )
        )
        XCTAssertTrue(
            source.contains(
                "V86_DESIGNATED_REQUIREMENT = 'identifier \"com.elamin.AudioStreamer.CaptureServer\""
            )
        )
        XCTAssertTrue(source.contains("PredecessorReferenceFingerprint"))
        XCTAssertTrue(source.contains("verify-media-v1-host-bundle.sh"))
        XCTAssertTrue(source.contains("\"--media-integration-v1\""))
        XCTAssertTrue(source.contains("signature_layout"))
        XCTAssertTrue(source.contains("CandidateCDHashFull sha256="))
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
        XCTAssertFalse(source.contains("UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL"))
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
        XCTAssertTrue(source.contains("worktree_status=$(git_value status --porcelain=v1"))
        XCTAssertFalse(source.contains("upstream_head status remote_record"))
        XCTAssertFalse(source.contains("\n    status=$(git_value status"))
        XCTAssertTrue(source.contains("553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66"))
        XCTAssertFalse(source.contains("UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL"))
        XCTAssertFalse(source.contains("pending explicit Ahmed approval"))
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
