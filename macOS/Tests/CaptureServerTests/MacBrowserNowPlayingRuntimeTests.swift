import Darwin
import Foundation
import MediaBridgeCore
import WebRTCTransport
import XCTest
@testable import CaptureServer

private final class BrowserTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 10
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

final class MacBrowserNowPlayingRuntimeTests: XCTestCase {
    private let context = "163D5BA8-9141-4986-BD6F-94AD9F52699D"
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("mb-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return value
    }
    private func state(revision: Int = 1, context: String? = nil, playing: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": 1, "type": "state", "revision": revision,
            "item": ["contextID": context ?? self.context, "sourceName": "YouTube", "title": "Fixture",
                "duration": 120, "elapsedTime": 7, "playbackRate": playing ? 1 : 0,
                "playbackState": playing ? "playing" : "paused", "canPlay": !playing,
                "canPause": playing, "canSkipForward": true, "canSkipBackward": false]])
    }
    private func fetch(_ runtime: MacBrowserNowPlayingRuntime) async -> MacNowPlayingRuntimeSnapshot? {
        await withCheckedContinuation { continuation in
            runtime.fetchSnapshot {
                if case .snapshot(let value) = $0 { continuation.resume(returning: value) }
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

    func testRealSocketPublishesTimelineAndDispatchesOneExactCommand() async throws {
        let dir = try directory()
        let runtime = MacBrowserNowPlayingRuntime(socketPath: dir.appendingPathComponent("socket").path,
            peerIsTrusted: { _ in true }, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: dir.appendingPathComponent("socket").path)
        defer { close(fd) }
        try MediaBridgeFraming.writeFrame(fd, data: state())
        let item = try await waitForItem(runtime)
        XCTAssertEqual(item.metadata.title, "Fixture")
        XCTAssertEqual(item.metadata.duration, 120)
        XCTAssertEqual(item.metadata.elapsedTime, 7)
        XCTAssertEqual(item.enabledCommands, [1, 4])
        let result = expectation(description: "acknowledged exact command")
        runtime.send(rawCommand: 1, snapshot: item, isAuthorized: { true }) {
            XCTAssertEqual($0, .applied); result.fulfill()
        }
        let bytes = try XCTUnwrap(MediaBridgeFraming.readFrame(fd, idleTimeout: 1))
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(command["contextID"] as? String, context)
        XCTAssertEqual(command["command"] as? String, "pause")
        XCTAssertNotNil(command["issuedAtMilliseconds"] as? NSNumber)
        let response = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "result",
            "id": try XCTUnwrap(command["id"] as? String), "contextID": context, "result": "applied"])
        try MediaBridgeFraming.writeFrame(fd, data: response)
        await fulfillment(of: [result], timeout: 1)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fd, idleTimeout: 0.02))
    }

    func testQueueDelayExpiresBeforeNativeSendWithoutRenewingTTL() async throws {
        let dir = try directory(), clock = BrowserTestClock()
        let queue = DispatchQueue(label: "test.browser.command-delay")
        let runtime = MacBrowserNowPlayingRuntime(socketPath: dir.appendingPathComponent("socket").path,
            now: clock.now, peerIsTrusted: { _ in true }, commandQueue: queue, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: dir.appendingPathComponent("socket").path)
        defer { close(fd) }
        try MediaBridgeFraming.writeFrame(fd, data: state())
        let item = try await waitForItem(runtime)
        let result = expectation(description: "expired")
        queue.suspend()
        runtime.send(rawCommand: 4, snapshot: item, isAuthorized: { true }) {
            XCTAssertEqual($0, .staleContext); result.fulfill()
        }
        clock.advance(1.5)
        queue.resume()
        await fulfillment(of: [result], timeout: 1)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fd, idleTimeout: 0.02))
    }

    func testStaleHeartbeatAndReplacedItemRejectOldCommands() async throws {
        let dir = try directory(), clock = BrowserTestClock()
        let runtime = MacBrowserNowPlayingRuntime(socketPath: dir.appendingPathComponent("socket").path,
            now: clock.now, peerIsTrusted: { _ in true }, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: dir.appendingPathComponent("socket").path)
        defer { close(fd) }
        try MediaBridgeFraming.writeFrame(fd, data: state())
        let old = try await waitForItem(runtime)
        clock.advance(4)
        let absent = await fetch(runtime)
        XCTAssertNil(absent)
        let rejected = expectation(description: "old context rejected")
        runtime.send(rawCommand: 4, snapshot: old, isAuthorized: { true }) {
            XCTAssertEqual($0, .staleContext); rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fd, idleTimeout: 0.02))
        try MediaBridgeFraming.writeFrame(fd, data: state(revision: 2, context: UUID().uuidString))
        let fresh = try await waitForItem(runtime)
        XCTAssertNotEqual(fresh.identityKey, old.identityKey)
    }

    func testMalformedStateRetiresSocketRatherThanPublishingPartialItem() async throws {
        let dir = try directory()
        let runtime = MacBrowserNowPlayingRuntime(socketPath: dir.appendingPathComponent("socket").path,
            peerIsTrusted: { _ in true }, permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let fd = try MediaBridgeSocket.connect(path: dir.appendingPathComponent("socket").path)
        defer { close(fd) }
        try MediaBridgeFraming.writeFrame(fd, data: Data("{\"v\":1,\"type\":\"state\",\"revision\":1,\"item\":{}}".utf8))
        let bytes = try MediaBridgeFraming.readFrame(fd, idleTimeout: 1)
        XCTAssertNil(bytes)
        let value = await fetch(runtime)
        XCTAssertNil(value)
    }
}
