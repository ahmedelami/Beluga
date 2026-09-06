import Darwin
import Foundation
import MediaBridgeCore
import XCTest
@testable import CaptureServer

private final class BrowserWriteAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    private var clock: Double = 10
    func revoke() { lock.withLock { current = false } }
    func expire() { lock.withLock { clock = 12 } }
    func admits(deadline: Double) -> Bool { lock.withLock { current && clock < deadline } }
}

final class MacBrowserNowPlayingWriteAdmissionTests: XCTestCase {
    func testWriteLockWaitCannotRetainRevokedAuthorityOrRenewDeadline() async throws {
        for expire in [false, true] {
            var fds: [Int32] = [0, 0]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
            MediaBridgeSocket.configure(fds[0]); MediaBridgeSocket.configure(fds[1])
            let connection = BrowserBridgeConnection(fd: fds[0])
            let reader = fds[1]
            defer { connection.close(); close(reader) }
            let baseline = Data("baseline".utf8)
            XCTAssertTrue(try connection.send(baseline))
            XCTAssertEqual(try MediaBridgeFraming.readFrame(reader, idleTimeout: 1), baseline)

            let authority = BrowserWriteAuthority()
            let firstEntered = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let secondStarted = DispatchSemaphore(value: 0)
            let secondAdmission = DispatchSemaphore(value: 0)
            let firstDone = expectation(description: "lock holder finishes \(expire)")
            let secondDone = expectation(description: "waiting write rejected \(expire)")
            DispatchQueue.global(qos: .utility).async {
                do {
                    let sent = try connection.send(Data("first".utf8)) {
                        firstEntered.signal()
                        XCTAssertEqual(releaseFirst.wait(timeout: .now() + 2), .success)
                        return false
                    }
                    XCTAssertFalse(sent)
                } catch { XCTFail("Unexpected first write error: \(error)") }
                firstDone.fulfill()
            }
            XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
            DispatchQueue.global(qos: .utility).async {
                secondStarted.signal()
                do {
                    let sent = try connection.send(Data("must not arrive".utf8)) {
                        secondAdmission.signal()
                        return authority.admits(deadline: 11)
                    }
                    XCTAssertFalse(sent)
                } catch { XCTFail("Unexpected second write error: \(error)") }
                secondDone.fulfill()
            }
            XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(secondAdmission.wait(timeout: .now() + 0.05), .timedOut,
                "Admission must wait for the connection's write lock")
            if expire { authority.expire() } else { authority.revoke() }
            releaseFirst.signal()
            await fulfillment(of: [firstDone, secondDone], timeout: 1)
            XCTAssertThrowsError(try MediaBridgeFraming.readFrame(reader, idleTimeout: 0.02))
        }
    }

    private func fetch(_ runtime: MacBrowserNowPlayingRuntime) async -> MacNowPlayingRuntimeSnapshot? {
        await withCheckedContinuation { continuation in
            runtime.fetchSnapshot {
                if case .snapshot(let value) = $0 { continuation.resume(returning: value) }
                else { continuation.resume(returning: nil) }
            }
        }
    }

    private func publish(_ fd: Int32, context: String, revision: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "state", "revision": revision,
            "item": ["contextID": context, "sourceName": "YouTube", "title": "Playing item",
                "playbackRate": 1, "playbackState": "playing", "canPlay": false,
                "canPause": true, "canSkipForward": true, "canSkipBackward": false]])
        try MediaBridgeFraming.writeFrame(fd, data: data)
        let id = UUID().uuidString
        let barrier = try JSONSerialization.data(withJSONObject: ["v": 1, "type": "authorizeMusic", "id": id])
        try MediaBridgeFraming.writeFrame(fd, data: barrier)
        let response = try XCTUnwrap(MediaBridgeFraming.readFrame(fd, idleTimeout: 1))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertEqual(reply["id"] as? String, id)
    }

    func testNewPlayingItemCanRegainSelectionWithoutObservedPause() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbw-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("socket").path
        let runtime = MacBrowserNowPlayingRuntime(socketPath: path, peerIsTrusted: { _ in true },
            permissionRequest: { $0(false) })
        defer { runtime.stop(); try? FileManager.default.removeItem(at: dir) }
        _ = await fetch(runtime)
        let first = try MediaBridgeSocket.connect(path: path)
        let second = try MediaBridgeSocket.connect(path: path)
        defer { close(first); close(second) }
        let firstItem = UUID().uuidString, secondItem = UUID().uuidString, replacement = UUID().uuidString
        try publish(first, context: firstItem, revision: 1)
        var selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, firstItem)
        try publish(second, context: secondItem, revision: 1)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, secondItem)
        try publish(first, context: replacement, revision: 2)
        selected = await fetch(runtime)
        XCTAssertEqual(selected?.metadata.contentIdentifier, replacement)
    }
}
