import Foundation
import WebRTCTransport

/// Bounded, content-free evidence from the paired viewer, never an audio authorization input.
struct WorldwideAudioClientDiagnosticsSink {
    enum Finding: String, Equatable, Sendable {
        case awaitingEvidence, intentionallyPaused, authorizationUnavailable
        case transportUncertain, remoteTrackUnavailable, nativeEvidenceUnavailable
        case nativeInitializationFailed, nativeStartFailed, nativeNotInitialized, nativeNotStarted
        case policyMismatch, routeUnavailable, nativeRenderFailed, recoveryFailed
        case inboundStalled, renderStalled, renderingNonzero, renderingSilent
    }

    enum Availability: String, Equatable, Sendable {
        case awaitingHeartbeat, notNegotiated, transportRevoked, laneUnavailable, streamEnded, stopped
    }

    enum Status: Equatable, Sendable {
        case unavailable(Availability)
        case fresh(Finding)
        case stale

        var label: String {
            switch self {
            case .unavailable(let reason): return "unavailable.\(reason.rawValue)"
            case .fresh(let finding): return finding.rawValue
            case .stale: return "stale"
            }
        }
    }

    struct Latest: Sendable {
        let hostPID: Int32
        let peerGeneration: UInt64
        let negotiationEpoch: UInt64
        let status: Status
        let heartbeat: WebRTCAudioClientDiagnosticsHeartbeat?
        let receiptUptime: TimeInterval?
    }

    static let staleInterval: TimeInterval = 10
    static let minimumLogInterval: TimeInterval = 2
    static let summaryLogInterval: TimeInterval = 30
    static let maximumPendingEvents = 8

    private let hostPID: Int32
    private(set) var peerGeneration: UInt64 = 0
    private(set) var negotiationEpoch: UInt64 = 0
    private var received: WebRTCReceivedAudioClientDiagnostics?
    private var receiptTime: TimeInterval?
    private var evidenceBaseline: (snapshot: WebRTCAudioClientSnapshot, time: TimeInterval, observed: UInt64)?
    private var finding: Finding = .awaitingEvidence
    private var unavailable: Availability? = .stopped
    private var highestEventSequence: UInt64 = 0
    private(set) var pendingEvents: [WebRTCAudioClientEvent] = []
    private(set) var droppedEventCount: UInt64 = 0
    private var lastLogTime: TimeInterval?
    private var lastLogFingerprint: String?

    init(hostPID: Int32) { self.hostPID = hostPID }

    mutating func bind(peerGeneration: UInt64) {
        self.peerGeneration = peerGeneration
        negotiationEpoch = 0
        received = nil
        receiptTime = nil
        evidenceBaseline = nil
        finding = .awaitingEvidence
        unavailable = .awaitingHeartbeat
        highestEventSequence = 0
        pendingEvents.removeAll(keepingCapacity: true)
        droppedEventCount = 0
    }

    @discardableResult
    mutating func receive(
        _ value: WebRTCReceivedAudioClientDiagnostics,
        peerGeneration: UInt64,
        now: TimeInterval
    ) -> Bool {
        guard peerGeneration == self.peerGeneration, peerGeneration > 0,
              value.isValid, value.heartbeat.isValid, now.isFinite,
              receiptTime.map({ now >= $0 }) ?? true else { return false }
        let heartbeat = value.heartbeat
        let sameNegotiation = received.map { value.isSameNegotiation(as: $0) } ?? false
        if let received, sameNegotiation {
            guard heartbeat.sessionID == received.heartbeat.sessionID,
                  heartbeat.build == received.heartbeat.build,
                  heartbeat.observedElapsedMilliseconds >= received.heartbeat.observedElapsedMilliseconds,
                  heartbeat.sequence > received.heartbeat.sequence else { return false }
        } else {
            // A second still-valid authority is not evidence that the original was retired.
            guard received?.isValid != true else { return false }
            negotiationEpoch &+= 1
            if negotiationEpoch == 0 { negotiationEpoch = 1 }
            if heartbeat.sessionID != received?.heartbeat.sessionID {
                highestEventSequence = 0
                pendingEvents.removeAll(keepingCapacity: true)
                droppedEventCount = 0
            }
        }

        if !sameNegotiation { evidenceBaseline = nil }
        let elapsed = evidenceBaseline.map { now - $0.time }
        finding = Self.classify(heartbeat.snapshot, previous: evidenceBaseline?.snapshot, elapsed: elapsed,
                               observed: heartbeat.observedElapsedMilliseconds, previousObserved: evidenceBaseline?.observed)
        if evidenceBaseline == nil || (elapsed.map { $0 >= 2 } ?? true)
            || !Self.sameEvidenceEpoch(heartbeat.snapshot, evidenceBaseline!.snapshot) {
            evidenceBaseline = (heartbeat.snapshot, now, heartbeat.observedElapsedMilliseconds)
        }
        for event in heartbeat.events where event.sequence > highestEventSequence {
            highestEventSequence = event.sequence
            if pendingEvents.count == Self.maximumPendingEvents {
                pendingEvents.removeFirst()
                if droppedEventCount < UInt64.max { droppedEventCount += 1 }
            }
            pendingEvents.append(event)
        }
        received = value
        receiptTime = now
        unavailable = nil
        return true
    }

    mutating func markUnavailable(_ reason: Availability) {
        unavailable = reason
    }

    mutating func observeNegotiated(_ negotiated: Bool) {
        if !negotiated {
            if received?.isValid != true { unavailable = .notNegotiated }
        } else if unavailable == .notNegotiated {
            unavailable = .awaitingHeartbeat
        }
    }

    func latest(now: TimeInterval) -> Latest {
        let status: Status
        if let unavailable {
            status = .unavailable(unavailable)
        } else if received?.isValid != true {
            status = .unavailable(.transportRevoked)
        } else if !now.isFinite || receiptTime.map({ now < $0 || now - $0 >= Self.staleInterval }) != false {
            status = .stale
        } else {
            let ageSinceReceipt = max(0, now - (receiptTime ?? now)) * 1_000
            let snapshot = received?.heartbeat.snapshot
            switch finding {
            case .renderingNonzero, .renderingSilent, .renderStalled, .inboundStalled:
                if snapshot?.nativeObservationAgeMilliseconds.map({ Double($0) + ageSinceReceipt <= 5_000 }) != true {
                    status = .fresh(.nativeEvidenceUnavailable)
                } else if finding == .inboundStalled,
                          snapshot?.inboundObservationAgeMilliseconds.map({ Double($0) + ageSinceReceipt <= 5_000 }) != true {
                    status = .fresh(.awaitingEvidence)
                } else {
                    status = .fresh(finding)
                }
            default: status = .fresh(finding)
            }
        }
        return Latest(hostPID: hostPID, peerGeneration: peerGeneration,
                      negotiationEpoch: negotiationEpoch, status: status,
                      heartbeat: received?.heartbeat, receiptUptime: receiptTime)
    }

    mutating func logMessageIfDue(now: TimeInterval) -> String? {
        guard now.isFinite,
              lastLogTime.map({ now >= $0 + Self.minimumLogInterval }) ?? true else { return nil }
        let value = latest(now: now)
        let heartbeat = value.heartbeat
        let snapshot = heartbeat?.snapshot
        let failure = heartbeat?.failureSnapshot
        let fingerprint = "\(peerGeneration)/\(negotiationEpoch)/\(value.status.label)/"
            + "\(heartbeat?.sessionID.uuidString ?? "none")/\(snapshot?.audioPolicyID?.uuidString ?? "none")/"
            + "\(snapshot?.recoveryAttempt ?? 0)/\(snapshot?.proofStage.rawValue ?? "none")/"
            + "\(snapshot?.authorization.rawValue ?? "unknown")/\(snapshot?.retryState.rawValue ?? "idle")/"
            + "\(failure?.audioPolicyID?.uuidString ?? "none")/\(failure?.recoveryAttempt ?? 0)/"
            + "\(failure?.failurePhase.rawValue ?? "none")/\(failure?.native?.failureCode ?? 0)"
            + "/\(snapshot?.native?.failureContext?.eventSequence ?? 0)/\(failure?.native?.failureContext?.eventSequence ?? 0)"
        guard fingerprint != lastLogFingerprint || !pendingEvents.isEmpty
                || (lastLogTime.map({ now - $0 >= Self.summaryLogInterval }) ?? true) else { return nil }
        lastLogTime = now
        lastLogFingerprint = fingerprint
        let build = heartbeat.map {
            "\($0.build.versionMajor).\($0.build.versionMinor).\($0.build.versionPatch)(\($0.build.buildNumber))"
        } ?? "unknown"
        var message = "Worldwide audio client diagnostics pid=\(hostPID) peerGeneration=\(peerGeneration) "
            + "negotiationEpoch=\(negotiationEpoch) status=\(value.status.label) "
            + "session=\(heartbeat?.sessionID.uuidString ?? "none") build=\(build) "
            + "sequence=\(heartbeat?.sequence ?? 0) acousticAudibility=unverified"
        if let snapshot {
            let prefix: String
            if case .fresh = value.status { prefix = "current" } else { prefix = "lastReceived" }
            message += " " + Self.snapshotLog(snapshot, prefix: prefix)
        }
        if let failure {
            message += " " + Self.snapshotLog(failure, prefix: "retainedFailure")
        }
        if !pendingEvents.isEmpty {
            message += " events=" + pendingEvents.map {
                "\($0.sequence):\($0.kind.rawValue):policy=\($0.audioPolicyID?.uuidString ?? "none")"
                    + ":attempt=\($0.recoveryAttempt):phase=\($0.failurePhase.rawValue)"
                    + ":code=\($0.failureCode):status=\($0.status):retry=\($0.retryState.rawValue)"
                    + ":authorization=\($0.authorization.rawValue):target=\($0.targetMatched.map(String.init) ?? "unknown")"
                    + ":authorityCode=\($0.authorityFailureCode.map(String.init) ?? "none")"
            }.joined(separator: ",")
        }
        message += " droppedEvents=\(droppedEventCount)"
        pendingEvents.removeAll(keepingCapacity: true)
        droppedEventCount = 0
        return message
    }

    private static func snapshotLog(_ value: WebRTCAudioClientSnapshot, prefix: String) -> String {
        let native = value.native
        var result = "\(prefix).policy=\(value.audioPolicyID?.uuidString ?? "none") "
            + "\(prefix).attempt=\(value.recoveryAttempt) playback=\(value.playbackState.rawValue) "
            + "peerConnected=\(value.peerConnected) iceConnected=\(value.iceConnected) controlOpen=\(value.controlOpen) "
            + "trackAvailable=\(value.remoteTrackAvailable) appActive=\(value.applicationActive) "
            + "micIntent=\(value.microphoneIntent) micPermission=\(value.microphonePermissionGranted) micCallBlocked=\(value.microphoneBlockedByCall) "
            + "proof=\(value.proofStage.rawValue) authorization=\(value.authorization.rawValue) "
            + "retry=\(value.retryState.rawValue) phase=\(value.failurePhase.rawValue) "
            + "authorityFailureCode=\(value.authorityFailureCode.map(String.init) ?? "none") "
            + "targetMatched=\(value.targetMatched.map(String.init) ?? "unknown") "
            + "nativeAgeMs=\(value.nativeObservationAgeMilliseconds.map(String.init) ?? "unknown") "
            + "inboundAgeMs=\(value.inboundObservationAgeMilliseconds.map(String.init) ?? "unknown") "
            + "inboundPackets=\(value.inboundAudioPackets.map(String.init) ?? "unknown") "
            + "inboundBytes=\(value.inboundAudioBytes.map(String.init) ?? "unknown") "
            + "initialized=\(native.map { String($0.initialized) } ?? "unknown") "
            + "playoutInitialized=\(native.map { String($0.playoutInitialized) } ?? "unknown") "
            + "nativePlaying=\(native.map { String($0.playing) } ?? "unknown") "
            + "nativeActive=\(native.map { String($0.sessionActive) } ?? "unknown") "
            + "nativeOwnsActivation=\(native.map { String($0.ownsSessionActivation) } ?? "unknown") "
            + "rate=\(native?.sampleRate.map(String.init) ?? "unknown") "
            + "channels=\(native?.inputChannelCount.map(String.init) ?? "unknown")/\(native?.outputChannelCount.map(String.init) ?? "unknown") "
            + "outputRoute=\(native.map { String($0.hasOutputRoute) } ?? "unknown") "
            + "failureCode=\(native.map { String($0.failureCode) } ?? "unknown") "
            + "lifecycleStatus=\(native.map { String($0.lastLifecycleStatus) } ?? "unknown") "
            + "playoutStatus=\(native.map { String($0.lastPlayoutStatus) } ?? "unknown") "
            + "callbacks=\(native.map { String($0.playoutCallbackCount) } ?? "unknown") "
            + "frames=\(native.map { String($0.playoutFrameCount) } ?? "unknown") "
            + "nonzeroSamples=\(native.map { String($0.playoutPCMNonzeroSampleCount) } ?? "unknown")"
        if let cause = native?.failureContext {
            result += " \(prefix).historicalNativeFailure=\(cause.eventSequence) stage=\(cause.stage) reason=\(cause.reason) "
                + "deviceGeneration=\(cause.deviceInstanceGeneration) systemGeneration=\(cause.systemAudioGeneration) "
                + "configurationGeneration=\(cause.configurationGeneration) operationGeneration=\(cause.appOperationTagGeneration) "
                + "preRollbackCode=\(cause.failureCode) preRollbackStatus=\(cause.status) "
                + "preRollbackOutputRoute=\(cause.hasOutputRoute) preRollbackInputRequired=\(cause.inputRequired) "
                + "preRollbackActive=\(cause.sessionActive) preRollbackOwnsActivation=\(cause.ownsSessionActivation) "
                + "preRollbackPlaybackCategory=\(cause.categoryIsMediaPlayback) preRollbackDuplexCategory=\(cause.categoryIsMediaPlayAndRecord) "
                + "preRollbackDefaultMode=\(cause.modeIsDefault) preRollbackOptionsEmpty=\(cause.categoryOptionsAreEmpty) "
                + "preRollbackRate=\(cause.sampleRate.map(String.init) ?? "unknown") "
                + "preRollbackChannels=\(cause.inputChannelCount)/\(cause.outputChannelCount)"
        }
        return result
    }

    static func classify(
        _ current: WebRTCAudioClientSnapshot,
        previous: WebRTCAudioClientSnapshot?,
        elapsed: TimeInterval?,
        observed: UInt64? = nil,
        previousObserved: UInt64? = nil
    ) -> Finding {
        if current.playbackState == .paused { return .intentionallyPaused }
        guard current.peerConnected, current.iceConnected, current.controlOpen else { return .transportUncertain }
        if current.retryState == .executing, current.proofStage == .awaitingAuthorization {
            return .awaitingEvidence
        }
        if current.targetMatched == false,
           current.failurePhase == .none || current.failurePhase == .evidence {
            return .policyMismatch
        }
        let currentPlaybackProven = current.playbackState == .playing && current.proofStage == .complete
            && current.targetMatched == true && current.native?.playing == true
        switch currentPlaybackProven ? .none : current.failurePhase {
        case .initialization: return .nativeInitializationFailed
        case .start: return .nativeStartFailed
        case .route: return .routeUnavailable
        case .authorization: return .authorizationUnavailable
        case .render: return .nativeRenderFailed
        case .session, .evidence, .retirement, .unknown: return .recoveryFailed
        case .none: break
        }
        if current.targetMatched == false { return .policyMismatch }
        if !currentPlaybackProven && (current.authorization == .absent || current.authorization == .revoked
            || current.authorization == .rejected) { return .authorizationUnavailable }
        guard current.remoteTrackAvailable else { return .remoteTrackUnavailable }
        guard let native = current.native else { return .awaitingEvidence }
        guard let nativeAge = current.nativeObservationAgeMilliseconds, nativeAge <= 5_000 else {
            return .nativeEvidenceUnavailable
        }
        guard native.hasOutputRoute else { return .routeUnavailable }
        guard native.initialized, native.playoutInitialized else { return .nativeNotInitialized }
        guard native.playing else { return .nativeNotStarted }
        guard let previous, let before = previous.native, let elapsed,
              elapsed >= 2, elapsed < staleInterval,
              previous.nativeObservationAgeMilliseconds.map({ $0 <= 5_000 }) == true,
              let nativeObservation = observationTime(observed, age: current.nativeObservationAgeMilliseconds),
              let previousNativeObservation = observationTime(previousObserved, age: previous.nativeObservationAgeMilliseconds),
              nativeObservation > previousNativeObservation,
              sameEvidenceEpoch(current, previous),
              native.playoutCallbackCount >= before.playoutCallbackCount,
              native.playoutFrameCount >= before.playoutFrameCount,
              native.playoutPCMNonzeroSampleCount >= before.playoutPCMNonzeroSampleCount else {
            return .awaitingEvidence
        }
        if current.inboundObservationAgeMilliseconds.map({ $0 <= 5_000 }) == true,
           previous.inboundObservationAgeMilliseconds.map({ $0 <= 5_000 }) == true,
           let inboundObservation = observationTime(observed, age: current.inboundObservationAgeMilliseconds),
           let previousInboundObservation = observationTime(previousObserved, age: previous.inboundObservationAgeMilliseconds),
           inboundObservation > previousInboundObservation,
           let packets = current.inboundAudioPackets, let previousPackets = previous.inboundAudioPackets,
           let bytes = current.inboundAudioBytes, let previousBytes = previous.inboundAudioBytes {
            guard packets >= previousPackets, bytes >= previousBytes else { return .awaitingEvidence }
            if packets == previousPackets && bytes == previousBytes { return .inboundStalled }
        }
        if native.playoutCallbackCount > before.playoutCallbackCount,
           native.playoutFrameCount > before.playoutFrameCount {
            return native.playoutPCMNonzeroSampleCount > before.playoutPCMNonzeroSampleCount
                ? .renderingNonzero : .renderingSilent
        }
        return .renderStalled
    }

    private static func sameEvidenceEpoch(_ current: WebRTCAudioClientSnapshot,
                                          _ previous: WebRTCAudioClientSnapshot) -> Bool {
        guard let policyID = current.audioPolicyID, policyID == previous.audioPolicyID,
              current.recoveryAttempt == previous.recoveryAttempt,
              let native = current.native, let before = previous.native else { return false }
        return native.recoveryRebuildCount == before.recoveryRebuildCount
            && native.captureRouteProofGeneration == before.captureRouteProofGeneration
            && native.playoutCallbackCount >= before.playoutCallbackCount
            && native.playoutFrameCount >= before.playoutFrameCount
            && native.playoutPCMNonzeroSampleCount >= before.playoutPCMNonzeroSampleCount
    }

    private static func observationTime(_ observed: UInt64?, age: UInt64?) -> UInt64? {
        guard let observed, let age, observed >= age else { return nil }
        return observed - age
    }
}
