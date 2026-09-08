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

private final class BrowserOnboardingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 20 } }
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
    private func authorize(_ fd: Int32, type: String = "authorizeMusic") throws -> String {
        let id = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "type": type, "id": id])
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

    func testNativeOnboardingWorksWithoutMediaPeerOrExtensionAndRejectsStateInjection() async throws {
        let dir = try directory(), chrome = BrowserPermissionCallbacks(), music = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            acceptsMediaStates: false, chromePermissionRequest: chrome.append, permissionRequest: music.append)
        let service = MacMediaAutomationService(bridge: runtime)
        defer { service.stop(); try? FileManager.default.removeItem(at: dir) }
        service.start()
        XCTAssertEqual(chrome.count, 0)
        XCTAssertEqual(music.count, 0)
        let fd = try MediaBridgeSocket.connect(path: path)
        defer { close(fd) }
        let id = try authorize(fd, type: "authorizeChrome")
        try await waitForPermissions(chrome, count: 1)
        XCTAssertEqual(music.count, 0)
        chrome.resolve(0, allowed: true)
        let reply = try response(fd)
        XCTAssertEqual(reply["id"] as? String, id)
        XCTAssertEqual(reply["result"] as? String, "authorized")
        try MediaBridgeFraming.writeFrame(fd, data: MediaAutomationOnboarding.request(type: "authorizeChrome", id: id))
        XCTAssertEqual(try response(fd)["result"] as? String, "unavailable")
        XCTAssertEqual(chrome.count, 1)
        let beforeStateInjection = await fetch(runtime)
        XCTAssertNil(beforeStateInjection)
        try MediaBridgeFraming.writeFrame(fd, data: state(context: UUID().uuidString, revision: 1))
        XCTAssertNil(try MediaBridgeFraming.readFrame(fd, idleTimeout: 1))
        let afterStateInjection = await fetch(runtime)
        XCTAssertNil(afterStateInjection)
    }

    func testNativeConsentCanOutliveExtensionHeartbeatWithoutIncomingFrames() async throws {
        let dir = try directory(), callbacks = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            acceptsMediaStates: false, chromePermissionRequest: callbacks.append, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: path)
        defer { close(fd) }
        let id = try authorize(fd, type: "authorizeChrome")
        try await waitForPermissions(callbacks, count: 1)
        try await Task.sleep(for: .seconds(4))
        callbacks.resolve(0, allowed: true)
        let reply = try response(fd)
        XCTAssertEqual(reply["id"] as? String, id)
        XCTAssertEqual(reply["result"] as? String, "authorized")
    }

    func testOnboardingListenerRecoversFromInitialLockContentionAndStopsRetrying() async throws {
        let dir = try directory(), clock = BrowserOnboardingClock(), callbacks = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let owner = open(dir.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(owner, 0)
        guard owner >= 0 else { return }
        defer { close(owner) }
        XCTAssertEqual(flock(owner, LOCK_EX | LOCK_NB), 0)
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, now: clock.now, peerIsTrusted: { _ in true },
            acceptsMediaStates: false, chromePermissionRequest: callbacks.append, permissionRequest: { $0(false) })
        let service = MacMediaAutomationService(bridge: runtime, retryInterval: 0.02)
        defer { service.stop(); try? FileManager.default.removeItem(at: dir) }
        service.start()
        XCTAssertThrowsError(try MediaBridgeSocket.connect(path: path))
        XCTAssertEqual(flock(owner, LOCK_UN), 0)
        clock.advance()
        var connected: Int32?
        for _ in 0..<100 {
            if let fd = try? MediaBridgeSocket.connect(path: path) { connected = fd; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let fd = try XCTUnwrap(connected)
        defer { close(fd) }
        let id = try authorize(fd, type: "authorizeChrome")
        try await waitForPermissions(callbacks, count: 1)
        callbacks.resolve(0, allowed: false)
        XCTAssertEqual(try response(fd)["id"] as? String, id)
        service.stop()
        clock.advance()
        // stop revokes authority synchronously; the accept loop owns a duplicate
        // descriptor that drains asynchronously after its bounded one-second poll.
        // A kernel connect during that drain is not a live permission listener.
        var listenerDrained = false
        for _ in 0..<200 {
            if let pending = try? MediaBridgeSocket.connect(path: path) {
                _ = try? authorize(pending, type: "authorizeChrome")
                let replyData = try? MediaBridgeFraming.readFrame(pending, idleTimeout: 0.05)
                let reply = replyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                XCTAssertNotEqual(reply?["result"] as? String, "authorized")
                close(pending)
                try await Task.sleep(for: .milliseconds(10))
            } else { listenerDrained = true; break }
        }
        XCTAssertTrue(listenerDrained, "Stopped service retained or restarted its listener")
        XCTAssertEqual(callbacks.count, 1, "Stopped service requested fresh consent")
    }

    func testDisconnectedChromePermissionCannotAcknowledgeReplacementConnection() async throws {
        let dir = try directory(), callbacks = BrowserPermissionCallbacks()
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            acceptsMediaStates: false, chromePermissionRequest: callbacks.append, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let first = try MediaBridgeSocket.connect(path: path)
        defer { close(first) }
        _ = try authorize(first, type: "authorizeChrome")
        try await waitForPermissions(callbacks, count: 1)
        _ = shutdown(first, SHUT_RDWR)
        // Socket teardown is asynchronous; the new request retries only permission
        // admission, never a media command, and every request retains a unique ID.
        let second = try MediaBridgeSocket.connect(path: path)
        defer { close(second) }
        var id = ""
        for _ in 0..<100 {
            id = try authorize(second, type: "authorizeChrome")
            try await Task.sleep(for: .milliseconds(10))
            if callbacks.count == 2 { break }
            _ = try response(second)
        }
        XCTAssertEqual(callbacks.count, 2)
        guard callbacks.count == 2 else { return }
        callbacks.resolve(0, allowed: true)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(second, idleTimeout: 0.02))
        callbacks.resolve(1, allowed: false)
        let reply = try response(second)
        XCTAssertEqual(reply["id"] as? String, id)
        XCTAssertEqual(reply["result"] as? String, "denied")
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
