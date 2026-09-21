#if os(macOS)
import Foundation
import XCTest

final class StartupVideoNativePacingWitnessTests: XCTestCase {
    private let started: UInt64 = 1_000_000_000
    private let captureStarted: UInt64 = 2_000_000_000
    private var binding: StartupVideoNativePacingBinding {
        .init(hostWorkerID: 41, viewerWorkerID: 42, registeredAtUptimeNanoseconds: 1_500_000_000)
    }

    func testThreeAdvancingHostPairsVerifyEachFactorAndRoundTripWithoutPeerGuessing() throws {
        for factor in [1.0, 1.15] {
            let result = evaluate(fixture(factor: factor), expectedFactor: factor)
            XCTAssertTrue(result.isVerified, "\(result.failures)")
            XCTAssertEqual(result.counts.matchedPairs, 3)
            XCTAssertEqual(result.matchedPairs.map(\.nativeTimestampMilliseconds), [1_000, 1_100, 1_200])
            XCTAssertEqual(result.matchedPairs.map(\.estimateBps), [800_000, 900_000, 1_000_000])
            XCTAssertEqual(result.matchedPairs.map(\.pushbackTargetBps), [640_000, 720_000, 800_000])
            XCTAssertEqual(result.counts.matchingALRSettings, 1)
            XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativePacingWitnessSummary.self,
                                                    from: JSONEncoder().encode(result)), result)
        }
    }

    func testContradictedFactorIsRejectedEvenWithCorrectALRIntent() {
        for (actual, expected) in [(1.0, 1.15), (1.15, 1.0)] {
            var events = fixture(factor: actual)
            events[0] = event(time: started + 1_000, payload: alr(expected))
            let result = evaluate(events, expectedFactor: expected)
            XCTAssertFalse(result.isVerified)
            XCTAssertEqual(result.counts.contradictedFactorMatches, 3)
            XCTAssertEqual(result.counts.matchedPairs, 0)
            XCTAssertTrue(result.failures.contains(.contradictedFactorObserved))
        }
    }

    func testUsesEstimateRatherThanPushbackTargetAndDoesNotBlessClampedRatios() {
        var events = fixture()
        for index in 0..<3 {
            let estimate = UInt64(800_000 + index * 100_000)
            events[index * 2 + 2] = event(
                time: events[index * 2 + 2].callbackUptimeNanoseconds,
                payload: .pacerUpdated(pacingKbps: estimate * 80 / 100 * 115 / 100 / 1_000,
                                       paddingBudgetKbps: 0)
            )
        }
        let result = evaluate(events)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.ratioMismatches, 3)
        XCTAssertEqual(result.counts.matchedPairs, 0)
    }

    func testViewerEventsAreExcludedAndUnknownOrWrongBindingsCannotSupplyHostEvidence() {
        var events = fixture()
        let extra = event(time: 3_005_000_000, thread: 42,
                          payload: .pacerUpdated(pacingKbps: 1, paddingBudgetKbps: 0))
        events.insert(extra, at: 2)
        let ordinary = evaluate(events)
        XCTAssertTrue(ordinary.isVerified)
        XCTAssertEqual(ordinary.counts.excludedViewerEvents, 1)

        events[2] = event(time: extra.callbackUptimeNanoseconds, thread: 999, payload: extra.payload)
        let unknown = evaluate(events)
        XCTAssertFalse(unknown.isVerified)
        XCTAssertEqual(unknown.counts.unknownThreadEvents, 1)
        XCTAssertTrue(unknown.failures.contains(.unknownThreadEvidence))

        let swapped = StartupVideoNativePacingWitness.evaluate(
            batch: batch(fixture()),
            binding: .init(hostWorkerID: 42, viewerWorkerID: 41, registeredAtUptimeNanoseconds: 1_500_000_000),
            captureStartedAtUptimeNanoseconds: captureStarted, expectedFactor: 1.15
        )
        XCTAssertFalse(swapped.isVerified)
        XCTAssertEqual(swapped.counts.matchedPairs, 0)
        XCTAssertEqual(swapped.counts.excludedViewerEvents, 6)
        let invalidIDs: [(UInt64, UInt64)] = [(0, 42), (41, 0), (41, 41)]
        for ids in invalidIDs {
            let invalid = StartupVideoNativePacingWitness.evaluate(
                batch: batch(fixture()),
                binding: .init(hostWorkerID: ids.0, viewerWorkerID: ids.1,
                               registeredAtUptimeNanoseconds: 1_500_000_000),
                captureStartedAtUptimeNanoseconds: captureStarted, expectedFactor: 1.15
            )
            XCTAssertFalse(invalid.isVerified)
            XCTAssertTrue(invalid.failures.contains(.invalidBinding))
        }
    }

    func testTwoBWEsBeforePacerAreAmbiguousEvenWhenLaterPairsMatch() {
        var events = fixture(count: 5)
        events.insert(event(time: 3_005_000_000,
                            payload: .bweUpdated(nativeTimestampMilliseconds: 1_050,
                                                 pushbackTargetBps: 640_000, estimateBps: 800_000)), at: 2)
        let result = evaluate(events)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.ambiguousBWEs, 2)
        XCTAssertEqual(result.counts.ambiguousPacers, 1)
        XCTAssertEqual(result.counts.matchedPairs, 4)
        XCTAssertTrue(result.failures.contains(.ambiguousPairing))
    }

    func testPacerWithoutBWERemainsExplicitlyUnmatchedAndDoesNotInventPair() {
        var events = fixture()
        events.insert(event(time: 2_100_000_000,
                            payload: .pacerUpdated(pacingKbps: 300, paddingBudgetKbps: 0)), at: 1)
        let result = evaluate(events)
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.counts.unmatchedPacers, 1)
        XCTAssertEqual(result.counts.matchedPairs, 3)
        let noBWEs = events.filter { if case .bweUpdated = $0.payload { false } else { true } }
        let missing = evaluate(noBWEs)
        XCTAssertFalse(missing.isVerified)
        XCTAssertEqual(missing.counts.unmatchedPacers, 4)
        XCTAssertEqual(missing.counts.matchedPairs, 0)
    }

    func testHundredMillisecondPairBoundaryAndMissingPacerAreNotGuessed() {
        for (gap, expectedMatches) in [(UInt64(100_000_000), 3), (100_000_001, 0)] {
            var events = fixture()
            for index in 0..<3 {
                let pacerIndex = index * 2 + 2
                events[pacerIndex] = event(time: events[pacerIndex - 1].callbackUptimeNanoseconds + gap,
                                           payload: events[pacerIndex].payload)
            }
            let result = evaluate(events)
            XCTAssertEqual(result.counts.matchedPairs, expectedMatches)
            XCTAssertEqual(result.isVerified, expectedMatches == 3)
            XCTAssertEqual(result.counts.latePairs, expectedMatches == 3 ? 0 : 3)
        }
        let missing = evaluate(Array(fixture().dropLast()))
        XCTAssertFalse(missing.isVerified)
        XCTAssertEqual(missing.counts.unmatchedBWEs, 1)
        XCTAssertEqual(missing.counts.matchedPairs, 2)
    }

    func testRejectsNonpositiveOrRegressedNativeTimestamps() {
        for timestamp in [Int64(0), -1, 999] {
            var events = fixture()
            events[3] = event(time: events[3].callbackUptimeNanoseconds,
                              payload: .bweUpdated(nativeTimestampMilliseconds: timestamp,
                                                   pushbackTargetBps: 720_000, estimateBps: 900_000))
            let result = evaluate(events)
            XCTAssertFalse(result.isVerified)
            XCTAssertLessThan(result.counts.matchedPairs, 3)
            XCTAssertTrue(result.failures.contains(timestamp <= 0 ? .invalidEvent : .outOfOrderHostEvidence))
        }
    }

    func testCompletedTiedPairsAreCheckedButThreeDistinctNativeMatchesRemainRequired() throws {
        for factor in [1.0, 1.15] {
            let original = fixture(factor: factor)
            var events = [original[0]]
            for index in 0..<3 {
                let bwe = original[index * 2 + 1]
                let pacer = original[index * 2 + 2]
                events.append(contentsOf: [bwe, pacer])
                guard case let .bweUpdated(timestamp, pushback, estimate) = bwe.payload else {
                    return XCTFail("Expected fixture BWE")
                }
                events.append(event(time: pacer.callbackUptimeNanoseconds + 20_000,
                                    payload: .bweUpdated(nativeTimestampMilliseconds: timestamp,
                                                         pushbackTargetBps: pushback * 9 / 10,
                                                         estimateBps: estimate)))
                events.append(event(time: pacer.callbackUptimeNanoseconds + 40_000,
                                    payload: pacer.payload))
            }
            let result = evaluate(events, expectedFactor: factor)
            XCTAssertTrue(result.isVerified, "\(result.failures)")
            XCTAssertEqual(result.counts.matchedPairs, 3)
            XCTAssertEqual(result.counts.tiedPairs, 3)
            XCTAssertEqual(result.counts.outOfOrderHostEvents, 0)
            XCTAssertEqual(result.matchedPairs.map(\.nativeTimestampMilliseconds), [1_000, 1_100, 1_200])
            XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativePacingWitnessSummary.self,
                                                    from: JSONEncoder().encode(result)), result)
        }
    }

    func testAllSameMillisecondPairsCannotSupplyThreeIndependentMatches() {
        var events = fixture()
        for index in 0..<3 {
            let bweIndex = index * 2 + 1
            guard case let .bweUpdated(_, pushback, estimate) = events[bweIndex].payload else {
                return XCTFail("Expected fixture BWE")
            }
            events[bweIndex] = event(time: events[bweIndex].callbackUptimeNanoseconds,
                                     payload: .bweUpdated(nativeTimestampMilliseconds: 1_000,
                                                          pushbackTargetBps: pushback, estimateBps: estimate))
        }
        let result = evaluate(events)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.matchedPairs, 1)
        XCTAssertEqual(result.counts.tiedPairs, 2)
        XCTAssertEqual(result.counts.outOfOrderHostEvents, 0)
        XCTAssertEqual(result.failures, [.insufficientMatchedPairs])
    }

    func testSameMillisecondContradictionRejectsEvenWithThreeDistinctMatches() {
        for factor in [1.0, 1.15] {
            var events = fixture(factor: factor)
            let contradictoryKbps: UInt64 = factor == 1.0 ? 920 : 800
            events.insert(contentsOf: [
                event(time: 3_010_020_000,
                      payload: .bweUpdated(nativeTimestampMilliseconds: 1_000,
                                           pushbackTargetBps: 576_000, estimateBps: 800_000)),
                event(time: 3_010_040_000,
                      payload: .pacerUpdated(pacingKbps: contradictoryKbps, paddingBudgetKbps: 0))
            ], at: 3)
            let result = evaluate(events, expectedFactor: factor)
            XCTAssertFalse(result.isVerified)
            XCTAssertEqual(result.counts.matchedPairs, 3)
            XCTAssertEqual(result.counts.tiedPairs, 0)
            XCTAssertEqual(result.counts.contradictedFactorMatches, 1)
            XCTAssertEqual(result.failures, [.contradictedFactorObserved])
        }
    }

    func testSameMillisecondOverlappingBWEsRemainAmbiguous() {
        var events = fixture(count: 4)
        events.insert(event(time: 3_000_020_000,
                            payload: .bweUpdated(nativeTimestampMilliseconds: 1_000,
                                                 pushbackTargetBps: 576_000, estimateBps: 800_000)), at: 2)
        let result = evaluate(events)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.matchedPairs, 3)
        XCTAssertEqual(result.counts.tiedPairs, 0)
        XCTAssertEqual(result.counts.ambiguousBWEs, 2)
        XCTAssertEqual(result.counts.ambiguousPacers, 1)
        XCTAssertEqual(result.failures, [.ambiguousPairing])
    }

    func testTiedPairRequiresStrictlyAdvancingCallbackForBothBWEAndPacer() {
        for delta in [UInt64(0), 1] {
            for breaksBWE in [true, false] {
                var events = fixture(count: 4)
                let bweTime: UInt64 = breaksBWE ? 3_010_000_000 - delta : 3_010_020_000
                let pacerTime: UInt64 = breaksBWE ? 3_010_040_000 : bweTime - delta
                events.insert(contentsOf: [
                    event(time: bweTime,
                          payload: .bweUpdated(nativeTimestampMilliseconds: 1_000,
                                               pushbackTargetBps: 576_000, estimateBps: 800_000)),
                    event(time: pacerTime, payload: .pacerUpdated(pacingKbps: 920, paddingBudgetKbps: 0))
                ], at: 3)
                let result = evaluate(events)
                XCTAssertFalse(result.isVerified)
                XCTAssertEqual(result.counts.matchedPairs, 4)
                XCTAssertEqual(result.counts.tiedPairs, 0)
                XCTAssertEqual(result.counts.outOfOrderHostEvents, 1)
                XCTAssertEqual(result.failures, [.outOfOrderHostEvidence])
            }
        }
    }

    func testReducedRecordedPushbackPairs48Through51ShareNativeMillisecondWithoutReordering() {
        // Numeric reduction of the recorded 48/49/50/51 sequence; no external log dependency.
        // Two complete pairs in one rounded millisecond are only one independent witness.
        let result = evaluate([
            event(time: started + 1_000, payload: alr(1.0)),
            event(time: 1_193_773_991_401_875,
                  payload: .bweUpdated(nativeTimestampMilliseconds: 1_193_773_991,
                                       pushbackTargetBps: 634_587, estimateBps: 703_144)),
            event(time: 1_193_773_991_445_583,
                  payload: .pacerUpdated(pacingKbps: 703, paddingBudgetKbps: 100)),
            event(time: 1_193_773_991_476_916,
                  payload: .bweUpdated(nativeTimestampMilliseconds: 1_193_773_991,
                                       pushbackTargetBps: 571_128, estimateBps: 703_144)),
            event(time: 1_193_773_991_501_083,
                  payload: .pacerUpdated(pacingKbps: 703, paddingBudgetKbps: 100))
        ], expectedFactor: 1.0)
        XCTAssertEqual(result.counts.matchedPairs, 1)
        XCTAssertEqual(result.counts.tiedPairs, 1)
        XCTAssertEqual(result.counts.outOfOrderHostEvents, 0)
        XCTAssertEqual(result.counts.ratioMismatches, 0)
        XCTAssertEqual(result.matchedPairs.first?.callbackGapNanoseconds, 43_708)
        XCTAssertEqual(result.failures, [.insufficientMatchedPairs])
    }

    func testCaptureAndRegistrationBoundariesCannotBorrowEarlierSamples() {
        for registration in [UInt64(1_500_000_000), 3_210_000_000] {
            let capture: UInt64 = registration == 1_500_000_000 ? 3_210_000_000 : captureStarted
            let result = StartupVideoNativePacingWitness.evaluate(
                batch: batch(fixture()),
                binding: .init(hostWorkerID: 41, viewerWorkerID: 42,
                               registeredAtUptimeNanoseconds: registration),
                captureStartedAtUptimeNanoseconds: capture, expectedFactor: 1.15
            )
            XCTAssertFalse(result.isVerified)
            XCTAssertEqual(result.counts.beforeObservationBoundary, 4)
            XCTAssertEqual(result.counts.matchedPairs, 1)
        }
    }

    func testALRAloneIsInsufficientAndEveryFixedTupleFieldIsRequired() {
        XCTAssertFalse(evaluate([event(time: started + 1_000, payload: alr(1.15))]).isVerified)
        let wrongTuples: [StartupVideoNativePacingPayload] = [
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2876, bandwidthUsagePercent: 80,
                         startBudgetLevelPercent: 40, endBudgetLevelPercent: -60, groupID: 3),
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875, bandwidthUsagePercent: 81,
                         startBudgetLevelPercent: 40, endBudgetLevelPercent: -60, groupID: 3),
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875, bandwidthUsagePercent: 80,
                         startBudgetLevelPercent: 41, endBudgetLevelPercent: -60, groupID: 3),
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875, bandwidthUsagePercent: 80,
                         startBudgetLevelPercent: 40, endBudgetLevelPercent: -59, groupID: 3),
            .alrSettings(pacingFactor: 1.15, maxPacerQueueMilliseconds: 2875, bandwidthUsagePercent: 80,
                         startBudgetLevelPercent: 40, endBudgetLevelPercent: -60, groupID: 4)
        ]
        for tuple in wrongTuples {
            var events = fixture()
            events[0] = event(time: started + 1_000, payload: tuple)
            let result = evaluate(events)
            XCTAssertFalse(result.isVerified)
            XCTAssertEqual(result.counts.matchedPairs, 3)
            XCTAssertEqual(result.counts.conflictingALRSettings, 1)
        }
        let absent = evaluate(Array(fixture().dropFirst()))
        XCTAssertFalse(absent.isVerified)
        XCTAssertTrue(absent.failures.contains(.missingALRCorroboration))
    }

    func testRejectsFabricatedCountsOverflowAndInvalidEvidenceCounters() {
        let ordinary = batch(fixture())
        let broken: [StartupVideoNativePacingBatch] = [
            batch(fixture(), matchingCount: 999), batch(fixture(), dropped: 1),
            batch(fixture(), invalidTime: 1), batch(fixture(), invalidThread: 1),
            batch([], matchingCount: 3)
        ]
        for value in broken {
            let result = evaluateBatch(value)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.incompleteBatch))
        }
        XCTAssertTrue(evaluateBatch(ordinary).isVerified)
        var events = fixture()
        events[2] = event(time: events[2].callbackUptimeNanoseconds,
                          payload: .pacerUpdated(pacingKbps: UInt64.max, paddingBudgetKbps: 0))
        XCTAssertTrue(evaluate(events).failures.contains(.invalidEvent))
        events = fixture()
        events[1] = event(time: events[1].callbackUptimeNanoseconds,
                          payload: .bweUpdated(nativeTimestampMilliseconds: 1_000,
                                               pushbackTargetBps: 1, estimateBps: UInt64.max))
        XCTAssertTrue(evaluate(events).failures.contains(.invalidEvent))
    }

    func testRejectsReorderedSequenceSameThreadClockRegressionAndBadEventCopies() {
        var events = sequenced(fixture())
        events.swapAt(1, 2)
        XCTAssertTrue(evaluateBatch(batch(events, resequence: false)).failures.contains(.invalidEvent))
        events = fixture()
        events[2] = event(time: events[1].callbackUptimeNanoseconds - 1,
                          payload: events[2].payload)
        XCTAssertTrue(evaluate(events).failures.contains(.outOfOrderHostEvidence))
        events = fixture()
        events[1] = event(time: events[1].callbackUptimeNanoseconds, thread: 0, payload: events[1].payload)
        XCTAssertTrue(evaluate(events).failures.contains(.invalidEvent))
        events = sequenced(fixture())
        let original = events[1]
        events[1] = .init(sequence: original.sequence, threadID: original.threadID,
                          callbackUptimeNanoseconds: original.callbackUptimeNanoseconds,
                          processObserverAgeMilliseconds: 0, payload: original.payload)
        XCTAssertTrue(evaluateBatch(batch(events, resequence: false)).failures.contains(.invalidEvent))
    }

    func testPairDetailRetentionIsBoundedWhileTotalMatchesRemainTruthful() {
        let result = evaluate(fixture(count: 40))
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.counts.matchedPairs, 40)
        XCTAssertEqual(result.matchedPairs.count, 32)
        XCTAssertEqual(result.counts.omittedMatchedPairDetails, 8)
    }

    func testOverlappingRoundingWindowsDoNotDistinguishFactors() {
        var events = fixture()
        for index in 0..<3 {
            let bweIndex = index * 2 + 1
            events[bweIndex] = event(time: events[bweIndex].callbackUptimeNanoseconds,
                                     payload: .bweUpdated(nativeTimestampMilliseconds: Int64(1_000 + index * 100),
                                                          pushbackTargetBps: 4_000, estimateBps: 5_000))
            events[bweIndex + 1] = event(time: events[bweIndex + 1].callbackUptimeNanoseconds,
                                         payload: .pacerUpdated(pacingKbps: 5, paddingBudgetKbps: 0))
        }
        let result = evaluate(events)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.ambiguousFactorMatches, 3)
        XCTAssertEqual(result.counts.matchedPairs, 0)
    }

    func testUnsupportedFactorInvalidStartAndOverCapacityBatchFailClosed() {
        for factor in [0, 1.1, Double.nan, Double.infinity] {
            let result = evaluate(fixture(), expectedFactor: factor)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.unsupportedExpectedFactor))
        }
        let invalidStart = StartupVideoNativePacingWitness.evaluate(
            batch: batch(fixture()), binding: binding,
            captureStartedAtUptimeNanoseconds: 0, expectedFactor: 1.15
        )
        XCTAssertFalse(invalidStart.isVerified)
        XCTAssertTrue(invalidStart.failures.contains(.invalidCaptureStart))
        let overCapacity = evaluate(fixture(count: 2_048))
        XCTAssertFalse(overCapacity.isVerified)
        XCTAssertEqual(overCapacity.counts.examinedEvents, 4_096)
        XCTAssertTrue(overCapacity.failures.contains(.incompleteBatch))
    }

    private func alr(_ factor: Double) -> StartupVideoNativePacingPayload {
        .alrSettings(pacingFactor: factor, maxPacerQueueMilliseconds: 2_875, bandwidthUsagePercent: 80,
                     startBudgetLevelPercent: 40, endBudgetLevelPercent: -60, groupID: 3)
    }

    private func fixture(factor: Double = 1.15, count: Int = 3) -> [StartupVideoNativePacingEvent] {
        var events = [event(time: started + 1_000, thread: 99, payload: alr(factor))]
        for index in 0..<count {
            let time = UInt64(3_000_000_000 + index * 200_000_000)
            let estimate = UInt64(800_000 + index * 100_000)
            events.append(event(time: time,
                                payload: .bweUpdated(nativeTimestampMilliseconds: Int64(1_000 + index * 100),
                                                     pushbackTargetBps: estimate * 80 / 100, estimateBps: estimate)))
            events.append(event(time: time + 10_000_000,
                                payload: .pacerUpdated(pacingKbps: estimate * (factor == 1.15 ? 115 : 100) / 100 / 1_000,
                                                       paddingBudgetKbps: 0)))
        }
        return events
    }

    private func event(time: UInt64, thread: UInt64 = 41,
                       payload: StartupVideoNativePacingPayload) -> StartupVideoNativePacingEvent {
        .init(sequence: 0, threadID: thread, callbackUptimeNanoseconds: time,
              processObserverAgeMilliseconds: (time - started) / 1_000_000, payload: payload)
    }

    private func sequenced(_ events: [StartupVideoNativePacingEvent]) -> [StartupVideoNativePacingEvent] {
        events.enumerated().map { index, value in
            .init(sequence: UInt64(index + 1), threadID: value.threadID,
                  callbackUptimeNanoseconds: value.callbackUptimeNanoseconds,
                  processObserverAgeMilliseconds: value.processObserverAgeMilliseconds, payload: value.payload)
        }
    }

    private func batch(_ events: [StartupVideoNativePacingEvent], matchingCount: UInt64? = nil,
                       dropped: UInt64 = 0, invalidTime: UInt64 = 0, invalidThread: UInt64 = 0,
                       resequence: Bool = true) -> StartupVideoNativePacingBatch {
        .init(scope: .process, startedAtUptimeNanoseconds: started,
              events: resequence ? sequenced(events) : events,
              matchingEventCount: matchingCount ?? UInt64(events.count), droppedEventCount: dropped,
              rejectedMessageCount: 123, invalidObservationTimeCount: invalidTime,
              invalidThreadIDCount: invalidThread)
    }

    private func evaluate(_ events: [StartupVideoNativePacingEvent],
                          expectedFactor: Double = 1.15) -> StartupVideoNativePacingWitnessSummary {
        evaluateBatch(batch(events), expectedFactor: expectedFactor)
    }

    private func evaluateBatch(_ value: StartupVideoNativePacingBatch,
                               expectedFactor: Double = 1.15) -> StartupVideoNativePacingWitnessSummary {
        StartupVideoNativePacingWitness.evaluate(batch: value, binding: binding,
                                                captureStartedAtUptimeNanoseconds: captureStarted,
                                                expectedFactor: expectedFactor)
    }
}
#endif
