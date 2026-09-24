import Darwin
import Foundation
import MediaBridgeCore
import RemoteSessionCore
import XCTest
@testable import CaptureServer

final class WorldwideSecondaryTestViewerControlServerTests: XCTestCase {
    private let hostGeneration = String(repeating: "a", count: 64)
    private let nonce = String(repeating: "b", count: 32)

    func testDefaultSocketPathFitsDarwinAddressAndUsesPrivateLeaf() throws {
        let path = try WorldwideSecondaryTestViewerControlServer.defaultSocketPath()
        _ = try MediaBridgeSocket.address(path)
        XCTAssertLessThan(path.utf8.count, MemoryLayout<sockaddr_un>.size)
        XCTAssertEqual(
            path,
            "/private/tmp/opensteamer-wv-\(geteuid())/control.sock"
        )
        let mode = try XCTUnwrap(
            WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--request-secondary-test-viewer-invitation",
                "/private/tmp/invitation.txt",
            ], environment: [:])
        )
        XCTAssertEqual(mode.socketPath, path)
        XCTAssertEqual(mode.receiptURL.path, "/private/tmp/invitation.txt.receipt")
    }

    func testClientModeParsesBeforeHostStartupWithExplicitNonsecretPaths()
        throws {
        let output = "/private/tmp/secondary-invitation.txt"
        let socket = "/private/tmp/secondary-control.sock"
        let mode = try XCTUnwrap(
            WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--request-secondary-test-viewer-invitation",
                output,
                "--secondary-test-viewer-control-socket",
                socket,
            ], environment: [:])
        )

        XCTAssertEqual(mode.outputURL.path, output)
        XCTAssertEqual(mode.receiptURL.path, output + ".receipt")
        XCTAssertEqual(mode.socketPath, socket)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--request-secondary-test-viewer-invitation",
                output,
                "--worldwide",
            ], environment: [:])
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/CaptureServerMain.swift"
            ),
            encoding: .utf8
        )
        let clientEntry = try XCTUnwrap(
            source.range(of: "WorldwideSecondaryTestViewerControlClientMode")
        )
        let displayProbe = try XCTUnwrap(
            source.range(of: "ScreenVideoDisplayModeProbeMode")
        )
        let hostOptions = try XCTUnwrap(
            source.range(of: "CaptureServerOptions.parse(CommandLine.arguments)")
        )
        let hostLock = try XCTUnwrap(
            source.range(of: "WorldwideHostProcessLock.acquire()")
        )
        XCTAssertLessThan(clientEntry.lowerBound, hostOptions.lowerBound)
        XCTAssertLessThan(clientEntry.lowerBound, hostLock.lowerBound)
        XCTAssertLessThan(clientEntry.lowerBound, displayProbe.lowerBound)
    }

    func testStopClientModeIsExclusiveAndUsesReceiptPath() throws {
        let receipt = "/private/tmp/secondary-invitation.txt.receipt"
        let socket = "/private/tmp/secondary-control.sock"
        let mode = try XCTUnwrap(
            WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--stop-secondary-test-viewer-generation",
                receipt,
                "--secondary-test-viewer-control-socket",
                socket,
            ], environment: [:])
        )

        XCTAssertEqual(mode.receiptURL.path, receipt)
        XCTAssertEqual(mode.socketPath, socket)
        guard case .stop(let receiptURL) = mode.action else {
            return XCTFail("Expected exact-generation stop mode")
        }
        XCTAssertEqual(receiptURL.path, receipt)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--request-secondary-test-viewer-invitation",
                "/private/tmp/invitation.txt",
                "--stop-secondary-test-viewer-generation",
                receipt,
            ], environment: [:])
        )
    }

    func testProbeClientModeIsExclusiveAndUsesExplicitOwnerOnlyOutputPath() throws {
        let output = "/private/tmp/secondary-viewer-status.json"
        let socket = "/private/tmp/secondary-control.sock"
        let mode = try XCTUnwrap(
            WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--probe-secondary-test-viewer-status",
                output,
                "--secondary-test-viewer-control-socket",
                socket,
            ], environment: [:])
        )

        XCTAssertEqual(mode.outputURL.path, output)
        XCTAssertEqual(mode.socketPath, socket)
        guard case .probe(let outputURL) = mode.action else {
            return XCTFail("Expected status probe mode")
        }
        XCTAssertEqual(outputURL.path, output)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--probe-secondary-test-viewer-status",
                output,
                "--request-secondary-test-viewer-invitation",
                "/private/tmp/invitation.txt",
            ], environment: [:])
        )
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested([
                "CaptureServer",
                "--probe-secondary-test-viewer-status",
                "relative.json",
            ], environment: [:])
        )
    }

    func testLiveExchangeSelectsBoundedTimeoutForEachRequestTypeAndThenChecksEOF()
        throws {
        let identity = WorldwideSecondaryTestViewerHostIdentity(
            processIdentifier: 123,
            generation: hostGeneration
        )
        let probe = WorldwideSecondaryTestViewerControlRequest(
            probing: identity,
            requestNonce: String(repeating: "1", count: 32)
        )
        let renewal = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: identity.processIdentifier,
            expectedHostGeneration: identity.generation,
            expectedManagerGeneration: 0,
            requestNonce: String(repeating: "2", count: 32)
        )
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: identity.processIdentifier,
            hostGeneration: identity.generation,
            managerGeneration: 1,
            renewalRequestNonce: renewal.requestNonce
        )
        let stop = WorldwideSecondaryTestViewerControlRequest(
            stopping: receipt,
            requestNonce: String(repeating: "3", count: 32)
        )
        let cases: [(
            request: WorldwideSecondaryTestViewerControlRequest,
            response: WorldwideSecondaryTestViewerControlResponse,
            timeout: TimeInterval
        )] = [
            (
                probe,
                WorldwideSecondaryTestViewerControlResponse(
                    status: .observed,
                    hostProcessIdentifier: identity.processIdentifier,
                    hostGeneration: identity.generation,
                    managerGeneration: 0,
                    requestNonce: probe.requestNonce,
                    managerPhase: "idle",
                    managerIsIdle: true
                ),
                WorldwideSecondaryTestViewerControlClient.probeResponseTimeout
            ),
            (
                renewal,
                WorldwideSecondaryTestViewerControlResponse(
                    status: .staleGeneration,
                    hostProcessIdentifier: identity.processIdentifier,
                    hostGeneration: identity.generation,
                    managerGeneration: 7,
                    requestNonce: renewal.requestNonce
                ),
                WorldwideSecondaryTestViewerControlClient.renewalResponseTimeout
            ),
            (
                stop,
                WorldwideSecondaryTestViewerControlResponse(
                    status: .stopped,
                    hostProcessIdentifier: identity.processIdentifier,
                    hostGeneration: identity.generation,
                    managerGeneration: receipt.managerGeneration,
                    requestNonce: stop.requestNonce
                ),
                WorldwideSecondaryTestViewerControlClient.stopResponseTimeout
            ),
        ]

        XCTAssertEqual(
            WorldwideSecondaryTestViewerControlClient.probeResponseTimeout,
            2
        )
        XCTAssertGreaterThan(
            WorldwideSecondaryTestViewerControlClient.renewalResponseTimeout,
            30
        )
        XCTAssertGreaterThan(
            WorldwideSecondaryTestViewerControlClient.stopResponseTimeout,
            45
        )

        for testCase in cases {
            var frames: [Data?] = [try testCase.response.encode(), nil]
            var observedTimeouts: [TimeInterval] = []
            let decoded = try WorldwideSecondaryTestViewerControlClient
                .readSingleResponse(
                    descriptor: -1,
                    request: testCase.request
                ) { _, idleTimeout in
                    observedTimeouts.append(idleTimeout)
                    return frames.removeFirst()
                }

            XCTAssertEqual(decoded, testCase.response)
            XCTAssertEqual(
                observedTimeouts,
                [
                    testCase.timeout,
                    WorldwideSecondaryTestViewerControlClient.trailingFrameTimeout,
                ]
            )
            XCTAssertTrue(frames.isEmpty)
        }
    }

    func testLiveExchangeRejectsTrailingFrameAfterValidResponse() throws {
        let request = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: 123,
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )
        let response = WorldwideSecondaryTestViewerControlResponse(
            status: .staleGeneration,
            hostProcessIdentifier: request.expectedHostProcessIdentifier,
            hostGeneration: request.expectedHostGeneration,
            managerGeneration: 4,
            requestNonce: request.requestNonce
        )
        var frames: [Data?] = [try response.encode(), Data([0x01])]
        var observedTimeouts: [TimeInterval] = []

        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClient.readSingleResponse(
                descriptor: -1,
                request: request
            ) { _, idleTimeout in
                observedTimeouts.append(idleTimeout)
                return frames.removeFirst()
            }
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }
        XCTAssertEqual(
            observedTimeouts,
            [
                WorldwideSecondaryTestViewerControlClient.renewalResponseTimeout,
                WorldwideSecondaryTestViewerControlClient.trailingFrameTimeout,
            ]
        )
        XCTAssertTrue(frames.isEmpty)
    }

    func testIdleStatusProbeIsReplaySafeAndDoesNotMintOrAdvanceGeneration()
        async throws {
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let identity = WorldwideSecondaryTestViewerHostIdentity(
            processIdentifier: 123,
            generation: hostGeneration
        )
        let request = WorldwideSecondaryTestViewerControlRequest(
            probing: identity,
            requestNonce: nonce
        )

        let response = await handler.handle(request)
        let replay = await handler.handle(request)
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(response.status, .observed)
        XCTAssertEqual(response.hostProcessIdentifier, identity.processIdentifier)
        XCTAssertEqual(response.hostGeneration, identity.generation)
        XCTAssertEqual(response.managerGeneration, 0)
        XCTAssertEqual(response.managerPhase, "idle")
        XCTAssertEqual(response.managerIsIdle, true)
        XCTAssertEqual(response.requestNonce, nonce)
        XCTAssertNil(response.invitationCode)
        XCTAssertNil(response.generationReceipt)
        XCTAssertEqual(replay.status, .replayed)
        XCTAssertEqual(snapshot.managerGeneration, 0)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertEqual(factory.requestedGenerations, [])
    }

    func testClientProbeRejectsResponseNotBoundToNonceOrConsistentPhase() throws {
        let identity = WorldwideSecondaryTestViewerHostIdentity(
            processIdentifier: 123,
            generation: hostGeneration
        )
        let wrongNonce = WorldwideSecondaryTestViewerControlClient { _, request in
            WorldwideSecondaryTestViewerControlResponse(
                status: .observed,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: 0,
                requestNonce: String(repeating: "0", count: 32),
                managerPhase: "idle",
                managerIsIdle: true
            )
        }
        XCTAssertThrowsError(
            try wrongNonce.probeStatus(
                socketPath: "/unused/control.sock",
                hostIdentity: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }

        let inconsistent = WorldwideSecondaryTestViewerControlClient { _, request in
            // The strict response codec rejects this before a live client can receive it; the
            // injected exchange also proves the client result validation fails closed.
            WorldwideSecondaryTestViewerControlResponse(
                status: .observed,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: 0,
                requestNonce: request.requestNonce,
                managerPhase: "running",
                managerIsIdle: true
            )
        }
        XCTAssertThrowsError(
            try inconsistent.probeStatus(
                socketPath: "/unused/control.sock",
                hostIdentity: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }
    }

    func testStatusProbeReportsCurrentRunningGenerationWithoutMintingAnother()
        async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.renew(expectedManagerGeneration: 0)
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let request = WorldwideSecondaryTestViewerControlRequest(
            probing: WorldwideSecondaryTestViewerHostIdentity(
                processIdentifier: 123,
                generation: hostGeneration
            ),
            requestNonce: String(repeating: "c", count: 32)
        )

        let response = await handler.handle(request)

        XCTAssertEqual(response.status, .observed)
        XCTAssertEqual(response.managerGeneration, 1)
        XCTAssertEqual(response.managerPhase, "running")
        XCTAssertEqual(response.managerIsIdle, false)
        XCTAssertNil(response.invitationCode)
        XCTAssertNil(response.generationReceipt)
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testClientRetriesStaleGenerationOnceWithFreshNonce() throws {
        let invitation = try RemoteInvitationCode.generate().exportedCode
        let exchange = ControlClientExchangeStub(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            invitation: invitation
        )
        let client = WorldwideSecondaryTestViewerControlClient(
            exchange: exchange.exchange
        )

        let result = try client.requestInvitation(
            socketPath: "/unused/control.sock",
            hostIdentity: WorldwideSecondaryTestViewerHostIdentity(
                processIdentifier: 123,
                generation: hostGeneration
            )
        )

        XCTAssertEqual(result, invitation)
        XCTAssertEqual(exchange.managerGenerations, [0, 7])
        XCTAssertEqual(exchange.nonces.count, 2)
        XCTAssertNotEqual(exchange.nonces[0], exchange.nonces[1])
    }

    func testClientRejectsResponseNotBoundToRequestNonce() throws {
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            WorldwideSecondaryTestViewerControlResponse(
                status: .staleGeneration,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: 9,
                requestNonce: String(repeating: "0", count: 32)
            )
        }

        XCTAssertThrowsError(
            try client.requestInvitation(
                socketPath: "/unused/control.sock",
                hostIdentity: WorldwideSecondaryTestViewerHostIdentity(
                    processIdentifier: 123,
                    generation: hostGeneration
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }
    }

    func testClientRejectsStartedResponseWithUnexpectedGeneration() throws {
        let invitation = try RemoteInvitationCode.generate().exportedCode
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            WorldwideSecondaryTestViewerControlResponse(
                status: .started,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: request.expectedManagerGeneration + 2,
                requestNonce: request.requestNonce,
                invitationCode: invitation,
                generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt(
                    hostProcessIdentifier: request.expectedHostProcessIdentifier,
                    hostGeneration: request.expectedHostGeneration,
                    managerGeneration: request.expectedManagerGeneration + 2,
                    renewalRequestNonce: request.requestNonce
                )
            )
        }

        XCTAssertThrowsError(
            try client.requestInvitation(
                socketPath: "/unused/control.sock",
                hostIdentity: WorldwideSecondaryTestViewerHostIdentity(
                    processIdentifier: 123,
                    generation: hostGeneration
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }
    }

    func testInvitationReservationFailureRemovesOnlyCreatedInode() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("invitation.txt")

        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerInvitationFile.reserve(
                at: outputURL,
                afterOutputOpenForTesting: {
                    throw ControlTestError.factoryFailure
                }
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testInvitationReservationCancelDoesNotDeleteReplacementInode() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let reservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
            at: outputURL
        )
        try FileManager.default.removeItem(at: outputURL)
        let replacement = Data("replacement\n".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: outputURL.path,
                contents: replacement,
                attributes: [.posixPermissions: 0o600]
            )
        )

        reservation.cancel()

        XCTAssertEqual(try Data(contentsOf: outputURL), replacement)
    }

    func testInvitationAndReceiptPathsRejectSymlinkedAncestorDirectories()
        throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real", isDirectory: true)
        let privateOutput = realParent.appendingPathComponent(
            "private-output",
            isDirectory: true
        )
        let aliasParent = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateOutput,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(realParent.path, 0o700), 0)
        XCTAssertEqual(chmod(privateOutput.path, 0o700), 0)
        try FileManager.default.createSymbolicLink(
            at: aliasParent,
            withDestinationURL: realParent
        )

        let aliasedInvitation = aliasParent
            .appendingPathComponent("private-output/invitation.txt")
        let realInvitation = privateOutput.appendingPathComponent("invitation.txt")
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerInvitationFile.reserve(
                at: aliasedInvitation
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .unsafeOutput
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: realInvitation.path))

        let realReceipt = URL(fileURLWithPath: realInvitation.path + ".receipt")
        let aliasedReceipt = URL(fileURLWithPath: aliasedInvitation.path + ".receipt")
        let receiptReservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
            at: realReceipt
        )
        try receiptReservation.commitReceipt(
            WorldwideSecondaryTestViewerPersistedGenerationReceipt(
                invitationOutputPath: aliasedInvitation.path,
                receipt: WorldwideSecondaryTestViewerGenerationReceipt(
                    hostProcessIdentifier: 123,
                    hostGeneration: hostGeneration,
                    managerGeneration: 1,
                    renewalRequestNonce: nonce
                )
            )
        )

        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerGenerationReceiptFile.load(
                from: aliasedReceipt
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .unsafeOutput
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: realReceipt.path))
    }

    func testClientWritesInvitationToFreshOwnerOnlyFileWithoutOverwrite()
        async throws {
        // Keep the real /private spelling through creation, receipt load, and exact stop.
        let directory = try makePrivateDirectory(usePrivateTemporaryRoot: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let invitation = try RemoteInvitationCode.generate().exportedCode
        let service = ControlServiceStub(invitationCode: invitation)
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: [service]).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=\(getpid())\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        try server.start()

        try WorldwideSecondaryTestViewerControlClient().requestAndWriteInvitation(
            socketPath: path,
            hostLockURL: lockURL,
            outputURL: outputURL
        )

        var metadata = stat()
        XCTAssertEqual(lstat(outputURL.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            invitation + "\n"
        )
        var receiptMetadata = stat()
        XCTAssertEqual(lstat(receiptURL.path, &receiptMetadata), 0)
        XCTAssertEqual(receiptMetadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(receiptMetadata.st_mode & 0o777, 0o600)
        let receiptBytes = try Data(contentsOf: receiptURL)
        XCTAssertFalse(
            try XCTUnwrap(String(data: receiptBytes, encoding: .utf8))
                .contains(invitation)
        )
        let persistedReceipt = try WorldwideSecondaryTestViewerPersistedGenerationReceipt
            .decode(receiptBytes)
        XCTAssertEqual(persistedReceipt.invitationOutputPath, outputURL.path)
        XCTAssertEqual(persistedReceipt.receipt.managerGeneration, 1)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerInvitationFile.write(
                try RemoteInvitationCode.generate().exportedCode,
                to: outputURL
            )
        )
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            invitation + "\n"
        )
        try WorldwideSecondaryTestViewerControlClient().stopGeneration(
            socketPath: path,
            hostLockURL: lockURL,
            receiptURL: receiptURL
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertEqual(service.stopCallCount, 1)
        let stopped = await coordinator.snapshot()
        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(stopped.phase, .idle)
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testClientAtomicallyWritesOwnerOnlyStatusWithoutMinting() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("status.json")
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=\(getpid())\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        try server.start()

        try WorldwideSecondaryTestViewerControlClient().probeAndWriteStatus(
            socketPath: path,
            hostLockURL: lockURL,
            outputURL: outputURL
        )

        var metadata = stat()
        XCTAssertEqual(lstat(outputURL.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(metadata.st_uid, geteuid())
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_nlink, 1)
        let result = try WorldwideSecondaryTestViewerStatusProbeResult.decode(
            Data(contentsOf: outputURL)
        )
        XCTAssertEqual(result.hostProcessIdentifier, getpid())
        XCTAssertEqual(result.hostGeneration, hostGeneration)
        XCTAssertEqual(result.managerGeneration, 0)
        XCTAssertEqual(result.managerPhase, "idle")
        XCTAssertTrue(result.managerIsIdle)
        XCTAssertEqual(result.requestNonce.utf8.count, 32)
        XCTAssertEqual(factory.requestedGenerations, [])
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.managerGeneration, 0)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".status.json.") }
        )

        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testStatusOutputRejectsCollisionSymlinkAndUnsafeDirectory() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let collision = directory.appendingPathComponent("collision.json")
        let original = Data("preserve\n".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: collision.path,
                contents: original,
                attributes: [.posixPermissions: 0o600]
            )
        )
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerStatusFile.reserve(at: collision)
        )
        XCTAssertEqual(try Data(contentsOf: collision), original)

        let symlink = directory.appendingPathComponent("status-link.json")
        XCTAssertEqual(Darwin.symlink(collision.path, symlink.path), 0)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerStatusFile.reserve(at: symlink)
        )
        XCTAssertEqual(try Data(contentsOf: collision), original)

        let unsafeDirectory = directory.appendingPathComponent(
            "unsafe",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(unsafeDirectory.path, 0o755), 0)
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerStatusFile.reserve(
                at: unsafeDirectory.appendingPathComponent("status.json")
            )
        )
    }

    func testStatusReservationCleanupDoesNotDeleteReplacementTemporaryInode()
        throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("status.json")
        var reservation: WorldwideSecondaryTestViewerStatusFile.Reservation? = try
            WorldwideSecondaryTestViewerStatusFile.reserve(at: outputURL)
        let temporaryName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: directory.path)
                .first { $0.hasPrefix(".status.json.") && $0.hasSuffix(".tmp") }
        )
        let temporaryURL = directory.appendingPathComponent(temporaryName)
        try FileManager.default.removeItem(at: temporaryURL)
        let replacement = Data("replacement\n".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: replacement,
                attributes: [.posixPermissions: 0o600]
            )
        )

        reservation = nil

        XCTAssertNil(reservation)
        XCTAssertEqual(try Data(contentsOf: temporaryURL), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testStatusPublicationDoesNotOverwriteRacingOutputCreation() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("status.json")
        var reservation: WorldwideSecondaryTestViewerStatusFile.Reservation? = try
            WorldwideSecondaryTestViewerStatusFile.reserve(at: outputURL)
        let competingBytes = Data("competing-output\n".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: outputURL.path,
                contents: competingBytes,
                attributes: [.posixPermissions: 0o600]
            )
        )
        let result = WorldwideSecondaryTestViewerStatusProbeResult(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 0,
            managerPhase: "idle",
            managerIsIdle: true,
            requestNonce: nonce
        )

        XCTAssertThrowsError(try reservation?.commit(result))
        reservation = nil

        XCTAssertEqual(try Data(contentsOf: outputURL), competingBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".status.json.") }
        )
    }

    func testClientRequestFailureRemovesReservedOutput() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let client = WorldwideSecondaryTestViewerControlClient { _, _ in
            throw ControlTestError.factoryFailure
        }

        XCTAssertThrowsError(
            try client.requestAndWriteInvitation(
                socketPath: "/unused/control.sock",
                hostLockURL: lockURL,
                outputURL: outputURL
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testClientDurablyStagesExactReceiptBeforeRenewalExchange() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let invitation = try RemoteInvitationCode.generate().exportedCode
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let probe = ReceiptStageProbe(receiptURL: receiptURL)
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: request.expectedManagerGeneration + 1,
                renewalRequestNonce: request.requestNonce
            )
            try probe.observe(expected: receipt, outputURL: outputURL)
            return WorldwideSecondaryTestViewerControlResponse(
                status: .started,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: receipt.managerGeneration,
                requestNonce: request.requestNonce,
                invitationCode: invitation,
                generationReceipt: receipt
            )
        }

        try client.requestAndWriteInvitation(
            socketPath: "/unused/control.sock",
            hostLockURL: lockURL,
            outputURL: outputURL,
            receiptURL: receiptURL
        )

        XCTAssertTrue(probe.didObserve)
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            invitation + "\n"
        )
    }

    func testPostMintOutputFailureStopsExactGenerationAndRollsBackFiles()
        async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("control.sock").path
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: [service]).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: socketPath,
            handler: handler
        )
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=\(getpid())\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        try server.start()

        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlClient().requestAndWriteInvitation(
                socketPath: socketPath,
                hostLockURL: lockURL,
                outputURL: outputURL,
                receiptURL: receiptURL,
                afterReceiptCommitForTesting: {
                    throw ControlTestError.factoryFailure
                }
            )
        )
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .idle)
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testLostMintResponseUsesPreStagedReceiptForAuthenticatedCleanup()
        throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let exchange = LostRenewalResponseExchangeStub()
        let client = WorldwideSecondaryTestViewerControlClient(
            exchange: exchange.exchange
        )

        XCTAssertThrowsError(
            try client.requestAndWriteInvitation(
                socketPath: "/unused/control.sock",
                hostLockURL: lockURL,
                outputURL: outputURL,
                receiptURL: receiptURL
            )
        ) { error in
            XCTAssertTrue(error is ControlTestError)
        }
        XCTAssertEqual(exchange.requestTypes, [
            WorldwideSecondaryTestViewerControlRequest.renewalMessageType,
            WorldwideSecondaryTestViewerControlRequest.stopMessageType,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testUnconfirmedLostMintCleanupPreservesDurableReceiptForRetry()
        throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            if request.isRenewal {
                // Model a minted service whose response is lost.
                throw ControlTestError.factoryFailure
            }
            return WorldwideSecondaryTestViewerControlResponse(
                status: .quarantined,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: request.expectedManagerGeneration,
                requestNonce: request.requestNonce
            )
        }

        XCTAssertThrowsError(
            try client.requestAndWriteInvitation(
                socketPath: "/unused/control.sock",
                hostLockURL: lockURL,
                outputURL: outputURL,
                receiptURL: receiptURL
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .cleanupUnconfirmed
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let persisted = try WorldwideSecondaryTestViewerPersistedGenerationReceipt
            .decode(Data(contentsOf: receiptURL))
        XCTAssertEqual(persisted.invitationOutputPath, outputURL.path)
        XCTAssertEqual(persisted.receipt.managerGeneration, 1)
        XCTAssertEqual(persisted.receipt.hostProcessIdentifier, 123)
        XCTAssertEqual(persisted.receipt.hostGeneration, hostGeneration)
    }

    func testStartFailureWithUnconfirmedNativeTeardownPreservesReceiptUntilExactRetry()
        async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("control.sock").path
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=\(getpid())\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)

        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode,
            startError: ControlTestError.factoryFailure,
            nativeStopIsUnconfirmed: true
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: [service]).factory
        )
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
        defer { server.stop() }
        let client = WorldwideSecondaryTestViewerControlClient()

        XCTAssertThrowsError(
            try client.requestAndWriteInvitation(
                socketPath: socketPath,
                hostLockURL: lockURL,
                outputURL: outputURL,
                receiptURL: receiptURL
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .cleanupUnconfirmed
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        let quarantined = await coordinator.snapshot()
        XCTAssertEqual(quarantined.managerGeneration, 1)
        XCTAssertEqual(quarantined.phase, .quarantined)

        service.nativeStopIsUnconfirmed = false
        try client.stopGeneration(
            socketPath: socketPath,
            hostLockURL: lockURL,
            receiptURL: receiptURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertEqual(service.stopCallCount, 3)
        let stopped = await coordinator.snapshot()
        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(stopped.phase, .idle)
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testStopClientConsumesProvisionalReceiptWhenServerProvesItNeverMinted()
        throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: nonce
        )
        let reservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
            at: receiptURL
        )
        try reservation.commitReceipt(
            WorldwideSecondaryTestViewerPersistedGenerationReceipt(
                invitationOutputPath: outputURL.path,
                receipt: receipt
            )
        )
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            WorldwideSecondaryTestViewerControlResponse(
                status: .invalidReceipt,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: 0,
                requestNonce: request.requestNonce
            )
        }

        try client.stopGeneration(
            socketPath: "/unused/control.sock",
            hostLockURL: lockURL,
            receiptURL: receiptURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testStopClientPreservesReceiptWhenCurrentGenerationRejectsIt()
        throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("worldwide-host.lock")
        let outputURL = directory.appendingPathComponent("invitation.txt")
        let receiptURL = URL(fileURLWithPath: outputURL.path + ".receipt")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: nonce
        )
        let reservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
            at: receiptURL
        )
        try reservation.commitReceipt(
            WorldwideSecondaryTestViewerPersistedGenerationReceipt(
                invitationOutputPath: outputURL.path,
                receipt: receipt
            )
        )
        let lockRecord = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(lockRecord.utf8)
            )
        )
        XCTAssertEqual(chmod(lockURL.path, 0o600), 0)
        let client = WorldwideSecondaryTestViewerControlClient { _, request in
            WorldwideSecondaryTestViewerControlResponse(
                status: .invalidReceipt,
                hostProcessIdentifier: request.expectedHostProcessIdentifier,
                hostGeneration: request.expectedHostGeneration,
                managerGeneration: receipt.managerGeneration,
                requestNonce: request.requestNonce
            )
        }

        XCTAssertThrowsError(
            try client.stopGeneration(
                socketPath: "/unused/control.sock",
                hostLockURL: lockURL,
                receiptURL: receiptURL
            )
        ) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlClientError,
                .invalidResponse
            )
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testRequestCodecRejectsExtraKeysShortNonceAndWrongVersion() throws {
        let valid = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: 123,
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )
        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlRequest.decode(valid.encode()),
            valid
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid.encode()) as? [String: Any]
        )
        object["extra"] = true
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlRequest.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        object.removeValue(forKey: "extra")
        object["requestNonce"] = "abc"
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlRequest.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        object["requestNonce"] = nonce
        object["v"] = 2
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlRequest.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testProbeRequestAndResponseCodecsAreStrictAndContainNoInvitation() throws {
        let identity = WorldwideSecondaryTestViewerHostIdentity(
            processIdentifier: 123,
            generation: hostGeneration
        )
        let request = WorldwideSecondaryTestViewerControlRequest(
            probing: identity,
            requestNonce: nonce
        )
        let requestData = try request.encode()
        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlRequest.decode(requestData),
            request
        )
        XCTAssertTrue(request.isProbe)
        XCTAssertFalse(request.isRenewal)
        XCTAssertFalse(request.isStop)
        XCTAssertFalse(
            try XCTUnwrap(String(data: requestData, encoding: .utf8))
                .contains("invitation")
        )
        var requestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        requestObject["expectedManagerGeneration"] = 1
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlRequest.decode(
                JSONSerialization.data(withJSONObject: requestObject)
            )
        )

        let response = WorldwideSecondaryTestViewerControlResponse(
            status: .observed,
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 7,
            requestNonce: nonce,
            managerPhase: "idle",
            managerIsIdle: true
        )
        let responseData = try response.encode()
        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlResponse.decode(responseData),
            response
        )
        XCTAssertFalse(
            try XCTUnwrap(String(data: responseData, encoding: .utf8))
                .contains("invitation")
        )
        var responseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        responseObject["managerIsIdle"] = false
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlResponse.decode(
                JSONSerialization.data(withJSONObject: responseObject)
            )
        )
        responseObject["managerIsIdle"] = true
        responseObject["extra"] = true
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlResponse.decode(
                JSONSerialization.data(withJSONObject: responseObject)
            )
        )
    }

    func testStopRequestAndReceiptCodecsAreStrictAndContainNoInvitation()
        throws {
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 7,
            renewalRequestNonce: nonce
        )
        let request = WorldwideSecondaryTestViewerControlRequest(
            stopping: receipt,
            requestNonce: String(repeating: "c", count: 32)
        )
        let encoded = try request.encode()

        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlRequest.decode(encoded),
            request
        )
        XCTAssertFalse(
            try XCTUnwrap(String(data: encoded, encoding: .utf8))
                .contains("invitationCode")
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var receiptObject = try XCTUnwrap(
            object["generationReceipt"] as? [String: Any]
        )
        receiptObject["extra"] = true
        object["generationReceipt"] = receiptObject
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlRequest.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )

        let stopped = WorldwideSecondaryTestViewerControlResponse(
            status: .stopped,
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 7,
            requestNonce: String(repeating: "c", count: 32)
        )
        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlResponse.decode(stopped.encode()),
            stopped
        )
    }

    func testResponseCodecIsStrictAndValidatesInvitationShape() throws {
        let invitation = try RemoteInvitationCode.generate().exportedCode
        let valid = WorldwideSecondaryTestViewerControlResponse(
            status: .started,
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            requestNonce: nonce,
            invitationCode: invitation,
            generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt(
                hostProcessIdentifier: 123,
                hostGeneration: hostGeneration,
                managerGeneration: 1,
                renewalRequestNonce: nonce
            )
        )
        XCTAssertEqual(
            try WorldwideSecondaryTestViewerControlResponse.decode(valid.encode()),
            valid
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid.encode()) as? [String: Any]
        )
        object["extra"] = "not permitted"
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlResponse.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        object.removeValue(forKey: "extra")
        object["invitationCode"] = "NOT-AN-INVITATION"
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlResponse.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
        object["invitationCode"] = invitation
        object["status"] = WorldwideSecondaryTestViewerControlStatus.busy.rawValue
        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerControlResponse.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testWrongHostDoesNotConsumeNonceAndReplayCannotMintAgain() async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let wrongHost = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: 456,
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )
        let admitted = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: 123,
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )

        let wrongResponse = await handler.handle(wrongHost)
        let startedResponse = await handler.handle(admitted)
        let replayResponse = await handler.handle(admitted)

        XCTAssertEqual(wrongResponse.status, .wrongHost)
        XCTAssertNil(wrongResponse.invitationCode)
        XCTAssertEqual(startedResponse.status, .started)
        XCTAssertEqual(startedResponse.managerGeneration, 1)
        XCTAssertEqual(startedResponse.invitationCode, service.invitationCode)
        XCTAssertEqual(replayResponse.status, .replayed)
        XCTAssertNil(replayResponse.invitationCode)
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testReceiptAuthenticatedStopIsExactIdempotentAndFencesNewGeneration()
        async throws {
        let first = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let second = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: [first, second]).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let started = await handler.handle(request(generation: 0, nonceByte: "1"))
        let receipt = try XCTUnwrap(started.generationReceipt)
        let forged = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: receipt.hostProcessIdentifier,
            hostGeneration: receipt.hostGeneration,
            managerGeneration: receipt.managerGeneration,
            renewalRequestNonce: String(repeating: "f", count: 32)
        )

        let rejected = await handler.handle(
            stopRequest(receipt: forged, nonceByte: "2")
        )
        XCTAssertEqual(rejected.status, .invalidReceipt)
        XCTAssertEqual(first.stopCallCount, 0)

        let stopped = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "3")
        )
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(first.stopCallCount, 1)
        let firstStoppedSnapshot = await coordinator.snapshot()
        XCTAssertEqual(firstStoppedSnapshot.phase, .idle)

        let retryAfterLostResponse = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "4")
        )
        XCTAssertEqual(retryAfterLostResponse.status, .stopped)
        XCTAssertEqual(first.stopCallCount, 1)

        let secondStarted = await handler.handle(
            request(generation: 1, nonceByte: "5")
        )
        XCTAssertEqual(secondStarted.status, .started)
        XCTAssertEqual(secondStarted.managerGeneration, 2)

        let staleStop = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "6")
        )
        XCTAssertEqual(staleStop.status, .invalidReceipt)
        XCTAssertEqual(second.stopCallCount, 0)
        let secondRunningSnapshot = await coordinator.snapshot()
        XCTAssertEqual(secondRunningSnapshot.phase, .running)
        _ = await coordinator.stop()
    }

    func testStopOverlappingDelayedRenewalWaitsForExactNativeTeardown()
        async throws {
        let service = BlockingControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: BlockingControlFactoryStub(service: service).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let renewal = request(generation: 0, nonceByte: "1")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: renewal.requestNonce
        )
        let renewalTask = Task { await handler.handle(renewal) }
        await service.waitUntilStartEntered()

        let stopped = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "2")
        )
        let renewalResponse = await renewalTask.value
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(renewalResponse.status, .unavailable)
        XCTAssertNil(renewalResponse.invitationCode)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(snapshot.managerGeneration, 1)
        XCTAssertEqual(snapshot.phase, .idle)
        _ = await coordinator.stop()
    }

    func testStopInCoordinatorEnqueueGapWaitsForGenerationAdvance()
        async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let advanceGate = RenewalGenerationAdvanceGate()
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory,
            beforeGenerationAdvanceForTesting: advanceGate.wait
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let renewal = request(generation: 0, nonceByte: "1")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: renewal.requestNonce
        )
        let renewalTask = Task { await handler.handle(renewal) }
        await advanceGate.waitUntilEntered()

        let exactStop = stopRequest(receipt: receipt, nonceByte: "2")
        let stopTask = Task { await handler.handle(exactStop) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while await handler.pendingGenerationStopWaiterCountForTesting() == 0,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let waiterCount = await handler
            .pendingGenerationStopWaiterCountForTesting()
        XCTAssertEqual(waiterCount, 1)
        let beforeAdvance = await coordinator.snapshot()
        XCTAssertEqual(beforeAdvance.managerGeneration, 0)
        XCTAssertEqual(beforeAdvance.phase, .idle)

        advanceGate.release()
        let stopped = await stopTask.value
        let renewalResponse = await renewalTask.value
        let final = await coordinator.snapshot()

        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertNotEqual(renewalResponse.status, .started)
        XCTAssertNil(renewalResponse.invitationCode)
        XCTAssertEqual(factory.requestedGenerations, [1])
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(final.managerGeneration, 1)
        XCTAssertEqual(final.phase, .idle)
        _ = await coordinator.stop()
    }

    func testStopOvertakingRenewalTombstonesCandidateBeforeFactoryCall()
        async throws {
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let renewal = request(generation: 0, nonceByte: "1")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: renewal.requestNonce
        )

        let stoppedBeforeDelivery = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "2")
        )
        let delayedRenewal = await handler.handle(renewal)

        XCTAssertEqual(stoppedBeforeDelivery.status, .invalidReceipt)
        XCTAssertEqual(delayedRenewal.status, .invalidReceipt)
        XCTAssertNil(delayedRenewal.invitationCode)
        XCTAssertTrue(factory.requestedGenerations.isEmpty)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.managerGeneration, 0)
        XCTAssertEqual(snapshot.phase, .idle)
        _ = await coordinator.stop()
    }

    func testStaleResponseSupportsGenerationRecoveryWithFreshNonce() async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(
            services: [service],
            failuresBeforeServices: 1
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )

        let failed = await handler.handle(request(generation: 0, nonceByte: "1"))
        let stale = await handler.handle(request(generation: 0, nonceByte: "2"))
        let recovered = await handler.handle(request(generation: 1, nonceByte: "3"))

        XCTAssertEqual(failed.status, .unavailable)
        XCTAssertEqual(failed.managerGeneration, 1)
        XCTAssertEqual(stale.status, .staleGeneration)
        XCTAssertEqual(stale.managerGeneration, 1)
        XCTAssertNil(stale.invitationCode)
        XCTAssertEqual(recovered.status, .started)
        XCTAssertEqual(recovered.managerGeneration, 2)
        XCTAssertNotNil(recovered.invitationCode)
        _ = await coordinator.stop()
    }

    func testConstructionFailureRetainsAdvancedCandidateForExactIdleStop()
        async throws {
        let factory = ControlFactoryStub(
            services: [],
            failuresBeforeServices: 1
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let renewal = request(generation: 0, nonceByte: "1")
        let receipt = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            managerGeneration: 1,
            renewalRequestNonce: renewal.requestNonce
        )

        let failed = await handler.handle(renewal)
        let stopped = await handler.handle(
            stopRequest(receipt: receipt, nonceByte: "2")
        )
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(failed.status, .unavailable)
        XCTAssertEqual(failed.managerGeneration, 1)
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(snapshot.managerGeneration, 1)
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testReplayTableIsBoundedAndFailsClosedWhenFull() async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )

        for value in 0..<WorldwideSecondaryTestViewerControlHandler
            .maximumConsumedNonces {
            let nonce = String(format: "%032x", value)
            let response = await handler.handle(
                WorldwideSecondaryTestViewerControlRequest(
                    expectedHostProcessIdentifier: 123,
                    expectedHostGeneration: hostGeneration,
                    expectedManagerGeneration: value == 0 ? 0 : 1,
                    requestNonce: nonce
                )
            )
            XCTAssertNotEqual(response.status, .unavailable)
        }

        let overflow = await handler.handle(
            WorldwideSecondaryTestViewerControlRequest(
                expectedHostProcessIdentifier: 123,
                expectedHostGeneration: hostGeneration,
                expectedManagerGeneration: 1,
                requestNonce: String(repeating: "f", count: 32)
            )
        )
        XCTAssertEqual(overflow.status, .unavailable)
        XCTAssertNil(overflow.invitationCode)
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testProbeReplayTableIsBoundedWithoutConsumingMutationNonceBudget()
        async throws {
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let identity = WorldwideSecondaryTestViewerHostIdentity(
            processIdentifier: 123,
            generation: hostGeneration
        )

        for value in 0..<WorldwideSecondaryTestViewerControlHandler
            .maximumConsumedProbeNonces {
            let response = await handler.handle(
                WorldwideSecondaryTestViewerControlRequest(
                    probing: identity,
                    requestNonce: String(format: "%032x", value)
                )
            )
            XCTAssertEqual(response.status, .observed)
        }
        let overflow = await handler.handle(
            WorldwideSecondaryTestViewerControlRequest(
                probing: identity,
                requestNonce: String(repeating: "f", count: 32)
            )
        )
        XCTAssertEqual(overflow.status, .unavailable)
        XCTAssertNil(overflow.invitationCode)

        let renewal = await handler.handle(
            WorldwideSecondaryTestViewerControlRequest(
                expectedHostProcessIdentifier: 123,
                expectedHostGeneration: hostGeneration,
                expectedManagerGeneration: 0,
                requestNonce: String(repeating: "e", count: 32)
            )
        )
        XCTAssertEqual(renewal.status, .started)
        XCTAssertEqual(renewal.managerGeneration, 1)
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testSocketIsOwnerOnlyAndDeliversExactlyOneResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let service = ControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = ControlFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )
        try server.start()
        defer { server.stop() }

        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_uid, geteuid())
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)

        let client = try MediaBridgeSocket.connect(path: path)
        defer { Darwin.close(client) }
        let request = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: getpid(),
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )
        try MediaBridgeFraming.writeFrame(client, data: request.encode())
        let responseData = try XCTUnwrap(
            MediaBridgeFraming.readFrame(client, idleTimeout: 1)
        )
        let response = try WorldwideSecondaryTestViewerControlResponse.decode(
            responseData
        )
        let secondFrame = try MediaBridgeFraming.readFrame(
            client,
            idleTimeout: 1
        )

        XCTAssertEqual(response.status, .started)
        XCTAssertEqual(response.requestNonce, nonce)
        XCTAssertEqual(response.invitationCode, service.invitationCode)
        XCTAssertNil(secondFrame)
        _ = await coordinator.stop()
    }

    func testConcurrentStartsPublishOnlyOneListener() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: []).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )

        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        try server.start()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
        XCTAssertEqual(outcomes.filter { !$0 }.count, 1)
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFSOCK)
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testActiveClientCountIsBounded() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: ControlFactoryStub(services: []).factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )
        try server.start()

        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        for _ in 0..<WorldwideSecondaryTestViewerControlServer.maximumActiveClients {
            clients.append(try MediaBridgeSocket.connect(path: path))
        }
        try await waitUntil {
            server.activeClientCountForTesting ==
                WorldwideSecondaryTestViewerControlServer.maximumActiveClients
        }

        let overflow = try MediaBridgeSocket.connect(path: path)
        clients.append(overflow)
        let overflowResponse = try MediaBridgeFraming.readFrame(
            overflow,
            idleTimeout: 1
        )

        XCTAssertNil(overflowResponse)
        XCTAssertLessThanOrEqual(
            server.activeClientCountForTesting,
            WorldwideSecondaryTestViewerControlServer.maximumActiveClients
        )
        server.stop()
        await server.waitUntilRequestsDrain()
        _ = await coordinator.stop()
    }

    func testLifetimeStopsManagerToUnblockThenDrainsAdmittedRenewalBeforeConfirmation()
        async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let service = BlockingControlServiceStub(
            invitationCode: try RemoteInvitationCode.generate().exportedCode
        )
        let factory = BlockingControlFactoryStub(service: service)
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler
        )
        let lifetime = CaptureServiceLifetime()
        try lifetime.installAndStart(
            secondaryTestViewerCoordinator: coordinator,
            controlServer: server
        )
        let client = try MediaBridgeSocket.connect(path: path)
        defer { Darwin.close(client) }
        let renewal = WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: getpid(),
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: 0,
            requestNonce: nonce
        )
        try MediaBridgeFraming.writeFrame(client, data: renewal.encode())
        await service.waitUntilStartEntered()

        let completion = CompletionFlag()
        let shutdown = Task {
            let result = await lifetime.shutdown()
            completion.markCompleted()
            return result
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !completion.isCompleted,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if !completion.isCompleted {
            service.releaseStart()
            XCTFail("Coordinator stop did not unblock the admitted start request")
        }

        let confirmation = await shutdown.value
        let snapshot = await coordinator.snapshot()

        XCTAssertTrue(confirmation.worldwideNativeCaptureIsConfirmed)
        XCTAssertTrue(completion.isCompleted)
        XCTAssertEqual(snapshot.phase, .shutdown)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testClosedAdmissionRejectsBeforeConstructingService() async {
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: 123,
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        handler.closeAdmission()

        let response = await handler.handle(request(generation: 0, nonceByte: "9"))

        XCTAssertEqual(response.status, .shutdown)
        XCTAssertTrue(factory.requestedGenerations.isEmpty)
        _ = await coordinator.stop()
    }

    func testRejectedPeerGetsNoResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: path,
            handler: handler,
            peerIsAdmitted: { _ in false }
        )
        try server.start()
        defer { server.stop() }

        let client = try MediaBridgeSocket.connect(path: path)
        defer { Darwin.close(client) }
        try? MediaBridgeFraming.writeFrame(
            client,
            data: request(generation: 0, nonceByte: "4").encode()
        )
        let response = try MediaBridgeFraming.readFrame(client, idleTimeout: 1)

        XCTAssertNil(response)
        XCTAssertTrue(factory.requestedGenerations.isEmpty)
        _ = await coordinator.stop()
    }

    func testSocketDirectorySymlinkIsRejectedWithoutReplacingTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = ControlFactoryStub(services: [])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        let server = WorldwideSecondaryTestViewerControlServer(
            socketPath: alias.appendingPathComponent("control.sock").path,
            handler: handler
        )

        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlProtocolError,
                .unsafeSocketPath
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("control.sock").path
            )
        )
        _ = await coordinator.stop()
    }

    func testHostIdentityParserAndSecureLoaderMatchPublishedRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("worldwide-host.lock")
        let record = "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\n" +
            "pid=123\nnonce=\(hostGeneration)\n"
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data(record.utf8)
            )
        )
        XCTAssertEqual(chmod(url.path, 0o600), 0)

        let parsed = try WorldwideSecondaryTestViewerHostIdentity.parse(record)
        let loaded = try WorldwideSecondaryTestViewerHostIdentity.load(from: url)

        XCTAssertEqual(parsed.processIdentifier, 123)
        XCTAssertEqual(parsed.generation, hostGeneration)
        XCTAssertEqual(loaded, parsed)

        XCTAssertThrowsError(
            try WorldwideSecondaryTestViewerHostIdentity.parse(
                record + "extra=true\n"
            )
        )
    }

    private func request(
        generation: UInt64,
        nonceByte: Character
    ) -> WorldwideSecondaryTestViewerControlRequest {
        WorldwideSecondaryTestViewerControlRequest(
            expectedHostProcessIdentifier: 123,
            expectedHostGeneration: hostGeneration,
            expectedManagerGeneration: generation,
            requestNonce: String(repeating: nonceByte, count: 32)
        )
    }

    private func stopRequest(
        receipt: WorldwideSecondaryTestViewerGenerationReceipt,
        nonceByte: Character
    ) -> WorldwideSecondaryTestViewerControlRequest {
        WorldwideSecondaryTestViewerControlRequest(
            stopping: receipt,
            requestNonce: String(repeating: nonceByte, count: 32)
        )
    }

    private func makePrivateDirectory(usePrivateTemporaryRoot: Bool = false) throws -> URL {
        if usePrivateTemporaryRoot {
            var template = Array("/private/tmp/v90-control-fixture.XXXXXX".utf8CString)
            let created = try XCTUnwrap(mkdtemp(&template))
            return URL(fileURLWithPath: String(cString: created), isDirectory: true)
        }
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for control-server state")
    }
}

private enum ControlTestError: Error {
    case factoryFailure
}

private final class ControlFactoryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [ControlServiceStub]
    private var remainingFailures: Int
    private var generations: [UInt64] = []

    init(services: [ControlServiceStub], failuresBeforeServices: Int = 0) {
        self.services = services
        remainingFailures = failuresBeforeServices
    }

    var factory: WorldwideSecondaryTestViewerServiceFactory {
        WorldwideSecondaryTestViewerServiceFactory { [self] generation in
            try lock.withLock {
                generations.append(generation)
                if remainingFailures > 0 {
                    remainingFailures -= 1
                    throw ControlTestError.factoryFailure
                }
                guard !services.isEmpty else { throw ControlTestError.factoryFailure }
                return services.removeFirst()
            }
        }
    }

    var requestedGenerations: [UInt64] {
        lock.withLock { generations }
    }
}

private final class ControlServiceStub:
    WorldwideSecondaryTestViewerServing,
    @unchecked Sendable
{
    let completion: AsyncStream<Void>
    let invitationCode: String
    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation
    private let startError: (any Error)?
    private var storedStopCallCount = 0
    private var storedNativeStopIsUnconfirmed: Bool

    init(
        invitationCode: String,
        startError: (any Error)? = nil,
        nativeStopIsUnconfirmed: Bool = false
    ) {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        continuation = pair.continuation
        self.invitationCode = invitationCode
        self.startError = startError
        storedNativeStopIsUnconfirmed = nativeStopIsUnconfirmed
    }

    func startSecondaryTestViewer() async throws -> String {
        if let startError { throw startError }
        return invitationCode
    }

    func stopSecondaryTestViewer() async {
        lock.withLock { storedStopCallCount += 1 }
    }

    var stopCallCount: Int {
        lock.withLock { storedStopCallCount }
    }

    var nativeStopIsUnconfirmed: Bool {
        get { lock.withLock { storedNativeStopIsUnconfirmed } }
        set { lock.withLock { storedNativeStopIsUnconfirmed = newValue } }
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        nativeStopIsUnconfirmed
    }
}

private final class BlockingControlFactoryStub: @unchecked Sendable {
    private let service: BlockingControlServiceStub

    init(service: BlockingControlServiceStub) {
        self.service = service
    }

    var factory: WorldwideSecondaryTestViewerServiceFactory {
        WorldwideSecondaryTestViewerServiceFactory { [service] _ in service }
    }
}

private final class BlockingControlServiceStub:
    WorldwideSecondaryTestViewerServing,
    @unchecked Sendable
{
    let completion: AsyncStream<Void>
    private let lock = NSLock()
    private let invitationCode: String
    private let startEnteredStream: AsyncStream<Void>
    private let startEnteredContinuation: AsyncStream<Void>.Continuation
    private var startContinuation: CheckedContinuation<String, Error>?
    private var storedStopCallCount = 0

    init(invitationCode: String) {
        completion = AsyncStream { _ in }
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        startEnteredStream = pair.stream
        startEnteredContinuation = pair.continuation
        self.invitationCode = invitationCode
    }

    var stopCallCount: Int {
        lock.withLock { storedStopCallCount }
    }

    func startSecondaryTestViewer() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            startEnteredContinuation.yield(())
        }
    }

    func stopSecondaryTestViewer() async {
        lock.withLock { storedStopCallCount += 1 }
        releaseStart()
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        false
    }

    func waitUntilStartEntered() async {
        for await _ in startEnteredStream { return }
    }

    func releaseStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(returning: invitationCode)
    }
}

private final class RenewalGenerationAdvanceGate: @unchecked Sendable {
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let entered = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        enteredStream = entered.stream
        enteredContinuation = entered.continuation
        let release = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        releaseStream = release.stream
        releaseContinuation = release.continuation
    }

    func wait(_ generation: UInt64) async {
        _ = generation
        enteredContinuation.yield(())
        for await _ in releaseStream { return }
    }

    func waitUntilEntered() async {
        for await _ in enteredStream { return }
    }

    func release() {
        releaseContinuation.yield(())
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.withLock { completed }
    }

    func markCompleted() {
        lock.withLock { completed = true }
    }
}

private final class ReceiptStageProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let receiptURL: URL
    private var observed = false

    init(receiptURL: URL) {
        self.receiptURL = receiptURL
    }

    var didObserve: Bool {
        lock.withLock { observed }
    }

    func observe(
        expected: WorldwideSecondaryTestViewerGenerationReceipt,
        outputURL: URL
    ) throws {
        let data = try Data(contentsOf: receiptURL)
        let record = try WorldwideSecondaryTestViewerPersistedGenerationReceipt
            .decode(data)
        guard record.receipt == expected,
              record.invitationOutputPath == outputURL.path else {
            throw ControlTestError.factoryFailure
        }
        var metadata = stat()
        guard lstat(receiptURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o777 == 0o600 else {
            throw ControlTestError.factoryFailure
        }
        lock.withLock { observed = true }
    }
}

private final class LostRenewalResponseExchangeStub: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [WorldwideSecondaryTestViewerControlRequest] = []
    private var candidate: WorldwideSecondaryTestViewerGenerationReceipt?

    var exchange: WorldwideSecondaryTestViewerControlClient.Exchange {
        { [self] _, request in
            try lock.withLock {
                requests.append(request)
                if request.isRenewal {
                    candidate = WorldwideSecondaryTestViewerGenerationReceipt(
                        hostProcessIdentifier: request.expectedHostProcessIdentifier,
                        hostGeneration: request.expectedHostGeneration,
                        managerGeneration: request.expectedManagerGeneration + 1,
                        renewalRequestNonce: request.requestNonce
                    )
                    // Model a service minted by the server whose response is lost in transport.
                    throw ControlTestError.factoryFailure
                }
                guard request.isStop,
                      request.generationReceipt == candidate,
                      let candidate else {
                    throw ControlTestError.factoryFailure
                }
                return WorldwideSecondaryTestViewerControlResponse(
                    status: .stopped,
                    hostProcessIdentifier: candidate.hostProcessIdentifier,
                    hostGeneration: candidate.hostGeneration,
                    managerGeneration: candidate.managerGeneration,
                    requestNonce: request.requestNonce
                )
            }
        }
    }

    var requestTypes: [String] {
        lock.withLock { requests.map(\.type) }
    }
}

private final class ControlClientExchangeStub: @unchecked Sendable {
    private let lock = NSLock()
    private let hostProcessIdentifier: Int32
    private let hostGeneration: String
    private let invitation: String
    private var requests: [WorldwideSecondaryTestViewerControlRequest] = []

    init(
        hostProcessIdentifier: Int32,
        hostGeneration: String,
        invitation: String
    ) {
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostGeneration = hostGeneration
        self.invitation = invitation
    }

    var exchange: WorldwideSecondaryTestViewerControlClient.Exchange {
        { [self] _, request in
            lock.withLock {
                requests.append(request)
                if requests.count == 1 {
                    return WorldwideSecondaryTestViewerControlResponse(
                        status: .staleGeneration,
                        hostProcessIdentifier: hostProcessIdentifier,
                        hostGeneration: hostGeneration,
                        managerGeneration: 7,
                        requestNonce: request.requestNonce
                    )
                }
                return WorldwideSecondaryTestViewerControlResponse(
                    status: .started,
                    hostProcessIdentifier: hostProcessIdentifier,
                    hostGeneration: hostGeneration,
                    managerGeneration: 8,
                    requestNonce: request.requestNonce,
                    invitationCode: invitation,
                    generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt(
                        hostProcessIdentifier: hostProcessIdentifier,
                        hostGeneration: hostGeneration,
                        managerGeneration: 8,
                        renewalRequestNonce: request.requestNonce
                    )
                )
            }
        }
    }

    var managerGenerations: [UInt64] {
        lock.withLock { requests.map(\.expectedManagerGeneration) }
    }

    var nonces: [String] {
        lock.withLock { requests.map(\.requestNonce) }
    }
}
