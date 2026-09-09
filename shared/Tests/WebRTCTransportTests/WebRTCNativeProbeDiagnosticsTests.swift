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

    func testEstimatorResultsPreserveOnlyTypedRatesAndClusterNumber() throws {
        let success = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(successful))
        XCTAssertEqual(success, ParsedNativeProbeEvent(
            kind: .probeSucceeded, bitrateBps: 1_200_000,
            receiveBitrateBps: 960_000, clusterID: 7
        ))
        let invalidInterval = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            "(probe_bitrate_estimator.cc:114): Probing unsuccessful, invalid send/receive interval [cluster id: 8] [send interval: 0 us] [receive interval: -inf ms]"
        ))
        XCTAssertEqual(invalidInterval, ParsedNativeProbeEvent(kind: .invalidInterval, clusterID: 8))
        let ratio = try XCTUnwrap(WebRTCNativeProbeLogParser.parse(
            "(probe_bitrate_estimator.cc:143): Probing unsuccessful, receive/send ratio too high [cluster id: 9] [send: 3000 bytes / 20 ms = 1200 kbps] [receive: 3000 bytes / 10 ms = 2400 kbps ] [ratio: 2400 kbps / 1200 kbps = 2 > kMaxValidRatio (2)]"
        ))
        XCTAssertEqual(ratio, ParsedNativeProbeEvent(
            kind: .invalidRatio, bitrateBps: 1_200_000,
            receiveBitrateBps: 2_400_000, clusterID: 9
        ))
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
