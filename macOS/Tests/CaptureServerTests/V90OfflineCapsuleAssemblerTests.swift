import Darwin
import Foundation
import XCTest

final class V90OfflineCapsuleAssemblerTests: XCTestCase {
    private enum CandidateLinkFault {
        case none
        case unknown
        case missing
        case dangling
        case wrongReviewedTarget
    }

    private enum HandoffMutation {
        case none
        case candidateExecutable
        case candidateAppRootMode
        case candidateAppRootACL
        case candidateAppRootXattr
        case candidateAppRootBSDFlag
        case candidateOutputMode
        case candidateOutputACL
        case candidateOutputXattr
        case candidateOutputBSDFlag
        case extraCandidateOutputFile
        case sourceExport
        case deploymentPlist
        case extraHandoffFile
    }

    private enum InitialMetadataFault {
        case none
        case candidateAppRootMode
        case candidateAppRootACL
        case candidateAppRootXattr
        case candidateAppRootBSDFlag
        case candidateOutputMode
        case candidateOutputACL
        case candidateOutputXattr
        case candidateOutputBSDFlag
    }

    private enum SourceToolingPlacement {
        case siblings
        case sourceInsideTooling
        case toolingInsideSource
    }

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
        let assembler: URL
        let source: URL
        let capsule: URL
        let reference: URL
        let referenceSHA256: String
        let archive: URL
        let fakeGit: URL
        let buildCapture: URL
        let prepareCapture: URL
        let developerDirectory: URL
        let protectedRuntime: URL
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testAssemblerBuildsCommittedOfflinePayloadFromExplicitInputs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runAssembler(fixture)
        guard result.status == 0 else {
            XCTFail(result.diagnostic)
            return
        }

        let metadata = fixture.capsule.appendingPathComponent(
            "trusted-v90-host-oracle-capsule-metadata.json"
        )
        let sourceManifest = fixture.capsule.appendingPathComponent(
            "v90-source-export-tree-manifest.txt"
        )
        let candidateManifest = fixture.capsule.appendingPathComponent(
            "v90-candidate-app-tree-manifest.txt"
        )
        let candidateCopyManifest = fixture.capsule.appendingPathComponent(
            "v90-candidate-app-copy-manifest.txt"
        )
        let payload = fixture.capsule.appendingPathComponent(
            "v90-deployment-payload-manifest.json"
        )
        let payloadSidecar = fixture.capsule.appendingPathComponent(
            "v90-deployment-payload-manifest.json.sha256"
        )
        let deploymentPlist = fixture.capsule.appendingPathComponent(
            "deployment/org.example.opensteamer.worldwide.plist"
        )
        XCTAssertTrue(try modeAndLinks(of: fixture.capsule).hasPrefix("700:"))
        for file in [metadata, sourceManifest, candidateManifest, candidateCopyManifest,
                     payload, payloadSidecar, deploymentPlist] {
            XCTAssertEqual(try modeAndLinks(of: file), "600:1", file.path)
        }

        let payloadSHA256 = try sha256(of: payload)
        XCTAssertEqual(
            try String(contentsOf: payloadSidecar, encoding: .utf8),
            payloadSHA256 + "\n"
        )
        let payloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: payload))
                as? [String: String]
        )
        XCTAssertEqual(
            Set(payloadObject.keys),
            Set([
                "schema", "sourceCommit", "sourceTree", "sourceBranch", "sourceUpstream",
                "toolingBranch", "toolingUpstream", "toolingCommit", "toolingTree",
                "toolingRemoteURL", "assemblerScriptRelativePath", "assemblerScriptGitBlob",
                "sourceExportRelativePath", "sourceTreeManifestRelativePath",
                "sourceTreeManifestSHA256", "candidateAppRelativePath",
                "candidateAppTreeManifestRelativePath", "candidateAppTreeManifestSHA256",
                "candidateAppCopyManifestRelativePath", "candidateAppCopyManifestSHA256",
                "candidateExecutableRelativePath", "candidateExecutableSHA256",
                "candidateMediaFrameworkExecutableRelativePath",
                "candidateMediaFrameworkExecutableSHA256", "candidateInfoPlistRelativePath",
                "candidateInfoPlistSHA256", "candidateLaunchPlistRelativePath",
                "candidateLaunchPlistSHA256", "capsuleMetadataRelativePath",
                "capsuleMetadataSHA256", "handoffRelativePath", "handoffSHA256",
                "hostIdentityManifestRelativePath", "hostIdentityManifestSHA256",
                "designatedRequirementReferenceRelativePath",
                "designatedRequirementReferenceSHA256",
            ])
        )
        XCTAssertEqual(
            payloadObject["schema"],
            "opensteamer.v90-deployment-payload-manifest.v1"
        )
        XCTAssertEqual(
            payloadObject["sourceCommit"],
            "229eabc22b9990891c5e5b2a5cfa27111f0a6b3e"
        )
        XCTAssertEqual(
            payloadObject["sourceTree"],
            "0192ef02be478f094afe1f66b50fe3b14717d0ea"
        )
        XCTAssertEqual(payloadObject["sourceTreeManifestSHA256"], try sha256(of: sourceManifest))
        XCTAssertEqual(
            payloadObject["candidateAppTreeManifestSHA256"],
            try sha256(of: candidateManifest)
        )
        XCTAssertEqual(
            payloadObject["candidateAppCopyManifestSHA256"],
            try sha256(of: candidateCopyManifest)
        )
        XCTAssertEqual(
            payloadObject["candidateMediaFrameworkExecutableRelativePath"],
            "candidate/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC"
        )
        XCTAssertEqual(
            payloadObject["designatedRequirementReferenceSHA256"],
            fixture.referenceSHA256
        )
        XCTAssertEqual(
            payloadObject["candidateLaunchPlistRelativePath"],
            "deployment/org.example.opensteamer.worldwide.plist"
        )
        XCTAssertEqual(
            payloadObject["candidateLaunchPlistSHA256"],
            try sha256(of: deploymentPlist)
        )
        XCTAssertEqual(
            try Data(contentsOf: deploymentPlist),
            try Data(contentsOf: fixture.capsule.appendingPathComponent(
                "source/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
            ))
        )
        let candidateOutput = fixture.capsule.appendingPathComponent(
            "candidate",
            isDirectory: true
        )
        let candidateApp = candidateOutput.appendingPathComponent(
            "opensteamer Host.app",
            isDirectory: true
        )
        XCTAssertEqual(
            try ownerModeFlags(of: candidateOutput),
            "\(geteuid()):700:0"
        )
        XCTAssertEqual(
            try ownerModeFlags(of: candidateApp),
            "\(geteuid()):755:0"
        )
        XCTAssertFalse(try hasACL(candidateOutput))
        XCTAssertFalse(try hasACL(candidateApp))
        XCTAssertEqual(try extendedAttributes(of: candidateOutput), "")
        XCTAssertEqual(try extendedAttributes(of: candidateApp), "")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: candidateOutput.path),
            ["opensteamer Host.app"]
        )

        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: deploymentPlist),
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
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

        let sourceLines = try String(contentsOf: sourceManifest, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertFalse(sourceLines.isEmpty)
        XCTAssertFalse(sourceLines.contains { $0.hasPrefix("L\t") })
        XCTAssertTrue(sourceLines.contains {
            $0.hasSuffix("\tmacOS/scripts/build-opensteamer-host-app.sh")
        })
        XCTAssertTrue(sourceLines.contains {
            $0.hasSuffix("\tmacOS/LaunchAgents/org.example.opensteamer.worldwide.plist")
        })
        let candidateLines = try String(contentsOf: candidateManifest, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(candidateLines.filter { $0.hasPrefix("L\t") }.count, 5)
        XCTAssertTrue(candidateLines.allSatisfy(validTreeRecord))
        XCTAssertTrue(sourceLines.allSatisfy(validTreeRecord))
        let candidateCopyLines = try String(
            contentsOf: candidateCopyManifest,
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        XCTAssertEqual(candidateCopyLines.filter { $0.hasPrefix("L\t") }.count, 5)
        XCTAssertTrue(candidateCopyLines.allSatisfy(validCopyRecord))

        let buildRecord = try String(contentsOf: fixture.buildCapture, encoding: .utf8)
        XCTAssertTrue(buildRecord.contains("require_fresh=1\n"), buildRecord)
        XCTAssertTrue(
            buildRecord.contains(
                "signer=483C08B6517EBC1CFCCAB1A88BBEE8028750AA13\n"
            ),
            buildRecord
        )
        XCTAssertTrue(buildRecord.contains("team=MSMG8CJLB3\n"), buildRecord)
        XCTAssertTrue(buildRecord.contains("architectures=arm64\n"), buildRecord)
        XCTAssertTrue(
            buildRecord.contains("developer_dir=\(fixture.developerDirectory.path)\n"),
            buildRecord
        )
        XCTAssertTrue(
            buildRecord.contains(
                "reference=\(fixture.capsule.path)/trusted-reference/CaptureServer\n"
            ),
            buildRecord
        )
        XCTAssertTrue(
            buildRecord.contains("tmpdir=\(fixture.capsule.path)/private-tmp\n"),
            buildRecord
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.capsule.appendingPathComponent("private-tmp").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.prepareCapture.path),
            "The committed handoff preparer must run exactly after metadata publication."
        )
        XCTAssertTrue(
            result.stdout.contains("deployment_payload_manifest_sha256=\(payloadSHA256)\n"),
            result.diagnostic
        )
    }

    func testAssemblerRejectsDirtySourceBeforeCreatingCapsule() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runAssembler(fixture, extraEnvironment: ["FAKE_GIT_DIRTY": "1"])
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(result.stderr.contains("source checkout is not clean"), result.diagnostic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testAssemblerRejectsRetainedCapsuleReferenceBeforeGitOrBuild() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retainedDirectory = fixture.root.appendingPathComponent(
            "retained-evidence-capsule",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let retainedReference = retainedDirectory.appendingPathComponent("CaptureServer")
        try Data("independent predecessor\n".utf8).write(to: retainedReference)
        try setMode(0o755, on: retainedReference)
        fixture = Fixture(
            root: fixture.root,
            assembler: fixture.assembler,
            source: fixture.source,
            capsule: fixture.capsule,
            reference: retainedReference,
            referenceSHA256: try sha256(of: retainedReference),
            archive: fixture.archive,
            fakeGit: fixture.fakeGit,
            buildCapture: fixture.buildCapture,
            prepareCapture: fixture.prepareCapture,
            developerDirectory: fixture.developerDirectory,
            protectedRuntime: fixture.protectedRuntime
        )

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains("retained or consumed runtime/evidence capsule"),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testAssemblerRejectsCandidateDerivedReferenceBeforeMetadataOrHandoff() throws {
        let fixture = try makeFixture(candidateMatchesReference: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains("candidate and predecessor reference are not independent"),
            result.diagnostic
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.capsule.appendingPathComponent(
                    "trusted-v90-host-oracle-capsule-metadata.json"
                ).path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
    }

    func testAssemblerRejectsUnreviewedCandidateSymlink() throws {
        let fixture = try makeFixture(linkFault: .unknown)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains("candidate app contains an unreviewed symbolic link"),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
    }

    func testAssemblerRejectsUnsafeCapsuleParentModeBeforeCreatingCapsule() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setMode(0o755, on: fixture.root)

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains("V90 capsule parent must be owner-owned mode 0700"),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testAssemblerRejectsUnsafeCapsuleParentACLWhenSupported() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let acl = try run(
            URL(fileURLWithPath: "/bin/chmod"),
            arguments: ["+a", "everyone allow read", fixture.root.path]
        )
        guard acl.status == 0 else {
            throw XCTSkip("filesystem does not support macOS ACL fixtures: \(acl.diagnostic)")
        }
        defer {
            _ = try? run(
                URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["-N", fixture.root.path]
            )
        }

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(result.stderr.contains("must not have an ACL"), result.diagnostic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testAssemblerRejectsCaseVariantProtectedRuntimePathLexically() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let caseVariantProtectedPath = fixture.protectedRuntime
            .deletingLastPathComponent()
            .appendingPathComponent(
                "pRoTeCtEd-RuNtImE/host-source-that-must-never-be-opened"
            ).path
        let result = try runAssembler(
            fixture,
            argumentOverride: [
                caseVariantProtectedPath,
                fixture.capsule.path,
                fixture.reference.path,
                fixture.referenceSHA256,
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains("source checkout is inside an installed-runtime"),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testAssemblerContainsHostileInheritedTMPDIR() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hostileTMPDIR = fixture.root.appendingPathComponent(
            "caller-controlled-tmp",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hostileTMPDIR,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = hostileTMPDIR.appendingPathComponent("sentinel")
        try Data("unchanged\n".utf8).write(to: sentinel)

        let result = try runAssembler(
            fixture,
            extraEnvironment: [
                "TMPDIR": hostileTMPDIR.path,
                "FAKE_HOSTILE_TMPDIR": hostileTMPDIR.path,
            ]
        )
        guard result.status == 0 else {
            XCTFail(result.diagnostic)
            return
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "unchanged\n")
        let buildRecord = try String(contentsOf: fixture.buildCapture, encoding: .utf8)
        XCTAssertTrue(
            buildRecord.contains("tmpdir=\(fixture.capsule.path)/private-tmp\n"),
            buildRecord
        )
        XCTAssertFalse(buildRecord.contains(hostileTMPDIR.path), buildRecord)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: hostileTMPDIR.path),
            ["sentinel"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.capsule.appendingPathComponent("private-tmp").path
            )
        )
    }

    func testAssemblerRejectsMissingDanglingAndWrongReviewedAliases() throws {
        let cases: [(CandidateLinkFault, String)] = [
            (.missing, "exactly five reviewed framework aliases"),
            (.dangling, "symbolic link is dangling or escapes the app"),
            (.wrongReviewedTarget, "unreviewed symbolic link"),
        ]
        for (fault, diagnostic) in cases {
            let fixture = try makeFixture(linkFault: fault)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try runAssembler(fixture)
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(result.stderr.contains(diagnostic), result.diagnostic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
        }
    }

    func testAssemblerRejectsCandidateOutputDebrisBeforeHandoff() throws {
        let fixture = try makeFixture(candidateOutputDebris: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runAssembler(fixture)
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains(
                "V90 candidate output directory contains missing, unexpected"
            ),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
    }

    func testAssemblerRejectsInitialCandidateAppRootMetadataFaults() throws {
        let cases: [(InitialMetadataFault, String)] = [
            (.candidateAppRootMode, "candidate app root must be owner-owned mode 0755"),
            (.candidateAppRootACL, "candidate app root must not have an ACL"),
            (.candidateAppRootXattr, "candidate app root contains extended attributes"),
            (.candidateAppRootBSDFlag, "candidate app root must be owner-owned mode 0755"),
        ]
        for (fault, diagnostic) in cases {
            let fixture = try makeFixture(initialMetadataFault: fault)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try runAssembler(fixture)
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(result.stderr.contains(diagnostic), result.diagnostic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
        }
    }

    func testAssemblerRejectsInitialCandidateOutputMetadataFaults() throws {
        let cases: [(InitialMetadataFault, String)] = [
            (.candidateOutputMode, "candidate output directory must be owner-owned mode 0700"),
            (.candidateOutputACL, "candidate output directory must not have an ACL"),
            (.candidateOutputXattr, "candidate output directory contains extended attributes"),
            (.candidateOutputBSDFlag, "candidate output directory must be owner-owned mode 0700"),
        ]
        for (fault, diagnostic) in cases {
            let fixture = try makeFixture(initialMetadataFault: fault)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try runAssembler(fixture)
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(result.stderr.contains(diagnostic), result.diagnostic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prepareCapture.path))
        }
    }

    func testAssemblerDetectsPostHandoffPayloadAndTreeMutations() throws {
        let cases: [(HandoffMutation, String)] = [
            (.candidateExecutable, "tree changed after manifest commitment"),
            (.candidateAppRootMode, "candidate app root must be owner-owned mode 0755"),
            (.candidateAppRootACL, "candidate app root must not have an ACL"),
            (.candidateAppRootXattr, "candidate app root contains extended attributes"),
            (.candidateAppRootBSDFlag, "candidate app root must be owner-owned mode 0755"),
            (.candidateOutputMode, "candidate output directory must be owner-owned mode 0700"),
            (.candidateOutputACL, "candidate output directory must not have an ACL"),
            (.candidateOutputXattr, "candidate output directory contains extended attributes"),
            (.candidateOutputBSDFlag, "candidate output directory must be owner-owned mode 0700"),
            (.extraCandidateOutputFile, "candidate output directory contains missing, unexpected"),
            (.sourceExport, "tree changed after manifest commitment"),
            (.deploymentPlist, "launch plist changed before payload publication"),
            (.extraHandoffFile, "handoff directory contains missing, unexpected"),
        ]
        for (mutation, diagnostic) in cases {
            let fixture = try makeFixture(handoffMutation: mutation)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try runAssembler(fixture)
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(result.stderr.contains(diagnostic), result.diagnostic)
            XCTAssertFalse(
                result.stdout.contains("deployment_payload_manifest_sha256="),
                result.diagnostic
            )
        }
    }

    func testAssemblerRejectsCapsuleOverlapWithSourceOrToolingBeforeCreation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tooling = fixture.assembler
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cases: [(URL, String)] = [
            (
                fixture.source.appendingPathComponent("nested-capsule"),
                "V90 capsule and source checkout must not overlap"
            ),
            (
                tooling.appendingPathComponent("nested-capsule"),
                "V90 capsule and tooling checkout must not overlap"
            ),
        ]
        for (capsule, diagnostic) in cases {
            let result = try runAssembler(
                fixture,
                argumentOverride: [
                    fixture.source.path,
                    capsule.path,
                    fixture.reference.path,
                    fixture.referenceSHA256,
                ]
            )
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(result.stderr.contains(diagnostic), result.diagnostic)
            XCTAssertFalse(FileManager.default.fileExists(atPath: capsule.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
        }
    }

    func testAssemblerRejectsNestedSourceAndToolingBeforeCreatingCapsule() throws {
        for placement in [
            SourceToolingPlacement.sourceInsideTooling,
            SourceToolingPlacement.toolingInsideSource,
        ] {
            let fixture = try makeFixture(sourceToolingPlacement: placement)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let result = try runAssembler(fixture)
            XCTAssertNotEqual(result.status, 0, result.diagnostic)
            XCTAssertTrue(
                result.stderr.contains(
                    "pinned release source and tooling checkout must not overlap"
                ),
                result.diagnostic
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
        }
    }

    func testAssemblerManifestsAndPayloadAreDeterministicAcrossCreationOrder() throws {
        let first = try makeFixture(reverseCandidateCreationOrder: false)
        defer { try? FileManager.default.removeItem(at: first.root) }
        let second = try makeFixture(reverseCandidateCreationOrder: true)
        defer { try? FileManager.default.removeItem(at: second.root) }

        let firstResult = try runAssembler(first)
        guard firstResult.status == 0 else {
            XCTFail(firstResult.diagnostic)
            return
        }
        let secondResult = try runAssembler(second)
        guard secondResult.status == 0 else {
            XCTFail(secondResult.diagnostic)
            return
        }
        for relative in [
            "v90-source-export-tree-manifest.txt",
            "v90-candidate-app-tree-manifest.txt",
            "v90-candidate-app-copy-manifest.txt",
            "v90-deployment-payload-manifest.json",
        ] {
            XCTAssertEqual(
                try Data(contentsOf: first.capsule.appendingPathComponent(relative)),
                try Data(contentsOf: second.capsule.appendingPathComponent(relative)),
                relative
            )
        }
    }

    func testProductionPlaceholderFailsBeforeCapsuleCreation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let production = repositoryRoot.appendingPathComponent(
            "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh"
        )

        let result = try run(
            production,
            arguments: [
                fixture.source.path,
                fixture.capsule.path,
                fixture.reference.path,
                fixture.referenceSHA256,
            ]
        )
        XCTAssertNotEqual(result.status, 0, result.diagnostic)
        XCTAssertTrue(
            result.stderr.contains(
                "compiled approved predecessor-reference digest (explicit Ahmed approval required)"
            ),
            result.diagnostic
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.capsule.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.buildCapture.path))
    }

    func testProductionAssemblerPinsOfflineContractAndNoKnownIneligibleReference() throws {
        let script = repositoryRoot.appendingPathComponent(
            "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh"
        )
        let text = try String(contentsOf: script, encoding: .utf8)
        for expected in [
            "229eabc22b9990891c5e5b2a5cfa27111f0a6b3e",
            "0192ef02be478f094afe1f66b50fe3b14717d0ea",
            "fix/ios-metal-watchdog-testflight-83",
            "https://github.com/ahmedelami/opensteamer.git",
            "483C08B6517EBC1CFCCAB1A88BBEE8028750AA13",
            "MSMG8CJLB3",
            "OPENSTEAMER_REQUIRE_FRESH_RELEASE=1",
            "git -C \"$SOURCE_ROOT\" archive",
            "APPROVED_PREDECESSOR_REFERENCE_SHA256='UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL'",
        ] {
            XCTAssertTrue(text.contains(expected), "missing production pin: \(expected)")
        }
        XCTAssertFalse(text.contains("4b353f"))
        XCTAssertFalse(text.contains("beluga-v86-independent-reference-rebuild"))
        XCTAssertFalse(text.contains("/bin/launchctl"))
        XCTAssertFalse(text.contains("/usr/bin/kill"))
        XCTAssertFalse(text.contains("/usr/bin/pkill"))
    }

    private func makeFixture(
        candidateMatchesReference: Bool = false,
        linkFault: CandidateLinkFault = .none,
        handoffMutation: HandoffMutation = .none,
        reverseCandidateCreationOrder: Bool = false,
        candidateOutputDebris: Bool = false,
        sourceToolingPlacement: SourceToolingPlacement = .siblings,
        initialMetadataFault: InitialMetadataFault = .none
    ) throws -> Fixture {
        let root = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(
                "v90-offline-assembler-\(UUID().uuidString.prefix(8))",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let source: URL
            let tooling: URL
            switch sourceToolingPlacement {
            case .siblings:
                source = root.appendingPathComponent("source-checkout", isDirectory: true)
                tooling = root.appendingPathComponent("tooling-checkout", isDirectory: true)
            case .sourceInsideTooling:
                tooling = root.appendingPathComponent("tooling-checkout", isDirectory: true)
                source = tooling.appendingPathComponent("source-checkout", isDirectory: true)
            case .toolingInsideSource:
                source = root.appendingPathComponent("source-checkout", isDirectory: true)
                tooling = source.appendingPathComponent("tooling-checkout", isDirectory: true)
            }
            let archiveRoot = root.appendingPathComponent("archive-root", isDirectory: true)
            let developerDirectory = root.appendingPathComponent(
                "PinnedXcode.app/Contents/Developer",
                isDirectory: true
            )
            let protectedRuntime = root.appendingPathComponent(
                "Protected-Runtime",
                isDirectory: true
            )
            for directory in [source, tooling, archiveRoot, developerDirectory] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try setMode(0o700, on: directory)
            }
            let scripts = archiveRoot.appendingPathComponent("macOS/scripts", isDirectory: true)
            let launchAgents = archiveRoot.appendingPathComponent(
                "macOS/LaunchAgents",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: scripts,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: launchAgents,
                withIntermediateDirectories: true
            )
            let buildCapture = root.appendingPathComponent("build-capture.txt")
            let prepareCapture = root.appendingPathComponent("prepare-capture.txt")
            let reference = root.appendingPathComponent("approved-reference/CaptureServer")
            try FileManager.default.createDirectory(
                at: reference.deletingLastPathComponent(),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("independent predecessor\n".utf8).write(to: reference)
            try setMode(0o755, on: reference)
            let referenceSHA256 = try sha256(of: reference)

            let builder = scripts.appendingPathComponent("build-opensteamer-host-app.sh")
            let candidateBytes = candidateMatchesReference
                ? "independent predecessor\n"
                : "fresh V90 candidate\n"
            try fakeBuilder(
                candidateBytes: candidateBytes,
                linkFault: linkFault,
                candidateOutputDebris: candidateOutputDebris,
                initialMetadataFault: initialMetadataFault
            ).write(to: builder, atomically: false, encoding: .utf8)
            try setMode(0o755, on: builder)
            let preparer = scripts.appendingPathComponent(
                "prepare-v90-sealed-host-oracle-handoff.sh"
            )
            try fakePreparer(mutation: handoffMutation).write(
                to: preparer,
                atomically: false,
                encoding: .utf8
            )
            try setMode(0o755, on: preparer)
            let sourcePlist = launchAgents.appendingPathComponent(
                "org.example.opensteamer.worldwide.plist"
            )
            try sourceLaunchPlist.write(to: sourcePlist, atomically: false, encoding: .utf8)
            try setMode(0o644, on: sourcePlist)
            let filler = archiveRoot.appendingPathComponent("README.md")
            try Data("pinned source export\n".utf8).write(to: filler)
            try setMode(0o644, on: filler)
            try clearExtendedAttributesRecursively(at: archiveRoot)

            let archive = root.appendingPathComponent("source.tar")
            let tar = try run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-c", "-f", archive.path, "-C", archiveRoot.path, "."],
                extraEnvironment: ["COPYFILE_DISABLE": "1"]
            )
            XCTAssertEqual(tar.status, 0, tar.diagnostic)

            let fakeGit = root.appendingPathComponent("fake-git")
            try fakeGitScript.write(to: fakeGit, atomically: false, encoding: .utf8)
            try setMode(0o755, on: fakeGit)
            let sourceAssembler = repositoryRoot.appendingPathComponent(
                "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh"
            )
            var assemblerText = try String(contentsOf: sourceAssembler, encoding: .utf8)
            assemblerText = assemblerText.replacingOccurrences(
                of: "/usr/bin/git",
                with: fakeGit.path
            )
            assemblerText = assemblerText.replacingOccurrences(
                of: "/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer",
                with: developerDirectory.path
            )
            assemblerText = assemblerText.replacingOccurrences(
                of: "/Users/ahmed/Library/Application Support/opensteamer",
                with: protectedRuntime.path
            )
            let assembler = tooling.appendingPathComponent(
                "macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh"
            )
            try FileManager.default.createDirectory(
                at: assembler.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            assemblerText = assemblerText.replacingOccurrences(
                of: "UNSET_REQUIRES_EXPLICIT_AHMED_APPROVAL",
                with: referenceSHA256
            )
            try assemblerText.write(to: assembler, atomically: false, encoding: .utf8)
            try setMode(0o755, on: assembler)
            if reverseCandidateCreationOrder {
                try Data().write(to: root.appendingPathComponent("reverse-candidate-order"))
            }
            try clearExtendedAttributesRecursively(at: root)

            return Fixture(
                root: root,
                assembler: assembler,
                source: source,
                capsule: root.appendingPathComponent("fresh-v90-capsule"),
                reference: reference,
                referenceSHA256: referenceSHA256,
                archive: archive,
                fakeGit: fakeGit,
                buildCapture: buildCapture,
                prepareCapture: prepareCapture,
                developerDirectory: developerDirectory,
                protectedRuntime: protectedRuntime
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func runAssembler(
        _ fixture: Fixture,
        extraEnvironment: [String: String] = [:],
        argumentOverride: [String]? = nil
    ) throws -> ProcessResult {
        var environment = extraEnvironment
        environment["FAKE_GIT_ROOT"] = fixture.source.path
        environment["FAKE_TOOLING_ROOT"] = fixture.assembler
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path
        environment["FAKE_GIT_ARCHIVE"] = fixture.archive.path
        return try run(
            fixture.assembler,
            arguments: argumentOverride ?? [
                fixture.source.path,
                fixture.capsule.path,
                fixture.reference.path,
                fixture.referenceSHA256,
            ],
            extraEnvironment: environment
        )
    }

    private func fakeBuilder(
        candidateBytes: String,
        linkFault: CandidateLinkFault,
        candidateOutputDebris: Bool,
        initialMetadataFault: InitialMetadataFault
    ) -> String {
        let infoPlistCreation = """
        /usr/bin/printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \\
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \\
          '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.elamin.AudioStreamer.CaptureServer</string></dict></plist>' \\
          > "$app/Contents/Info.plist"
        /bin/chmod 644 "$app/Contents/Info.plist"
        """
        let linkFaultScript: String
        switch linkFault {
        case .none:
            linkFaultScript = ""
        case .unknown:
            linkFaultScript = "/bin/ln -s Contents \"$app/UnexpectedAlias\"\n"
        case .missing:
            linkFaultScript = "/bin/rm \"$framework/Resources\"\n"
        case .dangling:
            linkFaultScript = "/bin/rm -R \"$framework/Versions/A/Resources\"\n"
        case .wrongReviewedTarget:
            linkFaultScript = """
            /bin/rm "$framework/Headers"
            /bin/ln -s Versions/Current/Resources "$framework/Headers"
            """
        }
        let candidateOutputDebrisScript = candidateOutputDebris
            ? "/usr/bin/printf 'debris\\n' > \"${OPENSTEAMER_HOST_APP_OUTPUT_DIR}/unexpected-debris\"\n"
            : ""
        let initialMetadataFaultScript: String
        switch initialMetadataFault {
        case .none:
            initialMetadataFaultScript = ""
        case .candidateAppRootMode:
            initialMetadataFaultScript = "/bin/chmod 700 \"$app\"\n"
        case .candidateAppRootACL:
            initialMetadataFaultScript = "/bin/chmod +a 'everyone allow read' \"$app\"\n"
        case .candidateAppRootXattr:
            initialMetadataFaultScript = "/usr/bin/xattr -w org.example.opensteamer.fixture unsafe \"$app\"\n"
        case .candidateAppRootBSDFlag:
            initialMetadataFaultScript = "/usr/bin/chflags hidden \"$app\"\n"
        case .candidateOutputMode:
            initialMetadataFaultScript = "/bin/chmod 755 \"${OPENSTEAMER_HOST_APP_OUTPUT_DIR}\"\n"
        case .candidateOutputACL:
            initialMetadataFaultScript = "/bin/chmod +a 'everyone allow read' \"${OPENSTEAMER_HOST_APP_OUTPUT_DIR}\"\n"
        case .candidateOutputXattr:
            initialMetadataFaultScript = "/usr/bin/xattr -w org.example.opensteamer.fixture unsafe \"${OPENSTEAMER_HOST_APP_OUTPUT_DIR}\"\n"
        case .candidateOutputBSDFlag:
            initialMetadataFaultScript = "/usr/bin/chflags hidden \"${OPENSTEAMER_HOST_APP_OUTPUT_DIR}\"\n"
        }
        return """
        #!/bin/zsh
        set -euo pipefail
        [[ "${OPENSTEAMER_REQUIRE_FRESH_RELEASE:-}" == 1 ]]
        [[ "${OPENSTEAMER_HOST_CODESIGN_IDENTITY:-}" == 483C08B6517EBC1CFCCAB1A88BBEE8028750AA13 ]]
        [[ "${OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1:-}" == 483C08B6517EBC1CFCCAB1A88BBEE8028750AA13 ]]
        [[ "${OPENSTEAMER_EXPECTED_TEAM_ID:-}" == MSMG8CJLB3 ]]
        [[ "${OPENSTEAMER_EXPECTED_ARCHITECTURES:-}" == arm64 ]]
        [[ "${TMPDIR:-}" == "${OPENSTEAMER_HOST_APP_OUTPUT_DIR:h}/private-tmp" ]]
        fixture_root="${OPENSTEAMER_HOST_APP_OUTPUT_DIR:h:h}"
        [[ "${DEVELOPER_DIR:-}" == "$fixture_root/PinnedXcode.app/Contents/Developer" ]]
        /bin/mkdir -m 700 "${OPENSTEAMER_HOST_SCRATCH_PATH}"
        /usr/bin/printf 'private scratch\n' > "${OPENSTEAMER_HOST_SCRATCH_PATH}/fixture"
        app="${OPENSTEAMER_HOST_APP_OUTPUT_DIR}/opensteamer Host.app"
        framework="$app/Contents/Frameworks/LiveKitWebRTC.framework"
        if [[ -e "$fixture_root/reverse-candidate-order" ]]; then
          /bin/mkdir -p "$framework/Versions/A/Resources" \
            "$framework/Versions/A/Modules" "$framework/Versions/A/Headers" \
            "$app/Contents/MacOS"
          \(infoPlistCreation)
        else
          /bin/mkdir -p "$app/Contents/MacOS" "$framework/Versions/A/Headers" \
            "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
        fi
        /usr/bin/printf '%s' '\(candidateBytes)' > "$app/Contents/MacOS/CaptureServer"
        /usr/bin/printf 'fresh framework\n' > "$framework/Versions/A/LiveKitWebRTC"
        /bin/chmod 755 "$app/Contents/MacOS/CaptureServer" \
          "$framework/Versions/A/LiveKitWebRTC"
        /bin/ln -s A "$framework/Versions/Current"
        /bin/ln -s Versions/Current/Headers "$framework/Headers"
        /bin/ln -s Versions/Current/LiveKitWebRTC "$framework/LiveKitWebRTC"
        /bin/ln -s Versions/Current/Modules "$framework/Modules"
        /bin/ln -s Versions/Current/Resources "$framework/Resources"
        \(linkFaultScript)
        if [[ ! -e "$fixture_root/reverse-candidate-order" ]]; then
          \(infoPlistCreation)
        fi
        /bin/chmod 755 "$app"
        \(candidateOutputDebrisScript)
        \(initialMetadataFaultScript)
        {
          print -r -- "require_fresh=${OPENSTEAMER_REQUIRE_FRESH_RELEASE}"
          print -r -- "signer=${OPENSTEAMER_HOST_CODESIGN_IDENTITY}"
          print -r -- "team=${OPENSTEAMER_EXPECTED_TEAM_ID}"
          print -r -- "architectures=${OPENSTEAMER_EXPECTED_ARCHITECTURES}"
          print -r -- "developer_dir=${DEVELOPER_DIR}"
          print -r -- "reference=${OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE}"
          print -r -- "scratch=${OPENSTEAMER_HOST_SCRATCH_PATH}"
          print -r -- "tmpdir=${TMPDIR}"
        } > "$fixture_root/build-capture.txt"
        print -r -- "$app"
        """
    }

    private func fakePreparer(mutation: HandoffMutation) -> String {
        let mutationScript: String
        switch mutation {
        case .none:
            mutationScript = ""
        case .candidateExecutable:
            mutationScript = """
            /usr/bin/printf 'post-handoff candidate mutation\n' >> \
              "${metadata:h}/candidate/opensteamer Host.app/Contents/MacOS/CaptureServer"
            """
        case .candidateAppRootMode:
            mutationScript = """
            /bin/chmod 700 "${metadata:h}/candidate/opensteamer Host.app"
            """
        case .candidateAppRootACL:
            mutationScript = """
            /bin/chmod +a 'everyone allow read' \
              "${metadata:h}/candidate/opensteamer Host.app"
            """
        case .candidateAppRootXattr:
            mutationScript = """
            /usr/bin/xattr -w org.example.opensteamer.fixture unsafe \
              "${metadata:h}/candidate/opensteamer Host.app"
            """
        case .candidateAppRootBSDFlag:
            mutationScript = """
            /usr/bin/chflags hidden "${metadata:h}/candidate/opensteamer Host.app"
            """
        case .candidateOutputMode:
            mutationScript = """
            /bin/chmod 755 "${metadata:h}/candidate"
            """
        case .candidateOutputACL:
            mutationScript = """
            /bin/chmod +a 'everyone allow read' "${metadata:h}/candidate"
            """
        case .candidateOutputXattr:
            mutationScript = """
            /usr/bin/xattr -w org.example.opensteamer.fixture unsafe \
              "${metadata:h}/candidate"
            """
        case .candidateOutputBSDFlag:
            mutationScript = """
            /usr/bin/chflags hidden "${metadata:h}/candidate"
            """
        case .extraCandidateOutputFile:
            mutationScript = """
            /usr/bin/printf 'uncommitted\n' > "${metadata:h}/candidate/uncommitted-output"
            """
        case .sourceExport:
            mutationScript = """
            /usr/bin/printf 'post-handoff source mutation\n' >> "${metadata:h}/source/README.md"
            """
        case .deploymentPlist:
            mutationScript = """
            /usr/bin/printf '\n<!-- post-handoff deployment mutation -->\n' >> \
              "${metadata:h}/deployment/org.example.opensteamer.worldwide.plist"
            """
        case .extraHandoffFile:
            mutationScript = """
            /usr/bin/printf 'uncommitted\n' > "$output/uncommitted-helper-output"
            """
        }
        return """
        #!/bin/zsh
        set -euo pipefail
        [[ $# == 3 && "$1" == prepare ]]
        metadata=$2
        expected=$3
        actual=$(/usr/bin/shasum -a 256 "$metadata" | /usr/bin/awk '{print $1}')
        [[ "$actual" == "$expected" ]]
        output="${metadata:h}/v90-screen-oracle-handoff"
        /bin/mkdir -m 700 "$output"
        manifest="$output/sealed-live-mac-host-identity.json"
        manifest_sidecar="$output/sealed-live-mac-host-identity.json.sha256"
        handoff="$output/v90-screen-oracle-host-identity-handoff.json"
        handoff_sidecar="$output/v90-screen-oracle-host-identity-handoff.json.sha256"
        /usr/bin/printf '{"fixture":"identity"}\n' > "$manifest"
        /bin/chmod 600 "$manifest"
        manifest_sha=$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')
        /usr/bin/printf '%s\n' "$manifest_sha" > "$manifest_sidecar"
        /bin/chmod 600 "$manifest_sidecar"
        /usr/bin/printf '{"fixture":"handoff"}\n' > "$handoff"
        /bin/chmod 600 "$handoff"
        handoff_sha=$(/usr/bin/shasum -a 256 "$handoff" | /usr/bin/awk '{print $1}')
        /usr/bin/printf '%s\n' "$handoff_sha" > "$handoff_sidecar"
        /bin/chmod 600 "$handoff_sidecar"
        \(mutationScript)
        /usr/bin/printf '%s\n' "$metadata|$expected" > "${metadata:h:h}/prepare-capture.txt"
        print -r -- "handoff_path=$handoff"
        print -r -- "handoff_sha256=$handoff_sha"
        print -r -- "handoff_sha256_path=$handoff_sidecar"
        print -r -- "manifest_path=$manifest"
        print -r -- "manifest_sha256=$manifest_sha"
        print -r -- "manifest_sha256_path=$manifest_sidecar"
        """
    }

    private var fakeGitScript: String {
        """
        #!/bin/zsh
        set -euo pipefail
        [[ -z "${FAKE_HOSTILE_TMPDIR:-}" \
          || "${TMPDIR:-}" != "${FAKE_HOSTILE_TMPDIR}" ]]
        [[ "$1" == -C ]]
        repository=$2
        [[ "$repository" == "${FAKE_GIT_ROOT}" || "$repository" == "${FAKE_TOOLING_ROOT}" ]]
        shift 2
        case "$1" in
          rev-parse)
            shift
            if [[ "$1" == --show-toplevel ]]; then
              print -r -- "$repository"
            elif [[ "$1" == --abbrev-ref && "$2" == --symbolic-full-name ]]; then
              print -r -- origin/fix/ios-metal-watchdog-testflight-83
            elif [[ "$1" == --verify ]]; then
              case "$2" in
                HEAD|'@{upstream}')
                  if [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]; then
                    print -r -- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                  else
                    print -r -- 229eabc22b9990891c5e5b2a5cfa27111f0a6b3e
                  fi ;;
                'HEAD^{tree}')
                  if [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]; then
                    print -r -- bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
                  else
                    print -r -- 0192ef02be478f094afe1f66b50fe3b14717d0ea
                  fi ;;
                '229eabc22b9990891c5e5b2a5cfa27111f0a6b3e^{tree}')
                  print -r -- 0192ef02be478f094afe1f66b50fe3b14717d0ea ;;
                'HEAD:macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh')
                  print -r -- cccccccccccccccccccccccccccccccccccccccc ;;
                *) exit 65 ;;
              esac
            else
              exit 65
            fi
            ;;
          symbolic-ref)
            [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]
            print -r -- fix/ios-metal-watchdog-testflight-83
            ;;
          status)
            if [[ "$repository" == "${FAKE_GIT_ROOT}" && -n "${FAKE_GIT_DIRTY:-}" ]]; then
              print -r -- '?? dirty-file'
            fi
            ;;
          archive)
            [[ "$repository" == "${FAKE_GIT_ROOT}" ]]
            /bin/cat "${FAKE_GIT_ARCHIVE}"
            ;;
          remote)
            [[ "$repository" == "${FAKE_TOOLING_ROOT}" && "$2" == get-url ]]
            print -r -- https://github.com/ahmedelami/opensteamer.git
            ;;
          ls-remote)
            [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]
            /usr/bin/printf '%s\t%s\n' \
              aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
              refs/heads/fix/ios-metal-watchdog-testflight-83
            ;;
          hash-object)
            [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]
            print -r -- cccccccccccccccccccccccccccccccccccccccc
            ;;
          merge-base)
            [[ "$repository" == "${FAKE_TOOLING_ROOT}" ]]
            exit 0
            ;;
          *) exit 65 ;;
        esac
        """
    }

    private var sourceLaunchPlist: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>org.example.opensteamer.worldwide</string>
          <key>ProgramArguments</key>
          <array>
            <string>/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer</string>
            <string>--worldwide</string>
            <string>--allow-remote-control</string>
            <string>--virtual-phone-display</string>
            <string>--secondary-test-viewer</string>
            <string>--duration</string><string>0</string>
            <string>--verbose</string>
            <string>--rendezvous-url</string>
            <string>wss://audiostreamer-rendezvous.elaminahmed03.workers.dev</string>
          </array>
          <key>EnvironmentVariables</key><dict><key>OSLogRateLimit</key><string>64</string></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>StandardOutPath</key><string>/var/tmp/opensteamer-worldwide-host.log</string>
          <key>StandardErrorPath</key><string>/var/tmp/opensteamer-worldwide-host.err.log</string>
        </dict>
        </plist>
        """
    }

    private func validTreeRecord(_ line: String) -> Bool {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        switch fields.first {
        case "D":
            return fields.count == 3 && validMetadata(String(fields[1]))
        case "F":
            return fields.count == 4 && validMetadata(String(fields[1]))
                && String(fields[2]).range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                ) != nil
        case "L":
            return fields.count == 5 && validMetadata(String(fields[1]))
                && String(fields[2]).range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                ) != nil
        default:
            return false
        }
    }

    private func validMetadata(_ value: String) -> Bool {
        value.range(
            of: "^0[0-7]{3}:[0-9]+:[0-9]+:[0-9]+:[0-9]+:0$",
            options: .regularExpression
        ) != nil
    }

    private func validCopyRecord(_ line: String) -> Bool {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        switch fields.first {
        case "D":
            return fields.count == 3 && String(fields[1]).range(
                of: "^0[0-7]{3}$",
                options: .regularExpression
            ) != nil
        case "F":
            return fields.count == 4 && String(fields[1]).range(
                of: "^0[0-7]{3}:[0-9]+$",
                options: .regularExpression
            ) != nil && String(fields[2]).range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        case "L":
            return fields.count == 4 && String(fields[1]).range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil
        default:
            return false
        }
    }

    private func run(
        _ executable: URL,
        arguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) throws -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
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

    private func clearExtendedAttributesRecursively(at path: URL) throws {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-c", "-r", path.path]
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "V90OfflineCapsuleAssemblerTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.diagnostic]
            )
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

    private func ownerModeFlags(of path: URL) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/stat"),
            arguments: ["-f", "%u:%Lp:%f", path.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasACL(_ path: URL) throws -> Bool {
        let result = try run(
            URL(fileURLWithPath: "/bin/ls"),
            arguments: ["-lde", path.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        let mode = result.stdout.split(whereSeparator: { $0.isWhitespace }).first ?? ""
        return mode.contains("+")
    }

    private func extendedAttributes(of path: URL) throws -> String {
        let result = try run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: [path.path]
        )
        XCTAssertEqual(result.status, 0, result.diagnostic)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
