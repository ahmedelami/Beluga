#if os(macOS)
import Foundation
@preconcurrency import LiveKitWebRTC

public enum WebRTCNativeProbeEventKind: String, Equatable, Sendable {
    case clusterCreated
    case probeSucceeded
    case invalidInterval
    case invalidRatio
    case controllerTimedOut
    case controllerBlocked
    case measuredBitrate
}

public enum WebRTCNativeProbeBlockReason: String, Equatable, Sendable {
    case loss
    case delayIncreased
    case highRoundTripTime
    case zeroNetworkEstimate
}

/// Native logging has process scope, not peer ownership. Age starts when this collector starts,
/// not at connection establishment; no field identifies an endpoint or contains native log text.
public struct WebRTCNativeProbeEvent: Equatable, Sendable {
    public let sequence: UInt64
    public let processDiagnosticsAgeMilliseconds: UInt64
    public let kind: WebRTCNativeProbeEventKind
    public let isActive: Bool?
    public let bitrateBps: UInt64?
    public let receiveBitrateBps: UInt64?
    public let minimumBytes: UInt64?
    public let minimumPackets: UInt64?
    public let clusterID: UInt64?
    public let blockReason: WebRTCNativeProbeBlockReason?
}

public struct WebRTCNativeProbeDiagnosticsBatch: Equatable, Sendable {
    public let events: [WebRTCNativeProbeEvent]
    public let droppedEventCount: UInt64
}

/// One process-lifetime sink. Draining never starts native logging or changes media state.
public enum WebRTCNativeProbeDiagnostics {
    private static let collector = WebRTCNativeProbeDiagnosticCollector()
    private static let registration = NativeProbeLogRegistration(collector: collector)

    public static func start() {
        _ = registration
    }

    public static func drain() -> WebRTCNativeProbeDiagnosticsBatch {
        collector.drain()
    }
}

private final class NativeProbeLogRegistration: @unchecked Sendable {
    private let logger: LKRTCCallbackLogger

    init(collector: WebRTCNativeProbeDiagnosticCollector) {
        WebRTCNativeProbeLogParser.prepare()
        let logger = LKRTCCallbackLogger()
        self.logger = logger
        logger.severity = .info
        // The SDK calls this while holding its logging lock. Never log, dispatch synchronously,
        // or manage the native sink from this callback. Static initialization serializes start.
        logger.start { @Sendable message in
            collector.record(message)
        }
    }
}

struct ParsedNativeProbeEvent: Equatable, Sendable {
    var kind: WebRTCNativeProbeEventKind
    var isActive: Bool? = nil
    var bitrateBps: UInt64? = nil
    var receiveBitrateBps: UInt64? = nil
    var minimumBytes: UInt64? = nil
    var minimumPackets: UInt64? = nil
    var clusterID: UInt64? = nil
    var blockReason: WebRTCNativeProbeBlockReason? = nil
}

final class WebRTCNativeProbeDiagnosticCollector: @unchecked Sendable {
    static let capacity = 64
    private let lock = NSLock()
    private let startedAtUptimeNanoseconds: UInt64
    private var events: [WebRTCNativeProbeEvent] = []
    private var sequence: UInt64 = 0
    private var lastAgeMilliseconds: UInt64 = 0
    private var droppedEventCount: UInt64 = 0

    init(startedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startedAtUptimeNanoseconds = startedAtUptimeNanoseconds
        events.reserveCapacity(Self.capacity)
    }

    func record(
        _ message: String,
        observedAtUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard let parsed = WebRTCNativeProbeLogParser.parse(message) else { return }
        lock.withLock {
            guard sequence < UInt64.max else {
                countDrop()
                return
            }
            sequence += 1
            let age = observedAtUptimeNanoseconds >= startedAtUptimeNanoseconds
                ? (observedAtUptimeNanoseconds - startedAtUptimeNanoseconds) / 1_000_000
                : 0
            lastAgeMilliseconds = max(lastAgeMilliseconds, age)
            if events.count == Self.capacity {
                events.removeFirst()
                countDrop()
            }
            events.append(WebRTCNativeProbeEvent(
                sequence: sequence,
                processDiagnosticsAgeMilliseconds: lastAgeMilliseconds,
                kind: parsed.kind,
                isActive: parsed.isActive,
                bitrateBps: parsed.bitrateBps,
                receiveBitrateBps: parsed.receiveBitrateBps,
                minimumBytes: parsed.minimumBytes,
                minimumPackets: parsed.minimumPackets,
                clusterID: parsed.clusterID,
                blockReason: parsed.blockReason
            ))
        }
    }

    func drain() -> WebRTCNativeProbeDiagnosticsBatch {
        lock.withLock {
            let batch = WebRTCNativeProbeDiagnosticsBatch(
                events: events,
                droppedEventCount: droppedEventCount
            )
            events.removeAll(keepingCapacity: true)
            return batch
        }
    }

    private func countDrop() {
        if droppedEventCount < UInt64.max { droppedEventCount += 1 }
    }
}

/// Exact allowlist for the pinned SDK's three probe source files. Reject unknown text before
/// retention; regex work is bounded and occurs only after a known source/template prefix.
enum WebRTCNativeProbeLogParser {
    static let maximumMessageBytes = 2_048
    private static let rate = #"([0-9]{1,15}) (bps|kbps)"#
    private static let anyRate = #"(?:[0-9]{1,15} (?:bps|kbps)|[+-]inf bps)"#
    private static let interval = #"(?:-?[0-9]{1,18} (?:us|ms|s)|[+-]inf ms)"#
    private static let decimal = #"[0-9]{1,18}(?:\.[0-9]{1,18})?(?:e[+-]?[0-9]{1,3})?"#
    private static let cluster = expression(
        #"Probe cluster \(bitrate_bps:min bytes:min packets\): \("# + rate
            + #":([0-9]{1,15}):([0-9]{1,9}), (Active|Inactive)\)"#
    )
    private static let success = expression(
        #"Probing successful \[cluster id: ([0-9]{1,10})\] \[send: [0-9]{1,15} bytes / "#
            + interval + " = " + rate + #" \] \[receive: [0-9]{1,15} bytes / "#
            + interval + " = " + rate + #"\]"#
    )
    private static let invalidInterval = expression(
        #"Probing unsuccessful, invalid send/receive interval \[cluster id: ([0-9]{1,10})\] \[send interval: "#
            + interval + #"\] \[receive interval: "# + interval + #"\]"#
    )
    private static let invalidRatio = expression(
        #"Probing unsuccessful, receive/send ratio too high \[cluster id: ([0-9]{1,10})\] \[send: [0-9]{1,15} bytes / "#
            + interval + " = " + rate + #"\] \[receive: [0-9]{1,15} bytes / "#
            + interval + " = " + rate + #" \] \[ratio: "# + anyRate + " / "
            + anyRate + " = " + decimal + #" > kMaxValidRatio \("# + decimal + #"\)\]"#
    )
    private static let measured = expression(
        "Measured bitrate: " + rate + " Minimum to probe further: " + anyRate
            + " upper limit: " + anyRate
    )

    static func prepare() {
        _ = cluster
        _ = success
        _ = invalidInterval
        _ = invalidRatio
        _ = measured
    }

    static func parse(_ message: String) -> ParsedNativeProbeEvent? {
        guard message.utf8.prefix(maximumMessageBytes + 1).count <= maximumMessageBytes else {
            return nil
        }
        var line = message[...]
        if line.last == "\n" { line = line.dropLast() }
        guard line.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              let opening = line.firstIndex(of: "("),
              line.distance(from: line.startIndex, to: opening) <= 64 else { return nil }
        let prefix = line[..<opening]
        guard prefix.utf8.allSatisfy({ byte in
            byte == 32 || byte == 58 || byte == 91 || byte == 93 || (48...57).contains(byte)
        }) else { return nil }
        let sourceAndBody = line[line.index(after: opening)...]
        let source: Substring
        if sourceAndBody.hasPrefix("bitrate_prober.cc:") {
            source = "bitrate_prober.cc"
        } else if sourceAndBody.hasPrefix("probe_controller.cc:") {
            source = "probe_controller.cc"
        } else if sourceAndBody.hasPrefix("probe_bitrate_estimator.cc:") {
            source = "probe_bitrate_estimator.cc"
        } else {
            return nil
        }
        let suffix = sourceAndBody.dropFirst(source.count + 1)
        guard let separator = suffix.range(of: "): "),
              (1...6).contains(suffix[..<separator.lowerBound].count),
              suffix[..<separator.lowerBound].utf8.allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }
        let body = String(suffix[separator.upperBound...])
        switch source {
        case "bitrate_prober.cc":
            guard body.hasPrefix("Probe cluster ("), let fields = fields(cluster, in: body),
                  let bitrate = bitrate(fields[0], unit: fields[1]), bitrate > 0,
                  let bytes = positive(fields[2]),
                  let packets = positive(fields[3]) else { return nil }
            return ParsedNativeProbeEvent(
                kind: .clusterCreated, isActive: fields[4] == "Active",
                bitrateBps: bitrate, minimumBytes: bytes, minimumPackets: packets
            )
        case "probe_bitrate_estimator.cc":
            if body.hasPrefix("Probing successful "), let fields = fields(success, in: body) {
                return result(fields, kind: .probeSucceeded)
            }
            if body.hasPrefix("Probing unsuccessful, invalid send/receive interval "),
               let fields = fields(invalidInterval, in: body), let id = UInt64(fields[0]) {
                return ParsedNativeProbeEvent(kind: .invalidInterval, clusterID: id)
            }
            if body.hasPrefix("Probing unsuccessful, receive/send ratio too high "),
               let fields = fields(invalidRatio, in: body) {
                return result(fields, kind: .invalidRatio)
            }
            return nil
        case "probe_controller.cc":
            if body == "kWaitingForProbingResult: timeout" {
                return ParsedNativeProbeEvent(kind: .controllerTimedOut)
            }
            let blockReason: WebRTCNativeProbeBlockReason?
            switch body {
            case "Not sending probe in bandwidth limited state. 1": blockReason = .loss
            case "Not sending probe in bandwidth limited state. 3": blockReason = .delayIncreased
            case "Not sending probe in bandwidth limited state. 4": blockReason = .highRoundTripTime
            case "Not sending probe, Network state estimate is zero": blockReason = .zeroNetworkEstimate
            default: blockReason = nil
            }
            if let blockReason {
                return ParsedNativeProbeEvent(kind: .controllerBlocked, blockReason: blockReason)
            }
            if body.hasPrefix("Measured bitrate: "), let fields = fields(measured, in: body),
               let bitrate = bitrate(fields[0], unit: fields[1]) {
                return ParsedNativeProbeEvent(kind: .measuredBitrate, bitrateBps: bitrate)
            }
            return nil
        default:
            return nil
        }
    }

    private static func result(
        _ fields: [String], kind: WebRTCNativeProbeEventKind
    ) -> ParsedNativeProbeEvent? {
        guard let id = UInt64(fields[0]),
              let send = bitrate(fields[1], unit: fields[2]),
              let receive = bitrate(fields[3], unit: fields[4]) else { return nil }
        return ParsedNativeProbeEvent(
            kind: kind, bitrateBps: send, receiveBitrateBps: receive, clusterID: id
        )
    }

    private static func positive(_ value: String) -> UInt64? {
        guard let number = UInt64(value), number > 0 else { return nil }
        return number
    }

    private static func bitrate(_ value: String, unit: String) -> UInt64? {
        guard let value = UInt64(value) else { return nil }
        let (result, overflow) = value.multipliedReportingOverflow(by: unit == "kbps" ? 1_000 : 1)
        return overflow ? nil : result
    }

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "^(?:" + pattern + ")$")
    }

    private static func fields(_ expression: NSRegularExpression?, in body: String) -> [String]? {
        guard let expression,
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              match.range.length == body.utf16.count else { return nil }
        var values: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: body) else { return nil }
            values.append(String(body[range]))
        }
        return values
    }
}
#endif
