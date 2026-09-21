#if os(macOS)
import Foundation
import XCTest

final class StartupVideoNativeEstimatorSnapshotTests: XCTestCase {
    private typealias Snapshot = StartupVideoNativeEstimatorSnapshot
    private typealias Event = Snapshot.Event
    private let captureStarted: UInt64 = 2_000_000_000

    func testThreeAdvancingDelayEventsVerifyWithoutOveruseAndRoundTrip() throws {
        var value = fixture()
        value.unknownEventCount = 17
        let decoded = try Snapshot.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let result = evaluate(decoded)
        XCTAssertTrue(result.isVerified, "\(result.failures)")
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 3)
        XCTAssertEqual(result.counts.unknownEventCount, 17)
        XCTAssertEqual(result.delayOveruseCount, 0)
        XCTAssertNil(result.firstPostCaptureOveruseUptimeNanoseconds)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativeEstimatorSummary.self,
                                                from: JSONEncoder().encode(result)), result)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
            as? [String: Any])
        XCTAssertEqual(encoded["isVerified"] as? Bool, true)
    }

    func testEmptyAndFactoryIntentAloneCannotVerify() {
        var empty = fixture()
        empty.events = []
        XCTAssertTrue(evaluate(empty).failures.contains(.insufficientAdvancingDelayEvents))
        empty.controllerCreateCount = 0
        empty.processIntervalCallCount = 0
        let intent = evaluate(empty)
        XCTAssertFalse(intent.isVerified)
        XCTAssertTrue(intent.failures.contains(.invalidControllerEvidence))
        XCTAssertTrue(intent.failures.contains(.invalidProcessInterval))
    }

    func testExactlyTwoAdvancingDelayEventsCannotVerify() {
        var value = fixture()
        value.events.removeLast()
        let result = evaluate(value)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 2)
        XCTAssertEqual(result.failures, [.insufficientAdvancingDelayEvents])
    }

    func testEverySingletonFactoryEnvironmentAndLifetimeCountIsExact() {
        let singletons: [WritableKeyPath<Snapshot, UInt64>] = [
            \.factoryRequestCount, \.interceptionCount, \.controllerCreateCount,
            \.defaultDelegateCount, \.environmentIdentityMatches, \.liveLoggerCount,
            \.loggerCreatedCount
        ]
        for key in singletons {
            for wrong in [UInt64(0), 2, .max] {
                var value = fixture()
                value[keyPath: key] = wrong
                XCTAssertFalse(evaluate(value).isVerified, "\(key)=\(wrong)")
            }
        }
        var destroyed = fixture()
        destroyed.loggerDestroyedCount = 1
        XCTAssertTrue(evaluate(destroyed).failures.contains(.invalidLoggerLifetime))
    }

    func testMissingControllerCreateCannotBorrowValidEvents() {
        var value = fixture()
        value.controllerCreateCount = 0
        let result = evaluate(value)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 3)
        XCTAssertTrue(result.failures.contains(.invalidControllerEvidence))
    }

    func testEveryNativeFailureCounterRejectsOtherwiseValidEvidence() {
        let failures: [WritableKeyPath<Snapshot, UInt64>] = [
            \.invalidEventCount, \.droppedEventCount, \.rejectedCreateCount,
            \.unexpectedFactoryCount, \.startLoggingAttemptCount,
            \.environmentIdentityFailureCount, \.fieldTrialFailureCount,
            \.selectorFailureCount, \.lifetimeFailureCount
        ]
        for key in failures {
            for count in [UInt64(1), .max] {
                var value = fixture()
                value[keyPath: key] = count
                XCTAssertTrue(evaluate(value).failures.contains(.nativeFailureReported), "\(key)")
            }
        }
    }

    func testProcessIntervalMustBeObservedAndExactlyTwentyFiveMilliseconds() {
        var value = fixture()
        value.processIntervalCallCount = 0
        XCTAssertTrue(evaluate(value).failures.contains(.invalidProcessInterval))
        for interval in [UInt64(0), 24_999, 25_001, .max] {
            value = fixture()
            value.processIntervalMicroseconds = interval
            XCTAssertTrue(evaluate(value).failures.contains(.invalidProcessInterval))
        }
        value = fixture()
        value.processIntervalCallCount = 100
        XCTAssertTrue(evaluate(value).isVerified)
    }

    func testWrongHostWorkerAndUnprovenEnvironmentFail() {
        for thread in [UInt64(0), 42, .max] {
            var value = fixture()
            value.events[0].threadID = thread
            XCTAssertTrue(evaluate(value).failures.contains(.wrongWorkerThread))
        }
        XCTAssertTrue(fixture().evaluate(hostWorkerID: 0,
            captureStartedAtUptimeNanoseconds: captureStarted).failures.contains(.invalidHostWorker))
        var value = fixture()
        value.environmentIdentityMatches = 0
        XCTAssertTrue(evaluate(value).failures.contains(.invalidEnvironmentIdentity))
    }

    func testDelayAndLossPayloadFieldsCannotBeMixedOrOmitted() {
        var invalid: [Event] = []
        for original in [delay(0), loss(0)] {
            var event = original
            event.bitrateBps = nil
            invalid.append(event)
        }
        for state in [Int?.none, -1, 3] {
            var event = delay(0)
            event.detectorState = state
            invalid.append(event)
        }
        var event = delay(0)
        event.fractionLoss = 0
        invalid.append(event)
        event = delay(0)
        event.expectedPackets = 0
        invalid.append(event)
        for fraction in [Int?.none, -1, 256] {
            event = loss(0)
            event.fractionLoss = fraction
            invalid.append(event)
        }
        for packets in [Int?.none, -1] {
            event = loss(0)
            event.expectedPackets = packets
            invalid.append(event)
        }
        event = loss(0)
        event.detectorState = 0
        invalid.append(event)
        for event in invalid {
            var value = fixture()
            value.events[0] = event
            XCTAssertTrue(evaluate(value).failures.contains(.invalidEventFields), "\(event)")
        }
        for state in 0...2 {
            var value = fixture()
            value.events[0].detectorState = state
            XCTAssertTrue(evaluate(value).isVerified)
        }
    }

    func testDecodeRejectsUnknownKindMissingFieldsAndIntegerOverflow() throws {
        let original = String(decoding: try JSONEncoder().encode(fixture()), as: UTF8.self)
        for (from, to) in [
            ("\"delay\"", "\"other\""),
            ("\"capacity\":2048", "\"capacity\":18446744073709551616"),
            ("\"bitrateBps\":800000", "\"bitrateBps\":9223372036854775808"),
            ("\"capacity\":2048", "\"capacity\":-1"),
            ("\"detectorState\":0", "\"detectorState\":9223372036854775808")
        ] {
            XCTAssertTrue(original.contains(from))
            XCTAssertThrowsError(try Snapshot.decode(Data(original.replacingOccurrences(of: from, with: to).utf8)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        object.removeValue(forKey: "controllerCreateCount")
        XCTAssertThrowsError(try Snapshot.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testByteAndEventBoundsRejectOverflowWithoutLosingFailureEvidence() throws {
        XCTAssertThrowsError(try Snapshot.decode(Data(repeating: 32, count: Snapshot.maximumBytes + 1))) {
            guard case Snapshot.DecodeFailure.oversizedData = $0 else { return XCTFail("\($0)") }
        }
        var value = fixture()
        value.events = (0..<Snapshot.maximumEvents).map(delay)
        XCTAssertTrue(evaluate(try Snapshot.decode(JSONEncoder().encode(value))).isVerified)
        value.events.append(delay(Snapshot.maximumEvents))
        XCTAssertThrowsError(try Snapshot.decode(JSONEncoder().encode(value))) {
            guard case Snapshot.DecodeFailure.tooManyEvents = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(evaluate(value).failures.contains(.eventCapacityExceeded))
        XCTAssertEqual(evaluate(value).counts.retainedEventCount, 2_049)
    }

    func testSchemaCapacityAndSequenceAreValidated() throws {
        for schema in [UInt64(0), 1, 3, .max] {
            var value = fixture()
            value.schemaVersion = schema
            let decoded = try Snapshot.decode(JSONEncoder().encode(value))
            XCTAssertTrue(evaluate(decoded).failures.contains(.unsupportedSchema))
        }
        var value = fixture()
        value.capacity = 2_049
        XCTAssertTrue(evaluate(value).failures.contains(.invalidCapacity))
        for sequence in [UInt64(0), 1, 3, .max] {
            value = fixture()
            value.events[1].sequence = sequence
            XCTAssertTrue(evaluate(value).failures.contains(.invalidSequence))
        }
    }

    func testCallbackAndEnvironmentClocksCannotRegress() {
        var value = fixture()
        value.events[1].callbackUptimeNanoseconds = value.events[0].callbackUptimeNanoseconds - 1
        XCTAssertTrue(evaluate(value).failures.contains(.callbackTimeRegressed))
        value = fixture()
        value.events[1].environmentTimeMicroseconds = value.events[0].environmentTimeMicroseconds - 1
        XCTAssertTrue(evaluate(value).failures.contains(.environmentTimeRegressed))
    }

    func testClockTiesAreValidButDoNotSupplyDistinctProof() {
        for tieCallback in [false, true] {
            var value = fixture()
            for index in value.events.indices {
                if tieCallback {
                    value.events[index].callbackUptimeNanoseconds = 3_000_000_000
                } else {
                    value.events[index].environmentTimeMicroseconds = 1_000
                }
            }
            let result = evaluate(value)
            XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 1)
            XCTAssertEqual(result.failures, [.insufficientAdvancingDelayEvents])
        }
        var value = fixture()
        value.events.insert(value.events[0], at: 1)
        resequence(&value)
        XCTAssertTrue(evaluate(value).isVerified)
        XCTAssertEqual(evaluate(value).counts.advancingPostCaptureDelayEventCount, 3)
    }

    func testPreCaptureEventsAreValidatedButCannotSupplyObservationProof() {
        var value = fixture()
        for index in value.events.indices {
            value.events[index].callbackUptimeNanoseconds = 1_100_000_000 + UInt64(index) * 100_000_000
        }
        let before = evaluate(value)
        XCTAssertFalse(before.isVerified)
        XCTAssertEqual(before.counts.preCaptureEventCount, 3)
        XCTAssertEqual(before.counts.advancingPostCaptureDelayEventCount, 0)
        value.events.append(contentsOf: (3..<6).map(delay))
        XCTAssertTrue(evaluate(value).isVerified)
        value.events[0].threadID = 42
        XCTAssertTrue(evaluate(value).failures.contains(.wrongWorkerThread))
        value.events[0].threadID = 41
        value.events[0].detectorState = 3
        XCTAssertTrue(evaluate(value).failures.contains(.invalidEventFields))
    }

    func testOnlyPostCaptureDelayOveruseIsReportedAndLossAloneCannotVerify() {
        var value = fixture()
        value.events[1].detectorState = 2
        value.events[2].detectorState = 2
        let overuse = evaluate(value)
        XCTAssertTrue(overuse.isVerified)
        XCTAssertEqual(overuse.delayOveruseCount, 2)
        XCTAssertEqual(overuse.firstPostCaptureOveruseUptimeNanoseconds, 3_100_000_000)
        value.events = (0..<3).map(loss)
        let lossOnly = evaluate(value)
        XCTAssertFalse(lossOnly.isVerified)
        XCTAssertEqual(lossOnly.counts.postCaptureLossEventCount, 3)
        XCTAssertEqual(lossOnly.delayOveruseCount, 0)
        XCTAssertNil(lossOnly.firstPostCaptureOveruseUptimeNanoseconds)
        value.events.append(contentsOf: (3..<6).map(delay))
        XCTAssertTrue(evaluate(value).isVerified)
        value = fixture()
        var preCapture = delay(0)
        preCapture.callbackUptimeNanoseconds = 1_500_000_000
        preCapture.environmentTimeMicroseconds = 500
        preCapture.detectorState = 2
        value.events.insert(preCapture, at: 0)
        resequence(&value)
        XCTAssertTrue(evaluate(value).isVerified)
        XCTAssertEqual(evaluate(value).delayOveruseCount, 0)
        XCTAssertNil(evaluate(value).firstPostCaptureOveruseUptimeNanoseconds)
    }

    func testPositiveTimesBitratesAndCaptureBoundaryAreRequired() {
        for bitrate in [Int64(0), -1, .min] {
            var value = fixture()
            value.events[0].bitrateBps = bitrate
            XCTAssertTrue(evaluate(value).failures.contains(.invalidEventFields))
        }
        for clock in [Int64(0), -1, .min] {
            var value = fixture()
            value.events[0].environmentTimeMicroseconds = clock
            XCTAssertTrue(evaluate(value).failures.contains(.invalidEventTime))
        }
        for callback in [UInt64(0), 999_999_999] {
            var value = fixture()
            value.events[0].callbackUptimeNanoseconds = callback
            XCTAssertTrue(evaluate(value).failures.contains(.invalidEventTime))
        }
        var value = fixture()
        value.collectionStartUptimeNanoseconds = 0
        XCTAssertTrue(evaluate(value).failures.contains(.invalidCaptureBoundary))
        for capture in [UInt64(0), 999_999_999] {
            XCTAssertTrue(fixture().evaluate(hostWorkerID: 41,
                captureStartedAtUptimeNanoseconds: capture).failures.contains(.invalidCaptureBoundary))
        }
        value = fixture()
        value.events[0].bitrateBps = Int64.max
        XCTAssertTrue(evaluate(value).isVerified)
    }

    func testProbeVariantsRoundTripAndFailureBitrateRemainsAbsent() throws {
        var value = fixture()
        value.events += probeKinds.enumerated().map { probe($0.offset + 3, kind: $0.element) }
        let decoded = try Snapshot.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let result = evaluate(decoded)
        XCTAssertTrue(result.isVerified, "\(result.failures)")
        XCTAssertEqual(result.counts.probeCreatedEventCount, 1)
        XCTAssertEqual(result.counts.probeSuccessEventCount, 1)
        XCTAssertEqual(result.counts.probeFailureEventCount, 1)
        XCTAssertEqual(result.counts.postCaptureProbeCreatedEventCount, 1)
        XCTAssertEqual(result.counts.postCaptureProbeSuccessEventCount, 1)
        XCTAssertEqual(result.counts.postCaptureProbeFailureEventCount, 1)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 3)
        XCTAssertEqual(result.delayOveruseCount, 0)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativeEstimatorSummary.self,
                                                from: JSONEncoder().encode(result)), result)
        let failure = probe(0, kind: .probeFailure)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(failure))
            as? [String: Any])
        XCTAssertNil(object["bitrateBps"])
        object["bitrateBps"] = NSNull()
        let explicitNull = try JSONDecoder().decode(Event.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(explicitNull, failure)
        XCTAssertTrue(explicitNull.hasValidFields)
    }

    func testProbeClusterAndBitrateUsePositiveInt32Bounds() {
        let invalidIDs: [Int?] = [nil, -1, 0, Int(Int32.max) + 1, Int.max]
        for kind in probeKinds {
            for id in invalidIDs {
                var event = probe(0, kind: kind)
                event.probeClusterID = id
                assertInvalidFields(event)
            }
            var event = probe(0, kind: kind)
            event.probeClusterID = Int(Int32.max)
            XCTAssertTrue(event.hasValidFields)
        }
        let invalidRates: [Int64?] = [nil, -1, 0, Int64(Int32.max) + 1, Int64.max]
        for kind in [Event.Kind.probeCreated, .probeSuccess] {
            for bitrate in invalidRates {
                var event = probe(0, kind: kind)
                event.bitrateBps = bitrate
                assertInvalidFields(event)
            }
            for bitrate in [Int64(1), Int64(Int32.max)] {
                var event = probe(0, kind: kind)
                event.bitrateBps = bitrate
                XCTAssertTrue(event.hasValidFields)
            }
        }
    }

    func testProbeCreatedRequiresBothPositiveUInt32Minimums() {
        let fields: [WritableKeyPath<Event, UInt64?>] = [\.minimumProbes, \.minimumBytes]
        let invalidMinimums: [UInt64?] = [nil, 0, UInt64(UInt32.max) + 1, UInt64.max]
        for field in fields {
            for minimum in invalidMinimums {
                var event = probe(0, kind: .probeCreated)
                event[keyPath: field] = minimum
                assertInvalidFields(event)
            }
            for minimum in [UInt64(1), UInt64(UInt32.max)] {
                var event = probe(0, kind: .probeCreated)
                event[keyPath: field] = minimum
                XCTAssertTrue(event.hasValidFields)
            }
        }
    }

    func testProbeFailureRequiresReasonAndForbidsEvenZeroBitrate() {
        let invalidReasons: [Int?] = [nil, -1, 3, Int.max]
        for reason in invalidReasons {
            var event = probe(0, kind: .probeFailure)
            event.failureReason = reason
            assertInvalidFields(event)
        }
        for bitrate in [Int64(-1), 0, 1, Int64.max] {
            var event = probe(0, kind: .probeFailure)
            event.bitrateBps = bitrate
            assertInvalidFields(event)
        }
        for reason in 0...2 {
            var event = probe(0, kind: .probeFailure)
            event.failureReason = reason
            XCTAssertTrue(event.hasValidFields)
        }
    }

    func testEveryVariantRejectsFieldsBelongingToOtherPayloads() {
        let fields: [(String, [Event.Kind], (inout Event) -> Void)] = [
            ("detectorState", [.delay], { $0.detectorState = 0 }),
            ("fractionLoss", [.loss], { $0.fractionLoss = 0 }),
            ("expectedPackets", [.loss], { $0.expectedPackets = 0 }),
            ("probeClusterID", probeKinds, { $0.probeClusterID = 1 }),
            ("minimumProbes", [.probeCreated], { $0.minimumProbes = 1 }),
            ("minimumBytes", [.probeCreated], { $0.minimumBytes = 1 }),
            ("failureReason", [.probeFailure], { $0.failureReason = 0 }),
            ("inAlr", [.alrState], { $0.inAlr = false }),
            ("bitrateBps", [.delay, .loss, .probeCreated, .probeSuccess], { $0.bitrateBps = 1 })
        ]
        for kind in [Event.Kind.delay, .loss, .alrState] + probeKinds {
            let original = kind == .delay ? delay(0) : kind == .loss ? loss(0)
                : kind == .alrState ? alr(0, inAlr: false) : probe(0, kind: kind)
            XCTAssertTrue(original.hasValidFields)
            for (name, allowed, mutate) in fields where !allowed.contains(kind) {
                var event = original
                mutate(&event)
                XCTAssertFalse(event.hasValidFields, "\(kind) must reject \(name)")
                assertInvalidFields(event)
            }
        }
    }

    func testProbeOnlyEventsAndProbeAfterTwoDelaySamplesCannotVerify() {
        var value = fixture()
        value.events = probeKinds.enumerated().map { probe($0.offset, kind: $0.element) }
        var result = evaluate(value)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.failures, [.insufficientAdvancingDelayEvents])
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 0)
        XCTAssertEqual(result.delayOveruseCount, 0)
        XCTAssertNil(result.firstPostCaptureOveruseUptimeNanoseconds)
        value.events = [delay(0), delay(1)]
            + probeKinds.enumerated().map { probe($0.offset + 2, kind: $0.element) }
        result = evaluate(value)
        XCTAssertFalse(result.isVerified)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 2)
        XCTAssertEqual(result.failures, [.insufficientAdvancingDelayEvents])
    }

    func testRepeatedClusterResultsRemainIndependentObservations() {
        var value = fixture()
        let kinds: [Event.Kind] = [.probeCreated, .probeSuccess, .probeSuccess, .probeFailure]
        value.events += kinds.enumerated().map { probe($0.offset + 3, kind: $0.element) }
        let result = evaluate(value)
        XCTAssertTrue(result.isVerified, "\(result.failures)")
        XCTAssertEqual(Set(value.events.compactMap(\.probeClusterID)), [7])
        XCTAssertEqual(result.counts.probeCreatedEventCount, 1)
        XCTAssertEqual(result.counts.probeSuccessEventCount, 2)
        XCTAssertEqual(result.counts.probeFailureEventCount, 1)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 3)
        value.events.remove(at: 3)
        resequence(&value)
        XCTAssertTrue(evaluate(value).isVerified, "Results need not have a retained creation event")
    }

    func testPreCaptureProbeEventsAreValidatedWithoutPostCaptureCounts() {
        for kind in probeKinds {
            var value = fixture()
            var event = probe(0, kind: kind)
            event.callbackUptimeNanoseconds = 1_500_000_000
            event.environmentTimeMicroseconds = 500
            value.events.insert(event, at: 0)
            resequence(&value)
            let result = evaluate(value)
            XCTAssertTrue(result.isVerified, "\(result.failures)")
            XCTAssertEqual(result.counts.preCaptureEventCount, 1)
            XCTAssertEqual(result.counts.probeCreatedEventCount, kind == .probeCreated ? 1 : 0)
            XCTAssertEqual(result.counts.probeSuccessEventCount, kind == .probeSuccess ? 1 : 0)
            XCTAssertEqual(result.counts.probeFailureEventCount, kind == .probeFailure ? 1 : 0)
            XCTAssertEqual(result.counts.postCaptureProbeCreatedEventCount, 0)
            XCTAssertEqual(result.counts.postCaptureProbeSuccessEventCount, 0)
            XCTAssertEqual(result.counts.postCaptureProbeFailureEventCount, 0)
            value.events[0].probeClusterID = nil
            XCTAssertTrue(evaluate(value).failures.contains(.invalidEventFields))
            value.events[0].probeClusterID = 7
            value.events[0].threadID = 42
            XCTAssertTrue(evaluate(value).failures.contains(.wrongWorkerThread))
        }
    }

    func testProbeWireIntegersRejectNegativeUnsignedAndOverflow() throws {
        var value = fixture()
        value.events.append(probe(3, kind: .probeCreated))
        let original = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        for (from, to) in [
            ("\"probeClusterID\":7", "\"probeClusterID\":9223372036854775808"),
            ("\"minimumProbes\":5", "\"minimumProbes\":-1"),
            ("\"minimumBytes\":1200", "\"minimumBytes\":18446744073709551616")
        ] {
            XCTAssertTrue(original.contains(from))
            XCTAssertThrowsError(try Snapshot.decode(Data(original.replacingOccurrences(of: from, with: to).utf8)))
        }
    }

    func testALRMembershipRoundTripsWithoutContributingDelayEvidence() throws {
        var value = fixture()
        value.events += [alr(3, inAlr: true), alr(4, inAlr: false)]
        let decoded = try Snapshot.decode(JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value)
        let result = evaluate(decoded)
        XCTAssertTrue(result.isVerified, "\(result.failures)")
        XCTAssertEqual(result.counts.alrStateEventCount, 2)
        XCTAssertEqual(result.counts.postCaptureALRStateEventCount, 2)
        XCTAssertEqual(result.counts.advancingPostCaptureDelayEventCount, 3)
        XCTAssertEqual(result.delayOveruseCount, 0)
        value.events = [alr(0, inAlr: true), alr(1, inAlr: false), alr(2, inAlr: true)]
        XCTAssertEqual(evaluate(value).failures, [.insufficientAdvancingDelayEvents])
        XCTAssertEqual(evaluate(value).counts.advancingPostCaptureDelayEventCount, 0)
        value.events = [delay(0), delay(1), alr(2, inAlr: true)]
        XCTAssertEqual(evaluate(value).failures, [.insufficientAdvancingDelayEvents])
        XCTAssertEqual(evaluate(value).counts.advancingPostCaptureDelayEventCount, 2)
        value = fixture()
        var beforeCapture = alr(0, inAlr: true)
        beforeCapture.callbackUptimeNanoseconds = 1_500_000_000
        beforeCapture.environmentTimeMicroseconds = 500
        value.events.insert(beforeCapture, at: 0)
        resequence(&value)
        XCTAssertTrue(evaluate(value).isVerified)
        XCTAssertEqual(evaluate(value).counts.alrStateEventCount, 1)
        XCTAssertEqual(evaluate(value).counts.postCaptureALRStateEventCount, 0)
    }

    func testALRRequiresMembershipAndForbidsEvenZeroBitrate() {
        var event = alr(0, inAlr: false)
        event.inAlr = nil
        assertInvalidFields(event)
        for bitrate in [Int64(-1), 0, 1] {
            event = alr(0, inAlr: true)
            event.bitrateBps = bitrate
            assertInvalidFields(event)
        }
    }

    func testALRWireMembershipRejectsNumericAndStringValues() throws {
        var value = fixture()
        value.events.append(alr(3, inAlr: true))
        let original = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertTrue(original.contains("\"inAlr\":true"))
        for replacement in ["0", "1", "\"true\"", "\"false\""] {
            let malformed = original.replacingOccurrences(of: "\"inAlr\":true", with: "\"inAlr\":\(replacement)")
            XCTAssertThrowsError(try Snapshot.decode(Data(malformed.utf8)))
        }
    }

    private var probeKinds: [Event.Kind] { [.probeCreated, .probeSuccess, .probeFailure] }

    private func assertInvalidFields(_ event: Event, file: StaticString = #filePath, line: UInt = #line) {
        var value = fixture()
        value.events[0] = event
        XCTAssertTrue(evaluate(value).failures.contains(.invalidEventFields), "\(event)", file: file, line: line)
    }

    private func evaluate(_ value: Snapshot) -> StartupVideoNativeEstimatorSummary {
        value.evaluate(hostWorkerID: 41, captureStartedAtUptimeNanoseconds: captureStarted)
    }

    private func fixture() -> Snapshot {
        Snapshot(schemaVersion: 2, capacity: 2_048, collectionStartUptimeNanoseconds: 1_000_000_000,
                 interceptionCount: 1, controllerCreateCount: 1, processIntervalCallCount: 1,
                 defaultDelegateCount: 1, environmentIdentityMatches: 1, liveLoggerCount: 1,
                 loggerCreatedCount: 1, loggerDestroyedCount: 0, invalidEventCount: 0,
                 droppedEventCount: 0, unknownEventCount: 0, rejectedCreateCount: 0,
                 unexpectedFactoryCount: 0, startLoggingAttemptCount: 0,
                 environmentIdentityFailureCount: 0, fieldTrialFailureCount: 0,
                 selectorFailureCount: 0, lifetimeFailureCount: 0, factoryRequestCount: 1,
                 processIntervalMicroseconds: 25_000, events: (0..<3).map(delay))
    }

    private func delay(_ index: Int) -> Event {
        Event(sequence: UInt64(index) + 1, kind: .delay, bitrateBps: 800_000,
              callbackUptimeNanoseconds: 3_000_000_000 + UInt64(index) * 100_000_000,
              threadID: 41, environmentTimeMicroseconds: 1_000 + Int64(index) * 100,
              detectorState: 0, fractionLoss: nil, expectedPackets: nil)
    }

    private func loss(_ index: Int) -> Event {
        var event = delay(index)
        event.kind = .loss
        event.detectorState = nil
        event.fractionLoss = 255
        event.expectedPackets = 0
        return event
    }

    private func probe(_ index: Int, kind: Event.Kind) -> Event {
        var event = delay(index)
        event.kind = kind
        event.detectorState = nil
        event.probeClusterID = 7
        switch kind {
        case .probeCreated:
            event.minimumProbes = 5
            event.minimumBytes = 1_200
        case .probeSuccess:
            break
        case .probeFailure:
            event.bitrateBps = nil
            event.failureReason = 0
        case .delay, .loss, .alrState:
            preconditionFailure("Expected a probe event kind")
        }
        return event
    }

    private func alr(_ index: Int, inAlr: Bool) -> Event {
        var event = delay(index)
        event.kind = .alrState
        event.bitrateBps = nil
        event.detectorState = nil
        event.inAlr = inAlr
        return event
    }

    private func resequence(_ value: inout Snapshot) {
        for index in value.events.indices { value.events[index].sequence = UInt64(index) + 1 }
    }
}
#endif
