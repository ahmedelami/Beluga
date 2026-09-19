import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

final class WorldwideRemoteMediaCommandTraceTests: XCTestCase {
    func testTraceCorrelatesBoundariesWithoutOpaqueContextOrMediaMetadata() {
        let session = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let request = WebRTCRemoteMediaCommandRequest(id: 7,
            contextID: "PRIVATE-CONTEXT\ninjected=true", observedRevision: 11, command: .play)
        for stage in WorldwideRemoteMediaCommandTrace.Stage.allCases {
            let message = WorldwideRemoteMediaCommandTrace.message(stage: stage, session: session,
                processID: 42, peerGeneration: 3, request: request, publishedRevision: 12,
                contextMatches: false, authorized: false, transportReady: true,
                result: .staleContext, uptime: 123.5)
            XCTAssertEqual(message, "remote-media-command stage=\(stage.rawValue) "
                + "session=11111111-1111-1111-1111-111111111111 pid=42 peer=3 id=7 command=play "
                + "observedRevision=11 publishedRevision=12 contextMatches=false authorized=false "
                + "transportReady=true result=staleContext uptime=123.5")
            XCTAssertFalse(message.contains(request.contextID))
            XCTAssertFalse(message.contains("\n"))
        }
    }

    func testReceiveTraceDoesNotImplyExecutionOrAcknowledgement() {
        let message = WorldwideRemoteMediaCommandTrace.message(stage: .serviceReceived, session: UUID(),
            processID: 42, peerGeneration: 3,
            request: .init(id: 1, contextID: "private", observedRevision: 2, command: .pause),
            publishedRevision: nil, contextMatches: true, authorized: true,
            transportReady: false, result: nil, uptime: 1)
        XCTAssertTrue(message.contains("stage=serviceReceived"))
        XCTAssertTrue(message.contains("publishedRevision=0"))
        XCTAssertTrue(message.contains("result=none"))
        XCTAssertTrue(message.contains("transportReady=false"))
    }
}
