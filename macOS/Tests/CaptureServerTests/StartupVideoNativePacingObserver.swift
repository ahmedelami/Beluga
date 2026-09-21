#if os(macOS)
import Darwin
import Foundation
@preconcurrency import LiveKitWebRTC

enum StartupVideoNativePacingPayload: Codable, Equatable, Sendable {
    case pacerUpdated(pacingKbps: UInt64, paddingBudgetKbps: UInt64)
    case bweUpdated(nativeTimestampMilliseconds: Int64, pushbackTargetBps: UInt64, estimateBps: UInt64)
    case alrSettings(
        pacingFactor: Double,
        maxPacerQueueMilliseconds: Int64,
        bandwidthUsagePercent: Int32,
        startBudgetLevelPercent: Int32,
        endBudgetLevelPercent: Int32,
        groupID: Int32
    )
}

struct StartupVideoNativePacingEvent: Codable, Equatable, Sendable {
    // Sequence is collector serialization order, not an inferred cross-thread native order.
    let sequence: UInt64
    let threadID: UInt64
    let callbackUptimeNanoseconds: UInt64
    let processObserverAgeMilliseconds: UInt64
    let payload: StartupVideoNativePacingPayload
}

struct StartupVideoNativePacingBatch: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable { case process }
    let scope: Scope
    let startedAtUptimeNanoseconds: UInt64
    let events: [StartupVideoNativePacingEvent]
    let matchingEventCount: UInt64
    let droppedEventCount: UInt64
    // Includes ordinary unrelated SDK messages, not just malformed pacing messages.
    let rejectedMessageCount: UInt64
    let invalidObservationTimeCount: UInt64
    let invalidThreadIDCount: UInt64
}

/// Test-process logging only. Neither a callback's timing nor its consumer identifies a peer.
/// Start before native factory construction, in a fresh process, to observe ALR initialization.
final class StartupVideoNativePacingObserver: @unchecked Sendable {
    private static let processLifetimeInstance = StartupVideoNativePacingObserver()
    private let collector: StartupVideoNativePacingCollector
    private let logger: LKRTCCallbackLogger

    private init() {
        StartupVideoNativePacingParser.prepare()
        let collector = StartupVideoNativePacingCollector()
        self.collector = collector
        let logger = LKRTCCallbackLogger()
        self.logger = logger
        logger.severity = .verbose
        // The SDK owns its logging lock here. Never log, dispatch, or enter the SDK in this
        // callback. The static owner pins registration until process exit, avoiding stop/deinit
        // from a last-reference callback or a race with another fixture's registration.
        logger.start { @Sendable message in collector.record(message) }
    }

    static func start() -> StartupVideoNativePacingObserver { processLifetimeInstance }

    /// Non-destructive snapshot: bounded first events and cumulative overflow stay observable.
    func snapshot() -> StartupVideoNativePacingBatch { collector.snapshot() }
}

final class StartupVideoNativePacingCollector: @unchecked Sendable {
    static let capacity = 4_096
    private let lock = NSLock()
    private let startedAtUptimeNanoseconds: UInt64
    private var events: [StartupVideoNativePacingEvent] = []
    private var matchingEventCount: UInt64 = 0
    private var droppedEventCount: UInt64 = 0
    private var rejectedMessageCount: UInt64 = 0
    private var invalidObservationTimeCount: UInt64 = 0
    private var invalidThreadIDCount: UInt64 = 0

    init(startedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        events.reserveCapacity(Self.capacity)
    }

    func record(
        _ message: String,
        observedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        observedThreadID: UInt64 = currentStartupVideoNativePacingThreadID()
    ) {
        // Input exists only for this callback; raw SDK text is never retained or emitted.
        guard let payload = StartupVideoNativePacingParser.parse(message) else {
            lock.withLock { Self.increment(&rejectedMessageCount) }
            return
        }
        lock.withLock {
            guard observedThreadID != 0 else {
                Self.increment(&invalidThreadIDCount)
                return
            }
            guard observedAtUptimeNanoseconds >= startedAtUptimeNanoseconds else {
                Self.increment(&invalidObservationTimeCount)
                return
            }
            guard matchingEventCount < UInt64.max else {
                Self.increment(&droppedEventCount)
                return
            }
            matchingEventCount += 1
            guard events.count < Self.capacity else {
                Self.increment(&droppedEventCount)
                return
            }
            events.append(StartupVideoNativePacingEvent(
                sequence: matchingEventCount,
                threadID: observedThreadID,
                callbackUptimeNanoseconds: observedAtUptimeNanoseconds,
                processObserverAgeMilliseconds:
                    (observedAtUptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000,
                payload: payload
            ))
        }
    }

    func snapshot() -> StartupVideoNativePacingBatch {
        lock.withLock {
            StartupVideoNativePacingBatch(
                scope: .process,
                startedAtUptimeNanoseconds: startedAtUptimeNanoseconds,
                events: events,
                matchingEventCount: matchingEventCount,
                droppedEventCount: droppedEventCount,
                rejectedMessageCount: rejectedMessageCount,
                invalidObservationTimeCount: invalidObservationTimeCount,
                invalidThreadIDCount: invalidThreadIDCount
            )
        }
    }

    private static func increment(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}

private func currentStartupVideoNativePacingThreadID() -> UInt64 {
    var threadID: UInt64 = 0
    return pthread_threadid_np(nil, &threadID) == 0 ? threadID : 0
}

/// Complete allowlisted formats from LiveKitWebRTC 144.7559.11's pinned native source.
/// Unknown/duplicate/trailing fields and wrong source files cannot produce an event.
enum StartupVideoNativePacingParser {
    static let maximumMessageBytes = 1_024
    private static let integer = #"(-?[0-9]{1,20})"#
    private static let unsigned = #"([0-9]{1,20})"#
    private static let decimal = #"([0-9]{1,20}(?:\.[0-9]{1,20})?(?:[eE][+-]?[0-9]{1,3})?)"#
    private static let pacer = expression(
        "bwe:pacer_updated pacing_kbps=" + unsigned + " padding_budget_kbps=" + unsigned
    )
    private static let bwe = expression(
        "bwe " + integer + " pushback_target_bps=" + unsigned + " estimate_bps=" + unsigned
    )
    private static let alr = expression(
        "Using ALR experiment settings: pacing factor: " + decimal
            + ", max pacer queue length: " + integer
            + ", ALR bandwidth usage percent: " + integer
            + ", ALR start budget level percent: " + integer
            + ", ALR end budget level percent: " + integer
            + ", ALR experiment group ID: " + integer
    )

    static func prepare() {
        _ = pacer
        _ = bwe
        _ = alr
    }

    static func parse(_ message: String) -> StartupVideoNativePacingPayload? {
        guard message.utf8.prefix(maximumMessageBytes + 1).count <= maximumMessageBytes else {
            return nil
        }
        var line = message[...]
        if line.last == "\n" { line = line.dropLast() }
        guard line.utf8.allSatisfy({ (32...126).contains($0) }),
              let opening = line.firstIndex(of: "("),
              line.distance(from: line.startIndex, to: opening) <= 64,
              line[..<opening].utf8.allSatisfy({
                  $0 == 32 || $0 == 58 || $0 == 91 || $0 == 93 || (48...57).contains($0)
              }) else { return nil }
        let remainder = line[line.index(after: opening)...]
        guard let colon = remainder.firstIndex(of: ":") else { return nil }
        let source = remainder[..<colon]
        guard source == "pacing_controller.cc" || source == "goog_cc_network_control.cc"
                || source == "alr_experiment.cc" else { return nil }
        let suffix = remainder[remainder.index(after: colon)...]
        guard let separator = suffix.range(of: "): "),
              (1...6).contains(suffix[..<separator.lowerBound].count),
              suffix[..<separator.lowerBound].utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        let body = String(suffix[separator.upperBound...])
        switch source {
        case "pacing_controller.cc":
            guard let values = fields(pacer, body), let rate = nativeRate(values[0]),
                  let padding = nativeRate(values[1]) else { return nil }
            return .pacerUpdated(pacingKbps: rate, paddingBudgetKbps: padding)
        case "goog_cc_network_control.cc":
            guard let values = fields(bwe, body), let timestamp = Int64(values[0]),
                  let pushback = nativeRate(values[1]), let estimate = nativeRate(values[2]) else {
                return nil
            }
            return .bweUpdated(
                nativeTimestampMilliseconds: timestamp,
                pushbackTargetBps: pushback,
                estimateBps: estimate
            )
        case "alr_experiment.cc":
            guard let values = fields(alr, body), let factor = Double(values[0]),
                  factor.isFinite, factor > 0,
                  let queue = Int64(values[1]), let usage = Int32(values[2]),
                  let start = Int32(values[3]), let end = Int32(values[4]),
                  let group = Int32(values[5]) else { return nil }
            return .alrSettings(
                pacingFactor: factor,
                maxPacerQueueMilliseconds: queue,
                bandwidthUsagePercent: usage,
                startBudgetLevelPercent: start,
                endBudgetLevelPercent: end,
                groupID: group
            )
        default: return nil
        }
    }

    private static func nativeRate(_ token: String) -> UInt64? {
        guard let value = UInt64(token), value <= Int64.max else { return nil }
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
