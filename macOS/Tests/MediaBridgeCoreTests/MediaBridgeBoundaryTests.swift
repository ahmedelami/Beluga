import Darwin
import Foundation
import XCTest
@testable import MediaBridgeCore

private final class BridgeBoundaryDescriptors: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]
    init(_ descriptors: [Int32]) { self.descriptors = descriptors }
    func closeAll() {
        let owned = lock.withLock { let owned = descriptors; descriptors.removeAll(); return owned }
        for fd in owned { _ = shutdown(fd, SHUT_RDWR); _ = close(fd) }
    }
    deinit { closeAll() }
}

final class MediaBridgeBoundaryTests: XCTestCase {
    func testPartialHeaderHasDeadlineEvenWhenConnectionMayRemainIdle() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let owned = BridgeBoundaryDescriptors(fds)
        defer { owned.closeAll() }
        XCTAssertTrue(MediaBridgeSocket.configure(fds[0]))
        XCTAssertTrue(MediaBridgeSocket.configure(fds[1]))
        let partial: [UInt8] = [10]
        XCTAssertEqual(partial.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }, 1)
        // Retire a broken reader independently, so removing its deadline cannot hang this suite.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { owned.closeAll() }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fds[1])) { error in
            guard case MediaBridgeError.timedOut = error else { return XCTFail("Partial header did not time out: \(error)") }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testSocketConfigurationProvesNonblockingCloseOnExecAndNoSigpipe() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let owned = BridgeBoundaryDescriptors(fds)
        defer { owned.closeAll() }
        XCTAssertTrue(MediaBridgeSocket.configure(fds[0]))
        XCTAssertNotEqual(fcntl(fds[0], F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(fds[0], F_GETFD) & FD_CLOEXEC, 0)
        var enabled: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fds[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size), 0)
        XCTAssertEqual(enabled, 1)
        XCTAssertFalse(MediaBridgeSocket.configure(-1))
    }

    func testSuccessfulConnectReturnsConfiguredSameUserSocket() throws {
        let fixture = try listener()
        defer { close(fixture.fd); try? FileManager.default.removeItem(at: fixture.directory) }
        let fd = try MediaBridgeSocket.connect(path: fixture.path)
        defer { close(fd) }
        XCTAssertTrue(MediaBridgeSocket.sameUser(fd))
        XCTAssertNotEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, 0)
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testSaturatedListenerCannotBlockConnectBeyondDeadline() throws {
        let fixture = try listener()
        var descriptors = [fixture.fd]
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var saturated = false
        var connectedCount = 0
        var refusal: Int32?
        for _ in 0..<64 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            descriptors.append(fd)
            guard MediaBridgeSocket.configure(fd) else { break }
            var address = try MediaBridgeSocket.address(fixture.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == -1 {
                let error = errno
                refusal = error
                // XNU refuses a full Unix-domain accept queue instead of leaving connect pending.
                saturated = connectedCount > 0
                    && (error == EINPROGRESS || error == EAGAIN || error == ECONNREFUSED)
                close(fd)
                descriptors.removeLast()
                break
            }
            connectedCount += 1
        }
        let owned = BridgeBoundaryDescriptors(descriptors)
        defer { owned.closeAll() }
        guard saturated else {
            return XCTFail("Failed to saturate the private fixture listener; connected=\(connectedCount), errno=\(refusal ?? 0)")
        }
        // Closing the listener also releases an accidentally blocking connect after mutation.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { owned.closeAll() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let unexpected = try MediaBridgeSocket.connect(path: fixture.path)
            close(unexpected)
            XCTFail("Connect claimed success against a saturated listener")
        } catch { }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        let accepted = accept(fixture.fd, nil, nil)
        guard accepted >= 0 else { return XCTFail("The saturated listener lost its queued connection") }
        close(accepted)
        // Recovery after draining proves that refusal came from saturation, not a dead listener.
        let recovered = try MediaBridgeSocket.connect(path: fixture.path)
        defer { close(recovered) }
        XCTAssertTrue(MediaBridgeSocket.sameUser(recovered))
    }

    func testHelperInboundProtocolAdmitsOnlyBoundedTypedResultsAndPermissionRequests() throws {
        let identifier = "163D5BA8-9141-4986-BD6F-94AD9F52699D"
        let result: [String: Any] = ["v": 1, "type": "result", "id": identifier,
                                     "contextID": identifier, "result": "applied"]
        guard case .result(let decoded) = try MediaBridgeProtocol.decode(JSONSerialization.data(withJSONObject: result)) else {
            return XCTFail("Valid result rejected")
        }
        XCTAssertEqual(decoded.id, identifier)
        XCTAssertEqual(decoded.contextID, identifier)
        XCTAssertEqual(decoded.result, .applied)
        for changes: [String: Any] in [["id": "bad"], ["contextID": "bad"], ["result": "success"],
                                      ["command": "next"], ["v": true], ["result": 1]] {
            var malformed = result
            malformed.merge(changes) { _, new in new }
            XCTAssertThrowsError(try MediaBridgeProtocol.decode(JSONSerialization.data(withJSONObject: malformed)))
        }
        let permission: [String: Any] = ["v": 1, "type": "authorizeMusic", "id": identifier]
        guard case .authorizeMusic = try MediaBridgeProtocol.decode(JSONSerialization.data(withJSONObject: permission)) else {
            return XCTFail("Valid permission request rejected")
        }
        var extraPermissionField = permission
        extraPermissionField["item"] = NSNull()
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(JSONSerialization.data(withJSONObject: extraPermissionField)))
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data(repeating: 0x20, count: 4097)))
    }

    private func listener() throws -> (fd: Int32, path: String, directory: URL) {
        let directory = URL(fileURLWithPath: "/tmp/opensteamer-bridge-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("socket").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw MediaBridgeError.unavailable
        }
        do {
            var address = try MediaBridgeSocket.address(path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 1) == 0,
                  MediaBridgeSocket.configure(fd) else { throw MediaBridgeError.unavailable }
            return (fd, path, directory)
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
