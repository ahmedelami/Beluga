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
