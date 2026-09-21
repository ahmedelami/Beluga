#if os(macOS)
import Foundation

/// Opt-in fixture diagnostics, not a packet scheduler or an authenticated protocol parser.
/// Only successful UDP sends contribute traffic/timing evidence. Retained events contain
/// header classifications and scalar times, never payloads, transaction IDs or endpoints.
struct StartupVideoDatagramTrafficMeasurements: Codable, Sendable {
    enum BindingClass: String, Codable, Sendable {
        case request, indication, successResponse, errorResponse
    }

    struct DirectionCounters: Codable, Sendable {
        var forwardedDatagrams: UInt64 = 0
        var forwardedBytes: UInt64 = 0
        var rtpV2ShapedDatagrams: UInt64 = 0
        var rtpV2ShapedBytes: UInt64 = 0
        var otherDatagrams: UInt64 = 0
        var otherBytes: UInt64 = 0
        var bindingRequests: UInt64 = 0
        var bindingIndications: UInt64 = 0
        var bindingSuccessResponses: UInt64 = 0
        var bindingErrorResponses: UInt64 = 0
        var maximumBindingModeledResidenceNanoseconds: UInt64 = 0
        var maximumBindingCallbackLatenessNanoseconds: UInt64 = 0
        var maximumBindingActualResidenceNanoseconds: UInt64 = 0
    }

    struct BindingEvent: Codable, Sendable {
        let direction: String
        let bindingClass: BindingClass
        let byteCount: Int
        let receivedAtNanoseconds: UInt64
        let deliveryDeadlineNanoseconds: UInt64
        /// Successful send attempt's entry time, not syscall completion or remote delivery.
        let sentAtNanoseconds: UInt64
        /// Includes the fixture's propagation delay and this packet's serialization.
        let modeledResidenceNanoseconds: UInt64
        let callbackLatenessNanoseconds: UInt64
        let actualResidenceNanoseconds: UInt64
    }

    static let maximumBindingEvents = 256
    private(set) var hostToViewer = DirectionCounters()
    private(set) var viewerToHost = DirectionCounters()
    private(set) var bindingEvents: [BindingEvent] = []
    private(set) var omittedBindingEvents: UInt64 = 0
    private(set) var invalidTimingDatagrams: UInt64 = 0
    private(set) var unsuccessfulSendAttempts: UInt64 = 0
    private(set) var counterSaturated = false

    /// The native caller supplies sendto's result; failure/backpressure cannot be
    /// mistaken for forwarding, even if a caller invokes this outside its success branch.
    mutating func recordSendResult(
        _ datagram: StartupVideoDatagramScheduler.Datagram,
        sentByteCount: Int,
        at sentAt: UInt64
    ) {
        guard sentByteCount == datagram.bytes.count else {
            Self.increment(&unsuccessfulSendAttempts, saturated: &counterSaturated)
            return
        }
        switch datagram.from {
        case .host:
            var counters = hostToViewer
            recordForwarded(datagram, at: sentAt, counters: &counters)
            hostToViewer = counters
        case .viewer:
            var counters = viewerToHost
            recordForwarded(datagram, at: sentAt, counters: &counters)
            viewerToHost = counters
        }
    }

    private mutating func recordForwarded(
        _ datagram: StartupVideoDatagramScheduler.Datagram,
        at sentAt: UInt64,
        counters: inout DirectionCounters
    ) {
        let byteCount = UInt64(datagram.bytes.count)
        Self.increment(&counters.forwardedDatagrams, saturated: &counterSaturated)
        Self.increment(&counters.forwardedBytes, by: byteCount, saturated: &counterSaturated)
        if Self.isRTPV2Shaped(datagram.bytes) {
            Self.increment(&counters.rtpV2ShapedDatagrams, saturated: &counterSaturated)
            Self.increment(&counters.rtpV2ShapedBytes, by: byteCount, saturated: &counterSaturated)
        } else {
            Self.increment(&counters.otherDatagrams, saturated: &counterSaturated)
            Self.increment(&counters.otherBytes, by: byteCount, saturated: &counterSaturated)
        }
        guard let bindingClass = Self.bindingClass(in: datagram.bytes) else { return }
        switch bindingClass {
        case .request: Self.increment(&counters.bindingRequests, saturated: &counterSaturated)
        case .indication: Self.increment(&counters.bindingIndications, saturated: &counterSaturated)
        case .successResponse: Self.increment(&counters.bindingSuccessResponses, saturated: &counterSaturated)
        case .errorResponse: Self.increment(&counters.bindingErrorResponses, saturated: &counterSaturated)
        }
        guard datagram.receivedAt <= datagram.deliveryDeadline,
              datagram.deliveryDeadline <= sentAt else {
            Self.increment(&invalidTimingDatagrams, saturated: &counterSaturated)
            return
        }
        let modeledResidence = datagram.deliveryDeadline - datagram.receivedAt
        let callbackLateness = sentAt - datagram.deliveryDeadline
        let actualResidence = sentAt - datagram.receivedAt
        counters.maximumBindingModeledResidenceNanoseconds = max(
            counters.maximumBindingModeledResidenceNanoseconds, modeledResidence)
        counters.maximumBindingCallbackLatenessNanoseconds = max(
            counters.maximumBindingCallbackLatenessNanoseconds, callbackLateness)
        counters.maximumBindingActualResidenceNanoseconds = max(
            counters.maximumBindingActualResidenceNanoseconds, actualResidence)
        guard bindingEvents.count < Self.maximumBindingEvents else {
            Self.increment(&omittedBindingEvents, saturated: &counterSaturated)
            return
        }
        bindingEvents.append(BindingEvent(
            direction: datagram.from == .host ? "hostToViewer" : "viewerToHost",
            bindingClass: bindingClass,
            byteCount: datagram.bytes.count,
            receivedAtNanoseconds: datagram.receivedAt,
            deliveryDeadlineNanoseconds: datagram.deliveryDeadline,
            sentAtNanoseconds: sentAt,
            modeledResidenceNanoseconds: modeledResidence,
            callbackLatenessNanoseconds: callbackLateness,
            actualResidenceNanoseconds: actualResidence))
    }

    /// Validate the complete public STUN header and datagram length, not encrypted
    /// attributes or message integrity. Other STUN methods remain classified as other.
    static func bindingClass(in bytes: Data) -> BindingClass? {
        guard bytes.count >= 20 else { return nil }
        return bytes.withUnsafeBytes { raw -> BindingClass? in
            let header = raw.bindMemory(to: UInt8.self)
            guard header[0] & 0xc0 == 0,
                  header[4] == 0x21, header[5] == 0x12,
                  header[6] == 0xa4, header[7] == 0x42 else { return nil }
            let length = Int(header[2]) << 8 | Int(header[3])
            guard length % 4 == 0, length == bytes.count - 20 else { return nil }
            switch UInt16(header[0]) << 8 | UInt16(header[1]) {
            case 0x0001: return .request
            case 0x0011: return .indication
            case 0x0101: return .successResponse
            case 0x0111: return .errorResponse
            default: return nil
            }
        }
    }

    /// Header shape only. SRTP/SRTCP authentication, padding and media contents are
    /// unavailable here; these bytes are not a decrypted-video or padding measurement.
    static func isRTPV2Shaped(_ bytes: Data) -> Bool {
        guard bytes.count >= 12 else { return false }
        return bytes.withUnsafeBytes { raw in
            let header = raw.bindMemory(to: UInt8.self)
            return header[0] & 0xc0 == 0x80
                && bytes.count >= 12 + 4 * Int(header[0] & 0x0f)
        }
    }

    static func increment(_ value: inout UInt64, by amount: UInt64 = 1, saturated: inout Bool) {
        let result = value.addingReportingOverflow(amount)
        value = result.overflow ? .max : result.partialValue
        saturated = saturated || result.overflow
    }
}
#endif
