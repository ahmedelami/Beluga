import Foundation
import XCTest

final class SealedMacHostIdentityManifestGeneratorTests: XCTestCase {
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

    func testGeneratorPublishesExactCandidateIdentityAndRejectsReuseOrMutation() throws {
        let root = makeTemporaryDirectory(prefix: "sealed-host-generator")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseSigningIdentity = try approvedReleaseSigningIdentity()
        let candidate = try buildSignedCandidate(
            in: root,
            outputName: "candidate build with spaces",
            signingIdentity: releaseSigningIdentity
        )
        let designatedRequirementReference = try makeDesignatedRequirementReference(
            at: root.appendingPathComponent("sealed predecessor CaptureServer"),
            signingIdentity: releaseSigningIdentity,
            identifier: "com.elamin.AudioStreamer.CaptureServer"
        )
        let designatedRequirementReferenceSHA256 = try sha256(
            of: designatedRequirementReference
        )
        let publication = root.appendingPathComponent("publication")
        try FileManager.default.createDirectory(
            at: publication,
            withIntermediateDirectories: false
        )
        try setMode(0o700, on: publication)

        let generator = repositoryRoot.appendingPathComponent(
            "macOS/scripts/create-sealed-mac-host-identity-manifest.sh"
        )
        let generated = try run(
            executable: generator,
            arguments: [
                candidate.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                publication.path,
            ]
        )
        XCTAssertEqual(generated.status, 0, generated.diagnostic)

        let manifest = publication.appendingPathComponent(
            "sealed-live-mac-host-identity.json"
        )
        let sidecar = publication.appendingPathComponent(
            "sealed-live-mac-host-identity.json.sha256"
        )
        XCTAssertEqual(try metadata(of: manifest), "600:1")
        XCTAssertEqual(try metadata(of: sidecar), "600:1")
        let manifestDigest = try sha256(of: manifest)
        XCTAssertTrue(
            manifestDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        )
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), manifestDigest + "\n")
        XCTAssertEqual(
            generated.standardOutput,
            """
            manifest_path=\(manifest.path)
            manifest_sha256=\(manifestDigest)
            manifest_sha256_path=\(sidecar.path)

            """
        )

        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
                as? [String: Any]
        )
        let expectedKeys = Set([
            "schema",
            "executablePath",
            "executableSHA256",
            "executableCDHash",
            "executableIdentifier",
            "executableTeamIdentifier",
            "mediaFrameworkExecutablePath",
            "mediaFrameworkExecutableSHA256",
            "mediaFrameworkExecutableCDHash",
            "mediaFrameworkExecutableIdentifier",
            "mediaFrameworkExecutableTeamIdentifier",
        ])
        XCTAssertEqual(Set(manifestObject.keys), expectedKeys)
        XCTAssertTrue(manifestObject.values.allSatisfy { $0 is String })
        XCTAssertEqual(
            manifestObject["schema"] as? String,
            "opensteamer.sealed-live-mac-host-identity.v1"
        )
        XCTAssertEqual(
            manifestObject["executablePath"] as? String,
            "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer"
        )
        XCTAssertEqual(
            manifestObject["mediaFrameworkExecutablePath"] as? String,
            "/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        )
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: manifest), as: UTF8.self)
                .contains(candidate.path),
            "The release seal must describe eventual installed paths, not staging paths."
        )

        let candidateExecutable = candidate.appendingPathComponent(
            "Contents/MacOS/CaptureServer"
        )
        let candidateFramework = candidate.appendingPathComponent(
            "Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
        ).resolvingSymlinksInPath()
        let executableIdentity = try codeIdentity(of: candidateExecutable)
        let frameworkIdentity = try codeIdentity(of: candidateFramework)
        XCTAssertEqual(
            manifestObject["executableSHA256"] as? String,
            try sha256(of: candidateExecutable)
        )
        XCTAssertEqual(
            manifestObject["executableCDHash"] as? String,
            executableIdentity.cdHash
        )
        XCTAssertEqual(
            manifestObject["executableIdentifier"] as? String,
            executableIdentity.identifier
        )
        XCTAssertEqual(
            manifestObject["executableTeamIdentifier"] as? String,
            executableIdentity.teamIdentifier
        )
        XCTAssertEqual(
            manifestObject["mediaFrameworkExecutableSHA256"] as? String,
            try sha256(of: candidateFramework)
        )
        XCTAssertEqual(
            manifestObject["mediaFrameworkExecutableCDHash"] as? String,
            frameworkIdentity.cdHash
        )
        XCTAssertEqual(
            manifestObject["mediaFrameworkExecutableIdentifier"] as? String,
            frameworkIdentity.identifier
        )
        XCTAssertEqual(
            manifestObject["mediaFrameworkExecutableTeamIdentifier"] as? String,
            frameworkIdentity.teamIdentifier
        )
        XCTAssertEqual(executableIdentity.teamIdentifier, frameworkIdentity.teamIdentifier)
        XCTAssertEqual(executableIdentity.teamIdentifier, "MSMG8CJLB3")

        let manifestBytes = try Data(contentsOf: manifest)
        let sidecarBytes = try Data(contentsOf: sidecar)
        let reuse = try run(
            executable: generator,
            arguments: [
                candidate.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                publication.path,
            ]
        )
        XCTAssertNotEqual(reuse.status, 0, reuse.diagnostic)
        XCTAssertTrue(
            reuse.standardError.contains("publication destinations must both be absent"),
            reuse.diagnostic
        )
        XCTAssertEqual(try Data(contentsOf: manifest), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)

        let rejectedPublication = root.appendingPathComponent("signature-rejection")
        try FileManager.default.createDirectory(
            at: rejectedPublication,
            withIntermediateDirectories: false
        )
        try setMode(0o700, on: rejectedPublication)
        let executableHandle = try FileHandle(forWritingTo: candidateExecutable)
        try executableHandle.seekToEnd()
        try executableHandle.write(contentsOf: Data([0]))
        try executableHandle.close()
        let changedSignature = try run(
            executable: generator,
            arguments: [
                candidate.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                rejectedPublication.path,
            ]
        )
        XCTAssertNotEqual(changedSignature.status, 0, changedSignature.diagnostic)
        XCTAssertTrue(
            changedSignature.standardError.contains(
                "candidate host bundle failed reviewed verification"
            ),
            changedSignature.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: rejectedPublication.path),
            []
        )
    }

    func testGeneratorRejectsAdHocCandidateAndMismatchedDesignatedRequirement() throws {
        let root = makeTemporaryDirectory(prefix: "sealed-host-generator-signing-rejection")
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseSigningIdentity = try approvedReleaseSigningIdentity()
        let releaseCandidate = try buildSignedCandidate(
            in: root,
            outputName: "release-candidate-build",
            signingIdentity: releaseSigningIdentity
        )
        let designatedRequirementReference = try makeDesignatedRequirementReference(
            at: root.appendingPathComponent("approved designated requirement reference"),
            signingIdentity: releaseSigningIdentity,
            identifier: "com.elamin.AudioStreamer.CaptureServer"
        )
        let designatedRequirementReferenceSHA256 = try sha256(
            of: designatedRequirementReference
        )
        let adHocCandidate = try buildSignedCandidate(
            in: root,
            outputName: "ad-hoc-candidate-build",
            signingIdentity: "-"
        )
        let generator = repositoryRoot.appendingPathComponent(
            "macOS/scripts/create-sealed-mac-host-identity-manifest.sh"
        )

        let adHocPublication = try makePrivatePublicationDirectory(
            in: root,
            name: "ad-hoc-rejection"
        )
        let adHocRejection = try run(
            executable: generator,
            arguments: [
                adHocCandidate.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                adHocPublication.path,
            ]
        )
        XCTAssertNotEqual(adHocRejection.status, 0, adHocRejection.diagnostic)
        XCTAssertTrue(
            adHocRejection.standardError.contains(
                "candidate host bundle failed reviewed verification"
            ),
            adHocRejection.diagnostic
        )
        XCTAssertTrue(
            adHocRejection.standardError.contains(
                "TeamIdentifier: expected 'MSMG8CJLB3', found 'not set'"
            ),
            adHocRejection.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: adHocPublication.path),
            []
        )

        let mismatchedReference = try makeDesignatedRequirementReference(
            at: root.appendingPathComponent("mismatched designated requirement reference"),
            signingIdentity: releaseSigningIdentity,
            identifier: "com.elamin.opensteamer.WrongDesignatedRequirement"
        )
        let mismatchPublication = try makePrivatePublicationDirectory(
            in: root,
            name: "designated-requirement-rejection"
        )
        let mismatchRejection = try run(
            executable: generator,
            arguments: [
                releaseCandidate.path,
                mismatchedReference.path,
                try sha256(of: mismatchedReference),
                mismatchPublication.path,
            ]
        )
        XCTAssertNotEqual(mismatchRejection.status, 0, mismatchRejection.diagnostic)
        XCTAssertTrue(
            mismatchRejection.standardError.contains(
                "candidate host bundle failed reviewed verification"
            ),
            mismatchRejection.diagnostic
        )
        XCTAssertTrue(
            mismatchRejection.standardError.contains(
                "main executable designated requirement does not match the reference code object"
            ),
            mismatchRejection.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: mismatchPublication.path),
            []
        )

        let digestMismatchPublication = try makePrivatePublicationDirectory(
            in: root,
            name: "reference-digest-rejection"
        )
        let digestMismatch = try run(
            executable: generator,
            arguments: [
                releaseCandidate.path,
                designatedRequirementReference.path,
                String(repeating: "0", count: 64),
                digestMismatchPublication.path,
            ]
        )
        XCTAssertNotEqual(digestMismatch.status, 0, digestMismatch.diagnostic)
        XCTAssertTrue(
            digestMismatch.standardError.contains(
                "reference SHA-256 does not match the trusted predecessor digest"
            ),
            digestMismatch.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: digestMismatchPublication.path),
            []
        )

        let candidateExecutable = releaseCandidate.appendingPathComponent(
            "Contents/MacOS/CaptureServer"
        )
        let candidateDerivedReference = root.appendingPathComponent(
            "candidate-derived-reference"
        )
        try FileManager.default.copyItem(
            at: candidateExecutable,
            to: candidateDerivedReference
        )
        let candidateDerivedPublication = try makePrivatePublicationDirectory(
            in: root,
            name: "candidate-derived-reference-rejection"
        )
        let candidateDerivedRejection = try run(
            executable: generator,
            arguments: [
                releaseCandidate.path,
                candidateDerivedReference.path,
                try sha256(of: candidateDerivedReference),
                candidateDerivedPublication.path,
            ]
        )
        XCTAssertNotEqual(
            candidateDerivedRejection.status,
            0,
            candidateDerivedRejection.diagnostic
        )
        XCTAssertTrue(
            candidateDerivedRejection.standardError.contains(
                "reference must not be derived from the candidate executable"
            ),
            candidateDerivedRejection.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: candidateDerivedPublication.path
            ),
            []
        )

        try setMode(0o700, on: designatedRequirementReference)
        let unsafeMetadataPublication = try makePrivatePublicationDirectory(
            in: root,
            name: "reference-metadata-rejection"
        )
        let unsafeMetadataRejection = try run(
            executable: generator,
            arguments: [
                releaseCandidate.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                unsafeMetadataPublication.path,
            ]
        )
        XCTAssertNotEqual(
            unsafeMetadataRejection.status,
            0,
            unsafeMetadataRejection.diagnostic
        )
        XCTAssertTrue(
            unsafeMetadataRejection.standardError.contains(
                "canonical, owner-owned, executable, mode 0755, and one-link"
            ),
            unsafeMetadataRejection.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: unsafeMetadataPublication.path
            ),
            []
        )
    }

    func testGeneratorRejectsUnsafeDirectorySymlinkAndExistingLinkedDestinations() throws {
        let root = makeTemporaryDirectory(prefix: "sealed-host-generator-unsafe")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidatePlaceholder = root.appendingPathComponent("opensteamer Host.app")
        try FileManager.default.createDirectory(
            at: candidatePlaceholder,
            withIntermediateDirectories: false
        )
        let designatedRequirementReference = root.appendingPathComponent(
            "designated-requirement-reference"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: designatedRequirementReference.path,
                contents: Data("placeholder".utf8)
            )
        )
        try setMode(0o755, on: designatedRequirementReference)
        let designatedRequirementReferenceSHA256 = try sha256(
            of: designatedRequirementReference
        )
        let generator = repositoryRoot.appendingPathComponent(
            "macOS/scripts/create-sealed-mac-host-identity-manifest.sh"
        )

        let publicDirectory = root.appendingPathComponent("public")
        try FileManager.default.createDirectory(
            at: publicDirectory,
            withIntermediateDirectories: false
        )
        try setMode(0o755, on: publicDirectory)
        let publicRejection = try run(
            executable: generator,
            arguments: [
                candidatePlaceholder.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                publicDirectory.path,
            ]
        )
        XCTAssertNotEqual(publicRejection.status, 0, publicRejection.diagnostic)
        XCTAssertTrue(
            publicRejection.standardError.contains("owner-owned mode 0700"),
            publicRejection.diagnostic
        )

        let privateDirectory = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false
        )
        try setMode(0o700, on: privateDirectory)
        let directoryAlias = root.appendingPathComponent("private-alias")
        try FileManager.default.createSymbolicLink(
            atPath: directoryAlias.path,
            withDestinationPath: privateDirectory.path
        )
        let aliasRejection = try run(
            executable: generator,
            arguments: [
                candidatePlaceholder.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                directoryAlias.path,
            ]
        )
        XCTAssertNotEqual(aliasRejection.status, 0, aliasRejection.diagnostic)
        XCTAssertTrue(
            aliasRejection.standardError.contains("canonical absolute real directory"),
            aliasRejection.diagnostic
        )

        let manifest = privateDirectory.appendingPathComponent(
            "sealed-live-mac-host-identity.json"
        )
        try FileManager.default.createSymbolicLink(
            atPath: manifest.path,
            withDestinationPath: "/tmp/never-follow-this-manifest"
        )
        let symlinkRejection = try run(
            executable: generator,
            arguments: [
                candidatePlaceholder.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                privateDirectory.path,
            ]
        )
        XCTAssertNotEqual(symlinkRejection.status, 0, symlinkRejection.diagnostic)
        XCTAssertTrue(
            symlinkRejection.standardError.contains(
                "publication destinations must both be absent"
            ),
            symlinkRejection.diagnostic
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: manifest.path),
            "/tmp/never-follow-this-manifest"
        )
        try FileManager.default.removeItem(at: manifest)

        let linkedSource = privateDirectory.appendingPathComponent("linked-source")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: linkedSource.path,
                contents: Data("do-not-overwrite".utf8)
            )
        )
        let link = try run(
            executable: URL(fileURLWithPath: "/bin/ln"),
            arguments: [linkedSource.path, manifest.path]
        )
        XCTAssertEqual(link.status, 0, link.diagnostic)
        let linkedBytes = try Data(contentsOf: manifest)
        let hardlinkRejection = try run(
            executable: generator,
            arguments: [
                candidatePlaceholder.path,
                designatedRequirementReference.path,
                designatedRequirementReferenceSHA256,
                privateDirectory.path,
            ]
        )
        XCTAssertNotEqual(hardlinkRejection.status, 0, hardlinkRejection.diagnostic)
        XCTAssertTrue(
            hardlinkRejection.standardError.contains(
                "publication destinations must both be absent"
            ),
            hardlinkRejection.diagnostic
        )
        XCTAssertEqual(try Data(contentsOf: manifest), linkedBytes)
        XCTAssertEqual(try metadata(of: manifest), "644:2")
    }

    private func buildSignedCandidate(
        in root: URL,
        outputName: String,
        signingIdentity: String
    ) throws -> URL {
        let output = root.appendingPathComponent(outputName)
        let products = Bundle(
            for: SealedMacHostIdentityManifestGeneratorTests.self
        ).bundleURL.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["OPENSTEAMER_HOST_CODESIGN_IDENTITY"] = signingIdentity
        environment["OPENSTEAMER_HOST_APP_OUTPUT_DIR"] = output.path
        environment["OPENSTEAMER_HOST_PREBUILT_BIN_DIR"] = products.path
        environment["OPENSTEAMER_ALLOW_PREBUILT_FOR_TESTS"] = "1"
        environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_TEAM_ID")
        environment.removeValue(forKey: "OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1")
        environment.removeValue(forKey: "OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE")
        let builder = repositoryRoot.appendingPathComponent(
            "macOS/scripts/build-opensteamer-host-app.sh"
        )
        let result = try run(executable: builder, environment: environment)
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return output.appendingPathComponent("opensteamer Host.app")
            .resolvingSymlinksInPath()
    }

    private func approvedReleaseSigningIdentity() throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.contains("(MSMG8CJLB3)"),
                  value.contains("Developer ID Application:") else {
                continue
            }
            if let match = value.range(
                of: "[0-9A-Fa-f]{40}",
                options: .regularExpression
            ) {
                return String(value[match]).uppercased()
            }
        }
        throw XCTSkip(
            "No Developer ID Application identity for MSMG8CJLB3 is available."
        )
    }

    private func makeDesignatedRequirementReference(
        at destination: URL,
        signingIdentity: String,
        identifier: String
    ) throws -> URL {
        let source = destination.appendingPathExtension("c")
        try "int main(void) { return 0; }\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let compile = try run(
            executable: URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: ["-Werror", source.path, "-o", destination.path]
        )
        XCTAssertEqual(compile.status, 0, compile.diagnostic)
        let sign = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: [
                "--force",
                "--sign", signingIdentity,
                "--identifier", identifier,
                "--timestamp=none",
                destination.path,
            ]
        )
        XCTAssertEqual(sign.status, 0, sign.diagnostic)
        XCTAssertEqual(try metadata(of: destination), "755:1")
        return destination.resolvingSymlinksInPath()
    }

    private func makePrivatePublicationDirectory(in root: URL, name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try setMode(0o700, on: directory)
        return directory
    }

    private func codeIdentity(
        of target: URL
    ) throws -> (cdHash: String, identifier: String, teamIdentifier: String) {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--display", "--verbose=4", target.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        func uniqueField(_ name: String) throws -> String {
            let prefix = name + "="
            let values = result.standardError
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
            XCTAssertEqual(values.count, 1, result.diagnostic)
            return try XCTUnwrap(values.first, result.diagnostic)
        }
        return (
            try uniqueField("CDHash").lowercased(),
            try uniqueField("Identifier"),
            try uniqueField("TeamIdentifier")
        )
    }

    private func metadata(of file: URL) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/stat"),
            arguments: ["-f", "%Lp:%l", file.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func setMode(_ mode: Int, on target: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: target.path
        )
    }

    private func makeTemporaryDirectory(prefix: String) -> URL {
        let url = repositoryRoot.appendingPathComponent(".build")
            .appendingPathComponent("opensteamer-\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = repositoryRoot
        let directory = makeTemporaryDirectory(prefix: "sealed-host-generator-process")
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
