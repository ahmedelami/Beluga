#if os(macOS)
import Foundation
import XCTest

final class StartupVideoNativePacingObserverTests: XCTestCase {
    private let pacer = "(pacing_controller.cc:188): bwe:pacer_updated pacing_kbps=920 padding_budget_kbps=0"
    private let bwe = "(goog_cc_network_control.cc:644): bwe 1234567 pushback_target_bps=760000 estimate_bps=800000"
    private let alr = "(alr_experiment.cc:69): Using ALR experiment settings: pacing factor: 1.15, max pacer queue length: 2875, ALR bandwidth usage percent: 80, ALR start budget level percent: 40, ALR end budget level percent: -60, ALR experiment group ID: 3"

    func testParsesExactPacerAndControllerNumericEventsWithoutPeerAttribution() {
        XCTAssertEqual(StartupVideoNativePacingParser.parse(pacer),
                       .pacerUpdated(pacingKbps: 920, paddingBudgetKbps: 0))
        XCTAssertEqual(StartupVideoNativePacingParser.parse("[123:456][789] " + bwe + "\n"),
                       .bweUpdated(nativeTimestampMilliseconds: 1_234_567,
                                   pushbackTargetBps: 760_000, estimateBps: 800_000))
        XCTAssertEqual(StartupVideoNativePacingParser.parse(
            bwe.replacingOccurrences(of: "1234567", with: "-1")
        ), .bweUpdated(nativeTimestampMilliseconds: -1, pushbackTargetBps: 760_000,
                       estimateBps: 800_000))
    }

    func testPreservesAllSixALRFieldsAndBothDefaultAndExperimentalFactors() {
        XCTAssertEqual(StartupVideoNativePacingParser.parse(alr),
                       .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875,
                                    bandwidthUsagePercent: 80, startBudgetLevelPercent: 40,
                                    endBudgetLevelPercent: -60, groupID: 3))
        XCTAssertEqual(StartupVideoNativePacingParser.parse(
            alr.replacingOccurrences(of: "factor: 1.15", with: "factor: 1")
        ), .alrSettings(pacingFactor: 1, maxPacerQueueMilliseconds: 2875,
                        bandwidthUsagePercent: 80, startBudgetLevelPercent: 40,
                        endBudgetLevelPercent: -60, groupID: 3))
    }

    func testRejectsWrongSourceUnscopedTextAndInjectedPrefixOrLines() {
        let rejected = [
            pacer.replacingOccurrences(of: "pacing_controller.cc", with: "unrelated.cc"),
            pacer.replacingOccurrences(of: "pacing_controller.cc", with: "goog_cc_network_control.cc"),
            "bwe:pacer_updated pacing_kbps=920 padding_budget_kbps=0",
            "secret " + pacer, "/path/" + pacer, pacer + "\n" + bwe,
            pacer + "\r\n", pacer + "\n\n", pacer + "é",
            pacer.replacingOccurrences(of: ":188", with: ":-1"),
            pacer.replacingOccurrences(of: ":188", with: ":1234567"),
            pacer.replacingOccurrences(of: ":188", with: ":"),
            String(repeating: "0", count: 65) + pacer
        ]
        for value in rejected { XCTAssertNil(StartupVideoNativePacingParser.parse(value)) }
    }

    func testRejectsMissingDuplicateUnknownAndReorderedFields() {
        let rejected = [
            pacer + " padding_budget_kbps=1", pacer + " unknown=1",
            pacer.replacingOccurrences(of: " padding_budget_kbps=0", with: ""),
            pacer.replacingOccurrences(of: "pacing_kbps=920 padding_budget_kbps=0",
                                       with: "padding_budget_kbps=0 pacing_kbps=920"),
            bwe + " estimate_bps=1", bwe + " unknown=1",
            bwe.replacingOccurrences(of: " estimate_bps=800000", with: ""),
            alr + ", ALR experiment group ID: 4", alr + ", unknown: 1",
            alr.replacingOccurrences(of: ", ALR experiment group ID: 3", with: ""),
            alr.replacingOccurrences(of: "ALR end budget", with: "ALR stop budget")
        ]
        for value in rejected { XCTAssertNil(StartupVideoNativePacingParser.parse(value)) }
    }

    func testRejectsMalformedNonfiniteAndOverflowNumbers() {
        for token in ["-1", "+1", "1.5", "NaN", "inf", "9223372036854775808", "18446744073709551616"] {
            XCTAssertNil(StartupVideoNativePacingParser.parse(
                pacer.replacingOccurrences(of: "pacing_kbps=920", with: "pacing_kbps=" + token)
            ))
        }
        for token in ["0", "-1", "NaN", "inf", "1e999"] {
            XCTAssertNil(StartupVideoNativePacingParser.parse(
                alr.replacingOccurrences(of: "factor: 1.15", with: "factor: " + token)
            ))
        }
        XCTAssertNil(StartupVideoNativePacingParser.parse(
            bwe.replacingOccurrences(of: "1234567", with: "9223372036854775808")
        ))
        XCTAssertNil(StartupVideoNativePacingParser.parse(
            alr.replacingOccurrences(of: "length: 2875", with: "length: 9223372036854775808")
        ))
        XCTAssertNil(StartupVideoNativePacingParser.parse(
            alr.replacingOccurrences(of: "percent: -60", with: "percent: -2147483649")
        ))
        XCTAssertNil(StartupVideoNativePacingParser.parse(
            alr.replacingOccurrences(of: "ID: 3", with: "ID: 2147483648")
        ))
        XCTAssertNil(StartupVideoNativePacingParser.parse(
            String(repeating: "0", count: StartupVideoNativePacingParser.maximumMessageBytes + 1)
        ))
    }

    func testPreservesIntegerBoundariesAndZeroRates() {
        XCTAssertEqual(StartupVideoNativePacingParser.parse(
            pacer.replacingOccurrences(of: "pacing_kbps=920", with: "pacing_kbps=9223372036854775807")
        ), .pacerUpdated(pacingKbps: UInt64(Int64.max), paddingBudgetKbps: 0))
        XCTAssertEqual(StartupVideoNativePacingParser.parse(
            pacer.replacingOccurrences(of: "pacing_kbps=920", with: "pacing_kbps=0")
        ), .pacerUpdated(pacingKbps: 0, paddingBudgetKbps: 0))
        XCTAssertEqual(StartupVideoNativePacingParser.parse(
            bwe.replacingOccurrences(of: "1234567", with: "-9223372036854775808")
        ), .bweUpdated(nativeTimestampMilliseconds: Int64.min, pushbackTargetBps: 760_000,
                       estimateBps: 800_000))
    }

    func testCollectorCopiesAllPayloadsTimingAndCountersWithoutRawLogRetention() throws {
        let collector = StartupVideoNativePacingCollector(startedAtUptimeNanoseconds: 1_000_000)
        collector.record(pacer, observedAtUptimeNanoseconds: 2_500_000, observedThreadID: 41)
        collector.record(bwe, observedAtUptimeNanoseconds: 3_000_000, observedThreadID: 42)
        collector.record(alr, observedAtUptimeNanoseconds: 4_000_000, observedThreadID: 41)
        collector.record("private unrelated SDK message", observedAtUptimeNanoseconds: 5_000_000)
        collector.record(pacer, observedAtUptimeNanoseconds: 999_999)
        collector.record(pacer, observedAtUptimeNanoseconds: 5_000_000, observedThreadID: 0)
        let batch = collector.snapshot()
        XCTAssertEqual(batch.scope, .process)
        XCTAssertEqual(batch.startedAtUptimeNanoseconds, 1_000_000)
        XCTAssertEqual(batch.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(batch.events.map(\.threadID), [41, 42, 41])
        XCTAssertEqual(batch.events.map(\.callbackUptimeNanoseconds), [2_500_000, 3_000_000, 4_000_000])
        XCTAssertEqual(batch.events.map(\.processObserverAgeMilliseconds), [1, 2, 3])
        XCTAssertEqual(batch.events.map(\.payload), [
            .pacerUpdated(pacingKbps: 920, paddingBudgetKbps: 0),
            .bweUpdated(nativeTimestampMilliseconds: 1_234_567, pushbackTargetBps: 760_000,
                        estimateBps: 800_000),
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875,
                         bandwidthUsagePercent: 80, startBudgetLevelPercent: 40,
                         endBudgetLevelPercent: -60, groupID: 3)
        ])
        XCTAssertEqual(batch.matchingEventCount, 3)
        XCTAssertEqual(batch.droppedEventCount, 0)
        XCTAssertEqual(batch.rejectedMessageCount, 1)
        XCTAssertEqual(batch.invalidObservationTimeCount, 1)
        XCTAssertEqual(batch.invalidThreadIDCount, 1)
        XCTAssertEqual(collector.snapshot(), batch)
        let encoded = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativePacingBatch.self, from: encoded), batch)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["private", "unrelated", "pacing_controller.cc", "peer", "bwe:pacer"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testCollectorBoundsFirstEventsAndRetainsCumulativeOverflowAcrossSnapshots() {
        let collector = StartupVideoNativePacingCollector(startedAtUptimeNanoseconds: 0)
        for index in 0..<(StartupVideoNativePacingCollector.capacity + 3) {
            collector.record(pacer, observedAtUptimeNanoseconds: UInt64(index))
        }
        let batch = collector.snapshot()
        XCTAssertEqual(batch.events.count, 4_096)
        XCTAssertEqual(batch.events.first?.sequence, 1)
        XCTAssertEqual(batch.events.last?.sequence, 4_096)
        XCTAssertEqual(batch.matchingEventCount, 4_099)
        XCTAssertEqual(batch.droppedEventCount, 3)
        XCTAssertEqual(collector.snapshot(), batch)
        collector.record(bwe, observedAtUptimeNanoseconds: 5_000)
        XCTAssertEqual(collector.snapshot().matchingEventCount, 4_100)
        XCTAssertEqual(collector.snapshot().droppedEventCount, 4)
        XCTAssertEqual(collector.snapshot().events, batch.events)
    }
}
#endif
