#if os(macOS)
import Foundation
@testable import WebRTCTransport
import XCTest

final class WebRTCNativeProbeDiagnosticsTests: XCTestCase {
    private let created = "(bitrate_prober.cc:130): Probe cluster (bitrate_bps:min bytes:min packets): (827200 bps:1551:5, Active)"
    private let successful = "(probe_bitrate_estimator.cc:164): Probing successful [cluster id: 7] [send: 3000 bytes / 20 ms = 1200 kbps ] [receive: 3000 bytes / 25 ms = 960 kbps]"

    func testCreatedClusterDistinguishesActiveFromWaitingWithoutInventingClusterID() throws {
        let active = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(created))
        XCTAssertEqual(active, ParsedNativeProbeEvent(
            kind: .clusterCreated, isActive: true, bitrateBps: 827_200,
            minimumBytes: 1_551, minimumPackets: 5
        ))
        let inactive = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            "[001:004][7823] " + created
                .replacingOccurrences(of: "Active)", with: "Inactive)")
                .replacingOccurrences(of: "827200 bps", with: "414 kbps") + "\n"
        ))
        XCTAssertEqual(inactive.isActive, false)
        XCTAssertEqual(inactive.bitrateBps, 414_000)
        XCTAssertNil(inactive.clusterID)
    }

    func testEstimatorResultsPreserveTypedRatesIntervalsAndClusterNumber() throws {
        let success = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(successful))
        XCTAssertEqual(success, ParsedNativeProbeEvent(
            kind: .probeSucceeded, bitrateBps: 1_200_000,
            receiveBitrateBps: 960_000, sendInterval: .microseconds(20_000),
            receiveInterval: .microseconds(25_000), clusterID: 7
        ))
        let invalidInterval = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            "(probe_bitrate_estimator.cc:114): Probing unsuccessful, invalid send/receive interval [cluster id: 8] [send interval: 0 us] [receive interval: -inf ms]"
        ))
        XCTAssertEqual(invalidInterval, ParsedNativeProbeEvent(
            kind: .invalidInterval, sendInterval: .microseconds(0),
            receiveInterval: .negativeInfinity, clusterID: 8
        ))
        let ratio = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            "(probe_bitrate_estimator.cc:143): Probing unsuccessful, receive/send ratio too high [cluster id: 9] [send: 3000 bytes / 20 ms = 1200 kbps] [receive: 3000 bytes / 10 ms = 2400 kbps ] [ratio: 2400 kbps / 1200 kbps = 2 > kMaxValidRatio (2)]"
        ))
        XCTAssertEqual(ratio, ParsedNativeProbeEvent(
            kind: .invalidRatio, bitrateBps: 1_200_000,
            receiveBitrateBps: 2_400_000, sendInterval: .microseconds(20_000),
            receiveInterval: .microseconds(10_000), clusterID: 9
        ))
    }

    private func intervalFailure(send: String, receive: String) -> String {
        "(probe_bitrate_estimator.cc:114): Probing unsuccessful, invalid send/receive interval "
            + "[cluster id: 8] [send interval: \(send)] [receive interval: \(receive)]"
    }

    func testFiniteIntervalsPreserveUnitsSignAndNativeOneSecondBoundary() throws {
        let cases: [(String, Int64)] = [
            ("0 us", 0), ("-1 us", -1), ("250 us", 250),
            ("12 ms", 12_000), ("-12 ms", -12_000), ("1 s", 1_000_000),
            ("1000 ms", 1_000_000), ("1000001 us", 1_000_001),
            ("2 s", 2_000_000), ("-2 s", -2_000_000),
            ("9223372036854775 ms", 9_223_372_036_854_775_000),
            ("-9223372036854775 ms", -9_223_372_036_854_775_000)
        ]
        for (token, value) in cases {
            let event = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
                intervalFailure(send: token, receive: token)
            ), token)
            XCTAssertEqual(event.sendInterval, .microseconds(value), token)
            XCTAssertEqual(event.receiveInterval, .microseconds(value), token)
            XCTAssertEqual(event.sendInterval?.diagnosticToken, String(value))
        }
    }

    func testInfiniteIntervalsRemainDistinctFromZeroAndUnknown() throws {
        let event = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            intervalFailure(send: "+inf ms", receive: "-inf ms")
        ))
        XCTAssertEqual(event.sendInterval, .positiveInfinity)
        XCTAssertEqual(event.receiveInterval, .negativeInfinity)
        XCTAssertEqual(event.sendInterval?.diagnosticToken, "positiveInfinity")
        XCTAssertEqual(event.receiveInterval?.diagnosticToken, "negativeInfinity")
        XCTAssertEqual(WebRTCNativeProbeInterval.microseconds(0).diagnosticToken, "0")
        XCTAssertEqual(WebRTCNativeProbeInterval.microseconds(Int64.min).diagnosticToken, String(Int64.min))
        XCTAssertEqual(WebRTCNativeProbeInterval.microseconds(Int64.max).diagnosticToken, String(Int64.max))
        let nonEstimator = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(created))
        XCTAssertNil(nonEstimator.sendInterval)
        XCTAssertNil(nonEstimator.receiveInterval)
    }

    func testMalformedOrOverflowingIntervalsCannotBecomeZeroInfinityOrRetainedText() {
        let collector = WebRTCNativeProbeDiagnosticCollector(startedAtUptimeNanoseconds: 0)
        for token in [
            "9223372036854776 ms", "-9223372036854776 ms", "9223372036855 s",
            "999999999999999999 s", "18446744073709551616 us",
            "NaN ms", "inf ms", "+inf s", "-inf us", "+1 ms", "1.5 ms",
            "1e3 us", "1  ms", "1\tms", "0 us] private=secret [ignored: 0 us"
        ] {
            for message in [intervalFailure(send: token, receive: "20 ms"),
                            intervalFailure(send: "20 ms", receive: token)] {
                XCTAssertNil(WebRTCNativeProbeLogParser.parse(message), token)
                collector.record(message, observedAtUptimeNanoseconds: 1)
            }
        }
        XCTAssertTrue(collector.drain().events.isEmpty)
        XCTAssertNil(WebRTCNativeProbeLogParser.parse(
            successful.replacingOccurrences(of: "20 ms", with: "9223372036854776 ms")
        ))
    }

    func testCollectorRetainsBothIntervalsThroughThePublicEventCopyAndDrain() throws {
        let collector = WebRTCNativeProbeDiagnosticCollector(startedAtUptimeNanoseconds: 0)
        collector.record(successful, observedAtUptimeNanoseconds: 1_000_000)
        collector.record(intervalFailure(send: "0 us", receive: "+inf ms"),
                         observedAtUptimeNanoseconds: 2_000_000)
        let batch = collector.drain()
        XCTAssertEqual(batch.events.count, 2)
        let first = try XCTUnwrap(batch.events.first)
        let last = try XCTUnwrap(batch.events.last)
        XCTAssertEqual(first.sendInterval, .microseconds(20_000))
        XCTAssertEqual(first.receiveInterval, .microseconds(25_000))
        XCTAssertEqual(last.sendInterval, .microseconds(0))
        XCTAssertEqual(last.receiveInterval, .positiveInfinity)
        XCTAssertEqual(batch.events.map(\.sequence), [1, 2])
        XCTAssertEqual(batch.events.map(\.clusterID), [7, 8])
        XCTAssertTrue(collector.drain().events.isEmpty)
    }

    func testControllerEventsUseKnownReasonsAndNormalizeNativeRateUnits() throws {
        let prefix = "(probe_controller.cc:342): "
        let measured = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            prefix + "Measured bitrate: 1073001 bps Minimum to probe further: 900 kbps upper limit: +inf bps"
        ))
        XCTAssertEqual(measured, ParsedNativeProbeEvent(kind: .measuredBitrate, bitrateBps: 1_073_001))
        XCTAssertEqual(WebRTCNativeProbeLogParser.parse(prefix + "kWaitingForProbingResult: timeout")?.kind, .controllerTimedOut)
        for (cause, reason) in [(1, WebRTCNativeProbeBlockReason.loss), (3, .delayIncreased), (4, .highRoundTripTime)] {
            XCTAssertEqual(WebRTCNativeProbeLogParser.parse(
                prefix + "Not sending probe in bandwidth limited state. \(cause)"
            )?.blockReason, reason)
        }
        XCTAssertEqual(WebRTCNativeProbeLogParser.parse(
            prefix + "Not sending probe, Network state estimate is zero"
        )?.blockReason, .zeroNetworkEstimate)
    }

    func testUnknownSensitiveMalformedAndOversizedMessagesCannotBeRetained() {
        let collector = WebRTCNativeProbeDiagnosticCollector(startedAtUptimeNanoseconds: 0)
        let rejected = [
            "(ice_transport.cc:130): " + created,
            "secret " + created,
            created + " candidate: 192.0.2.4 sdp=secret",
            created + "\n" + successful,
            created + "\r\n",
            created.replacingOccurrences(of: "827200", with: "-1"),
            created.replacingOccurrences(of: "827200", with: "18446744073709551616"),
            created.replacingOccurrences(of: "1551", with: "0"),
            created.replacingOccurrences(of: "Active)", with: "Unknown)"),
            created.replacingOccurrences(of: ":130):", with: ":NaN):"),
            created.replacingOccurrences(of: "bitrate_prober.cc:", with: "/private/bitrate_prober.cc:"),
            "(probe_controller.cc:568): Not sending probe in bandwidth limited state. 0",
            successful + " token=private",
            "(probe_controller.cc:342): Measured bitrate: NaN bps Minimum to probe further: 900 kbps upper limit: +inf bps",
            String(repeating: "x", count: 2_049),
            created + "🔑"
        ]
        for message in rejected {
            XCTAssertNil(WebRTCNativeProbeLogParser.parse(message))
            collector.record(message, observedAtUptimeNanoseconds: 1)
        }
        XCTAssertEqual(collector.drain(), WebRTCNativeProbeDiagnosticsBatch(events: [], droppedEventCount: 0))
    }

    func testRingIsBoundedDrainedOnceAndRetainsMonotonicProcessSequenceAndAge() {
        let collector = WebRTCNativeProbeDiagnosticCollector(startedAtUptimeNanoseconds: 1_000_000)
        for index in 1...70 {
            collector.record(created, observedAtUptimeNanoseconds: UInt64(index + 1) * 1_000_000)
        }
        let batch = collector.drain()
        XCTAssertEqual(batch.events.count, 64)
        XCTAssertEqual(batch.events.map(\.sequence), Array(UInt64(7)...70))
        XCTAssertEqual(batch.events.map(\.processDiagnosticsAgeMilliseconds), Array(UInt64(7)...70))
        XCTAssertEqual(batch.droppedEventCount, 6)
        XCTAssertTrue(collector.drain().events.isEmpty)
        collector.record(created, observedAtUptimeNanoseconds: 0)
        let next = collector.drain()
        XCTAssertEqual(next.events.first?.sequence, 71)
        XCTAssertEqual(next.events.first?.processDiagnosticsAgeMilliseconds, 70)
        XCTAssertEqual(next.droppedEventCount, 6)
    }

    func testConcurrentCallbacksCannotGrowRetentionOrDuplicateSequence() {
        let collector = WebRTCNativeProbeDiagnosticCollector(startedAtUptimeNanoseconds: 0)
        let message = created
        DispatchQueue.concurrentPerform(iterations: 256) { index in
            collector.record(message, observedAtUptimeNanoseconds: UInt64(index) * 1_000_000)
        }
        let batch = collector.drain()
        XCTAssertEqual(batch.events.count, 64)
        XCTAssertEqual(batch.droppedEventCount, 192)
        XCTAssertEqual(batch.events.map(\.sequence), Array(UInt64(193)...256))
        XCTAssertEqual(batch.events.map(\.processDiagnosticsAgeMilliseconds), batch.events.map(\.processDiagnosticsAgeMilliseconds).sorted())
    }
}
#endif
