import Foundation

#if os(iOS)
import IOSWebRTCAudioDeviceShim

extension WebRTCAudioClientFailureContext {
    init?(native: ASIOSAudioFailureContext) {
        guard native.eventSequence != 0,
              let stage = WebRTCAudioClientNativeFailureStage(rawValue: native.stage.rawValue),
              let reason = WebRTCAudioClientNativeFailureReason(rawValue: native.reason.rawValue) else { return nil }
        self.init()
        eventSequence = native.eventSequence
        deviceInstanceGeneration = native.deviceInstanceGeneration
        systemAudioGeneration = native.systemAudioGeneration
        configurationGeneration = native.configurationGeneration
        appOperationTagGeneration = native.appOperationTagGeneration
        failureCode = native.failureCode
        status = native.status
        inputChannelCount = native.inputChannelCount
        outputChannelCount = native.outputChannelCount
        sessionAvailable = native.sessionAvailable
        inputRequired = native.inputRequired
        hostedCall = native.hostedCall
        sessionActive = native.sessionActive
        ownsSessionActivation = native.ownsSessionActivation
        hasOutputRoute = native.hasOutputRoute
        categoryIsMediaPlayback = native.categoryIsMediaPlayback
        categoryIsMediaPlayAndRecord = native.categoryIsMediaPlayAndRecord
        modeIsDefault = native.modeIsDefault
        categoryOptionsAreEmpty = native.categoryOptionsAreEmpty
        categoryOptionsAreIPhoneMicrophoneRouting = native.categoryOptionsAreIPhoneMicrophoneRouting
        self.stage = stage
        self.reason = reason
        if failureCode == 4, stage == .routeValidation, reason == .policyMismatch {
            targetPolicyRejection = WebRTCAudioClientNativeTargetPolicyRejection(
                code: native.targetPolicyRejectionCode
            )
        }
        if native.sampleRate.isFinite, native.sampleRate >= 0, native.sampleRate <= 768_000 {
            sampleRate = UInt32(native.sampleRate.rounded())
        }
        let microseconds = native.outputIOBufferDuration * 1_000_000
        if microseconds.isFinite, microseconds >= 0, microseconds <= 10_000_000 {
            outputIOBufferMicroseconds = UInt32(microseconds.rounded())
        }
    }
}
#endif


/// Local, pre-rollback proof of an unsuccessful native output-policy target check.
/// This is not Codable: the collector may publish its bounded code in v1's existing
/// authorityFailureCode namespace, but cannot add private metadata to the wire context.
public struct WebRTCAudioClientNativeTargetPolicyRejection: Equatable, Sendable {
    public enum ObservedPolicy: UInt16, CaseIterable, Sendable {
        case `default` = 0
        case longFormAudio = 1
        case independent = 2
        case longFormVideo = 3
        case unknown = 4
    }

    public enum FencePhase: Equatable, Sendable {
        case beforeEffect
        case afterEffect
    }

    public enum FenceRejection: UInt16, CaseIterable, Sendable {
        case transactionIdentityUnavailable = 7
        case systemIdentityUnavailable = 8
        case deadlineUnavailable = 9
        case routeIdentityUnavailable = 10
        case outputIdentityUnavailable = 11
        case deviceUninitialized = 12
        case nativeSessionInactive = 13
        case interrupted = 14
        case inputBusEnabled = 15
        case alreadyPlaying = 16
        case audioUnitPresent = 17
        case hostedAuthorizationPresent = 18
        case effectiveMicrophoneActive = 19
        case recordingIntentChanged = 20
        case playoutIntentChanged = 21
        case microphoneAuthorizationChanged = 22
        case explicitResumeChanged = 23
        case deviceOwnershipChanged = 24
        case globalOwnershipChanged = 25
        case publishedSessionInactive = 26
        case systemGenerationChanged = 27
        case activeConfigurationChanged = 28
        case transactionNotPending = 29
        case transactionChanged = 30
        case transactionSystemChanged = 31
        case transactionConfigurationChanged = 32
        case transactionOwnershipChanged = 33
        case transactionDeadlineChanged = 34
        case clockUnavailable = 35
        case deadlineExpired = 36
        case notificationSequenceChanged = 37
        case transactionRevisionChanged = 38
        case notificationsInFlight = 39
        case inputTargetChanged = 40
        case preferredInputRequirementChanged = 41
        case targetInputPresent = 42
        case operationTagChanged = 43
        case operationTagDrained = 44
        case transitionRouteChanged = 45
        case pinnedOutputChanged = 46
        case categoryMismatch = 47
        case modeMismatch = 48
        case optionsMismatch = 49
        case observedOutputMissing = 50
        case observedRouteChanged = 51
        case observedOutputChanged = 52
        case sampleRateMismatch = 53
        case ioDurationInvalid = 54
        case outputChannelsMismatch = 55
    }

    public enum Outcome: Equatable, Sendable {
        case invalidArguments
        case priorAttemptFailed
        case preEffectDrainRejected
        case postEffectDrainRejected
        case setterRejected
        case persistentSharingMismatch
        case fenceRejected(FenceRejection, phase: FencePhase)
        case attemptAlreadySpent

        public var rawValue: UInt16 {
            switch self {
            case .invalidArguments: 1
            case .priorAttemptFailed: 2
            case .preEffectDrainRejected: 3
            case .postEffectDrainRejected: 4
            case .setterRejected: 5
            case .persistentSharingMismatch: 6
            case .fenceRejected(let reason, let phase):
                reason.rawValue + (phase == .afterEffect ? 64 : 0)
            case .attemptAlreadySpent: 56
            }
        }

        public init?(rawValue: UInt16) {
            switch rawValue {
            case 1: self = .invalidArguments
            case 2: self = .priorAttemptFailed
            case 3: self = .preEffectDrainRejected
            case 4: self = .postEffectDrainRejected
            case 5: self = .setterRejected
            case 6: self = .persistentSharingMismatch
            case 56: self = .attemptAlreadySpent
            case 7...55:
                guard let reason = FenceRejection(rawValue: rawValue) else { return nil }
                self = .fenceRejected(reason, phase: .beforeEffect)
            case 71...119:
                guard let reason = FenceRejection(rawValue: rawValue - 64) else { return nil }
                self = .fenceRejected(reason, phase: .afterEffect)
            default: return nil
            }
        }
    }

    public let outcome: Outcome
    public let observedPolicy: ObservedPolicy

    /// Stable native target-proof rejection namespace. Zero, success, reserved
    /// outcomes, and reserved policy kinds are never valid local receipts.
    public var code: UInt16 { 1024 + outcome.rawValue * 8 + observedPolicy.rawValue }

    public init(outcome: Outcome, observedPolicy: ObservedPolicy) {
        self.outcome = outcome
        self.observedPolicy = observedPolicy
    }

    public init?(code: UInt16) {
        guard code >= 1024 else { return nil }
        let packed = code - 1024
        guard let outcome = Outcome(rawValue: packed / 8),
              let policy = ObservedPolicy(rawValue: packed % 8) else { return nil }
        self.init(outcome: outcome, observedPolicy: policy)
    }
}

public enum WebRTCAudioClientNativeFailureStage: UInt16, Codable, Equatable, Sendable {
    case none = 0
    case sessionConfiguration = 1
    case sessionPreferences = 2
    case sessionActivation = 3
    case routeValidation = 4
    case audioUnitCreation = 5
    case audioUnitConfiguration = 6
    case audioUnitInitialization = 7
    case routePreparation = 8
    case routeBeginStart = 9
    case audioUnitStart = 10
    case routeStartCompleted = 11
    case routeCommit = 12
    case routePublication = 13
    case retry = 14
    case systemEvent = 15
    case teardown = 16
}

public enum WebRTCAudioClientNativeFailureReason: UInt16, Codable, Equatable, Sendable {
    case unspecified = 0
    case activationRejected = 1
    case builtInInputUnavailable = 2
    case preferredInputRequest = 3
    case preferredInputConvergence = 4
    case sessionOwnershipLost = 5
    case outputUnavailable = 6
    case outputChannelRequest = 7
    case inputUnavailable = 8
    case inputChannelRequest = 9
    case sampleRateRequest = 10
    case bufferDurationRequest = 11
    case retryHookUnavailable = 12
    case retryVerificationRejected = 13
    case policyMismatch = 14
    case routeTransactionRejected = 15
    case nativeOperationFailed = 16
    case sessionUnavailable = 17
    case hostedOwnershipChanged = 18
}

/// Historical pre-rollback evidence, never a claim about the currently installed route.
public struct WebRTCAudioClientFailureContext: Codable, Equatable, Sendable {
    public var eventSequence: UInt64 = 0
    public var deviceInstanceGeneration: UInt64 = 0
    public var systemAudioGeneration: UInt64 = 0
    public var configurationGeneration: UInt64 = 0
    public var appOperationTagGeneration: UInt64 = 0
    public var stage: WebRTCAudioClientNativeFailureStage = .none
    public var reason: WebRTCAudioClientNativeFailureReason = .unspecified
    public var failureCode: Int32 = 0
    public var status: Int32 = 0
    public var sampleRate: UInt32? = nil
    public var outputIOBufferMicroseconds: UInt32? = nil
    public var inputChannelCount: Int32 = 0
    public var outputChannelCount: Int32 = 0
    public var sessionAvailable: Bool = false
    public var inputRequired: Bool = false
    public var hostedCall: Bool = false
    public var sessionActive: Bool = false
    public var ownsSessionActivation: Bool = false
    public var hasOutputRoute: Bool = false
    public var categoryIsMediaPlayback: Bool = false
    public var categoryIsMediaPlayAndRecord: Bool = false
    public var modeIsDefault: Bool = false
    public var categoryOptionsAreEmpty: Bool = false
    public var categoryOptionsAreIPhoneMicrophoneRouting: Bool = false
    /// Local metadata shares this context's exact native identity. Deliberately
    /// excluded from CodingKeys; wire decoding leaves it nil. Equatable includes
    /// it, so enriched local contexts need not equal their wire-only round trip.
    public var targetPolicyRejection: WebRTCAudioClientNativeTargetPolicyRejection? = nil
    public init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case eventSequence = "0"
        case deviceInstanceGeneration = "1"
        case systemAudioGeneration = "2"
        case configurationGeneration = "3"
        case appOperationTagGeneration = "4"
        case stage = "5"
        case reason = "6"
        case failureCode = "7"
        case status = "8"
        case sampleRate = "9"
        case outputIOBufferMicroseconds = "a"
        case inputChannelCount = "b"
        case outputChannelCount = "c"
        case sessionAvailable = "d"
        case inputRequired = "e"
        case hostedCall = "f"
        case sessionActive = "g"
        case ownsSessionActivation = "h"
        case hasOutputRoute = "i"
        case categoryIsMediaPlayback = "j"
        case categoryIsMediaPlayAndRecord = "k"
        case modeIsDefault = "l"
        case categoryOptionsAreEmpty = "m"
        case categoryOptionsAreIPhoneMicrophoneRouting = "n"
    }
    var isValid: Bool {
        eventSequence > 0 && failureCode >= 0 && failureCode <= 25
            && inputChannelCount >= 0 && inputChannelCount <= 64
            && outputChannelCount >= 0 && outputChannelCount <= 64
            && (sampleRate.map { $0 <= 768_000 } ?? true)
            && (outputIOBufferMicroseconds.map { $0 <= 10_000_000 } ?? true)
    }
}
