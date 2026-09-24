import Darwin
import Foundation
import XCTest

final class V90SealedHostOracleHandoffTests: XCTestCase {
    private let deviceID = "00000000-0000-4000-8000-000000000000"
    private let hardwareUDID = "00000000-0000000000000000"

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String

        var diagnostic: String {
            "status=\(status)\nstdout:\n\(stdout)\nstderr:\n\(stderr)"
        }
    }

    private struct Fixture {
        let root: URL
        let wrapper: URL
        let capsule: URL
        let metadata: URL
        let metadataSHA256: String
        let candidateExecutableSHA256: String
        let candidateFrameworkSHA256: String
        let referenceSHA256: String
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPreparationBindsTrustedCapsuleAndArmTransportsCommittedIdentityPair()
        throws {
        let fixture = try makeFixture(referenceMatchesCandidate: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let prepared = try run(
            fixture.wrapper,
            arguments: ["prepare", fixture.metadata.path, fixture.metadataSHA256]
        )
        XCTAssertEqual(prepared.status, 0, prepared.diagnostic)

        let output = fixture.capsule.appendingPathComponent(
            "v90-screen-oracle-handoff",
            isDirectory: true
        )
        let manifest = output.appendingPathComponent(
            "sealed-live-mac-host-identity.json"
        )
        let manifestSidecar = output.appendingPathComponent(
            "sealed-live-mac-host-identity.json.sha256"
        )
        let handoff = output.appendingPathComponent(
            "v90-screen-oracle-host-identity-handoff.json"
        )
        let handoffSidecar = output.appendingPathComponent(
            "v90-screen-oracle-host-identity-handoff.json.sha256"
        )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: output.path)),
            Set([
                manifest.lastPathComponent,
                manifestSidecar.lastPathComponent,
                handoff.lastPathComponent,
                handoffSidecar.lastPathComponent,
            ])
        )
        XCTAssertTrue(try modeAndLinks(of: output).hasPrefix("700:"))
        for file in [manifest, manifestSidecar, handoff, handoffSidecar] {
            XCTAssertEqual(try modeAndLinks(of: file), "600:1", file.path)
        }

        let manifestSHA256 = try sha256(of: manifest)
        let handoffSHA256 = try sha256(of: handoff)
        XCTAssertEqual(
            try String(contentsOf: manifestSidecar, encoding: .utf8),
            manifestSHA256 + "\n"
        )
        XCTAssertEqual(
            try String(contentsOf: handoffSidecar, encoding: .utf8),
            handoffSHA256 + "\n"
        )
        let handoffObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: handoff))
                as? [String: String]
        )
        XCTAssertEqual(
            Set(handoffObject.keys),
            Set([
                "schema",
                "capsuleMetadataSHA256",
                "candidateAppRelativePath",
                "candidateExecutableSHA256",
                "candidateMediaFrameworkExecutableSHA256",
                "designatedRequirementReferenceRelativePath",
                "designatedRequirementReferenceSHA256",
                "expectedTeamIdentifier",
                "hostIdentityManifestBasename",
                "hostIdentityManifestSHA256",
                "hostIdentityManifestSHA256Basename",
            ])
        )
        XCTAssertEqual(
            handoffObject["schema"],
            "opensteamer.v90-screen-oracle-host-identity-handoff.v1"
        )
        XCTAssertEqual(
            handoffObject["capsuleMetadataSHA256"],
            fixture.metadataSHA256
        )
        XCTAssertEqual(
            handoffObject["candidateExecutableSHA256"],
            fixture.candidateExecutableSHA256
        )
        XCTAssertEqual(
            handoffObject["candidateMediaFrameworkExecutableSHA256"],
            fixture.candidateFrameworkSHA256
        )
        XCTAssertEqual(
            handoffObject["designatedRequirementReferenceSHA256"],
            fixture.referenceSHA256
        )
        XCTAssertEqual(handoffObject["hostIdentityManifestSHA256"], manifestSHA256)
        XCTAssertEqual(handoffObject["expectedTeamIdentifier"], "MSMG8CJLB3")

        let capture = fixture.root.appendingPathComponent("fake-armer-capture")
        let armed = try run(
            fixture.wrapper,
            arguments: [
                "arm",
                handoff.path,
                handoffSHA256,
                deviceID,
                hardwareUDID,
                "90",
            ],
            extraEnvironment: ["V90_HANDOFF_CAPTURE": capture.path]
        )
        XCTAssertEqual(armed.status, 0, armed.diagnostic)
        XCTAssertEqual(
            try String(contentsOf: capture, encoding: .utf8),
            """
            manifest=\(manifest.path)
            manifest_sha256_path=\(manifestSidecar.path)
            manifest_sha256=\(manifestSHA256)
            arguments=\(deviceID)|\(hardwareUDID)|90

            """
        )
    }

    func testPreparationRejectsCandidateDerivedReferenceBeforePublishing() throws {
        let fixture = try makeFixture(referenceMatchesCandidate: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try run(
            fixture.wrapper,
            arguments: ["prepare", fixture.metadata.path, fixture.metadataSHA256]
        )
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains(
                "designated-requirement reference digest may not be candidate-derived"
            ),
            result.diagnostic
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.capsule.appendingPathComponent(
                    "v90-screen-oracle-handoff"
                ).path
            )
        )
    }

    func testArmRejectsMissingOverallOrBrokenManifestCommitMarkerBeforeInvokingArmer()
        throws {
        let fixture = try makeFixture(referenceMatchesCandidate: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let prepared = try run(
            fixture.wrapper,
            arguments: ["prepare", fixture.metadata.path, fixture.metadataSHA256]
        )
        XCTAssertEqual(prepared.status, 0, prepared.diagnostic)

        let output = fixture.capsule.appendingPathComponent(
            "v90-screen-oracle-handoff",
            isDirectory: true
        )
        let handoff = output.appendingPathComponent(
            "v90-screen-oracle-host-identity-handoff.json"
        )
        let handoffSidecar = output.appendingPathComponent(
            "v90-screen-oracle-host-identity-handoff.json.sha256"
        )
        let manifestSidecar = output.appendingPathComponent(
            "sealed-live-mac-host-identity.json.sha256"
        )
        let handoffSHA256 = try sha256(of: handoff)
        let heldHandoffSidecar = output.appendingPathComponent("uncommitted-handoff-sidecar")
        try FileManager.default.moveItem(at: handoffSidecar, to: heldHandoffSidecar)

        let capture = fixture.root.appendingPathComponent("must-not-arm")
        let uncommitted = try run(
            fixture.wrapper,
            arguments: [
                "arm",
                handoff.path,
                handoffSHA256,
                deviceID,
                hardwareUDID,
                "90",
            ],
            extraEnvironment: ["V90_HANDOFF_CAPTURE": capture.path]
        )
        XCTAssertNotEqual(uncommitted.status, 0, uncommitted.diagnostic)
        XCTAssertTrue(
            uncommitted.stderr.contains("V90 handoff commit marker"),
            uncommitted.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        try FileManager.default.moveItem(at: heldHandoffSidecar, to: handoffSidecar)

        let sidecarHandle = try FileHandle(forWritingTo: manifestSidecar)
        try sidecarHandle.truncate(atOffset: 0)
        try sidecarHandle.write(contentsOf: Data((String(repeating: "0", count: 64) + "\n").utf8))
        try sidecarHandle.close()

        let result = try run(
            fixture.wrapper,
            arguments: [
                "arm",
                handoff.path,
                handoffSHA256,
                deviceID,
                hardwareUDID,
                "90",
            ],
            extraEnvironment: ["V90_HANDOFF_CAPTURE": capture.path]
        )
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains(
                "sealed host-identity manifest pair is uncommitted or mismatched"
            ),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
    }

    private func makeFixture(referenceMatchesCandidate: Bool) throws -> Fixture {
        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "v90-host-handoff-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let fakeRepository = root.appendingPathComponent("repository", isDirectory: true)
            let fakeMacScripts = fakeRepository.appendingPathComponent(
                "macOS/scripts",
                isDirectory: true
            )
            let fakeIOScripts = fakeRepository.appendingPathComponent(
                "iOS/opensteamer/scripts",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: fakeMacScripts,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: fakeIOScripts,
                withIntermediateDirectories: true
            )
            let sourceWrapper = repositoryRoot.appendingPathComponent(
                "macOS/scripts/prepare-v90-sealed-host-oracle-handoff.sh"
            )
            let wrapper = fakeMacScripts.appendingPathComponent(
                "prepare-v90-sealed-host-oracle-handoff.sh"
            )
            try FileManager.default.copyItem(at: sourceWrapper, to: wrapper)
            try setMode(0o755, on: wrapper)
            let generator = fakeMacScripts.appendingPathComponent(
                "create-sealed-mac-host-identity-manifest.sh"
            )
            try fakeIdentityGenerator.write(
                to: generator,
                atomically: false,
                encoding: .utf8
            )
            try setMode(0o755, on: generator)
            let armer = fakeIOScripts.appendingPathComponent(
                "arm-testflight-screen-visual-oracle.sh"
            )
            try fakeArmer.write(to: armer, atomically: false, encoding: .utf8)
            try setMode(0o755, on: armer)

            let capsule = root.appendingPathComponent("fresh-v90-capsule", isDirectory: true)
            try FileManager.default.createDirectory(
                at: capsule,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try setMode(0o700, on: capsule)
            let candidate = capsule.appendingPathComponent(
                "candidate/opensteamer Host.app",
                isDirectory: true
            )
            let executable = candidate.appendingPathComponent(
                "Contents/MacOS/CaptureServer"
            )
            let frameworkDirectory = candidate.appendingPathComponent(
                "Contents/Frameworks/LiveKitWebRTC.framework/Versions/A",
                isDirectory: true
            )
            let frameworkExecutable = frameworkDirectory.appendingPathComponent(
                "LiveKitWebRTC"
            )
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: frameworkDirectory,
                withIntermediateDirectories: true
            )
            try Data("signed candidate executable v90\n".utf8).write(
                to: executable,
                options: .withoutOverwriting
            )
            try Data("signed candidate framework v90\n".utf8).write(
                to: frameworkExecutable,
                options: .withoutOverwriting
            )
            try setMode(0o755, on: executable)
            try setMode(0o755, on: frameworkExecutable)
            let versions = frameworkDirectory.deletingLastPathComponent()
            try FileManager.default.createSymbolicLink(
                atPath: versions.appendingPathComponent("Current").path,
                withDestinationPath: "A"
            )
            try FileManager.default.createSymbolicLink(
                atPath: versions.deletingLastPathComponent()
                    .appendingPathComponent("LiveKitWebRTC").path,
                withDestinationPath: "Versions/Current/LiveKitWebRTC"
            )

            let reference = capsule.appendingPathComponent(
                "trusted-reference/CaptureServer"
            )
            try FileManager.default.createDirectory(
                at: reference.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let referenceBytes = referenceMatchesCandidate
                ? try Data(contentsOf: executable)
                : Data("approved predecessor designated requirement reference\n".utf8)
            try referenceBytes.write(to: reference, options: .withoutOverwriting)
            try setMode(0o755, on: reference)

            let candidateExecutableSHA256 = try sha256(of: executable)
            let candidateFrameworkSHA256 = try sha256(of: frameworkExecutable)
            let referenceSHA256 = try sha256(of: reference)
            let metadata = capsule.appendingPathComponent(
                "trusted-v90-host-oracle-capsule-metadata.json"
            )
            let metadataObject: [String: String] = [
                "schema": "opensteamer.v90-host-oracle-capsule-metadata.v1",
                "candidateAppRelativePath": "candidate/opensteamer Host.app",
                "candidateExecutableSHA256": candidateExecutableSHA256,
                "candidateMediaFrameworkExecutableSHA256": candidateFrameworkSHA256,
                "designatedRequirementReferenceRelativePath":
                    "trusted-reference/CaptureServer",
                "designatedRequirementReferenceSHA256": referenceSHA256,
            ]
            let metadataBytes = try JSONSerialization.data(
                withJSONObject: metadataObject,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try metadataBytes.write(to: metadata, options: .withoutOverwriting)
            try setMode(0o600, on: metadata)

            return Fixture(
                root: root,
                wrapper: wrapper,
                capsule: capsule,
                metadata: metadata,
                metadataSHA256: try sha256(of: metadata),
                candidateExecutableSHA256: candidateExecutableSHA256,
                candidateFrameworkSHA256: candidateFrameworkSHA256,
                referenceSHA256: referenceSHA256
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private var fakeIdentityGenerator: String {
        """
        #!/bin/zsh
        set -euo pipefail
        umask 077
        (( $# == 4 ))
        readonly APP=${1%/}
        readonly REFERENCE=${2%/}
        readonly REFERENCE_SHA256=$3
        readonly OUTPUT=${4%/}
        readonly EXECUTABLE="${APP}/Contents/MacOS/CaptureServer"
        readonly FRAMEWORK="${APP}/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        readonly MANIFEST="${OUTPUT}/sealed-live-mac-host-identity.json"
        readonly SIDECAR="${OUTPUT}/sealed-live-mac-host-identity.json.sha256"
        [[ "$(/usr/bin/shasum -a 256 "$REFERENCE" | /usr/bin/awk '{print $1}')" == "$REFERENCE_SHA256" ]]
        executable_sha=$(/usr/bin/shasum -a 256 "$EXECUTABLE" | /usr/bin/awk '{print $1}')
        framework_sha=$(/usr/bin/shasum -a 256 "${FRAMEWORK:A}" | /usr/bin/awk '{print $1}')
        /usr/bin/jq -n -S \\
          --arg schema opensteamer.sealed-live-mac-host-identity.v1 \\
          --arg executablePath '/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer' \\
          --arg executableSHA256 "$executable_sha" \\
          --arg executableCDHash aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \\
          --arg executableIdentifier com.elamin.AudioStreamer.CaptureServer \\
          --arg executableTeamIdentifier MSMG8CJLB3 \\
          --arg mediaFrameworkExecutablePath '/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC' \\
          --arg mediaFrameworkExecutableSHA256 "$framework_sha" \\
          --arg mediaFrameworkExecutableCDHash bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \\
          --arg mediaFrameworkExecutableIdentifier io.livekit.LiveKitWebRTC \\
          --arg mediaFrameworkExecutableTeamIdentifier MSMG8CJLB3 \\
          '{schema:$schema, executablePath:$executablePath,
            executableSHA256:$executableSHA256, executableCDHash:$executableCDHash,
            executableIdentifier:$executableIdentifier,
            executableTeamIdentifier:$executableTeamIdentifier,
            mediaFrameworkExecutablePath:$mediaFrameworkExecutablePath,
            mediaFrameworkExecutableSHA256:$mediaFrameworkExecutableSHA256,
            mediaFrameworkExecutableCDHash:$mediaFrameworkExecutableCDHash,
            mediaFrameworkExecutableIdentifier:$mediaFrameworkExecutableIdentifier,
            mediaFrameworkExecutableTeamIdentifier:$mediaFrameworkExecutableTeamIdentifier}' \\
          > "$MANIFEST"
        /bin/chmod 600 "$MANIFEST"
        manifest_sha=$(/usr/bin/shasum -a 256 "$MANIFEST" | /usr/bin/awk '{print $1}')
        /usr/bin/printf '%s\\n' "$manifest_sha" > "$SIDECAR"
        /bin/chmod 600 "$SIDECAR"
        print -r -- "manifest_path=$MANIFEST"
        print -r -- "manifest_sha256=$manifest_sha"
        print -r -- "manifest_sha256_path=$SIDECAR"
        """
    }

    private var fakeArmer: String {
        """
        #!/bin/zsh
        set -euo pipefail
        (( $# == 3 ))
        [[ -n "${V90_HANDOFF_CAPTURE:-}" ]]
        {
          print -r -- "manifest=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST:-}"
          print -r -- "manifest_sha256_path=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH:-}"
          print -r -- "manifest_sha256=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256:-}"
          print -r -- "arguments=$1|$2|$3"
        } > "$V90_HANDOFF_CAPTURE"
        """
    }

    private func run(
        _ executable: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ProcessResult(
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

    private func sha256(of file: URL) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", file.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        let value = String(result.stdout.prefix(64))
        XCTAssertNotNil(value.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        return value
    }

    private func setMode(_ mode: mode_t, on path: URL) throws {
        guard chmod(path.path, mode) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func modeAndLinks(of path: URL) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/stat"),
            arguments: ["-f", "%Lp:%l", path.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
