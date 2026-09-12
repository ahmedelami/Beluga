import Foundation
import XCTest
@testable import WebRTCTransport

final class WebRTCWindowMoveProtocolTests: XCTestCase {
    private let session = UUID()
    private let generation = UUID()
    private var actions: [WebRTCInputAction] {
        [.requestFocusedWindowMoveTarget, .selectWindowForMove(at: .init(x: 0.3, y: 0.4)),
         .commitFocusedWindowMove(targetGeneration: generation, start: .init(x: 0.1, y: 0.8), end: .init(x: 0.7, y: 0.2))]
    }

    func testMoveCapabilitiesAreAdditiveAndStrict() throws {
        let current = WebRTCInputCapability(
            inputSessionID: session,
            screenRequestID: 1,
            supportsFocusedWindowMove: true,
            supportsFocusedWindowMoveScaleRebinding: true
        )
        let data = try JSONEncoder().encode(current)
        XCTAssertEqual(try JSONDecoder().decode(WebRTCInputCapability.self, from: data), current)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for keyPath in [
            \WebRTCInputCapability.supportsFocusedWindowMove,
            \WebRTCInputCapability.supportsFocusedWindowMoveScaleRebinding
        ] {
            let key = keyPath == \WebRTCInputCapability.supportsFocusedWindowMove
                ? "supportsFocusedWindowMove"
                : "supportsFocusedWindowMoveScaleRebinding"
            var legacyObject = object
            legacyObject.removeValue(forKey: key)
            let legacy = try JSONDecoder().decode(
                WebRTCInputCapability.self,
                from: JSONSerialization.data(withJSONObject: legacyObject)
            )
            XCTAssertFalse(legacy[keyPath: keyPath])
            for invalid in [NSNull(), 1, "true"] as [Any] {
                var invalidObject = object
                invalidObject[key] = invalid
                XCTAssertThrowsError(try JSONDecoder().decode(
                    WebRTCInputCapability.self,
                    from: JSONSerialization.data(withJSONObject: invalidObject)
                ))
            }
        }
    }

    func testEveryMoveActionRequiresViewerGeometryAndRoundTrips() throws {
        for action in actions {
            let request = WebRTCInputRequest(id: 1, screenRequestID: 1, inputSessionID: session,
                action: action, viewerVideoSize: .init(width: 1920, height: 1080))
            let data = try JSONEncoder().encode(request)
            XCTAssertLessThan(data.count, WebRTCInputCapability.maximumMessageBytes)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputRequest.self, from: data), request)
            XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputRequest(
                id: 1, screenRequestID: 1, inputSessionID: session, action: action
            )))
        }
        for raw in [
            #"{"kind":"focusedWindowMoveTarget","point":{"x":0.1,"y":0.2}}"#,
            #"{"kind":"focusedWindowMoveSelection","point":{"x":1.1,"y":0.2}}"#,
            #"{"kind":"focusedWindowMoveCommit","targetGeneration":"00000000-0000-0000-0000-000000000000","start":{"x":0.1,"y":0.2},"end":{"x":0.3,"y":0.4}}"#,
            #"{"kind":"focusedWindowMoveCommit","start":{"x":0.1,"y":0.2},"end":{"x":0.3,"y":0.4}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(WebRTCInputAction.self, from: Data(raw.utf8)))
        }
    }

    func testFeedbackBindsExactMoveStageAndConsumedGeneration() throws {
        let target = WebRTCWindowMoveTarget(generation: UUID(), normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let kinds: [WebRTCWindowMoveFeedbackKind] = [.targetAcquired, .windowSelected, .moveCommitted]
        for (index, action) in actions.enumerated() {
            let move = WebRTCWindowMoveFeedback(kind: kinds[index],
                committedTargetGeneration: index == 2 ? generation : nil, target: target)
            let feedback = WebRTCInputFeedback(id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted, windowMove: move)
            XCTAssertEqual(try JSONDecoder().decode(WebRTCInputFeedback.self, from: JSONEncoder().encode(feedback)), feedback)
            for (otherIndex, other) in actions.enumerated() {
                XCTAssertEqual(WebRTCInputRequestActionBinding(other).permits(feedback), index == otherIndex)
            }
            XCTAssertFalse(WebRTCInputRequestActionBinding(.requestFocusedWindowResizeTarget).permits(feedback))
            XCTAssertFalse(WebRTCInputRequestActionBinding(.tap(.init(x: 0.1, y: 0.1))).permits(feedback))
            XCTAssertTrue(WebRTCInputRequestActionBinding(action).permits(feedback))
        }
        let wrong = WebRTCInputFeedback(id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted,
            windowMove: .init(kind: .moveCommitted, committedTargetGeneration: UUID(), target: target))
        XCTAssertFalse(WebRTCInputRequestActionBinding(actions[2]).permits(wrong))
    }

    func testFeedbackRejectsMixedAuthorityRejectedTargetsAndReusedSuccessor() throws {
        let target = WebRTCWindowMoveTarget(generation: generation, normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        let move = WebRTCWindowMoveFeedback(kind: .targetAcquired, target: target)
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputFeedback(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted,
            windowResize: .init(kind: .targetAcquired, target: target), windowMove: move
        )))
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCInputFeedback(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .rejected,
            rejectionReason: .rateLimited, windowMove: move
        )))
        XCTAssertThrowsError(try JSONEncoder().encode(WebRTCWindowMoveFeedback(
            kind: .moveCommitted, committedTargetGeneration: generation, target: target
        )))
    }

    func testMoveCapabilityIsEnforcedByViewerAndHost() async throws {
        let capability = WebRTCInputCapability(inputSessionID: session, screenRequestID: 1, supportsFocusedWindowResize: true)
        let viewer = try WebRTCPeer(configuration: .init(role: .viewer, iceServers: []))
        let viewerAuthorization = WebRTCInputAuthorization()
        try await viewer.installViewerInputSessionForTesting(capability: capability, authorization: viewerAuthorization)
        for action in actions {
            do {
                _ = try await viewer.requestInput(action, viewerVideoSize: .init(width: 1920, height: 1080),
                    capability: capability, authorization: viewerAuthorization)
                XCTFail("Move requires its own advertised capability")
            } catch WebRTCTransportError.invalidInputRequest {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await viewer.close(reason: .viewerDisconnected)
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(capability: capability, authorization: authorization)
        let admitted = await host.receiveInputRequestForTesting(.init(
            id: 1, screenRequestID: 1, inputSessionID: session, action: actions[0],
            viewerVideoSize: .init(width: 1920, height: 1080)
        ))
        XCTAssertFalse(admitted)
        XCTAssertFalse(authorization.isValid)
        await host.close(reason: .hostStopped)
    }

    func testMoveCommitReplayRetainsFeedbackAndNeverRepeatsApplicationWork() async throws {
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let capability = WebRTCInputCapability(inputSessionID: session, screenRequestID: 1, supportsFocusedWindowMove: true)
        let authorization = WebRTCInputAuthorization()
        try await host.installHostInputSessionForTesting(capability: capability, authorization: authorization)
        await host.beginRemoteInputControlDataCaptureForTesting()
        let request = WebRTCInputRequest(id: 1, screenRequestID: 1, inputSessionID: session,
            action: actions[2], viewerVideoSize: .init(width: 1920, height: 1080))
        let admitted = await host.receiveInputRequestForTesting(request)
        XCTAssertTrue(admitted)
        let move = WebRTCWindowMoveFeedback(kind: .moveCommitted, committedTargetGeneration: generation,
            target: .init(generation: UUID(), normalizedFrame: .init(x: 0.1, y: 0.2, width: 0.5, height: 0.5)))
        try await host.sendInputFeedback(for: 1, result: .accepted, windowMove: move)
        let replayed = await host.receiveInputRequestForTesting(request)
        XCTAssertTrue(replayed)
        let snapshot = await host.remoteInputReceiveDebugSnapshotForTesting()
        XCTAssertEqual(snapshot.receivedRequestHistoryCount, 1)
        XCTAssertEqual(snapshot.admittedRequestEventCount, 1)
        XCTAssertEqual(snapshot.sentFeedbackHistoryCount, 1)
        let expected = ControlChannelMessage.inputFeedback(.init(
            id: 1, screenRequestID: 1, inputSessionID: session, result: .accepted, windowMove: move
        ))
        XCTAssertEqual(try snapshot.capturedControlData.map {
            try JSONDecoder().decode(ControlChannelMessage.self, from: $0)
        }, [expected, expected])
        XCTAssertTrue(authorization.isValid)
        await host.close(reason: .hostStopped)
    }
}
