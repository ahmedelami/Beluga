import Darwin
import Foundation
import XCTest
@testable import MediaBridgeCore

final class MediaBridgeCoreTests: XCTestCase {
    private func state(_ changes: [String: Any] = [:]) throws -> Data {
        var item: [String: Any] = ["contextID": "163D5BA8-9141-4986-BD6F-94AD9F52699D", "sourceName": "YouTube",
            "title": "Fixture", "artist": "Artist", "duration": 120, "elapsedTime": 7,
            "playbackRate": 1, "playbackState": "playing", "canPlay": false, "canPause": true,
            "canSkipForward": true, "canSkipBackward": false]
        item.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: ["v": 1, "type": "state", "revision": 1, "item": item])
    }

    func testActualStateDecoderPreservesTimelineAndOnlyPublishedCapabilities() throws {
        guard case .state(let value) = try MediaBridgeProtocol.decode(state()) else { return XCTFail() }
        XCTAssertEqual(value.item?.title, "Fixture")
        XCTAssertEqual(value.item?.duration, 120)
        XCTAssertEqual(value.item?.elapsedTime, 7)
        XCTAssertEqual(value.item?.canSkipForward, true)
        XCTAssertEqual(value.item?.canSkipBackward, false)
    }

    func testRejectsMalformedBoundariesInsteadOfInventingMetadata() throws {
        for changes: [String: Any] in [
            ["contextID": "not-a-uuid"], ["sourceName": "Music"], ["title": ""],
            ["title": String(repeating: "x", count: 513)], ["artist": "bad\nmetadata"],
            ["duration": -1], ["elapsedTime": -1], ["playbackRate": 17],
            ["playbackState": "live"], ["canPlay": "true"], ["extra": "unexpected"]
        ] { XCTAssertThrowsError(try MediaBridgeProtocol.decode(state(changes)), "\(changes)") }
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data(repeating: 0x20, count: 4097)))
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data("{\"v\":true,\"type\":\"state\",\"revision\":1,\"item\":null}".utf8)))
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data("{\"v\":1,\"type\":\"state\",\"revision\":0,\"item\":null}".utf8)))
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data("{\"v\":1,\"type\":\"state\",\"revision\":9007199254740992,\"item\":null}".utf8)))
    }

    func testFramingRoundTripsExactNativeLengthAndRejectsOversizeHeader() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        MediaBridgeSocket.configure(fds[0]); MediaBridgeSocket.configure(fds[1])
        let payload = try state()
        try MediaBridgeFraming.writeFrame(fds[0], data: payload)
        XCTAssertEqual(try MediaBridgeFraming.readFrame(fds[1], idleTimeout: 0.1), payload)
        var count = UInt32(4097).littleEndian
        _ = withUnsafeBytes(of: &count) { Darwin.write(fds[0], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fds[1], idleTimeout: 0.1))
    }

    func testTruncatedAndStalledFramesAreBoundedFailures() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        MediaBridgeSocket.configure(fds[0]); MediaBridgeSocket.configure(fds[1])
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fds[1], idleTimeout: 0.01))
        let partial: [UInt8] = [10, 0, 0, 0, 123]
        _ = partial.withUnsafeBytes { Darwin.write(fds[0], $0.baseAddress, $0.count) }
        _ = shutdown(fds[0], SHUT_WR)
        XCTAssertThrowsError(try MediaBridgeFraming.readFrame(fds[1], idleTimeout: 0.1))
    }

    func testPermissionRequestIsSeparateAndRequiresExactUUIDShape() throws {
        let data = Data("{\"v\":1,\"type\":\"authorizeMusic\",\"id\":\"163D5BA8-9141-4986-BD6F-94AD9F52699D\"}".utf8)
        guard case .authorizeMusic = try MediaBridgeProtocol.decode(data) else { return XCTFail() }
        XCTAssertThrowsError(try MediaBridgeProtocol.decode(Data("{\"v\":1,\"type\":\"authorizeMusic\",\"id\":\"bad\"}".utf8)))
    }

    func testSocketPathsRejectOverflowAndUnsafeDirectoryModes() throws {
        XCTAssertThrowsError(try MediaBridgeSocket.address(String(repeating: "/long", count: 40)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNoThrow(try MediaBridgeSocket.validateDirectory(directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try MediaBridgeSocket.validateDirectory(directory))
    }
}
