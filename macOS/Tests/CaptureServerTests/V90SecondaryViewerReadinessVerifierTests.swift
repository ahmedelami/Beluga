import Darwin
import Foundation
import MediaBridgeCore
import XCTest
@testable import CaptureServer

final class V90SecondaryViewerReadinessVerifierTests: XCTestCase {
    private let hostGeneration = String(repeating: "a", count: 64)

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
    }

    private var verifier: URL {
        repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-v90-secondary-viewer-readiness.sh"
        )
    }

    private var verifierSource: String {
        get throws {
            try String(contentsOf: verifier, encoding: .utf8)
        }
    }

    func testVerifierHasTwoBoundedNonMintingAttempts() throws {
        let source = try verifierSource

        XCTAssertTrue(source.contains("readonly MAX_PROBE_ATTEMPTS=2"))
        XCTAssertTrue(source.contains("readonly PROBE_TIMEOUT_SECONDS=6"))
        XCTAssertTrue(source.contains("MAX_PROBE_ATTEMPTS < 16"))
        XCTAssertTrue(source.contains("PROBE_TIMEOUT_SECONDS <= 10"))
        XCTAssertTrue(source.contains("--probe-secondary-test-viewer-status"))
        XCTAssertFalse(source.contains("--request-secondary-test-viewer-invitation"))
        XCTAssertFalse(source.contains("--stop-secondary-test-viewer-generation"))
        XCTAssertTrue(
            source.contains(
                "\"$SECOND_MANAGER_GENERATION\" == \"$FIRST_MANAGER_GENERATION\""
            )
        )
        XCTAssertTrue(source.contains("\"$SECOND_REQUEST_NONCE\" != \"$FIRST_REQUEST_NONCE\""))

        let invocation = try XCTUnwrap(
            source.range(of: "\"$PROBE_FLAG\" \"$STATUS_OUTPUT\"")
        )
        let validation = try XCTUnwrap(
            source.range(of: "/usr/bin/jq --stream -e -s '")
        )
        XCTAssertLessThan(invocation.lowerBound, validation.lowerBound)
    }

    func testVerifierPinsExactCandidateAndEndpointOutputScope() throws {
        let source = try verifierSource

        for required in [
            "EXPECTED_CANDIDATE_SHA256",
            "candidate_owner\" == \"$EUID",
            "candidate_mode\" == \"755",
            "candidate_links\" == \"1",
            "/usr/bin/codesign --verify --strict --verbose=2",
            "EXPECTED_CANDIDATE_IDENTIFIER=\"com.elamin.AudioStreamer.CaptureServer\"",
            "candidate CaptureServer has the wrong preserved code identifier",
            "V90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertFalse(source.contains("V90_SECONDARY_VIEWER_READINESS_OK"))
    }

    func testVerifierFencesEndpointHostAndOutputIdentities() throws {
        let source = try verifierSource

        for required in [
            "CONTROL_SOCKET_BEFORE=\"$(require_control_socket",
            "control_socket_after=\"$(require_control_socket",
            "\"$control_socket_after\" == \"$CONTROL_SOCKET_BEFORE\"",
            "HOST_LOCK_BEFORE=\"$(require_host_lock",
            "host_lock_after=\"$(require_host_lock",
            "\"$host_lock_after\" == \"$HOST_LOCK_BEFORE\"",
            "\"$host_record_after\" == \"$HOST_RECORD_BEFORE\"",
            "status output has the wrong owner",
            "status-output mode is not exactly 0600",
            "status output must have exactly one hard link",
            "status_identity_after",
            "status output was replaced while it was validated",
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
        XCTAssertTrue(source.contains("managerPhase == \"idle\""))
        XCTAssertTrue(source.contains("managerIsIdle == true"))
        XCTAssertTrue(source.contains("hostProcessIdentifier == $hostProcessIdentifier"))
        XCTAssertTrue(source.contains("hostGeneration == $hostGeneration"))
        XCTAssertTrue(source.contains("private probe output cleanup was not confirmed"))
        XCTAssertFalse(source.contains("rm -rf"))
    }

    func testBuiltCaptureServerComesFromCurrentTestBuildTree() throws {
        let buildProductsDirectory = currentTestBuildProductsDirectory
        let candidate = try builtCaptureServer()

        XCTAssertEqual(
            candidate.deletingLastPathComponent(),
            buildProductsDirectory,
            "CaptureServer must be a sibling of the current test bundle"
        )
    }

    func testRealCaptureServerClientObservesLiveIdleEndpointAndCleansOutput() async throws {
        try await withFixture { fixture in
            let result = try runVerifier(fixture: fixture)

            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertTrue(
                result.stdout.hasPrefix(
                    "V90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK " +
                    "candidateSHA256=\(fixture.candidateSHA256) "
                ),
                result.stdout
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path),
                []
            )
        }
    }

    func testVerifierAcceptsSignedCandidateAtPathContainingSpaces() async throws {
        try await withFixture { fixture in
            let spacedDirectory = fixture.root.appendingPathComponent(
                "candidate path with spaces",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: spacedDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let spacedCandidate = spacedDirectory.appendingPathComponent("Capture Server")
            try FileManager.default.copyItem(at: fixture.candidate, to: spacedCandidate)
            let framework = fixture.candidate
                .deletingLastPathComponent()
                .appendingPathComponent("LiveKitWebRTC.framework", isDirectory: true)
            try FileManager.default.copyItem(
                at: framework,
                to: spacedDirectory.appendingPathComponent(
                    "LiveKitWebRTC.framework",
                    isDirectory: true
                )
            )
            XCTAssertEqual(chmod(spacedCandidate.path, 0o755), 0)

            let result = try runVerifier(
                fixture: fixture,
                candidate: spacedCandidate,
                candidateSHA256: try sha256(of: spacedCandidate)
            )

            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertTrue(
                result.stdout.hasPrefix("V90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK "),
                result.stdout
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path),
                []
            )
        }
    }

    func testFabricatedJSONWriterFailsCandidateSealBeforeExecution() async throws {
        try await withFixture { fixture in
            let fabricated = fixture.root.appendingPathComponent("FabricatedCaptureServer")
            let executionMarker = fixture.root.appendingPathComponent("fabricated-executed")
            try fabricatedCandidateSource.write(
                to: fabricated,
                atomically: false,
                encoding: .utf8
            )
            XCTAssertEqual(chmod(fabricated.path, 0o755), 0)
            let fabricatedSHA256 = try sha256(of: fabricated)

            let result = try runVerifier(
                fixture: fixture,
                candidate: fabricated,
                candidateSHA256: fabricatedSHA256,
                extraEnvironment: [
                    "V90_FAKE_EXECUTION_MARKER": executionMarker.path,
                ]
            )

            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(
                result.stderr.contains(
                    "candidate CaptureServer failed strict code-signature validation"
                ),
                result.stderr
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: executionMarker.path))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path),
                []
            )
        }
    }

    func testSymlinkSpelledTemporaryRootIsCanonicalizedBeforeValidation() async throws {
        try await withFixture { fixture in
            let aliasedScratch = fixture.root.appendingPathComponent("scratch-alias")
            try FileManager.default.createSymbolicLink(
                at: aliasedScratch,
                withDestinationURL: fixture.scratch
            )
            let result = try runVerifier(
                fixture: fixture,
                temporaryDirectory: aliasedScratch.path + "/"
            )

            XCTAssertEqual(result.status, 0, result.stderr)
            XCTAssertTrue(
                result.stdout.hasPrefix("V90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK ")
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.path),
                []
            )
        }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let scratch: URL
        let candidate: URL
        let candidateSHA256: String
        let socketPath: String
    }

    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func withFixture(
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let root = repositoryRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "v90-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let hostDirectory = home.appendingPathComponent(
            "Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime",
            isDirectory: true
        )
        let socketDirectory = root.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: hostDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(chmod(hostDirectory.path, 0o700), 0)
        XCTAssertEqual(chmod(scratch.path, 0o700), 0)
        XCTAssertEqual(chmod(socketDirectory.path, 0o700), 0)

        let hostLock = hostDirectory.appendingPathComponent("worldwide-host.lock")
        let record = """
        OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1
        pid=\(getpid())
        nonce=\(hostGeneration)

        """
        try Data(record.utf8).write(to: hostLock, options: .withoutOverwriting)
        XCTAssertEqual(chmod(hostLock.path, 0o600), 0)

        let socketPath = socketDirectory.appendingPathComponent("control.sock").path
        let factory = WorldwideSecondaryTestViewerServiceFactory {
            _ -> any WorldwideSecondaryTestViewerServing in
            throw V90VerifierTestError.unexpectedFactoryUse
        }
        let coordinator = WorldwideSecondaryTestViewerCoordinator(factory: factory)
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: socketPath,
            handler: handler
        )
        try server.start()

        let candidate = try builtCaptureServer()
        let fixture = Fixture(
            root: root,
            home: home,
            scratch: scratch,
            candidate: candidate,
            candidateSHA256: try sha256(of: candidate),
            socketPath: socketPath
        )
        do {
            try await body(fixture)
        } catch {
            server.stop()
            await server.waitUntilRequestsDrain()
            _ = await coordinator.stop()
            throw error
        }
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    private var currentTestBuildProductsDirectory: URL {
        Bundle(for: V90SecondaryViewerReadinessVerifierTests.self)
            .bundleURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    private func builtCaptureServer() throws -> URL {
        let buildProductsDirectory = currentTestBuildProductsDirectory
        let candidate = buildProductsDirectory
            .appendingPathComponent("CaptureServer")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue,
           FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw V90VerifierTestError.captureServerUnavailable
        }
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.deletingLastPathComponent() == buildProductsDirectory else {
            throw V90VerifierTestError.captureServerUnavailable
        }
        return resolvedCandidate
    }

    private func sha256(of file: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0,
              let digest = output.split(whereSeparator: \.isWhitespace).first,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw V90VerifierTestError.hashUnavailable
        }
        return String(digest)
    }

    private func runVerifier(
        fixture: Fixture,
        candidate: URL? = nil,
        candidateSHA256: String? = nil,
        temporaryDirectory: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let selectedCandidate = candidate ?? fixture.candidate
        let selectedSHA256 = candidateSHA256 ?? fixture.candidateSHA256
        return try runProcess(
            executable: verifier,
            arguments: [
                selectedCandidate.path,
                selectedSHA256,
                fixture.socketPath,
            ],
            fixture: fixture,
            temporaryDirectory: temporaryDirectory,
            extraEnvironment: extraEnvironment
        )
    }

    private func runProcess(
        executable: URL,
        arguments: [String],
        fixture: Fixture,
        temporaryDirectory: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": fixture.home.path,
            "CFFIXED_USER_HOME": fixture.home.path,
            "TMPDIR": temporaryDirectory ?? fixture.scratch.path + "/",
        ]
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

    private var fabricatedCandidateSource: String {
        #"""
        #!/usr/bin/python3
        import json
        import os
        import re
        import sys

        with open(os.environ["V90_FAKE_EXECUTION_MARKER"], "w", encoding="utf-8"):
            pass
        output = sys.argv[2]
        lock = os.path.join(
            os.environ["HOME"],
            "Library/Application Support",
            "com.elamin.AudioStreamer.CaptureServer.runtime",
            "worldwide-host.lock",
        )
        with open(lock, "r", encoding="utf-8") as stream:
            record = stream.read()
        match = re.fullmatch(
            r"OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=([1-9][0-9]*)\nnonce=([0-9a-f]{64})\n",
            record,
        )
        value = {
            "v": 1,
            "type": "secondaryTestViewerStatusProbeResult",
            "hostProcessIdentifier": int(match.group(1)),
            "hostGeneration": match.group(2),
            "managerGeneration": 7,
            "managerPhase": "idle",
            "managerIsIdle": True,
            "requestNonce": ("b" if output.endswith("status-1.json") else "c") * 32,
        }
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
        """#
    }
}

private enum V90VerifierTestError: Error {
    case captureServerUnavailable
    case hashUnavailable
    case unexpectedFactoryUse
}
