import Foundation
@preconcurrency import LiveKitWebRTC

/// This optional channel owns its own lock, single-element mailbox and replay/rate budget.
/// It never publishes to the critical peer/control event stream or the audio callback queue.
final class AudioClientDiagnosticsLane: NSObject, LKRTCDataChannelDelegate, @unchecked Sendable {
    static let label = "opensteamer.audio-diagnostics"
    static let channelProtocol = "opensteamer.audio-diagnostics.v1"
    static let minimumInterval: TimeInterval = 1
    static let maximumBufferedBytes: UInt64 = 4 * 1_024

    let events: AsyncStream<WebRTCAudioClientDiagnosticsEvent>
    private let continuation: AsyncStream<WebRTCAudioClientDiagnosticsEvent>.Continuation
    private let lock = NSLock()
    private var channel: LKRTCDataChannel?
    private var context: WebRTCAudioClientDiagnosticsContext?
    private var lastSent: TimeInterval?
    private var lastReceived: TimeInterval?
    private var highestSentSequence: UInt64 = 0
    private var highestReceivedSequence: UInt64 = 0
    private var acceptsIncoming = false
    private var closed = false
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        let pair = AsyncStream<WebRTCAudioClientDiagnosticsEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
        super.init()
    }

    func configure(negotiationID: UUID?, acceptsIncoming: Bool) {
        let old = lock.withLock { () -> WebRTCAudioClientDiagnosticsContext? in
            let old = context
            context = !closed ? negotiationID.map {
                WebRTCAudioClientDiagnosticsContext(negotiationID: $0, authorization: WebRTCControlAuthorization())
            } : nil
            self.acceptsIncoming = acceptsIncoming
            // Keep the physical send/receive cadence across an ICE restart, but retire replay IDs.
            highestSentSequence = 0
            highestReceivedSequence = 0
            return old
        }
        old?.authorization.revoke()
    }

    func currentContext() -> WebRTCAudioClientDiagnosticsContext? {
        lock.withLock { context }
    }

    func install(_ candidate: LKRTCDataChannel) {
        let result = lock.withLock { () -> (Bool, LKRTCDataChannel?) in
            guard !closed else { return (false, nil) }
            // A second channel cannot silently replace a negotiated lane's receive authority.
            guard channel == nil || channel === candidate else { return (false, nil) }
            channel = candidate
            return (true, nil)
        }
        guard result.0 else { candidate.close(); return }
        candidate.delegate = self
    }

    func send(_ heartbeat: WebRTCAudioClientDiagnosticsHeartbeat,
              context expected: WebRTCAudioClientDiagnosticsContext) throws {
        let data = try AudioClientDiagnosticsEnvelope(version: 1,
            negotiationID: expected.negotiationID, heartbeat: heartbeat).encoded()
        try expected.authorization.withValidAuthorization {
            let native = try lock.withLock { () throws -> LKRTCDataChannel in
                guard !closed, let context, context.isSameNegotiation(as: expected),
                      !acceptsIncoming else { throw WebRTCAudioClientDiagnosticsLaneFailure.staleContext }
                guard let channel, channel.readyState == .open else {
                    throw WebRTCAudioClientDiagnosticsLaneFailure.unavailable
                }
                try admitSend(sequence: heartbeat.sequence, bufferedAmount: channel.bufferedAmount,
                              byteCount: data.count, time: now())
                return channel
            }
            guard native.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
                throw WebRTCAudioClientDiagnosticsLaneFailure.backpressure
            }
        }
    }

    /// Called under the lane lock. A failed native send still spends one cadence slot.
    private func admitSend(sequence: UInt64, bufferedAmount: UInt64,
                           byteCount: Int, time: TimeInterval) throws {
        guard byteCount >= 0, byteCount <= AudioClientDiagnosticsEnvelope.maximumBytes else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.oversized
        }
        guard sequence > highestSentSequence else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.staleContext
        }
        guard lastSent.map({ time - $0 >= Self.minimumInterval }) ?? true else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.rateLimited
        }
        guard bufferedAmount <= Self.maximumBufferedBytes,
              UInt64(byteCount) <= Self.maximumBufferedBytes - bufferedAmount else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.backpressure
        }
        lastSent = time
        highestSentSequence = sequence
    }

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        if dataChannel.readyState == .closed,
           lock.withLock({ channel === dataChannel }) { fail(.closed) }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        guard lock.withLock({ channel === dataChannel }) else { return }
        receive(buffer.data, isBinary: buffer.isBinary)
    }

    func receive(_ data: Data, isBinary: Bool = false) {
        let admission = lock.withLock { () -> WebRTCAudioClientDiagnosticsContext? in
            guard !closed, acceptsIncoming, let context else { return nil }
            let time = now()
            guard lastReceived.map({ time - $0 >= Self.minimumInterval }) ?? true else { return nil }
            lastReceived = time
            return context
        }
        guard let admission else { return }
        guard !isBinary else { fail(.malformed); return }
        guard data.count <= AudioClientDiagnosticsEnvelope.maximumBytes else { fail(.oversized); return }
        guard let envelope = try? AudioClientDiagnosticsEnvelope.decode(data),
              envelope.version == 1, envelope.heartbeat.isValid else { fail(.malformed); return }
        // An old in-flight packet is harmless, not a reason to disable the successor lane.
        guard envelope.negotiationID == admission.negotiationID else { return }
        let accepted = lock.withLock {
            guard !closed, let context, context.isSameNegotiation(as: admission),
                  envelope.heartbeat.sequence > highestReceivedSequence else { return false }
            highestReceivedSequence = envelope.heartbeat.sequence
            return true
        }
        if accepted {
            continuation.yield(.heartbeat(WebRTCReceivedAudioClientDiagnostics(
                heartbeat: envelope.heartbeat, context: admission)))
        }
    }

    private func fail(_ reason: WebRTCAudioClientDiagnosticsLaneFailure) {
        close(reason: reason)
    }

    func close(reason: WebRTCAudioClientDiagnosticsLaneFailure? = nil) {
        let resources = lock.withLock { () -> (LKRTCDataChannel?, WebRTCAudioClientDiagnosticsContext?) in
            closed = true
            let resources = (channel, context)
            channel = nil
            context = nil
            return resources
        }
        resources.1?.authorization.revoke()
        resources.0?.delegate = nil
        resources.0?.close()
        if let reason { continuation.yield(.laneFailure(reason)) }
        continuation.finish()
    }

    #if DEBUG
    var highestReceivedSequenceForTesting: UInt64 {
        lock.withLock { highestReceivedSequence }
    }

    func admitSendForTesting(sequence: UInt64, bufferedAmount: UInt64, byteCount: Int, time: TimeInterval) throws {
        try lock.withLock {
            try admitSend(sequence: sequence, bufferedAmount: bufferedAmount, byteCount: byteCount, time: time)
        }
    }
    #endif
}
