import Foundation
import WebRTCTransport

enum WorldwideRemoteMediaCommandTrace {
    enum Stage: String, CaseIterable {
        case serviceReceived, capacityRejected, executionRetired, resultResolved
        case acknowledgementRetired, acknowledgementSent, acknowledgementFailed, queueCancelled
    }

    static func message(
        stage: Stage,
        session: UUID,
        processID: Int32,
        peerGeneration: UInt64,
        request: WebRTCRemoteMediaCommandRequest,
        publishedRevision: UInt64?,
        contextMatches: Bool,
        authorized: Bool,
        transportReady: Bool,
        result: WebRTCRemoteMediaCommandResult?,
        uptime: TimeInterval
    ) -> String {
        // Never log item metadata, opaque context IDs, signaling, or pairing material.
        "remote-media-command stage=\(stage.rawValue) session=\(session.uuidString.lowercased()) "
            + "pid=\(processID) peer=\(peerGeneration) id=\(request.id) command=\(request.command.rawValue) "
            + "observedRevision=\(request.observedRevision) publishedRevision=\(publishedRevision ?? 0) "
            + "contextMatches=\(contextMatches) authorized=\(authorized) transportReady=\(transportReady) "
            + "result=\(result?.rawValue ?? "none") uptime=\(uptime)"
    }
}
