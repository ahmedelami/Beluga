import Foundation
import XCTest

/// Locks the reviewed LaunchAgent, live-process verifier, and launch-state parser into one
/// deterministic deployment contract. All processes and files are disposable fixtures.
final class MacHostDeploymentContractTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String

        var diagnostic: String {
            "status=\(status)\nstdout:\n\(standardOutput)\nstderr:\n\(standardError)"
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testLaunchAgentHasExactTypedProductionContract() throws {
        let template = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
        )
        var format = PropertyListSerialization.PropertyListFormat.xml
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: template),
            options: [],
            format: &format
        )
        let values = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(
            Set(values.keys),
            Set([
                "Label",
                "ProgramArguments",
                "RunAtLoad",
                "KeepAlive",
                "ThrottleInterval",
                "StandardOutPath",
                "StandardErrorPath",
                "EnvironmentVariables",
            ])
        )
        XCTAssertEqual(values["Label"] as? String, "org.example.opensteamer.worldwide")
        XCTAssertEqual(
            values["ProgramArguments"] as? [String],
            [
                "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer",
                "--worldwide",
                "--allow-remote-control",
                "--virtual-phone-display",
                "--secondary-test-viewer",
                "--duration",
                "0",
                "--verbose",
                "--rendezvous-url",
                "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev",
            ]
        )
        XCTAssertEqual(values["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(values["KeepAlive"] as? Bool, true)
        XCTAssertEqual(values["ThrottleInterval"] as? Int, 10)
        XCTAssertEqual(
            values["StandardOutPath"] as? String,
            "/var/tmp/opensteamer-worldwide-host.log"
        )
        XCTAssertEqual(
            values["StandardErrorPath"] as? String,
            "/var/tmp/opensteamer-worldwide-host.err.log"
        )
        let environment = try XCTUnwrap(values["EnvironmentVariables"] as? [String: Any])
        XCTAssertEqual(Set(environment.keys), Set(["OSLogRateLimit"]))
        XCTAssertEqual(environment["OSLogRateLimit"] as? String, "64")
        XCTAssertFalse(values["RunAtLoad"] is String)
        XCTAssertFalse(values["KeepAlive"] is String)
        XCTAssertFalse(values["ThrottleInterval"] is String)
    }

    func testLaunchStateVerifierPositivePathReturnsZeroAndRejectsDrift() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "launch-state")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let template = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
        )
        let installed = temporaryRoot.appendingPathComponent(
            "org.example.opensteamer.worldwide.plist"
        )
        try FileManager.default.copyItem(at: template, to: installed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: installed.path
        )
        let executable = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
        let baseline = launchState(installedPath: installed.path)
        let stateURL = temporaryRoot.appendingPathComponent("launch-state.txt")
        try baseline.write(to: stateURL, atomically: true, encoding: .utf8)
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-launch-state.sh"
        )
        let arguments = [stateURL.path, executable, template.path, installed.path]
        let positive = try run(executable: verifier, arguments: arguments)
        XCTAssertEqual(positive.status, 0, positive.diagnostic)
        XCTAssertTrue(positive.standardOutput.contains("pid=4242"), positive.diagnostic)
        XCTAssertTrue(positive.standardOutput.contains("runs=1"), positive.diagnostic)
        XCTAssertFalse(positive.standardOutput.contains("pid=99999"), positive.diagnostic)
        XCTAssertFalse(positive.standardOutput.contains("adversarial-resource-host"), positive.diagnostic)

        let duplicateTopLevelPID = try insertingLine(
            "pid = 4343",
            beforeLineWhoseTrimmedValueIs: "resource coalition = {",
            in: baseline
        )
        XCTAssertNotEqual(duplicateTopLevelPID, baseline)
        let duplicatePIDURL = temporaryRoot.appendingPathComponent(
            "duplicate-top-level-pid.txt"
        )
        try duplicateTopLevelPID.write(
            to: duplicatePIDURL,
            atomically: true,
            encoding: .utf8
        )
        let duplicatePIDRejection = try run(
            executable: verifier,
            arguments: [duplicatePIDURL.path, executable, template.path, installed.path]
        )
        XCTAssertNotEqual(
            duplicatePIDRejection.status,
            0,
            "duplicate-top-level-pid false-passed.\n\(duplicatePIDRejection.diagnostic)"
        )

        let mutants: [(String, String, String)] = [
            ("wrong-state", "state = running", "state = exited"),
            ("wrong-program", "program = \(executable)", "program = /tmp/CaptureServer"),
            ("wrong-throttle", "minimum runtime = 10", "minimum runtime = 11"),
            ("wrong-log", "stdout path = /var/tmp/opensteamer-worldwide-host.log", "stdout path = /tmp/wrong.log"),
            ("missing-virtual-display", "        --virtual-phone-display\n", ""),
            ("missing-secondary-viewer", "        --secondary-test-viewer\n", ""),
            ("swapped-v90-flags", "        --virtual-phone-display\n        --secondary-test-viewer\n", "        --secondary-test-viewer\n        --virtual-phone-display\n"),
            ("duplicate-secondary-viewer", "        --secondary-test-viewer\n", "        --secondary-test-viewer\n        --secondary-test-viewer\n"),
            ("extra-argument", "        --verbose\n", "        --with-lan\n        --verbose\n"),
            ("endpoint-override", "OSLogRateLimit => 64", "OSLogRateLimit => 64\n        OPENSTEAMER_RENDEZVOUS_URL => wss://wrong.example"),
            ("unknown-job-env", "XPC_SERVICE_NAME => org.example.opensteamer.worldwide", "XPC_SERVICE_NAME => org.example.opensteamer.worldwide\n        UNREVIEWED_MODE => enabled"),
            ("missing-keepalive", "properties = keepalive | runatload | inferred program", "properties = runatload | inferred program"),
        ]
        for (name, original, replacement) in mutants {
            let mutant = try replacingExactlyOnce(
                original,
                with: replacement,
                in: baseline,
                mutationName: name
            )
            XCTAssertNotEqual(mutant, baseline, "Fixture replacement failed for \(name)")
            let mutantURL = temporaryRoot.appendingPathComponent("\(name).txt")
            try mutant.write(to: mutantURL, atomically: true, encoding: .utf8)
            let rejection = try run(
                executable: verifier,
                arguments: [mutantURL.path, executable, template.path, installed.path]
            )
            XCTAssertNotEqual(rejection.status, 0, "\(name) false-passed.\n\(rejection.diagnostic)")
        }
    }

    func testLaunchStateVerifierUsesTypedRawScalarExtractionWithoutJSONScalarProbe() throws {
        let verifier = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-mac-host-launch-state.sh"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(
            verifier.contains(
                "value=\"$(plist_extract \"$plist\" \"$key\" raw string)\""
            )
        )
        XCTAssertTrue(
            verifier.contains(
                "/usr/bin/plutil -extract \"$key\" xml1 -o /dev/null"
            )
        )
        XCTAssertFalse(
            verifier.contains(
                "/usr/bin/plutil -extract \"$key\" json -o /dev/null"
            )
        )
    }

    func testLaunchStateVerifierRejectsStringBooleanAndIntegerLookalikes() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "plist-types")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let template = repositoryRoot.appendingPathComponent(
            "macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
        )
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-mac-host-launch-state.sh"
        )
        let executable = "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
        let base = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: template),
                format: nil
            ) as? [String: Any]
        )
        let mutations: [(String, Any)] = [
            ("RunAtLoad", "true"),
            ("KeepAlive", "true"),
            ("ThrottleInterval", "10"),
            (
                "ProgramArguments",
                [
                    "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer",
                    "--worldwide",
                    "--allow-remote-control",
                    "--virtual-phone-display",
                    "--secondary-test-viewer",
                    "--duration",
                    0,
                    "--verbose",
                    "--rendezvous-url",
                    "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev",
                ] as [Any]
            ),
        ]
        for (key, value) in mutations {
            var values = base
            values[key] = value
            let path = temporaryRoot.appendingPathComponent("\(key).plist")
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .xml,
                options: 0
            )
            try data.write(to: path, options: .atomic)
            let rejection = try run(
                executable: verifier,
                arguments: ["--verify-plist", executable, path.path]
            )
            XCTAssertNotEqual(
                rejection.status,
                0,
                "String lookalike for \(key) false-passed.\n\(rejection.diagnostic)"
            )
        }
    }

    func testLiveProcessVerifierRejectsInvalidPIDWrongHashAndSamePathReplacement() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "live-code")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let identifier = "org.example.opensteamer.ProcessOracleFixture"
        let executable = temporaryRoot.appendingPathComponent("runner")
        try copyAndSign(
            source: URL(fileURLWithPath: "/bin/sleep"),
            destination: executable,
            identifier: identifier
        )
        let originalHash = try codeHash(of: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(process.isRunning)

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-live-mac-host-process.sh"
        )
        let valid = [
            String(process.processIdentifier),
            executable.path,
            originalHash,
            identifier,
            "not set",
            "/usr/lib/dyld",
        ]
        for invalidPID in ["0", "-1", "abc", "1x"] {
            var arguments = valid
            arguments[0] = invalidPID
            let rejection = try run(executable: verifier, arguments: arguments)
            XCTAssertNotEqual(rejection.status, 0, rejection.diagnostic)
            XCTAssertTrue(
                rejection.standardError.contains("PID must be a positive integer"),
                rejection.diagnostic
            )
        }
        let positive = try eventuallyRun(executable: verifier, arguments: valid) {
            $0.status == 0
        }
        XCTAssertEqual(positive.status, 0, positive.diagnostic)

        let wrongHash = String(repeating: "0", count: 40)
        var wrongArguments = valid
        wrongArguments[2] = wrongHash
        let wrongHashResult = try run(executable: verifier, arguments: wrongArguments)
        XCTAssertNotEqual(wrongHashResult.status, 0, wrongHashResult.diagnostic)

        let replacement = temporaryRoot.appendingPathComponent("replacement")
        try copyAndSign(
            source: URL(fileURLWithPath: "/bin/cat"),
            destination: replacement,
            identifier: identifier
        )
        let replacementHash = try codeHash(of: replacement)
        let move = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacement.path, executable.path]
        )
        XCTAssertEqual(move.status, 0, move.diagnostic)
        var replacementArguments = valid
        replacementArguments[2] = replacementHash
        let stale = try run(executable: verifier, arguments: replacementArguments)
        XCTAssertNotEqual(stale.status, 0, stale.diagnostic)
    }

    func testLiveProcessVerifierRejectsStaleFrameworkMapping() throws {
        let temporaryRoot = makeTemporaryDirectory(prefix: "live-framework")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let framework = temporaryRoot.appendingPathComponent("libFixture.dylib")
        let replacement = temporaryRoot.appendingPathComponent("replacement-libFixture.dylib")
        let executable = temporaryRoot.appendingPathComponent("runner")
        try compileDynamicLibrary(at: framework, returnValue: 7)
        try compileDynamicLibrary(at: replacement, returnValue: 11)
        try compileFrameworkFixtureRunner(at: executable, linkedTo: framework)
        let identifier = "org.example.opensteamer.FrameworkProcessOracleFixture"
        try sign(executable: framework, identifier: "org.example.opensteamer.Fixture")
        try sign(executable: replacement, identifier: "org.example.opensteamer.Fixture")
        try sign(executable: executable, identifier: identifier)
        let executableHash = try codeHash(of: executable)

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-live-mac-host-process.sh"
        )
        let arguments = [
            String(process.processIdentifier),
            executable.path,
            executableHash,
            identifier,
            "not set",
            framework.path,
        ]
        let positive = try eventuallyRun(executable: verifier, arguments: arguments) {
            $0.status == 0
        }
        XCTAssertEqual(positive.status, 0, positive.diagnostic)
        let move = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacement.path, framework.path]
        )
        XCTAssertEqual(move.status, 0, move.diagnostic)
        let stale = try run(executable: verifier, arguments: arguments)
        XCTAssertNotEqual(stale.status, 0, stale.diagnostic)
        XCTAssertTrue(stale.standardError.contains("live framework mapping:"), stale.diagnostic)
    }

    func testSealedLiveHostGateRejectsSHAIdentityAndMappedFrameworkMutationsBeforeChallenge() throws {
        // The installed product path contains "opensteamer Host.app". Keep a space in this
        // fixture so digest parsing cannot accidentally treat a shasum pathname as one field.
        let temporaryRoot = makeCanonicalRepositoryTemporaryDirectory(
            prefix: "sealed live host"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let executableIdentifier = "com.elamin.AudioStreamer.CaptureServer"
        let frameworkIdentifier = "io.livekit.LiveKitWebRTC"
        let productionTeamIdentifier = "MSMG8CJLB3"
        let releaseSigningIdentity = try approvedReleaseSigningIdentity()
        let framework = temporaryRoot.appendingPathComponent("libFixture.dylib")
        let replacement = temporaryRoot.appendingPathComponent("replacement-libFixture.dylib")
        let executable = temporaryRoot.appendingPathComponent("runner")
        try compileDynamicLibrary(at: framework, returnValue: 7)
        try compileDynamicLibrary(at: replacement, returnValue: 11)
        try compileFrameworkFixtureRunner(at: executable, linkedTo: framework)
        try sign(
            executable: framework,
            identifier: frameworkIdentifier,
            signingIdentity: releaseSigningIdentity
        )
        try sign(
            executable: replacement,
            identifier: frameworkIdentifier,
            signingIdentity: releaseSigningIdentity
        )
        try sign(
            executable: executable,
            identifier: executableIdentifier,
            signingIdentity: releaseSigningIdentity
        )

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-sealed-live-mac-host-identity.sh"
        )
        let challengeMarker = temporaryRoot.appendingPathComponent("challenge-started")
        var manifestSequence = 0

        func writeManifest(
            executableSHA256: String,
            executableIdentifier expectedExecutableIdentifier: String,
            frameworkSHA256: String,
            frameworkCDHash: String,
            executableTeamIdentifier: String = productionTeamIdentifier,
            frameworkTeamIdentifier: String = productionTeamIdentifier
        ) throws -> (url: URL, sidecar: URL, digest: String) {
            manifestSequence += 1
            let url = temporaryRoot.appendingPathComponent(
                "sealed-host-identity-\(manifestSequence).json"
            )
            let object: [String: String] = [
                "schema": "opensteamer.sealed-live-mac-host-identity.v1",
                "executablePath": executable.path,
                "executableSHA256": executableSHA256,
                "executableCDHash": try codeHash(of: executable),
                "executableIdentifier": expectedExecutableIdentifier,
                "executableTeamIdentifier": executableTeamIdentifier,
                "mediaFrameworkExecutablePath": framework.path,
                "mediaFrameworkExecutableSHA256": frameworkSHA256,
                "mediaFrameworkExecutableCDHash": frameworkCDHash,
                "mediaFrameworkExecutableIdentifier": frameworkIdentifier,
                "mediaFrameworkExecutableTeamIdentifier": frameworkTeamIdentifier,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            let digest = try sha256(of: url)
            let sidecar = URL(fileURLWithPath: url.path + ".sha256")
            try (digest + "\n").write(to: sidecar, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecar.path
            )
            return (url, sidecar, digest)
        }

        func gateArguments(manifest: URL, sidecar: URL, digest: String) -> [String] {
            [
                "-c",
                """
                /bin/zsh "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" \
                  && /usr/bin/touch "$9"
                """,
                "sealed-live-host-gate",
                verifier.path,
                manifest.path,
                sidecar.path,
                digest,
                String(process.processIdentifier),
                executable.path,
                framework.path,
                "-",
                challengeMarker.path,
            ]
        }

        let executableSHA256 = try sha256(of: executable)
        let initialFrameworkSHA256 = try sha256(of: framework)
        let initialFrameworkCDHash = try codeHash(of: framework)
        let validManifest = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        let positive = try eventuallyRun(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: validManifest.url,
                sidecar: validManifest.sidecar,
                digest: validManifest.digest
            )
        ) { $0.status == 0 }
        XCTAssertEqual(positive.status, 0, positive.diagnostic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: challengeMarker.path))

        if FileManager.default.fileExists(atPath: challengeMarker.path) {
            try FileManager.default.removeItem(at: challengeMarker)
        }
        let wrongSHA = try writeManifest(
            executableSHA256: String(repeating: "0", count: 64),
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        let shaRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: wrongSHA.url,
                sidecar: wrongSHA.sidecar,
                digest: wrongSHA.digest
            )
        )
        XCTAssertNotEqual(shaRejection.status, 0, shaRejection.diagnostic)
        XCTAssertTrue(
            shaRejection.standardError.contains("executable SHA-256 does not match"),
            shaRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let wrongCodeIdentity = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier + ".mutated",
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        let identityRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: wrongCodeIdentity.url,
                sidecar: wrongCodeIdentity.sidecar,
                digest: wrongCodeIdentity.digest
            )
        )
        XCTAssertNotEqual(identityRejection.status, 0, identityRejection.diagnostic)
        XCTAssertTrue(
            identityRejection.standardError.contains(
                "sealed code identifiers do not match the fixed production identities"
            ),
            identityRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let alternateTeam = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash,
            executableTeamIdentifier: "92LVX32M8K",
            frameworkTeamIdentifier: "92LVX32M8K"
        )
        let alternateTeamRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: alternateTeam.url,
                sidecar: alternateTeam.sidecar,
                digest: alternateTeam.digest
            )
        )
        XCTAssertNotEqual(
            alternateTeamRejection.status,
            0,
            alternateTeamRejection.diagnostic
        )
        XCTAssertTrue(
            alternateTeamRejection.standardError.contains(
                "sealed TeamIdentifier values do not match the fixed production team"
            ),
            alternateTeamRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let orphanManifest = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        try FileManager.default.removeItem(at: orphanManifest.sidecar)
        let orphanRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: orphanManifest.url,
                sidecar: orphanManifest.sidecar,
                digest: orphanManifest.digest
            )
        )
        XCTAssertNotEqual(orphanRejection.status, 0, orphanRejection.diagnostic)
        XCTAssertTrue(
            orphanRejection.standardError.contains(
                "sidecar must be an existing absolute physically canonical regular file"
            ),
            orphanRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let symlinkedSidecar = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        let realSidecar = temporaryRoot.appendingPathComponent("real-sidecar")
        try FileManager.default.moveItem(at: symlinkedSidecar.sidecar, to: realSidecar)
        try FileManager.default.createSymbolicLink(
            at: symlinkedSidecar.sidecar,
            withDestinationURL: realSidecar
        )
        let symlinkSidecarRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: symlinkedSidecar.url,
                sidecar: symlinkedSidecar.sidecar,
                digest: symlinkedSidecar.digest
            )
        )
        XCTAssertNotEqual(
            symlinkSidecarRejection.status,
            0,
            symlinkSidecarRejection.diagnostic
        )
        XCTAssertTrue(
            symlinkSidecarRejection.standardError.contains(
                "sidecar must be an existing absolute physically canonical regular file"
            ),
            symlinkSidecarRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let mismatchedSidecar = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        try (String(repeating: "0", count: 64) + "\n").write(
            to: mismatchedSidecar.sidecar,
            atomically: false,
            encoding: .utf8
        )
        let sidecarDigestRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: mismatchedSidecar.url,
                sidecar: mismatchedSidecar.sidecar,
                digest: mismatchedSidecar.digest
            )
        )
        XCTAssertNotEqual(
            sidecarDigestRejection.status,
            0,
            sidecarDigestRejection.diagnostic
        )
        XCTAssertTrue(
            sidecarDigestRejection.standardError.contains(
                "sidecar does not match the externally supplied digest"
            ),
            sidecarDigestRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let malformedSidecar = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        try malformedSidecar.digest.write(
            to: malformedSidecar.sidecar,
            atomically: false,
            encoding: .utf8
        )
        let malformedSidecarRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: malformedSidecar.url,
                sidecar: malformedSidecar.sidecar,
                digest: malformedSidecar.digest
            )
        )
        XCTAssertNotEqual(
            malformedSidecarRejection.status,
            0,
            malformedSidecarRejection.diagnostic
        )
        XCTAssertTrue(
            malformedSidecarRejection.standardError.contains(
                "sidecar must contain exactly 65 bytes"
            ),
            malformedSidecarRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let linkedSidecar = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: initialFrameworkSHA256,
            frameworkCDHash: initialFrameworkCDHash
        )
        let sidecarAlias = temporaryRoot.appendingPathComponent("sidecar-hardlink-alias")
        let linkSidecar = try run(
            executable: URL(fileURLWithPath: "/bin/ln"),
            arguments: [linkedSidecar.sidecar.path, sidecarAlias.path]
        )
        XCTAssertEqual(linkSidecar.status, 0, linkSidecar.diagnostic)
        let linkedSidecarRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: linkedSidecar.url,
                sidecar: linkedSidecar.sidecar,
                digest: linkedSidecar.digest
            )
        )
        XCTAssertNotEqual(
            linkedSidecarRejection.status,
            0,
            linkedSidecarRejection.diagnostic
        )
        XCTAssertTrue(
            linkedSidecarRejection.standardError.contains(
                "sidecar must be owner-owned mode 0600 with one hard link"
            ),
            linkedSidecarRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))

        let move = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacement.path, framework.path]
        )
        XCTAssertEqual(move.status, 0, move.diagnostic)
        let replacedFrameworkManifest = try writeManifest(
            executableSHA256: executableSHA256,
            executableIdentifier: executableIdentifier,
            frameworkSHA256: try sha256(of: framework),
            frameworkCDHash: try codeHash(of: framework)
        )
        let mappingRejection = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: gateArguments(
                manifest: replacedFrameworkManifest.url,
                sidecar: replacedFrameworkManifest.sidecar,
                digest: replacedFrameworkManifest.digest
            )
        )
        XCTAssertNotEqual(mappingRejection.status, 0, mappingRejection.diagnostic)
        XCTAssertTrue(
            mappingRejection.standardError.contains(
                "live-process verification rejected the sealed host identity"
            ),
            mappingRejection.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))
    }

    func testSealedLiveHostGateRejectsManifestThroughSymlinkedParentBeforeChallenge() throws {
        let temporaryRoot = makeCanonicalRepositoryTemporaryDirectory(
            prefix: "sealed manifest canonical path"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let realParent = temporaryRoot.appendingPathComponent("real", isDirectory: true)
        let symlinkedParent = temporaryRoot.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkedParent,
            withDestinationURL: realParent
        )

        let realManifest = realParent.appendingPathComponent("sealed-host-identity.json")
        try String(repeating: "x", count: 256).write(
            to: realManifest,
            atomically: false,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: realManifest.path
        )
        let manifestThroughSymlinkedParent = symlinkedParent.appendingPathComponent(
            realManifest.lastPathComponent
        )
        let challengeMarker = temporaryRoot.appendingPathComponent("challenge-started")
        let verifier = repositoryRoot.appendingPathComponent(
            "macOS/scripts/verify-sealed-live-mac-host-identity.sh"
        )
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-c",
                """
                /bin/zsh "$1" "$2" "$3" "$4" 1 /tmp/host /tmp/framework - \
                  && /usr/bin/touch "$5"
                """,
                "sealed-live-host-canonical-path-gate",
                verifier.path,
                manifestThroughSymlinkedParent.path,
                manifestThroughSymlinkedParent.path + ".sha256",
                String(repeating: "0", count: 64),
                challengeMarker.path,
            ]
        )

        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.standardError.contains(
                "physically canonical regular file with no symlinked ancestors"
            ),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: challengeMarker.path))
    }

    func testSealedLiveHostGateRejectsManifestSourceSwapAfterPinnedSnapshot() throws {
        let temporaryRoot = makeCanonicalRepositoryTemporaryDirectory(
            prefix: "sealed manifest swap"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let releaseSigningIdentity = try approvedReleaseSigningIdentity()
        let executableIdentifier = "com.elamin.AudioStreamer.CaptureServer"
        let frameworkIdentifier = "io.livekit.LiveKitWebRTC"
        let framework = temporaryRoot.appendingPathComponent("libFixture.dylib")
        let executable = temporaryRoot.appendingPathComponent("runner")
        try compileDynamicLibrary(at: framework, returnValue: 7)
        try compileFrameworkFixtureRunner(at: executable, linkedTo: framework)
        try sign(
            executable: framework,
            identifier: frameworkIdentifier,
            signingIdentity: releaseSigningIdentity
        )
        try sign(
            executable: executable,
            identifier: executableIdentifier,
            signingIdentity: releaseSigningIdentity
        )

        let liveProcess = Process()
        liveProcess.executableURL = executable
        liveProcess.standardOutput = FileHandle.nullDevice
        liveProcess.standardError = FileHandle.nullDevice
        try liveProcess.run()
        defer {
            if liveProcess.isRunning { liveProcess.terminate() }
            liveProcess.waitUntilExit()
        }

        let manifest = temporaryRoot.appendingPathComponent("sealed-host-identity.json")
        let manifestObject: [String: String] = [
            "schema": "opensteamer.sealed-live-mac-host-identity.v1",
            "executablePath": executable.path,
            "executableSHA256": try sha256(of: executable),
            "executableCDHash": try codeHash(of: executable),
            "executableIdentifier": executableIdentifier,
            "executableTeamIdentifier": "MSMG8CJLB3",
            "mediaFrameworkExecutablePath": framework.path,
            "mediaFrameworkExecutableSHA256": try sha256(of: framework),
            "mediaFrameworkExecutableCDHash": try codeHash(of: framework),
            "mediaFrameworkExecutableIdentifier": frameworkIdentifier,
            "mediaFrameworkExecutableTeamIdentifier": "MSMG8CJLB3",
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        try manifestData.write(to: manifest, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifest.path
        )
        let digest = try sha256(of: manifest)
        let sidecar = URL(fileURLWithPath: manifest.path + ".sha256")
        try (digest + "\n").write(to: sidecar, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sidecar.path
        )

        let fixtureScripts = temporaryRoot.appendingPathComponent(
            "fixture-scripts",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: fixtureScripts,
            withIntermediateDirectories: false
        )
        let verifier = fixtureScripts.appendingPathComponent(
            "verify-sealed-live-mac-host-identity.sh"
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent(
                "macOS/scripts/verify-sealed-live-mac-host-identity.sh"
            ),
            to: verifier
        )
        let fakeLiveVerifier = fixtureScripts.appendingPathComponent(
            "verify-live-mac-host-process.sh"
        )
        try """
        #!/bin/zsh
        set -euo pipefail
        /usr/bin/touch "$OPENSTEAMER_SEAL_SWAP_READY"
        while [[ ! -f "$OPENSTEAMER_SEAL_SWAP_CONTINUE" ]]; do
          /bin/sleep 0.01
        done
        """.write(to: fakeLiveVerifier, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeLiveVerifier.path
        )

        let ready = temporaryRoot.appendingPathComponent("snapshot-ready")
        let proceed = temporaryRoot.appendingPathComponent("continue-verification")
        let verifierProcess = Process()
        verifierProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        verifierProcess.arguments = [
            verifier.path,
            manifest.path,
            sidecar.path,
            digest,
            String(liveProcess.processIdentifier),
            executable.path,
            framework.path,
            "-",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_SEAL_SWAP_READY"] = ready.path
        environment["OPENSTEAMER_SEAL_SWAP_CONTINUE"] = proceed.path
        verifierProcess.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        verifierProcess.standardOutput = stdout
        verifierProcess.standardError = stderr
        try verifierProcess.run()

        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path),
              verifierProcess.isRunning,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ready.path),
            "Verifier did not reach the post-snapshot live-process fence."
        )

        let replacement = temporaryRoot.appendingPathComponent("replacement-manifest.json")
        try manifestData.write(to: replacement, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        let replace = try run(
            executable: URL(fileURLWithPath: "/bin/mv"),
            arguments: ["-f", replacement.path, manifest.path]
        )
        XCTAssertEqual(replace.status, 0, replace.diagnostic)
        XCTAssertTrue(FileManager.default.createFile(atPath: proceed.path, contents: Data()))
        verifierProcess.waitUntilExit()
        let standardOutput = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let standardError = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let diagnostic = """
        status=\(verifierProcess.terminationStatus)
        stdout:
        \(standardOutput)
        stderr:
        \(standardError)
        """
        XCTAssertNotEqual(verifierProcess.terminationStatus, 0, diagnostic)
        XCTAssertTrue(
            standardError.contains("sealed host artifacts changed during verification"),
            diagnostic
        )
    }

    private func replacingExactlyOnce(
        _ original: String,
        with replacement: String,
        in input: String,
        mutationName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let matchCount = input.components(separatedBy: original).count - 1
        XCTAssertEqual(
            matchCount,
            1,
            "\(mutationName) must identify exactly one mutation site.",
            file: file,
            line: line
        )
        guard matchCount == 1 else {
            throw NSError(
                domain: "MacHostDeploymentContractTests.Mutation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(mutationName) matched \(matchCount) sites"]
            )
        }
        let output = input.replacingOccurrences(of: original, with: replacement)
        XCTAssertNotEqual(
            output,
            input,
            "\(mutationName) mutation must not be a no-op.",
            file: file,
            line: line
        )
        return output
    }

    private func insertingLine(
        _ insertedLine: String,
        beforeLineWhoseTrimmedValueIs expectedLine: String,
        in input: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var lines = input.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let matches = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == expectedLine
        }
        XCTAssertEqual(
            matches.count,
            1,
            "The semantic line mutation must identify exactly one line.",
            file: file,
            line: line
        )
        guard matches.count == 1, let index = matches.first else {
            throw NSError(
                domain: "MacHostDeploymentContractTests.Mutation",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Expected one '\(expectedLine)' line, found \(matches.count)"
                ]
            )
        }
        let indentation = String(
            lines[index].prefix { character in
                character == " " || character == "\t"
            }
        )
        lines.insert(indentation + insertedLine, at: index)
        let output = lines.joined(separator: "\n")
        XCTAssertNotEqual(
            output,
            input,
            "The semantic line insertion must not be a no-op.",
            file: file,
            line: line
        )
        return output
    }

    private func launchState(installedPath: String) -> String {
        """
        gui/501/org.example.opensteamer.worldwide = {
            path = \(installedPath)
            type = LaunchAgent
            state = running
            program = /Applications/opensteamer Host.app/Contents/MacOS/CaptureServer
            arguments = {
                /Applications/opensteamer Host.app/Contents/MacOS/CaptureServer
                --worldwide
                --allow-remote-control
                --virtual-phone-display
                --secondary-test-viewer
                --duration
                0
                --verbose
                --rendezvous-url
                wss://audiostreamer-rendezvous.elaminahmed03.workers.dev
            }
            stdout path = /var/tmp/opensteamer-worldwide-host.log
            stderr path = /var/tmp/opensteamer-worldwide-host.err.log
            inherited environment = {
                SSH_AUTH_SOCK => /var/run/example
            }
            default environment = {
                PATH => /usr/bin:/bin:/usr/sbin:/sbin
            }
            environment = {
                OSLogRateLimit => 64
                XPC_SERVICE_NAME => org.example.opensteamer.worldwide
            }
            minimum runtime = 10
            runs = 1
            pid = 4242
            resource coalition = {
                ID = 919
                type = resource
                state = active
                pid = 99999
                program = /tmp/adversarial-resource-host
                arguments = {
                    /tmp/adversarial-resource-host
                    --nested-resource
                }
            }
            jetsam coalition = {
                ID = 920
                type = jetsam
                state = active
                pid = 88888
                program = /tmp/adversarial-jetsam-host
                arguments = {
                    /tmp/adversarial-jetsam-host
                    --nested-jetsam
                }
            }
            properties = keepalive | runatload | inferred program
        }
        """
    }

    private func makeTemporaryDirectory(prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensteamer-\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeCanonicalRepositoryTemporaryDirectory(prefix: String) -> URL {
        let base = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let url = base.appendingPathComponent(
            "opensteamer-\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func copyAndSign(source: URL, destination: URL, identifier: String) throws {
        let copy = try run(
            executable: URL(fileURLWithPath: "/bin/cp"),
            arguments: [source.path, destination.path]
        )
        XCTAssertEqual(copy.status, 0, copy.diagnostic)
        try sign(executable: destination, identifier: identifier)
    }

    private func sign(
        executable: URL,
        identifier: String,
        signingIdentity: String = "-"
    ) throws {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--sign", signingIdentity,
                "--identifier", identifier,
                "--timestamp=none",
                executable.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func approvedReleaseSigningIdentity() throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.contains("Developer ID Application:"),
                  value.contains("(MSMG8CJLB3)"),
                  let match = value.range(
                    of: "[0-9A-Fa-f]{40}",
                    options: .regularExpression
                  ) else {
                continue
            }
            return String(value[match]).uppercased()
        }
        throw XCTSkip("No Developer ID Application identity for MSMG8CJLB3 is available.")
    }

    private func compileDynamicLibrary(at output: URL, returnValue: Int) throws {
        let source = output.deletingPathExtension().appendingPathExtension("c")
        try "int fixture_value(void) { return \(returnValue); }\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                "-Werror",
                "-dynamiclib",
                "-install_name",
                "@rpath/libFixture.dylib",
                source.path,
                "-o",
                output.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func compileFrameworkFixtureRunner(at output: URL, linkedTo framework: URL) throws {
        let source = output.appendingPathExtension("c")
        try """
        #include <unistd.h>
        extern int fixture_value(void);
        int main(void) {
            if (fixture_value() != 7) { return 7; }
            sleep(30);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                "-Werror",
                source.path,
                framework.path,
                "-Wl,-rpath,@executable_path",
                "-o",
                output.path,
            ]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
    }

    private func codeHash(of executable: URL) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--display", "--verbose=4", executable.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        let hash = result.standardError
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("CDHash=") }?
            .dropFirst("CDHash=".count)
        return try XCTUnwrap(hash.map(String.init), result.diagnostic)
    }

    private func sha256(of file: URL) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", file.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        let digest = String(result.standardOutput.prefix(64))
        XCTAssertNotNil(
            digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
            result.diagnostic
        )
        return digest
    }

    private func eventuallyRun(
        executable: URL,
        arguments: [String],
        until predicate: (ProcessResult) -> Bool
    ) throws -> ProcessResult {
        let deadline = Date().addingTimeInterval(2)
        var result = try run(executable: executable, arguments: arguments)
        while !predicate(result), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            result = try run(executable: executable, arguments: arguments)
        }
        return result
    }

    private func run(executable: URL, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        let directory = makeTemporaryDirectory(prefix: "process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: stdoutURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: stderrURL.path, contents: nil))
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self)
        )
    }
}
