import Foundation

public enum WebRTCAudioClientPlaybackState: String, Codable, Equatable, Sendable {
    case unavailable
    case awaitingEvidence
    case playing
    case paused
    case failed
}

public enum WebRTCAudioClientProofStage: String, Codable, Equatable, Sendable {
    case none
    case awaitingAuthorization
    case awaitingNative
    case awaitingEvidence
    case complete
    case failed
}

public enum WebRTCAudioClientAuthorization: String, Codable, Equatable, Sendable {
    case unknown
    case absent
    case valid
    case revoked
    case rejected
}

public enum WebRTCAudioClientRetryState: String, Codable, Equatable, Sendable {
    case idle
    case requested
    case executing
    case accepted
    case rejected
    case failed
}

public enum WebRTCAudioClientFailurePhase: String, Codable, Equatable, Sendable {
    case none
    case authorization
    case session
    case route
    case initialization
    case start
    case render
    case evidence
    case retirement
    case unknown
}

public enum WebRTCAudioClientEventKind: String, Codable, Equatable, Sendable {
    case sessionStarted
    case policyChanged
    case retryRequested
    case nativeReceipt
    case failure
    case recovered
    case transportChanged
    case interruption
    case routeChanged
}

public struct WebRTCAudioClientBuild: Codable, Equatable, Sendable {
    public var versionMajor: UInt16 = 0
    public var versionMinor: UInt16 = 0
    public var versionPatch: UInt16 = 0
    public var buildNumber: UInt32 = 0
    public init(versionMajor: UInt16 = 0, versionMinor: UInt16 = 0,
                versionPatch: UInt16 = 0, buildNumber: UInt32 = 0) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.versionPatch = versionPatch
        self.buildNumber = buildNumber
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case versionMajor = "a", versionMinor = "b", versionPatch = "c", buildNumber = "d"
    }
}

/// Only structural evidence, never route names, NSError messages, audio samples or identifiers.
public struct WebRTCAudioClientNativeSnapshot: Codable, Equatable, Sendable {
    public var initialized: Bool = false
    public var playoutInitialized: Bool = false
    public var playing: Bool = false
    public var sessionActive: Bool = false
    public var ownsSessionActivation: Bool = false
    public var remoteIOCreated: Bool = false
    public var inputBusEnabled: Bool = false
    public var outputBusEnabled: Bool = false
    public var hasOutputRoute: Bool = false
    public var captureRouteIsBuiltInMicrophone: Bool = false
    public var recoveryRequired: Bool = false
    public var explicitResumeRequired: Bool = false
    public var categoryIsMediaPlayback: Bool = false
    public var categoryIsMediaPlayAndRecord: Bool = false
    public var modeIsDefault: Bool = false
    public var categoryOptionsAreEmpty: Bool = false
    public var categoryOptionsAreIPhoneMicrophoneRouting: Bool = false
    public var routeSharingPolicyIsDefault: Bool = false
    public var sampleRate: UInt32? = nil
    public var inputSampleRate: UInt32? = nil
    public var outputChannelCount: UInt16? = nil
    public var inputChannelCount: UInt16? = nil
    public var outputIOBufferMicroseconds: UInt32? = nil
    public var audioUnitSubType: UInt32 = 0
    public var activationCount: UInt64? = nil
    public var failureCode: Int32 = 0
    public var lastLifecycleStatus: Int32 = 0
    public var lastPlayoutStatus: Int32 = 0
    public var playoutCallbackCount: UInt64 = 0
    public var playoutFrameCount: UInt64 = 0
    public var playoutFailureCount: UInt64 = 0
    public var playoutPCMNonzeroSampleCount: UInt64 = 0
    public var recoveryRequestCount: UInt64 = 0
    public var recoveryAuthorizationRejectionCount: UInt64 = 0
    public var recoveryRebuildCount: UInt64 = 0
    public var captureRouteProofGeneration: UInt64 = 0
    public var failureContext: WebRTCAudioClientFailureContext? = nil
    public init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case initialized = "0"
        case playoutInitialized = "1"
        case playing = "2"
        case sessionActive = "3"
        case ownsSessionActivation = "4"
        case remoteIOCreated = "5"
        case inputBusEnabled = "6"
        case outputBusEnabled = "7"
        case hasOutputRoute = "8"
        case captureRouteIsBuiltInMicrophone = "9"
        case recoveryRequired = "a"
        case explicitResumeRequired = "b"
        case categoryIsMediaPlayback = "c"
        case categoryIsMediaPlayAndRecord = "d"
        case modeIsDefault = "e"
        case categoryOptionsAreEmpty = "f"
        case categoryOptionsAreIPhoneMicrophoneRouting = "g"
        case routeSharingPolicyIsDefault = "h"
        case sampleRate = "i"
        case inputSampleRate = "j"
        case outputChannelCount = "k"
        case inputChannelCount = "l"
        case outputIOBufferMicroseconds = "m"
        case audioUnitSubType = "n"
        case activationCount = "o"
        case failureCode = "p"
        case lastLifecycleStatus = "q"
        case lastPlayoutStatus = "r"
        case playoutCallbackCount = "s"
        case playoutFrameCount = "t"
        case playoutFailureCount = "u"
        case playoutPCMNonzeroSampleCount = "v"
        case recoveryRequestCount = "w"
        case recoveryAuthorizationRejectionCount = "x"
        case recoveryRebuildCount = "y"
        case captureRouteProofGeneration = "z"
        case failureContext = "A"
    }
    var isValid: Bool {
        failureCode >= 0 && failureCode <= 25
            && (failureContext?.isValid ?? true)
            && (sampleRate.map { $0 <= 768_000 } ?? true)
            && (inputSampleRate.map { $0 <= 768_000 } ?? true)
            && (outputChannelCount.map { $0 <= 64 } ?? true)
            && (inputChannelCount.map { $0 <= 64 } ?? true)
            && (outputIOBufferMicroseconds.map { $0 <= 10_000_000 } ?? true)
    }
}

public struct WebRTCAudioClientSnapshot: Codable, Equatable, Sendable {
    public var peerConnected: Bool = false
    public var iceConnected: Bool = false
    public var controlOpen: Bool = false
    public var applicationActive: Bool = false
    public var remoteTrackAvailable: Bool = false
    public var microphoneIntent: Bool = false
    public var microphonePermissionGranted: Bool = false
    public var microphoneBlockedByCall: Bool = false
    public var audioPolicyID: UUID? = nil
    public var recoveryAttempt: UInt64 = 0
    public var playbackState: WebRTCAudioClientPlaybackState = .unavailable
    public var proofStage: WebRTCAudioClientProofStage = .none
    public var authorization: WebRTCAudioClientAuthorization = .unknown
    public var retryState: WebRTCAudioClientRetryState = .idle
    public var failurePhase: WebRTCAudioClientFailurePhase = .none
    public var authorityFailureCode: UInt16? = nil
    public var targetMatched: Bool? = nil
    public var native: WebRTCAudioClientNativeSnapshot? = nil
    public var inboundAudioPackets: UInt64? = nil
    public var inboundAudioBytes: UInt64? = nil
    public var inboundAudioPacketsLost: Int64? = nil
    public var inboundAudioConcealedSamples: UInt64? = nil
    public var nativeObservationAgeMilliseconds: UInt64? = nil
    public var inboundObservationAgeMilliseconds: UInt64? = nil
    public var inboundAudioTotalEnergy: Double? = nil
    public var inboundAudioSamplesDuration: Double? = nil
    public init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case audioPolicyID = "0"
        case recoveryAttempt = "1"
        case playbackState = "2"
        case proofStage = "3"
        case authorization = "4"
        case retryState = "5"
        case failurePhase = "6"
        case targetMatched = "7"
        case native = "8"
        case inboundAudioPackets = "9"
        case inboundAudioBytes = "a"
        case inboundAudioPacketsLost = "b"
        case inboundAudioConcealedSamples = "c"
        case nativeObservationAgeMilliseconds = "d", inboundObservationAgeMilliseconds = "e"
        case inboundAudioTotalEnergy = "f", inboundAudioSamplesDuration = "g"
        case authorityFailureCode = "h"
        case peerConnected = "i"
        case iceConnected = "j"
        case controlOpen = "k"
        case applicationActive = "l"
        case remoteTrackAvailable = "m"
        case microphoneIntent = "n"
        case microphonePermissionGranted = "o"
        case microphoneBlockedByCall = "p"
    }
    var isValid: Bool {
        (native?.isValid ?? true)
            && (authorityFailureCode.map { $0 <= 4095 } ?? true)
            && (nativeObservationAgeMilliseconds.map { $0 <= 86_400_000 } ?? true)
            && (inboundObservationAgeMilliseconds.map { $0 <= 86_400_000 } ?? true)
            && (inboundAudioTotalEnergy.map { $0.isFinite && $0 >= 0 } ?? true)
            && (inboundAudioSamplesDuration.map { $0.isFinite && $0 >= 0 } ?? true)
    }
}

public struct WebRTCAudioClientEvent: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var elapsedMilliseconds: UInt64
    public var audioPolicyID: UUID?
    public var recoveryAttempt: UInt64
    public var kind: WebRTCAudioClientEventKind
    public var failurePhase: WebRTCAudioClientFailurePhase
    public var failureCode: Int32
    public var status: Int32
    public var retryState: WebRTCAudioClientRetryState
    public var authorization: WebRTCAudioClientAuthorization
    public var targetMatched: Bool?
    public var authorityFailureCode: UInt16?
    public init(sequence: UInt64, elapsedMilliseconds: UInt64, audioPolicyID: UUID? = nil,
                recoveryAttempt: UInt64 = 0, kind: WebRTCAudioClientEventKind,
                failurePhase: WebRTCAudioClientFailurePhase = .none,
                failureCode: Int32 = 0, status: Int32 = 0,
                retryState: WebRTCAudioClientRetryState = .idle,
                authorization: WebRTCAudioClientAuthorization = .unknown,
                targetMatched: Bool? = nil, authorityFailureCode: UInt16? = nil) {
        self.sequence = sequence
        self.elapsedMilliseconds = elapsedMilliseconds
        self.audioPolicyID = audioPolicyID
        self.recoveryAttempt = recoveryAttempt
        self.kind = kind
        self.failurePhase = failurePhase
        self.failureCode = failureCode
        self.status = status
        self.retryState = retryState
        self.authorization = authorization
        self.targetMatched = targetMatched
        self.authorityFailureCode = authorityFailureCode
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence = "s", elapsedMilliseconds = "t", audioPolicyID = "p"
        case recoveryAttempt = "r", kind = "k", failurePhase = "f"
        case failureCode = "c", status = "e"
        case retryState = "y", authorization = "a", targetMatched = "m", authorityFailureCode = "d"
    }
}

/// Retain and repeat the most recent events and first unresolved failure snapshot across losses.
/// Correlation UUIDs must be freshly generated per media session/policy, never persistent identity.
public struct WebRTCAudioClientDiagnosticsHeartbeat: Codable, Equatable, Sendable {
    public static let maximumEvents = 8
    public var sequence: UInt64
    public var sessionID: UUID
    public var observedElapsedMilliseconds: UInt64
    public var build: WebRTCAudioClientBuild
    public var snapshot: WebRTCAudioClientSnapshot
    public var failureSnapshot: WebRTCAudioClientSnapshot?
    public var events: [WebRTCAudioClientEvent]
    public init(sequence: UInt64, sessionID: UUID, build: WebRTCAudioClientBuild,
                snapshot: WebRTCAudioClientSnapshot, failureSnapshot: WebRTCAudioClientSnapshot? = nil,
                events: [WebRTCAudioClientEvent] = [], observedElapsedMilliseconds: UInt64 = 0) {
        self.sequence = sequence
        self.sessionID = sessionID
        self.observedElapsedMilliseconds = observedElapsedMilliseconds
        self.build = build
        self.snapshot = snapshot
        self.failureSnapshot = failureSnapshot
        self.events = events
    }
    enum CodingKeys: String, CodingKey, CaseIterable {
        case sequence = "s", sessionID = "i", build = "b", snapshot = "n"
        case failureSnapshot = "f", events = "e", observedElapsedMilliseconds = "t"
    }
    public var isValid: Bool {
        guard sequence > 0, events.count <= Self.maximumEvents,
              snapshot.isValid, failureSnapshot?.isValid ?? true else { return false }
        var previous: UInt64 = 0
        var previousTime: UInt64 = 0
        for event in events {
            guard event.sequence > previous, event.elapsedMilliseconds >= previousTime,
                  event.failureCode >= 0, event.failureCode <= 25,
                  event.authorityFailureCode.map({ $0 <= 4095 }) ?? true else { return false }
            previous = event.sequence
            previousTime = event.elapsedMilliseconds
        }
        return true
    }
}

public enum WebRTCAudioClientDiagnosticsLaneFailure: String, Codable, Error, Sendable {
    case unavailable, malformed, oversized, closed, backpressure, rateLimited, staleContext
}

public struct WebRTCAudioClientDiagnosticsContext: Sendable {
    let negotiationID: UUID
    let authorization: WebRTCControlAuthorization
    /// Proves this negotiation is not retired, not that media authorization or playback is healthy.
    public var isValid: Bool { authorization.isValid }
    public func isSameNegotiation(as other: Self) -> Bool {
        negotiationID == other.negotiationID && authorization === other.authorization
    }
}

public struct WebRTCReceivedAudioClientDiagnostics: Sendable {
    public let heartbeat: WebRTCAudioClientDiagnosticsHeartbeat
    let context: WebRTCAudioClientDiagnosticsContext
    public var isValid: Bool { context.isValid }
    public func isSameNegotiation(as other: Self) -> Bool {
        context.isSameNegotiation(as: other.context)
    }
}

public enum WebRTCAudioClientDiagnosticsEvent: Sendable {
    case heartbeat(WebRTCReceivedAudioClientDiagnostics)
    case laneFailure(WebRTCAudioClientDiagnosticsLaneFailure)
}

#if os(iOS)
import IOSWebRTCAudioDeviceShim

public extension WebRTCAudioClientNativeSnapshot {
    init(diagnostics: WebRTCIOSPlayoutDiagnostics) {
        self.init()
        initialized = diagnostics.initialized
        playoutInitialized = diagnostics.playoutInitialized
        playing = diagnostics.playing
        sessionActive = diagnostics.sessionActive
        ownsSessionActivation = diagnostics.ownsSessionActivation
        remoteIOCreated = diagnostics.remoteIOCreated
        inputBusEnabled = diagnostics.inputBusEnabled
        outputBusEnabled = diagnostics.outputBusEnabled
        hasOutputRoute = diagnostics.hasOutputRoute
        captureRouteIsBuiltInMicrophone = diagnostics.captureRouteIsBuiltInMicrophone
        recoveryRequired = diagnostics.recoveryRequired
        explicitResumeRequired = diagnostics.explicitResumeRequired
        categoryIsMediaPlayback = diagnostics.categoryIsMediaPlayback
        categoryIsMediaPlayAndRecord = diagnostics.categoryIsMediaPlayAndRecord
        modeIsDefault = diagnostics.modeIsDefault
        categoryOptionsAreEmpty = diagnostics.categoryOptionsAreEmpty
        categoryOptionsAreIPhoneMicrophoneRouting = diagnostics.categoryOptionsAreIPhoneMicrophoneRouting
        routeSharingPolicyIsDefault = diagnostics.routeSharingPolicyIsDefault
        audioUnitSubType = diagnostics.audioUnitSubType
        lastLifecycleStatus = diagnostics.lastLifecycleStatus
        lastPlayoutStatus = diagnostics.lastPlayoutStatus
        playoutCallbackCount = diagnostics.playoutCallbackCount
        playoutFrameCount = diagnostics.playoutFrameCount
        playoutFailureCount = diagnostics.playoutFailureCount
        playoutPCMNonzeroSampleCount = diagnostics.playoutPCMNonzeroSampleCount
        recoveryRequestCount = diagnostics.recoveryRequestCount
        recoveryAuthorizationRejectionCount = diagnostics.recoveryAuthorizationRejectionCount
        recoveryRebuildCount = diagnostics.recoveryRebuildCount
        captureRouteProofGeneration = diagnostics.captureRouteProofGeneration
        failureContext = diagnostics.failureContext
        failureCode = Int32(clamping: diagnostics.failureCode)
        sampleRate = Self.boundedUnsigned(diagnostics.sampleRate, maximum: 768_000)
        outputChannelCount = UInt16(exactly: diagnostics.outputChannelCount)
        outputIOBufferMicroseconds = Self.boundedUnsigned(
            diagnostics.outputIOBufferDuration * 1_000_000, maximum: 10_000_000
        )
        // These are not exposed by the current native snapshot; unavailable is not zero.
        inputSampleRate = nil
        inputChannelCount = nil
        activationCount = nil
    }

    private static func boundedUnsigned(_ value: Double, maximum: UInt32) -> UInt32? {
        guard value.isFinite, value >= 0, value <= Double(maximum) else { return nil }
        return UInt32(value.rounded())
    }
}

extension WebRTCAudioClientNativeSnapshot {
    init(native value: ASIOSStereoPlayoutDiagnostics) {
        self.init()
        initialized = value.initialized
        playoutInitialized = value.playoutInitialized
        playing = value.playing
        sessionActive = value.sessionActive
        ownsSessionActivation = value.ownsSessionActivation
        remoteIOCreated = value.remoteIOCreated
        inputBusEnabled = value.inputBusEnabled
        outputBusEnabled = value.outputBusEnabled
        hasOutputRoute = value.hasOutputRoute
        captureRouteIsBuiltInMicrophone = value.captureRouteIsBuiltInMicrophone
        recoveryRequired = value.recoveryRequired
        explicitResumeRequired = value.explicitResumeRequired
        categoryIsMediaPlayback = value.categoryIsMediaPlayback
        categoryIsMediaPlayAndRecord = value.categoryIsMediaPlayAndRecord
        modeIsDefault = value.modeIsDefault
        categoryOptionsAreEmpty = value.categoryOptionsAreEmpty
        categoryOptionsAreIPhoneMicrophoneRouting = value.categoryOptionsAreIPhoneMicrophoneRouting
        routeSharingPolicyIsDefault = value.routeSharingPolicyIsDefault
        audioUnitSubType = value.audioUnitSubType
        lastLifecycleStatus = value.lastLifecycleStatus
        lastPlayoutStatus = value.lastPlayoutStatus
        playoutCallbackCount = value.playoutCallbackCount
        playoutFrameCount = value.playoutFrameCount
        playoutFailureCount = value.playoutFailureCount
        playoutPCMNonzeroSampleCount = value.playoutPCMNonzeroSampleCount
        recoveryRequestCount = value.recoveryRequestCount
        recoveryAuthorizationRejectionCount = value.recoveryAuthorizationRejectionCount
        recoveryRebuildCount = value.recoveryRebuildCount
        captureRouteProofGeneration = value.captureRouteProofGeneration
        failureCode = Int32(clamping: value.failureCode.rawValue)
        failureContext = WebRTCAudioClientFailureContext(native: value.failureContext)
        sampleRate = Self.boundedUnsigned(value.sampleRate, maximum: 768_000)
        outputChannelCount = UInt16(exactly: value.outputChannelCount)
        outputIOBufferMicroseconds = Self.boundedUnsigned(
            value.outputIOBufferDuration * 1_000_000, maximum: 10_000_000
        )
    }
}
#endif

struct AudioClientDiagnosticsEnvelope: Codable {
    static let maximumBytes = 4 * 1_024
    let version: Int
    let negotiationID: UUID
    let heartbeat: WebRTCAudioClientDiagnosticsHeartbeat
    enum CodingKeys: String, CodingKey, CaseIterable { case version = "v", negotiationID = "n", heartbeat = "h" }
    func encoded() throws -> Data {
        guard version == 1, heartbeat.isValid else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.malformed
        }
        var boundedHeartbeat = heartbeat
        while true {
            let data = try JSONEncoder().encode(Self(version: version, negotiationID: negotiationID,
                                                     heartbeat: boundedHeartbeat))
            if data.count <= Self.maximumBytes { return data }
            // Never drop the current or retained failure snapshot to make room for history.
            guard !boundedHeartbeat.events.isEmpty else {
                throw WebRTCAudioClientDiagnosticsLaneFailure.oversized
            }
            boundedHeartbeat.events.removeFirst()
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WebRTCAudioClientDiagnosticsLaneFailure.oversized }
        let root = try object(JSONSerialization.jsonObject(with: data), keys: CodingKeys.allCases.map(\.rawValue))
        let beat = try object(root["h"], keys: WebRTCAudioClientDiagnosticsHeartbeat.CodingKeys.allCases.map(\.rawValue))
        _ = try object(beat["b"], keys: WebRTCAudioClientBuild.CodingKeys.allCases.map(\.rawValue))
        try validateSnapshot(beat["n"])
        if let failed = beat["f"], !(failed is NSNull) { try validateSnapshot(failed) }
        guard let events = beat["e"] as? [Any], events.count <= WebRTCAudioClientDiagnosticsHeartbeat.maximumEvents else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.malformed
        }
        for event in events { _ = try object(event, keys: WebRTCAudioClientEvent.CodingKeys.allCases.map(\.rawValue)) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, result.heartbeat.isValid else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.malformed
        }
        return result
    }

    private static func validateSnapshot(_ value: Any?) throws {
        let snapshot = try object(value, keys: WebRTCAudioClientSnapshot.CodingKeys.allCases.map(\.rawValue))
        if let rawNative = snapshot["8"], !(rawNative is NSNull) {
            let native = try object(rawNative, keys: WebRTCAudioClientNativeSnapshot.CodingKeys.allCases.map(\.rawValue))
            if let context = native["A"], !(context is NSNull) {
                _ = try object(context, keys: WebRTCAudioClientFailureContext.CodingKeys.allCases.map(\.rawValue))
            }
        }
    }

    private static func object(_ value: Any?, keys: [String]) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: Set(keys)) else {
            throw WebRTCAudioClientDiagnosticsLaneFailure.malformed
        }
        return object
    }
}
