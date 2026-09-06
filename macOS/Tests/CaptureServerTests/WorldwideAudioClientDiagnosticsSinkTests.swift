import Foundation
@testable import CaptureServer
@testable import WebRTCTransport
import XCTest

final class WorldwideAudioClientDiagnosticsSinkTests: XCTestCase {
    private let sessionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let policyID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let build = WebRTCAudioClientBuild(versionMinor: 1, buildNumber: 66)

    func testLatestAndLogBindExactHostPeerNegotiationClientBuildAndPolicy() throws {
        var sink = makeSink()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: context()), peerGeneration: 7, now: 0))
        let latest = sink.latest(now: 0)
        XCTAssertEqual(latest.hostPID, 123)
        XCTAssertEqual(latest.peerGeneration, 7)
        XCTAssertEqual(latest.negotiationEpoch, 1)
        XCTAssertEqual(latest.heartbeat?.sessionID, sessionID)
        XCTAssertEqual(latest.heartbeat?.build, build)
        XCTAssertEqual(latest.heartbeat?.snapshot.audioPolicyID, policyID)
        let log = try XCTUnwrap(sink.logMessageIfDue(now: 0))
        for marker in ["pid=123", "peerGeneration=7", "negotiationEpoch=1", "build=0.1.0(66)",
                       "session=\(sessionID)", "current.policy=\(policyID)", "acousticAudibility=unverified"] {
            XCTAssertTrue(log.contains(marker), marker)
        }
    }

    func testWrongPeerAndRevokedAuthorityCannotPublishOrAdvanceReceipt() {
        var sink = makeSink()
        let token = context()
        XCTAssertFalse(sink.receive(received(sequence: 1, context: token), peerGeneration: 8, now: 0))
        token.authorization.revoke()
        XCTAssertFalse(sink.receive(received(sequence: 1, context: token), peerGeneration: 7, now: 0))
        XCTAssertNil(sink.latest(now: 0).heartbeat)
        XCTAssertEqual(sink.latest(now: 0).negotiationEpoch, 0)
    }

    func testRevocationMakesRetainedEvidenceUnavailableWithoutAnotherHeartbeat() throws {
        var sink = makeSink()
        let token = context()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: token), peerGeneration: 7, now: 0))
        _ = sink.logMessageIfDue(now: 0)
        token.authorization.revoke()
        XCTAssertEqual(sink.latest(now: 1).status, .unavailable(.transportRevoked))
        let log = try XCTUnwrap(sink.logMessageIfDue(now: 2))
        XCTAssertTrue(log.contains("status=unavailable.transportRevoked"))
        XCTAssertTrue(log.contains("lastReceived.policy="))
        XCTAssertFalse(log.contains("current.policy="))
    }

    func testNewNegotiationRequiresRetirementAndCannotReuseCounterBaseline() {
        var sink = makeSink()
        let old = context()
        let new = context()
        XCTAssertTrue(sink.receive(received(sequence: 9, context: old), peerGeneration: 7, now: 0))
        XCTAssertFalse(sink.receive(received(sequence: 1, context: new), peerGeneration: 7, now: 3))
        old.authorization.revoke()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: new, snapshot: healthy(counter: 500)),
                                   peerGeneration: 7, now: 3))
        XCTAssertEqual(sink.latest(now: 3).negotiationEpoch, 2)
        XCTAssertEqual(sink.latest(now: 3).status, .fresh(.awaitingEvidence))
        XCTAssertFalse(sink.receive(received(sequence: 10, context: old), peerGeneration: 7, now: 4))
        XCTAssertEqual(sink.latest(now: 4).heartbeat?.sequence, 1)
    }

    func testSessionAndBuildDriftInsideOneNegotiationAreRejected() {
        var sink = makeSink()
        let token = context()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: token), peerGeneration: 7, now: 0))
        var changed = received(sequence: 2, context: token).heartbeat
        changed.sessionID = UUID()
        XCTAssertFalse(sink.receive(.init(heartbeat: changed, context: token), peerGeneration: 7, now: 3))
        changed.sessionID = sessionID
        changed.build.buildNumber += 1
        XCTAssertFalse(sink.receive(.init(heartbeat: changed, context: token), peerGeneration: 7, now: 3))
        XCTAssertEqual(sink.latest(now: 10).status, .stale)
    }

    func testDuplicateOutOfOrderAndInvalidHeartbeatsDoNotRefreshStaleness() {
        var sink = makeSink()
        let token = context()
        XCTAssertTrue(sink.receive(received(sequence: 5, context: token), peerGeneration: 7, now: 0))
        for sequence in [UInt64(5), 4, 0] {
            XCTAssertFalse(sink.receive(received(sequence: sequence, context: token), peerGeneration: 7, now: 9))
        }
        XCTAssertEqual(sink.latest(now: 10).status, .stale)
    }

    func testFreshnessAndUnavailableStatusDoNotRequireTransportStatistics() throws {
        var sink = makeSink()
        let token = context()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: token), peerGeneration: 7, now: 0))
        _ = sink.logMessageIfDue(now: 0)
        XCTAssertEqual(sink.latest(now: 9.9).status, .fresh(.awaitingEvidence))
        XCTAssertEqual(sink.latest(now: 10).status, .stale)
        XCTAssertTrue(try XCTUnwrap(sink.logMessageIfDue(now: 10)).contains("status=stale"))
        sink.markUnavailable(.streamEnded)
        XCTAssertEqual(sink.latest(now: 12).status, .unavailable(.streamEnded))
        sink.markUnavailable(.stopped)
        XCTAssertEqual(sink.latest(now: 14).status, .unavailable(.stopped))
    }

    func testLateUnnegotiatedObservationCannotReplaceCurrentValidHeartbeat() {
        var sink = makeSink()
        sink.observeNegotiated(false)
        XCTAssertEqual(sink.latest(now: 0).status, .unavailable(.notNegotiated))
        sink.observeNegotiated(true)
        XCTAssertEqual(sink.latest(now: 0).status, .unavailable(.awaitingHeartbeat))
        XCTAssertTrue(sink.receive(received(sequence: 1, context: context()), peerGeneration: 7, now: 0))
        sink.observeNegotiated(false)
        XCTAssertEqual(sink.latest(now: 0).status, .fresh(.awaitingEvidence))
    }

    func testRepeatedEventHistoryIsLoggedOnceAcrossNegotiationRecovery() throws {
        var sink = makeSink()
        let old = context()
        let event = event(sequence: 1)
        XCTAssertTrue(sink.receive(received(sequence: 1, context: old, events: [event]), peerGeneration: 7, now: 0))
        XCTAssertTrue(try XCTUnwrap(sink.logMessageIfDue(now: 0)).contains("events=1:failure"))
        old.authorization.revoke()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: context(), events: [event]), peerGeneration: 7, now: 3))
        XCTAssertTrue(sink.pendingEvents.isEmpty)
        XCTAssertFalse(try XCTUnwrap(sink.logMessageIfDue(now: 3)).contains("events="))
    }

    func testEventBufferAndOutputRateRemainBoundedDuringFailureFlood() throws {
        var sink = makeSink()
        let token = context()
        var logs: [String] = []
        for ordinal in 1...1_000 {
            let now = Double(ordinal - 1) / 100
            let events = [event(sequence: UInt64(ordinal))]
            XCTAssertTrue(sink.receive(received(sequence: UInt64(ordinal), context: token, events: events),
                                       peerGeneration: 7, now: now))
            if let log = sink.logMessageIfDue(now: now) { logs.append(log) }
            XCTAssertLessThanOrEqual(sink.pendingEvents.count, 8)
        }
        XCTAssertLessThanOrEqual(logs.count, 5)
        XCTAssertGreaterThan(sink.droppedEventCount, 0)
        let final = try XCTUnwrap(sink.logMessageIfDue(now: 10))
        XCTAssertTrue(final.contains("1000:failure"))
        XCTAssertFalse(final.contains("1:failure:"))
        XCTAssertTrue(sink.pendingEvents.isEmpty)
        XCTAssertNil(sink.logMessageIfDue(now: 11))
    }

    func testUnchangedStatusSummarizesAtThirtySecondsInsteadOfEveryHeartbeat() {
        var sink = makeSink()
        let token = context()
        var snapshot = healthy()
        snapshot.playbackState = .paused
        var logs = 0
        for second in 0...29 {
            XCTAssertTrue(sink.receive(received(sequence: UInt64(second + 1), context: token, snapshot: snapshot),
                                       peerGeneration: 7, now: Double(second)))
            if sink.logMessageIfDue(now: Double(second)) != nil { logs += 1 }
        }
        XCTAssertEqual(logs, 1)
        XCTAssertNotNil(sink.logMessageIfDue(now: 30))
    }

    func testRetainedFailureKeepsItsOwnPolicyAttemptAndNativeFailureEvidence() throws {
        var sink = makeSink()
        var heartbeat = received(sequence: 1, context: context()).heartbeat
        var failure = healthy()
        failure.audioPolicyID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        failure.recoveryAttempt = 4
        failure.failurePhase = .initialization
        failure.native?.failureCode = 3
        failure.native?.lastLifecycleStatus = -50
        heartbeat.failureSnapshot = failure
        XCTAssertTrue(sink.receive(.init(heartbeat: heartbeat, context: context()), peerGeneration: 7, now: 0))
        let log = try XCTUnwrap(sink.logMessageIfDue(now: 0))
        XCTAssertTrue(log.contains("current.policy=\(policyID)"))
        XCTAssertTrue(log.contains("retainedFailure.policy=\(failure.audioPolicyID!)"))
        XCTAssertTrue(log.contains("retainedFailure.attempt=4"))
        XCTAssertTrue(log.contains("phase=initialization"))
        XCTAssertTrue(log.contains("lifecycleStatus=-50"))
        XCTAssertEqual(sink.latest(now: 0).status, .fresh(.awaitingEvidence))
    }

    func testNativeFailureAndPolicyRouteClassificationsAreDistinct() {
        var current = healthy()
        current.playbackState = .failed
        let cases: [(WebRTCAudioClientFailurePhase, WorldwideAudioClientDiagnosticsSink.Finding)] = [
            (.initialization, .nativeInitializationFailed), (.start, .nativeStartFailed),
            (.route, .routeUnavailable), (.authorization, .authorizationUnavailable),
            (.render, .nativeRenderFailed), (.retirement, .recoveryFailed)
        ]
        for (phase, expected) in cases {
            current.failurePhase = phase
            XCTAssertEqual(classify(current), expected)
        }
        current.failurePhase = .evidence
        current.targetMatched = false
        XCTAssertEqual(classify(current), .policyMismatch)
        current.failurePhase = .none
        current.targetMatched = true
        current.native?.hasOutputRoute = false
        XCTAssertEqual(classify(current), .routeUnavailable)
        current.native?.hasOutputRoute = true
        current.native?.playoutInitialized = false
        XCTAssertEqual(classify(current), .nativeNotInitialized)
        current.native?.playoutInitialized = true
        current.native?.playing = false
        XCTAssertEqual(classify(current), .nativeNotStarted)
        current.playbackState = .paused
        XCTAssertEqual(classify(current), .intentionallyPaused)
    }

    func testInboundStallRenderStallNonzeroAndSilenceAreIndependentEvidence() {
        let previous = healthy()
        var current = healthy(counter: 20)
        XCTAssertEqual(classify(current, previous: previous), .renderingNonzero)
        current.native?.playoutPCMNonzeroSampleCount = previous.native!.playoutPCMNonzeroSampleCount
        XCTAssertEqual(classify(current, previous: previous), .renderingSilent)
        current.native?.playoutCallbackCount = previous.native!.playoutCallbackCount
        XCTAssertEqual(classify(current, previous: previous), .renderStalled)
        current.inboundAudioPackets = previous.inboundAudioPackets
        current.inboundAudioBytes = previous.inboundAudioBytes
        XCTAssertEqual(classify(current, previous: previous), .inboundStalled)
        current.inboundAudioPackets = nil
        current.inboundAudioBytes = nil
        current.native?.playoutCallbackCount = 20
        XCTAssertEqual(classify(current, previous: previous), .renderingSilent)
    }

    func testDifferentPolicyRebuildRouteOrRegressedCountersNeverFormAProgressWindow() {
        let previous = healthy()
        var current = healthy(counter: 20)
        current.audioPolicyID = UUID()
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 20)
        current.recoveryAttempt += 1
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 20)
        current.native?.recoveryRebuildCount += 1
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 20)
        current.native?.captureRouteProofGeneration += 1
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 1)
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 20)
        XCTAssertEqual(WorldwideAudioClientDiagnosticsSink.classify(current, previous: previous, elapsed: 10), .awaitingEvidence)
        current.audioPolicyID = nil
        var missingPolicy = previous
        missingPolicy.audioPolicyID = nil
        XCTAssertEqual(classify(current, previous: missingPolicy), .awaitingEvidence)
    }

    func testFreshPeerClearsOldSessionReceiptsButDoesNotResetLogRateLimit() {
        var sink = makeSink()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: context(), events: [event(sequence: 1)]),
                                   peerGeneration: 7, now: 0))
        XCTAssertNotNil(sink.logMessageIfDue(now: 0))
        sink.bind(peerGeneration: 8)
        XCTAssertNil(sink.latest(now: 1).heartbeat)
        XCTAssertTrue(sink.pendingEvents.isEmpty)
        XCTAssertNil(sink.logMessageIfDue(now: 1))
        XCTAssertNotNil(sink.logMessageIfDue(now: 2))
    }

    func testFrequentHeartbeatsAccumulateAnEvidenceWindowInsteadOfPerpetuallyAwaiting() {
        var sink = makeSink()
        let token = context()
        for ordinal in 0...20 {
            XCTAssertTrue(sink.receive(received(sequence: UInt64(ordinal + 1), context: token,
                                                snapshot: healthy(counter: UInt64(ordinal + 10))),
                                       peerGeneration: 7, now: Double(ordinal) / 10))
        }
        XCTAssertEqual(sink.latest(now: 2).status, .fresh(.renderingNonzero))
    }

    func testCachedNativeAndInboundSnapshotsAreNotFreshProgressOrStallEvidence() {
        let previous = healthy()
        var current = healthy(counter: 20)
        current.nativeObservationAgeMilliseconds = 5_001
        XCTAssertEqual(classify(current, previous: previous), .nativeEvidenceUnavailable)
        current.nativeObservationAgeMilliseconds = nil
        XCTAssertEqual(classify(current, previous: previous), .nativeEvidenceUnavailable)
        current = healthy(counter: 20)
        current.inboundObservationAgeMilliseconds = 5_001
        current.inboundAudioPackets = previous.inboundAudioPackets
        current.inboundAudioBytes = previous.inboundAudioBytes
        XCTAssertEqual(classify(current, previous: previous), .renderingNonzero)
    }

    func testSameCachedObservationWithinTTLIsNotAStallWindow() {
        let previous = healthy()
        var current = previous
        current.nativeObservationAgeMilliseconds = 3_000
        current.inboundObservationAgeMilliseconds = 3_000
        XCTAssertEqual(classify(current, previous: previous), .awaitingEvidence)
        current = healthy(counter: 20)
        current.inboundAudioPackets = previous.inboundAudioPackets
        current.inboundAudioBytes = previous.inboundAudioBytes
        current.inboundObservationAgeMilliseconds = 3_000
        XCTAssertEqual(classify(current, previous: previous), .renderingNonzero)
    }

    func testLatestAgesNativeEvidenceBeforeHeartbeatStaleDeadline() {
        var sink = makeSink()
        let token = context()
        XCTAssertTrue(sink.receive(received(sequence: 1, context: token), peerGeneration: 7, now: 0))
        XCTAssertTrue(sink.receive(received(sequence: 2, context: token, snapshot: healthy(counter: 20)),
                                   peerGeneration: 7, now: 3))
        XCTAssertEqual(sink.latest(now: 3).status, .fresh(.renderingNonzero))
        XCTAssertEqual(sink.latest(now: 8.001).status, .fresh(.nativeEvidenceUnavailable))
        XCTAssertEqual(sink.latest(now: 13).status, .stale)
    }

    func testNegotiationAuthorityDoesNotSubstituteForReportedTransportHealth() {
        var current = healthy(counter: 20)
        current.iceConnected = false
        XCTAssertEqual(classify(current, previous: healthy()), .transportUncertain)
        current = healthy(counter: 20)
        current.remoteTrackAvailable = false
        XCTAssertEqual(classify(current, previous: healthy()), .remoteTrackUnavailable)
    }

    func testObsoleteRejectedAttemptDoesNotEraseSeparatelyProvenCurrentRendering() {
        var current = healthy(counter: 20)
        current.failurePhase = .authorization
        current.authorityFailureCode = 3
        current.authorization = .rejected
        current.retryState = .rejected
        XCTAssertEqual(classify(current, previous: healthy()), .renderingNonzero)
    }

    func testExecutingRecoveryBaselineDoesNotAttributePredecessorFailureToNewAttempt() {
        var current = healthy()
        current.recoveryAttempt = 2
        current.retryState = .executing
        current.proofStage = .awaitingAuthorization
        current.playbackState = .failed
        current.failurePhase = .initialization
        current.targetMatched = false
        current.native?.playoutInitialized = false
        current.native?.failureCode = 3
        XCTAssertEqual(classify(current), .awaitingEvidence)
        current.proofStage = .failed
        current.retryState = .failed
        XCTAssertEqual(classify(current), .nativeInitializationFailed)
    }

    func testLargestTypedSummaryHasBoundedSizeAndNoRawPayloadFields() throws {
        var sink = makeSink()
        var heartbeat = received(sequence: .max, context: context(), snapshot: healthy(counter: .max / 1_000)).heartbeat
        heartbeat.events = (1...8).map { event(sequence: UInt64($0), attempt: .max) }
        heartbeat.failureSnapshot = heartbeat.snapshot
        XCTAssertTrue(sink.receive(.init(heartbeat: heartbeat, context: context()), peerGeneration: 7, now: 0))
        let log = try XCTUnwrap(sink.logMessageIfDue(now: 0))
        XCTAssertLessThan(log.utf8.count, 6_144)
        for forbidden in ["SDP", "SSRC", "trackID", "routeName", "NSError", "title", "artist", "PCM="] {
            XCTAssertFalse(log.contains(forbidden), forbidden)
        }
        XCTAssertTrue(log.contains("acousticAudibility=unverified"))
    }

    private func makeSink() -> WorldwideAudioClientDiagnosticsSink {
        var sink = WorldwideAudioClientDiagnosticsSink(hostPID: 123)
        sink.bind(peerGeneration: 7)
        return sink
    }

    private func context() -> WebRTCAudioClientDiagnosticsContext {
        .init(negotiationID: UUID(), authorization: WebRTCControlAuthorization())
    }

    private func received(sequence: UInt64, context: WebRTCAudioClientDiagnosticsContext,
                          snapshot: WebRTCAudioClientSnapshot? = nil,
                          events: [WebRTCAudioClientEvent] = []) -> WebRTCReceivedAudioClientDiagnostics {
        .init(heartbeat: .init(sequence: sequence, sessionID: sessionID, build: build,
                               snapshot: snapshot ?? healthy(), events: events,
                               observedElapsedMilliseconds: min(sequence, UInt64.max / 3_000) * 3_000), context: context)
    }

    private func event(sequence: UInt64, attempt: UInt64 = 1) -> WebRTCAudioClientEvent {
        .init(sequence: sequence, elapsedMilliseconds: sequence, audioPolicyID: policyID,
              recoveryAttempt: attempt, kind: .failure, failurePhase: .initialization,
              failureCode: 3, status: -50)
    }

    private func healthy(counter: UInt64 = 10) -> WebRTCAudioClientSnapshot {
        var value = WebRTCAudioClientSnapshot()
        value.peerConnected = true
        value.iceConnected = true
        value.controlOpen = true
        value.remoteTrackAvailable = true
        value.nativeObservationAgeMilliseconds = 0
        value.inboundObservationAgeMilliseconds = 0
        value.audioPolicyID = policyID
        value.authorization = .valid
        value.playbackState = .playing
        value.proofStage = .complete
        value.targetMatched = true
        value.inboundAudioPackets = counter
        value.inboundAudioBytes = counter * 100
        var native = WebRTCAudioClientNativeSnapshot()
        native.initialized = true
        native.playoutInitialized = true
        native.playing = true
        native.hasOutputRoute = true
        native.playoutCallbackCount = counter
        native.playoutFrameCount = counter * 100
        native.playoutPCMNonzeroSampleCount = counter * 200
        value.native = native
        return value
    }

    private func classify(_ value: WebRTCAudioClientSnapshot,
                          previous: WebRTCAudioClientSnapshot? = nil) -> WorldwideAudioClientDiagnosticsSink.Finding {
        WorldwideAudioClientDiagnosticsSink.classify(value, previous: previous, elapsed: 3,
                                                      observed: 6_000, previousObserved: 3_000)
    }
}
