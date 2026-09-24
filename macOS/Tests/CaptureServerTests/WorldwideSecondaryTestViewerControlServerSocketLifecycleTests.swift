import Darwin
import Foundation
import MediaBridgeCore
import XCTest
@testable import CaptureServer

final class WorldwideSecondaryTestViewerControlServerSocketLifecycleTests:
    XCTestCase
{
    private let hostGeneration = String(repeating: "a", count: 64)

    func testStartReclaimsDeadOwnerOnlySocket() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let stale = try bindSocket(at: path, shouldListen: false, mode: 0o600)
        Darwin.close(stale)
        XCTAssertThrowsError(try MediaBridgeSocket.connect(path: path))
        let subject = makeSubject(path: path)

        try subject.server.start()
        let connected = try MediaBridgeSocket.connect(path: path)
        Darwin.close(connected)
        let replacementIdentity = try socketIdentity(at: path)

        XCTAssertEqual(replacementIdentity.mode, 0o600)
        subject.server.stop()
        await subject.server.waitUntilRequestsDrain()
        XCTAssertEqual(lstatExists(path), false)
        _ = await subject.coordinator.stop()
    }

    func testStartRejectsLiveSocketWithoutReplacingIt() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let live = try bindSocket(at: path, shouldListen: true, mode: 0o600)
        defer { Darwin.close(live) }
        let original = try socketIdentity(at: path)
        let subject = makeSubject(path: path)

        XCTAssertThrowsError(try subject.server.start()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlProtocolError,
                .endpointUnavailable
            )
        }

        XCTAssertEqual(try socketIdentity(at: path), original)
        _ = await subject.coordinator.stop()
    }

    func testStartRejectsRegularFileWithoutReplacingIt() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let contents = Data("keep me".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: path,
                contents: contents,
                attributes: [.posixPermissions: 0o600]
            )
        )
        let subject = makeSubject(path: path)

        XCTAssertThrowsError(try subject.server.start()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlProtocolError,
                .unsafeSocketPath
            )
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), contents)
        _ = await subject.coordinator.stop()
    }

    func testStartRejectsSocketWithWrongModeWithoutReplacingIt() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let socket = try bindSocket(at: path, shouldListen: false, mode: 0o640)
        defer { Darwin.close(socket) }
        let original = try socketIdentity(at: path)
        let subject = makeSubject(path: path)

        XCTAssertThrowsError(try subject.server.start()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlProtocolError,
                .unsafeSocketPath
            )
        }

        XCTAssertEqual(try socketIdentity(at: path), original)
        _ = await subject.coordinator.stop()
    }

    func testStartRejectsSocketLeafSymlinkWithoutReplacingIt() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let path = directory.appendingPathComponent("control.sock")
        let contents = Data("keep target".utf8)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: target.path,
                contents: contents,
                attributes: [.posixPermissions: 0o600]
            )
        )
        try FileManager.default.createSymbolicLink(
            at: path,
            withDestinationURL: target
        )
        let subject = makeSubject(path: path.path)

        XCTAssertThrowsError(try subject.server.start()) { error in
            XCTAssertEqual(
                error as? WorldwideSecondaryTestViewerControlProtocolError,
                .unsafeSocketPath
            )
        }

        var metadata = stat()
        XCTAssertEqual(lstat(path.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(try Data(contentsOf: target), contents)
        _ = await subject.coordinator.stop()
    }

    func testFailureAfterBindRemovesOnlyOwnedSocket() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let subject = makeSubject(
            path: path,
            afterBindForTesting: { throw SocketLifecycleTestError.forcedFailure }
        )

        XCTAssertThrowsError(try subject.server.start()) { error in
            XCTAssertEqual(error as? SocketLifecycleTestError, .forcedFailure)
        }

        XCTAssertEqual(lstatExists(path), false)
        _ = await subject.coordinator.stop()
    }

    func testStopDoesNotUnlinkReplacementSocketInode() async throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let subject = makeSubject(path: path)
        try subject.server.start()

        XCTAssertEqual(unlink(path), 0)
        let replacement = try bindSocket(
            at: path,
            shouldListen: true,
            mode: 0o600
        )
        defer { Darwin.close(replacement) }
        let replacementIdentity = try socketIdentity(at: path)

        subject.server.stop()
        await subject.server.waitUntilRequestsDrain()

        XCTAssertEqual(try socketIdentity(at: path), replacementIdentity)
        _ = await subject.coordinator.stop()
    }

    private func makeSubject(
        path: String,
        afterBindForTesting: (@Sendable () throws -> Void)? = nil
    ) -> (
        server: WorldwideSecondaryTestViewerControlServer,
        coordinator: WorldwideSecondaryTestViewerCoordinator
    ) {
        let factory = WorldwideSecondaryTestViewerServiceFactory {
            _ -> any WorldwideSecondaryTestViewerServing in
            throw SocketLifecycleTestError.unexpectedFactoryUse
        }
        let coordinator = WorldwideSecondaryTestViewerCoordinator(factory: factory)
        let handler = WorldwideSecondaryTestViewerControlHandler(
            hostProcessIdentifier: getpid(),
            hostGeneration: hostGeneration,
            coordinator: coordinator
        )
        return (
            WorldwideSecondaryTestViewerControlServer(
                socketPath: path,
                handler: handler,
                afterBindForTesting: afterBindForTesting
            ),
            coordinator
        )
    }

    private func makePrivateDirectory() throws -> URL {
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

    private func bindSocket(
        at path: String,
        shouldListen: Bool,
        mode: mode_t
    ) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketLifecycleTestError.systemFailure }
        do {
            var address = try MediaBridgeSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0,
                  chmod(path, mode) == 0,
                  !shouldListen || Darwin.listen(descriptor, 4) == 0 else {
                throw SocketLifecycleTestError.systemFailure
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func socketIdentity(at path: String) throws -> SocketIdentity {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK else {
            throw SocketLifecycleTestError.systemFailure
        }
        return SocketIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            mode: metadata.st_mode & 0o777
        )
    }

    private func lstatExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}

private struct SocketIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
}

private enum SocketLifecycleTestError: Error, Equatable {
    case forcedFailure
    case systemFailure
    case unexpectedFactoryUse
}
