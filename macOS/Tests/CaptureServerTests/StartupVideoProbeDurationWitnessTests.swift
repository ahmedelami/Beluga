#if os(macOS)
import Foundation
import XCTest

final class StartupVideoProbeDurationWitnessTests: XCTestCase {
    private typealias Snapshot = StartupVideoNativeEstimatorSnapshot
    private typealias Event = Snapshot.Event
    private let captureStarted: UInt64 = 2_000_000_000

    func testBothDurationsVerifyInitialRequestedByteBudgetsAndRoundTrip() throws {
        for milliseconds in [15, 40] {
            var snapshot = fixture(milliseconds: milliseconds)
            snapshot.events.insert(Event(sequence: 1, kind: .loss, bitrateBps: 300_000,
                callbackUptimeNanoseconds: 1_400_000_000, threadID: 41,
                environmentTimeMicroseconds: 400, detectorState: nil, fractionLoss: 0,
                expectedPackets: 0), at: 0)
            resequence(&snapshot)
            let result = evaluate(snapshot, milliseconds: milliseconds)
            XCTAssertTrue(result.isVerified, "\(result.failures)")
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.expectedMilliseconds, milliseconds)
            XCTAssertEqual(result.initialProbeClusterIDs, [1, 2])
            XCTAssertEqual(result.initialProbeBitratesBps, [900_000, 905_041])
            XCTAssertEqual(result.initialProbeMinimumProbes, [5, 5])
            XCTAssertEqual(result.initialProbeMinimumBytes,
                           milliseconds == 15 ? [1_688, 1_697] : [4_500, 4_525])
            XCTAssertTrue(snapshot.events.prefix(2).allSatisfy {
                $0.callbackUptimeNanoseconds < captureStarted
            })
            XCTAssertEqual(try JSONDecoder().decode(StartupVideoProbeDurationWitnessSummary.self,
                from: JSONEncoder().encode(result)), result)
        }
    }

    func testMissingInitialRequestsCannotVerify() {
        for count in [0, 1] {
            var snapshot = fixture()
            snapshot.events.removeSubrange(count..<2)
            resequence(&snapshot)
            let result = evaluate(snapshot)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.missingInitialRequests))
            XCTAssertEqual(result.initialProbeClusterIDs.count, count)
        }
    }

    func testLaterMatchingRequestsCannotReplaceTheFirstTwo() {
        var snapshot = fixture()
        let original = Array(snapshot.events.prefix(2))
        snapshot.events[0].probeClusterID = 7
        snapshot.events[1].probeClusterID = 8
        snapshot.events[0].minimumBytes = 1_688
        snapshot.events[1].minimumBytes = 1_697
        for (index, event) in original.enumerated() {
            var later = event
            later.callbackUptimeNanoseconds = 3_300_000_000 + UInt64(index) * 100_000_000
            later.environmentTimeMicroseconds = 1_300 + Int64(index) * 100
            snapshot.events.append(later)
        }
        resequence(&snapshot)
        XCTAssertTrue(snapshot.evaluate(hostWorkerID: 41,
            captureStartedAtUptimeNanoseconds: captureStarted).isVerified)
        let result = evaluate(snapshot)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.initialProbeClusterIDs, [7, 8])
        XCTAssertEqual(result.initialProbeMinimumBytes, [1_688, 1_697])
        XCTAssertTrue(result.failures.contains(.unexpectedInitialIDs))
        XCTAssertTrue(result.failures.contains(.unexpectedInitialMinimumBytes))
    }

    func testWrongInitialIDsRatesCountsAndByteBudgetsFail() {
        for index in 0..<2 {
            for variant in 0..<4 {
                var snapshot = fixture()
                switch variant {
                case 0: snapshot.events[index].probeClusterID = 3
                case 1: snapshot.events[index].bitrateBps = 905_040
                case 2: snapshot.events[index].minimumProbes = 6
                default: snapshot.events[index].minimumBytes! += 1
                }
                XCTAssertTrue(snapshot.evaluate(hostWorkerID: 41,
                    captureStartedAtUptimeNanoseconds: captureStarted).isVerified)
                let result = evaluate(snapshot)
                XCTAssertFalse(result.isVerified, "index=\(index) variant=\(variant)")
                let expected: [StartupVideoProbeDurationWitnessSummary.Failure] = [
                    .unexpectedInitialIDs, .unexpectedInitialBitrates,
                    .unexpectedInitialMinimumProbes, .unexpectedInitialMinimumBytes
                ]
                XCTAssertTrue(result.failures.contains(expected[variant]))
            }
        }
        XCTAssertFalse(evaluate(fixture(milliseconds: 15), milliseconds: 40).isVerified)
        XCTAssertFalse(evaluate(fixture(milliseconds: 40), milliseconds: 15).isVerified)
    }

    func testMissingCreatedPayloadCannotBorrowValues() {
        for variant in 0..<4 {
            var snapshot = fixture()
            switch variant {
            case 0: snapshot.events[0].probeClusterID = nil
            case 1: snapshot.events[0].bitrateBps = nil
            case 2: snapshot.events[0].minimumProbes = nil
            default: snapshot.events[0].minimumBytes = nil
            }
            let result = evaluate(snapshot)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.invalidEstimatorEvidence))
        }
    }

    func testOnlyFifteenAndFortyMillisecondsAreAdmitted() {
        for milliseconds in [Int.min, -1, 0, 14, 16, 25, 39, 41, 100, Int.max] {
            let result = evaluate(fixture(), milliseconds: milliseconds)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.unsupportedDuration))
        }
    }

    func testExistingHostClockAndNativeFailureFencesRemainRequired() {
        for host in [UInt64(0), 42] {
            let result = StartupVideoProbeDurationWitness.evaluate(snapshot: fixture(), hostWorkerID: host,
                captureStartedAtUptimeNanoseconds: captureStarted, expectedMilliseconds: 40)
            XCTAssertFalse(result.isVerified)
            XCTAssertTrue(result.failures.contains(.invalidEstimatorEvidence))
        }
        for variant in 0..<7 {
            var snapshot = fixture()
            switch variant {
            case 0: snapshot.events[0].threadID = 42
            case 1: snapshot.events[0].callbackUptimeNanoseconds = 0
            case 2: snapshot.events[1].environmentTimeMicroseconds = 499
            case 3: snapshot.events[1].sequence = 1
            case 4: snapshot.invalidEventCount = 1
            case 5: snapshot.droppedEventCount = 1
            default: snapshot.events.removeLast()
            }
            let result = evaluate(snapshot)
            XCTAssertFalse(result.isVerified, "variant=\(variant)")
            XCTAssertTrue(result.failures.contains(.invalidEstimatorEvidence))
        }
        let nativeFailures: [WritableKeyPath<Snapshot, UInt64>] = [
            \.fieldTrialFailureCount, \.lifetimeFailureCount, \.rejectedCreateCount,
            \.environmentIdentityFailureCount, \.selectorFailureCount
        ]
        for failure in nativeFailures {
            var snapshot = fixture()
            snapshot[keyPath: failure] = 1
            XCTAssertTrue(evaluate(snapshot).failures.contains(.invalidEstimatorEvidence))
        }
    }

    func testProbeFailureResultsDoNotInvalidateRequestedBudgetWitness() {
        var snapshot = fixture()
        snapshot.unknownEventCount = 17
        snapshot.events.append(Event(sequence: 6, kind: .probeFailure, bitrateBps: nil,
            callbackUptimeNanoseconds: 3_300_000_000, threadID: 41,
            environmentTimeMicroseconds: 1_300, detectorState: nil, fractionLoss: nil,
            expectedPackets: nil, probeClusterID: 1, failureReason: 1))
        let result = evaluate(snapshot)
        XCTAssertTrue(result.isVerified, "\(result.failures)")
        XCTAssertEqual(result.initialProbeClusterIDs, [1, 2])
    }

    private func evaluate(_ snapshot: Snapshot, milliseconds: Int = 40) -> StartupVideoProbeDurationWitnessSummary {
        StartupVideoProbeDurationWitness.evaluate(snapshot: snapshot, hostWorkerID: 41,
            captureStartedAtUptimeNanoseconds: captureStarted, expectedMilliseconds: milliseconds)
    }

    private func fixture(milliseconds: Int = 40) -> Snapshot {
        let bytes: [UInt64] = milliseconds == 15 ? [1_688, 1_697] : [4_500, 4_525]
        let rates: [Int64] = [900_000, 905_041]
        let initial = (0..<2).map { index in
            Event(sequence: UInt64(index) + 1, kind: .probeCreated, bitrateBps: rates[index],
                  callbackUptimeNanoseconds: 1_500_000_000 + UInt64(index) * 1_000,
                  threadID: 41, environmentTimeMicroseconds: 500,
                  detectorState: nil, fractionLoss: nil, expectedPackets: nil,
                  probeClusterID: index + 1, minimumProbes: 5, minimumBytes: bytes[index])
        }
        let delays = (0..<3).map { index in
            Event(sequence: UInt64(index) + 3, kind: .delay, bitrateBps: 800_000,
                  callbackUptimeNanoseconds: 3_000_000_000 + UInt64(index) * 100_000_000,
                  threadID: 41, environmentTimeMicroseconds: 1_000 + Int64(index) * 100,
                  detectorState: 0, fractionLoss: nil, expectedPackets: nil)
        }
        return Snapshot(schemaVersion: 2, capacity: 2_048, collectionStartUptimeNanoseconds: 1_000_000_000,
            interceptionCount: 1, controllerCreateCount: 1, processIntervalCallCount: 1,
            defaultDelegateCount: 1, environmentIdentityMatches: 1, liveLoggerCount: 1,
            loggerCreatedCount: 1, loggerDestroyedCount: 0, invalidEventCount: 0,
            droppedEventCount: 0, unknownEventCount: 0, rejectedCreateCount: 0,
            unexpectedFactoryCount: 0, startLoggingAttemptCount: 0,
            environmentIdentityFailureCount: 0, fieldTrialFailureCount: 0,
            selectorFailureCount: 0, lifetimeFailureCount: 0, factoryRequestCount: 1,
            processIntervalMicroseconds: 25_000, events: initial + delays)
    }

    private func resequence(_ snapshot: inout Snapshot) {
        for index in snapshot.events.indices { snapshot.events[index].sequence = UInt64(index) + 1 }
    }
}
#endif
