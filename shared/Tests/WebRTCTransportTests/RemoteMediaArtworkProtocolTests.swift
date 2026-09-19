import Foundation
import XCTest
@testable import WebRTCTransport

final class RemoteMediaArtworkProtocolTests: XCTestCase {
    private struct LegacyMediaItem: Decodable, Equatable {
        let contextID: String
        let sourceName: String
        let title: String
        let artist: String?
        let album: String?
        let playbackState: WebRTCRemoteMediaPlaybackState
        let elapsedTime: TimeInterval?
        let duration: TimeInterval?
        let playbackRate: Double
        let capabilities: WebRTCRemoteMediaCapabilities
    }

    func testYouTubeReferenceHasFixedHTTPSOriginAndExactASCIIIdentifier() throws {
        for id in ["abcdefghijk", "AbCd-012_9Z"] {
            let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: id))
            XCTAssertEqual(reference.provider, .youtube)
            XCTAssertEqual(reference.videoID, id)
            XCTAssertEqual(reference.url.absoluteString, "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
            XCTAssertNil(reference.url.query)
            XCTAssertNil(reference.url.user)
            let data = try JSONEncoder().encode(reference)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCRemoteMediaArtworkReference.self, from: data), reference)
            XCTAssertLessThan(data.count, 64)
        }
        for id in ["", "abcdefghij", "abcdefghijkl", "abcdefghij/", "abcdefghij?", "abcdefghij#",
                   "abcdefghij%", "abcdefghij.", "abcdefghij ", "abcdefghij\n", "abcdefghié",
                   "https://a.b", "..%2Fsecret", "Ａbcdefghijk", String(repeating: "a", count: 4_096)] {
            XCTAssertNil(WebRTCRemoteMediaArtworkReference(videoID: id), id)
        }
    }

    func testLegacyMissingFieldAndExtraFieldCompatibility() throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "abcdefghijk"))
        let legacyBytes = try JSONEncoder().encode(item())
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        XCTAssertNil(legacyObject["artwork"])
        XCTAssertNil(try JSONDecoder().decode(WebRTCRemoteMediaItem.self, from: legacyBytes).artwork)
        let currentBytes = try JSONEncoder().encode(item(artwork: reference))
        XCTAssertEqual(try JSONDecoder().decode(LegacyMediaItem.self, from: currentBytes),
                       try JSONDecoder().decode(LegacyMediaItem.self, from: legacyBytes))
        XCTAssertEqual(try JSONDecoder().decode(WebRTCRemoteMediaItem.self, from: currentBytes).artwork, reference)
    }

    func testMalformedOrUnknownArtworkDropsOnlyArtwork() throws {
        let baseline = item()
        let encoded = try JSONEncoder().encode(baseline)
        let invalid: [Any] = [NSNull(), true, 42, "https://example.com/image.jpg", [], [:],
                              ["provider": "unreviewed", "videoID": "abcdefghijk"],
                              ["provider": "youtube", "videoID": "../../secrets"],
                              ["provider": "youtube", "videoID": "abcde\n12345"],
                              ["provider": "youtube", "videoID": 123],
                              ["provider": "youtube", "url": "http://127.0.0.1/private"]]
        for artwork in invalid {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object["artwork"] = artwork
            let decoded = try JSONDecoder().decode(WebRTCRemoteMediaItem.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, baseline)
            XCTAssertTrue(WebRTCRemoteMediaStateUpdate(revision: 7, item: decoded).isValid)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["artwork"] = ["provider": "youtube", "videoID": "abcdefghijk", "url": "http://127.0.0.1/private"]
        let decorated = try JSONDecoder().decode(WebRTCRemoteMediaItem.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decorated.artwork?.url.host, "i.ytimg.com")
        object["capabilities"] = "invalid required field"
        XCTAssertThrowsError(try JSONDecoder().decode(WebRTCRemoteMediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testArtworkWireStateRemainsWithinFourKiBAndOversizeStillFails() throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "abcdefghijk"))
        let bounded = WebRTCRemoteMediaItem(
            contextID: String(repeating: "c", count: WebRTCRemoteMediaItem.maximumContextIDBytes),
            sourceName: String(repeating: "s", count: WebRTCRemoteMediaItem.maximumSourceNameBytes),
            title: String(repeating: "t", count: WebRTCRemoteMediaItem.maximumTitleBytes),
            artist: String(repeating: "a", count: WebRTCRemoteMediaItem.maximumArtistBytes),
            album: String(repeating: "a", count: WebRTCRemoteMediaItem.maximumAlbumBytes),
            playbackState: .playing, elapsedTime: 31_536_000, duration: 31_536_000, playbackRate: 16,
            capabilities: item().capabilities, artwork: reference
        )
        let message = ControlChannelMessage.remoteMediaState(.init(
            authorization: .init(), update: .init(revision: UInt64.max, item: bounded), refreshID: UUID()
        ))
        let data = try JSONEncoder().encode(message)
        XCTAssertTrue(bounded.isValid)
        XCTAssertEqual(WebRTCWireConstants.maximumControlMessageBytes, 4_096)
        XCTAssertLessThanOrEqual(data.count, WebRTCWireConstants.maximumControlMessageBytes)
        XCTAssertEqual(try JSONDecoder().decode(ControlChannelMessage.self, from: data), message)
        let proxy = WebRTCDelegateProxy()
        XCTAssertThrowsError(try proxy.sendControlData(Data(repeating: 0, count: 4_097))) { error in
            XCTAssertEqual(error as? WebRTCTransportError, .invalidInputRequest)
        }
        proxy.close()
    }

    func testArtworkRevisionDoesNotChangeCommandAuthority() throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "abcdefghijk"))
        let request = WebRTCRemoteMediaCommandRequest(id: 1, contextID: "context", observedRevision: 1, command: .pause)
        XCTAssertNil(WebRTCRemoteMediaCommandAdmission.rejection(for: request,
            latestSuccessfullySent: .init(revision: 2, item: item(artwork: reference))))
        XCTAssertEqual(WebRTCRemoteMediaCommandAdmission.rejection(for: request,
            latestSuccessfullySent: .init(revision: 2, item: item(contextID: "new-context", artwork: reference))), .staleContext)
    }

    private func item(contextID: String = "context", artwork: WebRTCRemoteMediaArtworkReference? = nil) -> WebRTCRemoteMediaItem {
        .init(contextID: contextID, sourceName: "YouTube", title: "Video", artist: "Channel", album: nil,
              playbackState: .paused, elapsedTime: 15, duration: 120, playbackRate: 0,
              capabilities: .init(canPlay: true, canPause: true, canSkipForward: true, canSkipBackward: false),
              artwork: artwork)
    }
}
