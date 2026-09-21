#if os(macOS)
import Darwin
import Foundation
@preconcurrency import LiveKitWebRTC
@testable import WebRTCTransport

enum StartupVideoNativeEncoderLogPayload: Codable, Equatable, Sendable {
    enum EncodeStage: String, Codable, Sendable { case submission, completion }
    enum PropertyResult: Codable, Equatable, Sendable {
        case success
        case failure(status: Int32)
    }
    enum H264Profile: String, Codable, Sendable {
        case constrainedBaseline = "ConstrainedBaseline", baseline = "Baseline", main = "Main"
        case constrainedHigh = "ConstrainedHigh", high = "High", predictiveHigh444 = "PredictiveHigh444"
        case unparsed = "<unparsed>", unknown = "<unknown>"

        var isHighFamily: Bool { self == .constrainedHigh || self == .high || self == .predictiveHigh444 }
    }

    case encodeDropped
    case encodeFailed(stage: EncodeStage, status: Int32)
    case frameRateUpdate(framesPerSecond: UInt32, result: PropertyResult)
    case bitrateUpdate(bitrateBps: UInt32, result: PropertyResult)
    case dataRateLimitsUpdate(succeeded: Bool)
    // The native "disabled" message also covers failure of its property query.
    case hardwareAccelerationReported(enabled: Bool)
    case lowLatencyRateControl(enabled: Bool, profile: H264Profile)

    var isConfiguration: Bool {
        switch self {
        case .encodeDropped, .encodeFailed: false
        default: true
        }
    }
}

struct StartupVideoNativeEncoderLogEvent: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case preArmConfiguration, captureWindow }
    // Collector order and callback thread only; neither identifies an encoder or RTP frame.
    let sequence: UInt64
    let threadID: UInt64
    let callbackUptimeNanoseconds: UInt64
    let phase: Phase
    let payload: StartupVideoNativeEncoderLogPayload
}

struct StartupVideoNativeEncoderLogBatch: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case process }
    enum Failure: String, Codable, Sendable { case owner, arm, lifetime, clock, thread, overflow }
    struct Counts: Codable, Equatable, Sendable {
        var armCount: UInt64 = 0
        var rejectedArmCount: UInt64 = 0
        var matchingMessageCount: UInt64 = 0
        // Includes ordinary unrelated SDK text as well as malformed/unallowlisted messages.
        var rejectedMessageCount: UInt64 = 0
        var oversizedMessageCount: UInt64 = 0
        var omittedBeforeArmFrameCount: UInt64 = 0
        var outOfWindowEventCount: UInt64 = 0
        var retiredMessageCount: UInt64 = 0
        var invalidObservationTimeCount: UInt64 = 0
        var regressingObservationTimeCount: UInt64 = 0
        var invalidThreadIDCount: UInt64 = 0
        var droppedEventCount: UInt64 = 0
        var counterSaturated = false
    }
    let schemaVersion: Int
    let scope: Scope
    let startedAtUptimeNanoseconds: UInt64
    let captureStartedAtUptimeNanoseconds: UInt64?
    let windowNanoseconds: UInt64
    let capacity: Int
    let isRetired: Bool
    let counts: Counts
    let events: [StartupVideoNativeEncoderLogEvent]
    let failures: [Failure]
    // Structural validity only. Positive event presence is a separate receiving check.
    let isVerified: Bool
}

/// Process-wide logging only. This sink observes all native encoders in the process.
final class StartupVideoNativeEncoderLogObserver: @unchecked Sendable {
    private static let processLifetimeInstance = StartupVideoNativeEncoderLogObserver()
    private let collector: StartupVideoNativeEncoderLogCollector
    private let logger: LKRTCCallbackLogger

    private init() {
        StartupVideoNativeEncoderLogParser.prepare()
        let collector = StartupVideoNativeEncoderLogCollector()
        self.collector = collector
        let logger = LKRTCCallbackLogger()
        self.logger = logger
        logger.severity = .info
        // The SDK logging lock is held: never log, dispatch, enter the SDK or stop this sink
        // in the callback. The static owner retains registration through process exit.
        logger.start { @Sendable message in collector.record(message) }
    }

    static func start() -> StartupVideoNativeEncoderLogObserver { processLifetimeInstance }

    func arm(captureStartedAtUptimeNanoseconds: UInt64) throws {
        try collector.arm(captureStartedAtUptimeNanoseconds: captureStartedAtUptimeNanoseconds)
    }

    func snapshot() -> StartupVideoNativeEncoderLogBatch { collector.snapshot() }

    /// Retire metadata admission, not the SDK callback registration.
    func finish() -> StartupVideoNativeEncoderLogBatch { collector.finish() }
}

final class StartupVideoNativeEncoderLogCollector: @unchecked Sendable {
    static let capacity = 512
    static let windowNanoseconds: UInt64 = 6_000_000_000
    private let lock = NSLock()
    private let startedAtUptimeNanoseconds: UInt64
    private var captureStart: UInt64?
    private var captureEnd: UInt64?
    private var lastObservationTime: UInt64
    private var retired = false
    private var counts = StartupVideoNativeEncoderLogBatch.Counts()
    private var events: [StartupVideoNativeEncoderLogEvent] = []

    init(startedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        lastObservationTime = startedAtUptimeNanoseconds
        events.reserveCapacity(Self.capacity)
    }

    func arm(captureStartedAtUptimeNanoseconds start: UInt64,
             observedAtUptimeNanoseconds: UInt64? = nil) throws {
        try lock.withLock {
            let observed = observedAtUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
            let end = start.addingReportingOverflow(Self.windowNanoseconds)
            guard !retired, captureStart == nil, startedAtUptimeNanoseconds > 0,
                  start >= startedAtUptimeNanoseconds, start > 0, observed >= start,
                  observed >= lastObservationTime, !end.overflow, observed < end.partialValue else {
                increment(\.rejectedArmCount)
                throw WebRTCTransportError.nativeFailure("Native encoder logging requires one valid capture window")
            }
            captureStart = start
            captureEnd = end.partialValue
            lastObservationTime = observed
            increment(\.armCount)
        }
    }

    func record(_ message: String,
                observedAtUptimeNanoseconds: UInt64? = nil,
                observedThreadID: UInt64 = currentStartupVideoNativeEncoderLogThreadID()) {
        lock.withLock {
            guard !retired else { increment(\.retiredMessageCount); return }
            // Sample default time in collector order so arm cannot race an older callback sample.
            let observed = observedAtUptimeNanoseconds ?? DispatchTime.now().uptimeNanoseconds
            // The callback's String is transient. Neither raw text nor any substring is retained.
            guard message.utf8.prefix(StartupVideoNativeEncoderLogParser.maximumMessageBytes + 1).count
                    <= StartupVideoNativeEncoderLogParser.maximumMessageBytes else {
                increment(\.oversizedMessageCount)
                increment(\.rejectedMessageCount)
                return
            }
            guard let payload = StartupVideoNativeEncoderLogParser.parse(message) else {
                increment(\.rejectedMessageCount)
                return
            }
            increment(\.matchingMessageCount)
            guard observedThreadID != 0 else { increment(\.invalidThreadIDCount); return }
            guard observed > 0, observed >= startedAtUptimeNanoseconds else {
                increment(\.invalidObservationTimeCount)
                return
            }
            guard observed >= lastObservationTime else {
                increment(\.regressingObservationTimeCount)
                return
            }
            lastObservationTime = observed
            let phase: StartupVideoNativeEncoderLogEvent.Phase
            if let captureStart, let captureEnd {
                guard observed >= captureStart, observed < captureEnd else {
                    increment(\.outOfWindowEventCount)
                    return
                }
                phase = .captureWindow
            } else {
                guard payload.isConfiguration else { increment(\.omittedBeforeArmFrameCount); return }
                phase = .preArmConfiguration
            }
            guard events.count < Self.capacity else { increment(\.droppedEventCount); return }
            events.append(.init(sequence: UInt64(events.count) + 1,
                threadID: observedThreadID, callbackUptimeNanoseconds: observed,
                phase: phase, payload: payload))
        }
    }

    func snapshot() -> StartupVideoNativeEncoderLogBatch { lock.withLock { snapshotLocked() } }

    func finish() -> StartupVideoNativeEncoderLogBatch {
        lock.withLock { retired = true; return snapshotLocked() }
    }

    private func increment(_ key: WritableKeyPath<StartupVideoNativeEncoderLogBatch.Counts, UInt64>) {
        if counts[keyPath: key] == UInt64.max { counts.counterSaturated = true }
        else { counts[keyPath: key] += 1 }
    }

    private func snapshotLocked() -> StartupVideoNativeEncoderLogBatch {
        var failures: [StartupVideoNativeEncoderLogBatch.Failure] = []
        if startedAtUptimeNanoseconds == 0 { failures.append(.owner) }
        if counts.armCount != 1 || counts.rejectedArmCount != 0 { failures.append(.arm) }
        if !retired { failures.append(.lifetime) }
        if counts.invalidObservationTimeCount != 0 || counts.regressingObservationTimeCount != 0 {
            failures.append(.clock)
        }
        if counts.invalidThreadIDCount != 0 { failures.append(.thread) }
        if counts.droppedEventCount != 0 || counts.counterSaturated { failures.append(.overflow) }
        return .init(schemaVersion: 1, scope: .process,
            startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
            captureStartedAtUptimeNanoseconds: captureStart,
            windowNanoseconds: Self.windowNanoseconds, capacity: Self.capacity,
            isRetired: retired, counts: counts, events: events, failures: failures,
            isVerified: failures.isEmpty)
    }
}

private func currentStartupVideoNativeEncoderLogThreadID() -> UInt64 {
    var threadID: UInt64 = 0
    return pthread_threadid_np(nil, &threadID) == 0 ? threadID : 0
}

/// Complete format allowlist from the pinned RTCVideoEncoderH264.mm, not a general log parser.
enum StartupVideoNativeEncoderLogParser {
    static let maximumMessageBytes = 1_024
    private static let unsigned = #"([0-9]{1,10})"#
    private static let status = #"(-?[0-9]{1,10})"#
    private static let submissionFailure = expression("Failed to encode frame with code: " + status)
    private static let completionFailure = expression("H264 encode failed with code: " + status)
    private static let frameRateSuccess = expression("Did update encoder frame rate: " + unsigned)
    private static let frameRateFailure = expression("Failed to set frame rate: " + unsigned + " error: " + status)
    private static let bitrateSuccess = expression("Did update encoder bitrate: " + unsigned)
    // There is intentionally no space before "error:" in the pinned native message.
    private static let bitrateFailure = expression("Failed to update encoder bitrate: " + unsigned + "error: " + status)
    private static let lowLatency = expression(
        #"H264: (enabling|skipping) EnableLowLatencyRateControl \(profile=(ConstrainedBaseline|Baseline|Main|ConstrainedHigh|High|PredictiveHigh444|<unparsed>|<unknown>), (in|not in) High family\)\."#)

    static func prepare() {
        _ = submissionFailure; _ = completionFailure
        _ = frameRateSuccess; _ = frameRateFailure; _ = bitrateSuccess; _ = bitrateFailure; _ = lowLatency
    }

    static func parse(_ message: String) -> StartupVideoNativeEncoderLogPayload? {
        guard message.utf8.prefix(maximumMessageBytes + 1).count <= maximumMessageBytes else { return nil }
        var line = message[...]
        if line.last == "\n" { line = line.dropLast() }
        guard line.utf8.allSatisfy({ (32...126).contains($0) }),
              let opening = line.firstIndex(of: "("),
              line.distance(from: line.startIndex, to: opening) <= 64,
              line[..<opening].utf8.allSatisfy({
                  $0 == 32 || $0 == 58 || $0 == 91 || $0 == 93 || (48...57).contains($0)
              }) else { return nil }
        let remainder = line[line.index(after: opening)...]
        guard let colon = remainder.firstIndex(of: ":"),
              remainder[..<colon] == "RTCVideoEncoderH264.mm" else { return nil }
        let suffix = remainder[remainder.index(after: colon)...]
        guard let separator = suffix.range(of: "): "),
              (1...6).contains(suffix[..<separator.lowerBound].count),
              suffix[..<separator.lowerBound].utf8.allSatisfy({ (48...57).contains($0) }),
              let lineNumber = UInt32(suffix[..<separator.lowerBound]), lineNumber > 0 else { return nil }
        let body = String(suffix[separator.upperBound...])
        switch body {
        case "H264 encode dropped frame.": return .encodeDropped
        case "Did update encoder data rate limits": return .dataRateLimitsUpdate(succeeded: true)
        case "Failed to update encoder data rate limits": return .dataRateLimitsUpdate(succeeded: false)
        case "Compression session created with hw accl enabled": return .hardwareAccelerationReported(enabled: true)
        case "Compression session created with hw accl disabled": return .hardwareAccelerationReported(enabled: false)
        default: break
        }
        if let values = fields(submissionFailure, body), let code = nonzeroStatus(values[0]) {
            return .encodeFailed(stage: .submission, status: code)
        }
        if let values = fields(completionFailure, body), let code = nonzeroStatus(values[0]) {
            return .encodeFailed(stage: .completion, status: code)
        }
        if let values = fields(frameRateSuccess, body), let value = UInt32(values[0]) {
            return .frameRateUpdate(framesPerSecond: value, result: .success)
        }
        if let values = fields(frameRateFailure, body), let value = UInt32(values[0]),
           let code = nonzeroStatus(values[1]) {
            return .frameRateUpdate(framesPerSecond: value, result: .failure(status: code))
        }
        if let values = fields(bitrateSuccess, body), let value = UInt32(values[0]) {
            return .bitrateUpdate(bitrateBps: value, result: .success)
        }
        if let values = fields(bitrateFailure, body), let value = UInt32(values[0]),
           let code = nonzeroStatus(values[1]) {
            return .bitrateUpdate(bitrateBps: value, result: .failure(status: code))
        }
        if let values = fields(lowLatency, body),
           let profile = StartupVideoNativeEncoderLogPayload.H264Profile(rawValue: values[1]) {
            let enabled = values[0] == "enabling"
            guard enabled == profile.isHighFamily, enabled == (values[2] == "in") else { return nil }
            return .lowLatencyRateControl(enabled: enabled, profile: profile)
        }
        return nil
    }

    private static func nonzeroStatus(_ token: String) -> Int32? {
        guard let value = Int32(token), value != 0 else { return nil }
        return value
    }

    private static func expression(_ body: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "^(?:" + body + ")$")
    }

    private static func fields(_ expression: NSRegularExpression?, _ body: String) -> [String]? {
        guard let expression,
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.range.length == body.utf16.count else { return nil }
        let values = (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: body).map { String(body[$0]) }
        }
        return values.count == match.numberOfRanges - 1 ? values : nil
    }
}
#endif
