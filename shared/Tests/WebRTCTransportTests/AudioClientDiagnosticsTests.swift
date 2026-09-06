import Foundation
@testable import WebRTCTransport
import XCTest

private final class AudioDiagnosticsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { lock.withLock { time } }
    func advance() { lock.withLock { time += 1 } }
}

private actor AudioDiagnosticsRecorder {
    var received: [WebRTCReceivedAudioClientDiagnostics] = []
    var forwardingErrors: [String] = []
    func record(_ value: WebRTCReceivedAudioClientDiagnostics) { received.append(value) }
    func fail(_ error: any Error) { forwardingErrors.append(String(describing: error)) }
}

final class AudioClientDiagnosticsTests: XCTestCase {
    func testExactSessionLevelNonceEchoAndLegacyCompatibility() {
        let base = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
        let nonce = UUID()
        let offer = AudioClientDiagnosticsSDP.advertisingHostSupport(in: base, authorization: nonce)
        let answer = AudioClientDiagnosticsSDP.advertisingViewerSupport(in: base, remoteOfferSDP: offer)
        XCTAssertEqual(AudioClientDiagnosticsSDP.negotiatedAuthorization(hostOfferSDP: offer, viewerAnswerSDP: answer), nonce)
        XCTAssertEqual(AudioClientDiagnosticsSDP.advertisingViewerSupport(in: base, remoteOfferSDP: base), base)
        XCTAssertNil(AudioClientDiagnosticsSDP.negotiatedAuthorization(hostOfferSDP: offer, viewerAnswerSDP: base))
        let line = "\(AudioClientDiagnosticsSDP.prefix)1 \(nonce.uuidString)\r\n"
        for invalid in [base + line, "v=0\r\n" + line + line + "m=audio 9 x\r\n",
                        offer.replacingOccurrences(of: ":1 ", with: ":2 "),
                        offer.replacingOccurrences(of: nonce.uuidString, with: "not-a-uuid")] {
            XCTAssertNil(AudioClientDiagnosticsSDP.authorization(in: invalid))
        }
        let other = AudioClientDiagnosticsSDP.advertisingHostSupport(in: base, authorization: UUID())
        XCTAssertNil(AudioClientDiagnosticsSDP.negotiatedAuthorization(hostOfferSDP: offer, viewerAnswerSDP: other))
    }

    func testCompactWorstCasePreservesCurrentAndFirstFailureWithinFourKiB() throws {
        let heartbeat = worstCaseHeartbeat()
        let bytes = try AudioClientDiagnosticsEnvelope(version: 1, negotiationID: UUID(), heartbeat: heartbeat).encoded()
        XCTAssertLessThanOrEqual(bytes.count, 4096)
        let decoded = try AudioClientDiagnosticsEnvelope.decode(bytes).heartbeat
        XCTAssertEqual(decoded.snapshot, heartbeat.snapshot)
        XCTAssertEqual(decoded.failureSnapshot, heartbeat.failureSnapshot)
        XCTAssertEqual(decoded.events.last, heartbeat.events.last)
        XCTAssertLessThanOrEqual(decoded.events.count, 8)
        XCTAssertGreaterThan(decoded.events.count, 0)
    }

    func testMalformedValuesUnknownFieldsAndOverBoundInputsFailClosed() throws {
        let value = heartbeat(sequence: 1)
        let envelope = AudioClientDiagnosticsEnvelope(version: 1, negotiationID: UUID(), heartbeat: value)
        let bytes = try envelope.encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["failureMessage"] = "never transmit arbitrary native text"
        XCTAssertThrowsError(try AudioClientDiagnosticsEnvelope.decode(JSONSerialization.data(withJSONObject: object)))
        var native = WebRTCAudioClientNativeSnapshot()
        native.failureCode = 26
        var bad = value
        bad.snapshot.native = native
        XCTAssertFalse(bad.isValid)
        bad = value
        bad.snapshot.inboundAudioTotalEnergy = .infinity
        XCTAssertFalse(bad.isValid)
        bad = value
        bad.snapshot.nativeObservationAgeMilliseconds = 86_400_001
        XCTAssertFalse(bad.isValid)
        bad = value
        bad.events = (1...9).map { .init(sequence: UInt64($0), elapsedMilliseconds: 0, kind: .failure) }
        XCTAssertThrowsError(try AudioClientDiagnosticsEnvelope(version: 1, negotiationID: UUID(), heartbeat: bad).encoded())
        bad.events = [.init(sequence: 1, elapsedMilliseconds: 2, kind: .failure),
                      .init(sequence: 1, elapsedMilliseconds: 3, kind: .failure)]
        XCTAssertFalse(bad.isValid)
        XCTAssertThrowsError(try AudioClientDiagnosticsEnvelope.decode(Data(repeating: 32, count: 4097)))
        XCTAssertThrowsError(try AudioClientDiagnosticsEnvelope(version: 2, negotiationID: UUID(), heartbeat: value).encoded())
    }

    func testReplayAndQueuedContextCannotAdoptNewNegotiation() async throws {
        let clock = AudioDiagnosticsClock()
        let lane = AudioClientDiagnosticsLane(now: { clock.read() })
        let oldID = UUID()
        lane.configure(negotiationID: oldID, acceptsIncoming: true)
        let oldContext = try XCTUnwrap(lane.currentContext())
        var iterator = lane.events.makeAsyncIterator()
        let oldData = try AudioClientDiagnosticsEnvelope(version: 1, negotiationID: oldID, heartbeat: heartbeat(sequence: 50)).encoded()
        lane.receive(oldData)
        guard case .heartbeat(let old)? = await iterator.next() else { return XCTFail("Missing real lane receive") }
        XCTAssertTrue(old.isValid)
        clock.advance()
        lane.receive(oldData)
        XCTAssertEqual(lane.highestReceivedSequenceForTesting, 50)
        let newID = UUID()
        lane.configure(negotiationID: newID, acceptsIncoming: true)
        XCTAssertFalse(oldContext.isValid)
        XCTAssertFalse(old.isValid)
        clock.advance()
        lane.receive(oldData)
        XCTAssertEqual(lane.highestReceivedSequenceForTesting, 0, "Old packet must not become successor evidence")
        clock.advance()
        let current = heartbeat(sequence: 1)
        lane.receive(try AudioClientDiagnosticsEnvelope(version: 1, negotiationID: newID, heartbeat: current).encoded())
        guard case .heartbeat(let fresh)? = await iterator.next() else { return XCTFail("Missing fresh lane receive") }
        XCTAssertEqual(fresh.heartbeat, current)
        XCTAssertFalse(fresh.isSameNegotiation(as: old))
        XCTAssertTrue(fresh.isValid)
        lane.close()
        XCTAssertFalse(fresh.isValid)
    }

    func testCadenceAndQueueBackpressureSpendNoCriticalQueueOrRetryBacklog() throws {
        let lane = AudioClientDiagnosticsLane()
        try lane.admitSendForTesting(sequence: 1, bufferedAmount: 0, byteCount: 4096, time: 10)
        XCTAssertThrowsError(try lane.admitSendForTesting(sequence: 2, bufferedAmount: 0, byteCount: 1, time: 10.999))
        XCTAssertThrowsError(try lane.admitSendForTesting(sequence: 2, bufferedAmount: 4096, byteCount: 1, time: 11))
        XCTAssertThrowsError(try lane.admitSendForTesting(sequence: 2, bufferedAmount: .max, byteCount: 1, time: 11))
        try lane.admitSendForTesting(sequence: 2, bufferedAmount: 4095, byteCount: 1, time: 11)
        XCTAssertThrowsError(try lane.admitSendForTesting(sequence: 2, bufferedAmount: 0, byteCount: 1, time: 12))
        lane.close()
    }

    func testMalformedOptionalLaneCannotRevokeHealthyCriticalInput() throws {
        for data in [Data("{}".utf8), Data(repeating: 32, count: 4097)] {
            let proxy = WebRTCDelegateProxy()
            proxy.markNativeTransportHealthyForTesting()
            let gate = WebRTCInputAuthorization()
            XCTAssertTrue(proxy.installInputAuthorization(gate))
            proxy.audioDiagnosticsLane.configure(negotiationID: UUID(), acceptsIncoming: true)
            proxy.audioDiagnosticsLane.receive(data)
            XCTAssertFalse(proxy.didFailEventDelivery())
            XCTAssertTrue(proxy.hasHealthyInstalledInputAuthorization(gate))
            XCTAssertTrue(gate.isValid)
            XCTAssertNil(proxy.audioDiagnosticsLane.currentContext())
            proxy.close()
        }
    }

    func testLostEventPacketSurvivesRepeatedBoundedHistoryAndBacklogCoalesces() async throws {
        let clock = AudioDiagnosticsClock()
        let lane = AudioClientDiagnosticsLane(now: { clock.read() })
        let nonce = UUID()
        lane.configure(negotiationID: nonce, acceptsIncoming: true)
        let event = WebRTCAudioClientEvent(sequence: 1, elapsedMilliseconds: 1, kind: .failure,
                                          failurePhase: .initialization, failureCode: 13, status: -50)
        // The first event-bearing packet is intentionally never delivered.
        for sequence in 2...40 {
            var beat = heartbeat(sequence: UInt64(sequence))
            beat.events = [event]
            lane.receive(try AudioClientDiagnosticsEnvelope(version: 1, negotiationID: nonce, heartbeat: beat).encoded())
            clock.advance()
        }
        var iterator = lane.events.makeAsyncIterator()
        guard case .heartbeat(let last)? = await iterator.next() else { return XCTFail("Missing coalesced heartbeat") }
        XCTAssertEqual(last.heartbeat.sequence, 40)
        XCTAssertEqual(last.heartbeat.events, [event])
        lane.close()
    }

    func testRealPeersNegotiateOptionalLaneAndRetireContextOnRestart() async throws {
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(configuration: .init(role: .viewer, iceServers: []))
        let recorder = AudioDiagnosticsRecorder()
        let hostForwarder = Task {
            do { for await event in host.events {
                if case .outboundSignal(let signal) = event { try await viewer.handle(signal) }
            }} catch { await recorder.fail(error) }
        }
        let viewerForwarder = Task {
            do { for await event in viewer.events {
                if case .outboundSignal(let signal) = event { try await host.handle(signal) }
            }} catch { await recorder.fail(error) }
        }
        let receiver = Task {
            for await event in host.audioClientDiagnosticsEvents {
                if case .heartbeat(let received) = event { await recorder.record(received) }
            }
        }
        do {
            try await host.start()
            try await waitUntil { await viewer.audioClientDiagnosticsIsNegotiated() }
            let contextValue = await viewer.audioClientDiagnosticsContext()
            let context = try XCTUnwrap(contextValue)
            let first = heartbeat(sequence: 1)
            try await waitUntil {
                do { try await viewer.sendAudioClientDiagnosticsHeartbeat(first, context: context); return true }
                catch { return false }
            }
            try await waitUntil { await recorder.received.count == 1 }
            let old = await recorder.received[0]
            XCTAssertEqual(old.heartbeat, first)
            try await host.restartICE()
            XCTAssertFalse(old.isValid, "Host reset must revoke an already queued wrapper synchronously")
            try await waitUntil { !context.isValid }
            try await waitUntil {
                guard let current = await viewer.audioClientDiagnosticsContext() else { return false }
                return !current.isSameNegotiation(as: context) && current.isValid
            }
            do {
                try await viewer.sendAudioClientDiagnosticsHeartbeat(first, context: context)
                XCTFail("Old sender must not adopt replacement negotiation")
            } catch {}
            let freshValue = await viewer.audioClientDiagnosticsContext()
            let fresh = try XCTUnwrap(freshValue)
            try await waitUntil {
                do { try await viewer.sendAudioClientDiagnosticsHeartbeat(first, context: fresh); return true }
                catch { return false }
            }
            try await waitUntil { await recorder.received.count == 2 }
            let recovered = await recorder.received[1]
            XCTAssertTrue(recovered.isValid)
            XCTAssertFalse(recovered.isSameNegotiation(as: old))
            let errors = await recorder.forwardingErrors
            XCTAssertTrue(errors.isEmpty, "\(errors)")
        } catch {
            _ = await host.close(reason: .protocolError)
            _ = await viewer.close(reason: .protocolError)
            hostForwarder.cancel(); viewerForwarder.cancel(); receiver.cancel()
            throw error
        }
        _ = await host.close(reason: .normal)
        _ = await viewer.close(reason: .normal)
        hostForwarder.cancel(); viewerForwarder.cancel(); receiver.cancel()
        _ = await hostForwarder.value; _ = await viewerForwarder.value; _ = await receiver.value
    }

    func testRealLegacyPeerNeverNegotiatesAudioDiagnostics() async throws {
        for enabledHost in [false, true] {
            let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: [], supportsAudioClientDiagnostics: enabledHost))
            let viewer = try WebRTCPeer.makeHeadlessViewerForTesting(configuration: .init(role: .viewer, iceServers: [], supportsAudioClientDiagnostics: !enabledHost))
            do {
                try await host.start()
                var offer: String?
                for await event in host.events {
                    if case .outboundSignal(.offer(let sdp)) = event { offer = sdp; break }
                }
                try await viewer.handle(.offer(sdp: XCTUnwrap(offer)))
                var answer: String?
                for await event in viewer.events {
                    if case .outboundSignal(.answer(let sdp)) = event { answer = sdp; break }
                }
                try await host.handle(.answer(sdp: XCTUnwrap(answer)))
                let hostNegotiated = await host.audioClientDiagnosticsIsNegotiated()
                let viewerNegotiated = await viewer.audioClientDiagnosticsIsNegotiated()
                XCTAssertFalse(hostNegotiated)
                XCTAssertFalse(viewerNegotiated)
            } catch {
                _ = await host.close(reason: .protocolError); _ = await viewer.close(reason: .protocolError)
                throw error
            }
            _ = await host.close(reason: .normal); _ = await viewer.close(reason: .normal)
        }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AudioDiagnosticsTestTimeout", code: 1)
    }

    private func heartbeat(sequence: UInt64) -> WebRTCAudioClientDiagnosticsHeartbeat {
        .init(sequence: sequence, sessionID: UUID(), build: .init(buildNumber: 66), snapshot: .init())
    }

    private func worstCaseHeartbeat() -> WebRTCAudioClientDiagnosticsHeartbeat {
        var native = WebRTCAudioClientNativeSnapshot()
        native.playoutCallbackCount = .max; native.playoutFrameCount = .max
        native.playoutFailureCount = .max; native.playoutPCMNonzeroSampleCount = .max
        native.recoveryRequestCount = .max; native.recoveryAuthorizationRejectionCount = .max
        native.recoveryRebuildCount = .max; native.captureRouteProofGeneration = .max
        native.activationCount = .max; native.failureCode = 25
        native.lastLifecycleStatus = .min; native.lastPlayoutStatus = .min
        native.sampleRate = 768_000; native.inputSampleRate = 768_000
        native.outputChannelCount = 64; native.inputChannelCount = 64
        native.outputIOBufferMicroseconds = 10_000_000; native.audioUnitSubType = .max
        var context = WebRTCAudioClientFailureContext()
        context.eventSequence = .max; context.deviceInstanceGeneration = .max
        context.systemAudioGeneration = .max; context.configurationGeneration = .max
        context.appOperationTagGeneration = .max; context.failureCode = 25; context.status = .min
        context.stage = .audioUnitInitialization; context.reason = .preferredInputConvergence
        context.sampleRate = 768_000; context.outputIOBufferMicroseconds = 10_000_000
        context.inputChannelCount = 64; context.outputChannelCount = 64
        native.failureContext = context
        var snapshot = WebRTCAudioClientSnapshot()
        snapshot.native = native; snapshot.audioPolicyID = UUID(); snapshot.recoveryAttempt = .max
        snapshot.inboundAudioBytes = .max; snapshot.inboundAudioPackets = .max
        snapshot.inboundAudioPacketsLost = .min; snapshot.inboundAudioConcealedSamples = .max
        snapshot.nativeObservationAgeMilliseconds = 86_400_000; snapshot.inboundObservationAgeMilliseconds = 86_400_000
        snapshot.inboundAudioTotalEnergy = .greatestFiniteMagnitude
        snapshot.inboundAudioSamplesDuration = .greatestFiniteMagnitude
        snapshot.authorityFailureCode = 4095; snapshot.targetMatched = false
        snapshot.playbackState = .awaitingEvidence; snapshot.proofStage = .awaitingAuthorization
        snapshot.authorization = .rejected; snapshot.retryState = .executing
        snapshot.failurePhase = .initialization
        let events: [WebRTCAudioClientEvent] = (0..<8).map {
            .init(sequence: UInt64.max - UInt64(7 - $0), elapsedMilliseconds: .max,
                  audioPolicyID: UUID(), recoveryAttempt: .max, kind: .transportChanged,
                  failurePhase: .initialization, failureCode: 25, status: .min,
                  retryState: .executing, authorization: .rejected,
                  targetMatched: false, authorityFailureCode: 4095)
        }
        return .init(sequence: .max, sessionID: UUID(),
                     build: .init(versionMajor: .max, versionMinor: .max, versionPatch: .max, buildNumber: .max),
                     snapshot: snapshot, failureSnapshot: snapshot, events: events, observedElapsedMilliseconds: .max)
    }
}
