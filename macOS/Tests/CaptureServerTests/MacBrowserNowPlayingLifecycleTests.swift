import Darwin
import Foundation
import MediaBridgeCore
import WebRTCTransport
import XCTest
@testable import CaptureServer

private final class BrowserPermissionCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable (Bool) -> Void] = []
    var count: Int { lock.withLock { callbacks.count } }
    func append(_ callback: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { callbacks.append(callback) }
    }
    func resolve(_ index: Int, allowed: Bool) {
        let callback = lock.withLock { callbacks[index] }
        callback(allowed)
    }
}

final class MacBrowserNowPlayingLifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbl-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func state(context: String, revision: Int, playing: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "type": "state", "revision": revision,
            "item": ["contextID": context, "sourceName": "YouTube", "title": "Lifecycle fixture",
                "playbackRate": playing ? 1 : 0, "playbackState": playing ? "playing" : "paused",
                "canPlay": !playing, "canPause": playing, "canSkipForward": true,
                "canSkipBackward": false]])
    }

    @discardableResult
    private func authorize(_ fd: Int32) throws -> String {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "authorizeMusic", "id": id])
        try MediaBridgeFraming.writeFrame(fd, data: data)
        return id
    }

    private func response(_ fd: Int32) throws -> [String: Any] {
        let data = try XCTUnwrap(MediaBridgeFraming.readFrame(fd, idleTimeout: 1))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func flush(_ fd: Int32) throws {
        let id = try authorize(fd)
        XCTAssertEqual(try response(fd)["id"] as? String, id)
    }

    private func fetch(_ runtime: MacBrowserNowPlayingRuntime) async -> MacNowPlayingRuntimeSnapshot? {
        await withCheckedContinuation { continuation in
            runtime.fetchSnapshot {
                if case .snapshot(let snapshot) = $0 { continuation.resume(returning: snapshot) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func waitForItem(_ runtime: MacBrowserNowPlayingRuntime) async throws -> MacNowPlayingRuntimeSnapshot {
        for _ in 0..<100 {
            if let item = await fetch(runtime) { return item }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MediaBridgeError.timedOut
    }

    private func waitForClear(_ runtime: MacBrowserNowPlayingRuntime) async throws {
        for _ in 0..<100 {
            if await fetch(runtime) == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MediaBridgeError.timedOut
    }

    private func waitForPermissions(_ callbacks: BrowserPermissionCallbacks, count: Int) async throws {
        for _ in 0..<100 {
            if callbacks.count == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw MediaBridgeError.timedOut
    }

    func testDisconnectedPermissionOwnerCannotBlockOrCompleteSuccessorRequest() async throws {
        let dir = try directory(), callbacks = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            permissionRequest: callbacks.append)
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let first = try MediaBridgeSocket.connect(path: path)
        defer { close(first) }
        try MediaBridgeFraming.writeFrame(first, data: state(context: UUID().uuidString, revision: 1))
        _ = try await waitForItem(runtime)
        try authorize(first)
        try await waitForPermissions(callbacks, count: 1)
        _ = shutdown(first, SHUT_RDWR)
        try await waitForClear(runtime)

        let second = try MediaBridgeSocket.connect(path: path)
        defer { close(second) }
        let request = try authorize(second)
        try await waitForPermissions(callbacks, count: 2)
        callbacks.resolve(0, allowed: true)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(second, idleTimeout: 0.02))
        callbacks.resolve(1, allowed: false)
        let reply = try response(second)
        XCTAssertEqual(reply["id"] as? String, request)
        XCTAssertEqual(reply["result"] as? String, "denied")
        callbacks.resolve(0, allowed: true)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(second, idleTimeout: 0.02))
    }

    func testUntrustedPeerIsClosedBeforeSourceOrPermissionAdmission() async throws {
        let dir = try directory(), callbacks = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in false },
            permissionRequest: callbacks.append)
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: path)
        defer { close(fd) }
        XCTAssertNil(try MediaBridgeFraming.readFrame(fd, idleTimeout: 1))
        let selected = await fetch(runtime)
        XCTAssertNil(selected)
        XCTAssertEqual(callbacks.count, 0)
    }

    func testLatestNewlyPlayingHelperWinsWithoutHeartbeatOscillationAndRemainsSelectedPaused() async throws {
        let dir = try directory(), firstContext = UUID().uuidString, secondContext = UUID().uuidString
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let first = try MediaBridgeSocket.connect(path: path)
        let second = try MediaBridgeSocket.connect(path: path)
        defer { close(first); close(second) }
        try MediaBridgeFraming.writeFrame(first, data: state(context: firstContext, revision: 1))
        try flush(first)
        var selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, firstContext)
        try MediaBridgeFraming.writeFrame(second, data: state(context: secondContext, revision: 1, playing: false))
        try flush(second)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, firstContext)
        try MediaBridgeFraming.writeFrame(second, data: state(context: secondContext, revision: 2))
        try flush(second)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, secondContext)
        try MediaBridgeFraming.writeFrame(first, data: state(context: firstContext, revision: 2))
        try flush(first)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, secondContext)
        try MediaBridgeFraming.writeFrame(first, data: state(context: firstContext, revision: 3, playing: false))
        try MediaBridgeFraming.writeFrame(second, data: state(context: secondContext, revision: 3, playing: false))
        try flush(first); try flush(second)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, secondContext)
        XCTAssertEqual(selected?.metadata.playbackRate, 0)
    }

    func testReplayedOrRegressedRevisionRetiresOwnerAndFreshConnectionCanRestartAtOne() async throws {
        for replay in [2, 1] {
            let dir = try directory(), path = dir.appendingPathComponent("socket").path
            let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
                permissionRequest: { $0(false) })
            defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
            _ = await fetch(runtime)
            let first = try MediaBridgeSocket.connect(path: path)
            defer { close(first) }
            let context = UUID().uuidString
            try MediaBridgeFraming.writeFrame(first, data: state(context: context, revision: 2))
            try flush(first)
            let original = try await waitForItem(runtime)
            try MediaBridgeFraming.writeFrame(first, data: state(context: context, revision: replay))
            XCTAssertNil(try MediaBridgeFraming.readFrame(first, idleTimeout: 1))
            try await waitForClear(runtime)
            let second = try MediaBridgeSocket.connect(path: path)
            defer { close(second) }
            try MediaBridgeFraming.writeFrame(second, data: state(context: context, revision: 1))
            try flush(second)
            let replacement = try await waitForItem(runtime)
            XCTAssertFalse(replacement.client === original.client)
        }
    }
}
