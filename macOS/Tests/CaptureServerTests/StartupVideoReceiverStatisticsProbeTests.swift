#if os(macOS)
import Foundation
import WebRTCTransport
import XCTest

final class StartupVideoReceiverStatisticsProbeTests: XCTestCase {
    func testNonblockingRequestRejectsOverlapAndCopiesOnlyVideoEvidence() async throws {
        let started = expectation(description: "one collection started")
        let completed = expectation(description: "completion clock read")
        let gate = ReceiverProbeTestGate(onStart: { started.fulfill() })
        let clock = ReceiverProbeTestClock([100, 200]) { read in
            if read == 2 { completed.fulfill() }
        }
        let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                       now: { clock.read() })
        probe.request()
        await fulfillment(of: [started], timeout: 1)
        probe.request()
        probe.request()
        XCTAssertEqual(probe.snapshot().startedCount, 1)
        XCTAssertEqual(probe.snapshot().skippedBusyCount, 2)
        XCTAssertEqual(gate.maximumConcurrent, 1)
        XCTAssertTrue(probe.snapshot().records.isEmpty)

        let video = WebRTCVideoStatistics(
            bytes: UInt64.max, packets: 90, packetsLost: -2,
            framesPerSecond: 5.5, frameWidth: 1_080, frameHeight: 1_920,
            framesEncodedOrDecoded: 18, framesReceived: 20, framesDropped: 2,
            jitterBufferDelay: 0.375, jitterBufferEmittedCount: 18,
            totalDecodeTime: 0.0625, qpSum: 500, nackCount: 3, pliCount: 1
        )
        gate.release(WebRTCStatisticsSnapshot(
            collectedAt: Date(timeIntervalSince1970: 123), collectionSequence: 47,
            route: WebRTCICERouteDiagnostics(kind: .relayed), currentRoundTripTime: 0.7,
            availableOutgoingBitrate: 999, outboundVideo: .init(bytes: 9),
            inboundVideo: video, inboundAudio: .init(bytes: 7)
        ))
        await fulfillment(of: [completed], timeout: 1)
        let batch = probe.snapshot()
        let record = try XCTUnwrap(batch.records.first)
        XCTAssertEqual(batch.capacity, 128)
        XCTAssertEqual(batch.requestCount, 3)
        XCTAssertEqual(batch.completedCount, 1)
        XCTAssertEqual(record.requestedUptimeNanoseconds, 100)
        XCTAssertEqual(record.completedUptimeNanoseconds, 200)
        XCTAssertEqual(record.collectionSequence, 47)
        XCTAssertNil(record.nativeReportTimestampMicroseconds)
        XCTAssertEqual(record.inboundVideo, video)
        let encoded = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoReceiverStatisticsBatch.self,
                                                from: encoded), batch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), Set([
            "requestedUptimeNanoseconds", "completedUptimeNanoseconds",
            "collectionSequence", "inboundVideo"
        ]))
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["route", "Audio", "outboundVideo", "collectedAt", "currentRoundTripTime"] {
            XCTAssertFalse(text.contains(forbidden))
        }
        await probe.finish()
        await probe.finish()
        XCTAssertEqual(probe.snapshot(), batch)
    }

    func testRetirementRejectsLateCompletionEvenWhenCollectorIgnoresCancellation() async {
        let started = expectation(description: "collection started")
        let cancelled = expectation(description: "collection cancellation observed")
        let gate = ReceiverProbeTestGate(onStart: { started.fulfill() },
                                        onCancel: { cancelled.fulfill() })
        let clock = ReceiverProbeTestClock([100, 200])
        let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                       now: { clock.read() })
        probe.request()
        await fulfillment(of: [started], timeout: 1)
        let finish = Task { await probe.finish() }
        await fulfillment(of: [cancelled], timeout: 1)
        probe.request()
        XCTAssertEqual(probe.snapshot().skippedRetiredCount, 1)
        XCTAssertEqual(probe.snapshot().completedCount, 0)
        gate.release(WebRTCStatisticsSnapshot(collectionSequence: 1,
                                              inboundVideo: .init(framesReceived: 1)))
        await finish.value
        XCTAssertEqual(probe.snapshot().startedCount, 1)
        XCTAssertEqual(probe.snapshot().completedCount, 1)
        XCTAssertEqual(probe.snapshot().retiredCompletionCount, 1)
        XCTAssertTrue(probe.snapshot().records.isEmpty)
        XCTAssertEqual(clock.readCount, 1, "Retired payload must not become timed evidence")
    }

    func testFinalCollectionDrainsAndRetiresDiagnosticRequestFirst() async {
        let started = expectation(description: "diagnostic collection started")
        let cancelled = expectation(description: "diagnostic cancellation observed")
        let finalStarted = expectation(description: "final collection started")
        let gate = ReceiverProbeTestGate(onStart: { started.fulfill() })
        let finalSnapshot = WebRTCStatisticsSnapshot(
            collectionSequence: 99,
            inboundVideo: .init(bytes: 900, framesReceived: 9)
        )
        let probe = StartupVideoReceiverStatisticsProbe(collect: {
            if gate.maximumConcurrent == 0 {
                return await withTaskCancellationHandler {
                    await gate.collect()
                } onCancel: {
                    cancelled.fulfill()
                }
            }
            XCTAssertEqual(
                gate.pendingCount, 0,
                "Final collection must follow completion of the diagnostic request"
            )
            finalStarted.fulfill()
            return finalSnapshot
        }, now: { 100 })

        probe.request()
        await fulfillment(of: [started], timeout: 1)
        let finalTask = Task { await probe.finishAndCollectFinalSnapshot() }
        await fulfillment(of: [cancelled], timeout: 1)
        probe.request()
        XCTAssertEqual(probe.snapshot().skippedRetiredCount, 1)

        gate.release(WebRTCStatisticsSnapshot(
            collectionSequence: 1,
            inboundVideo: .init(bytes: 100, framesReceived: 1)
        ))
        let result = await finalTask.value
        await fulfillment(of: [finalStarted], timeout: 1)

        XCTAssertEqual(result, finalSnapshot)
        XCTAssertEqual(probe.snapshot().requestCount, 2)
        XCTAssertEqual(probe.snapshot().startedCount, 1)
        XCTAssertEqual(probe.snapshot().completedCount, 1)
        XCTAssertEqual(probe.snapshot().retiredCompletionCount, 1)
        XCTAssertTrue(probe.snapshot().records.isEmpty)
        await probe.finish()
    }

    func testSaturationRetainsFirstRecordsAndStopsFurtherNativeRequests() async throws {
        let started = [expectation(description: "first started"), expectation(description: "second started")]
        let completed = [expectation(description: "first completed"), expectation(description: "second completed")]
        let gate = ReceiverProbeTestGate(onNumberedStart: { number in
            guard (1...started.count).contains(number) else {
                XCTFail("Saturated collector started an unexpected request")
                return
            }
            started[number - 1].fulfill()
        })
        let clock = ReceiverProbeTestClock([100, 200, 300, 400]) { read in
            if read.isMultiple(of: 2), (1...completed.count).contains(read / 2) {
                completed[read / 2 - 1].fulfill()
            }
        }
        let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                       now: { clock.read() }, capacity: 2)
        for index in 0..<2 {
            probe.request()
            await fulfillment(of: [started[index]], timeout: 1)
            gate.release(WebRTCStatisticsSnapshot(collectionSequence: UInt64(index + 1),
                                                  inboundVideo: .init(framesReceived: UInt64(index))))
            await fulfillment(of: [completed[index]], timeout: 1)
        }
        let retained = probe.snapshot().records
        for _ in 0..<5 { probe.request() }
        let batch = probe.snapshot()
        XCTAssertEqual(batch.records, retained)
        XCTAssertEqual(batch.records.map(\.collectionSequence), [1, 2])
        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.requestCount, 7)
        XCTAssertEqual(batch.startedCount, 2)
        XCTAssertEqual(batch.completedCount, 2)
        XCTAssertEqual(batch.saturatedCount, 5)
        XCTAssertEqual(batch.skippedBusyCount, 0)
        XCTAssertEqual(gate.maximumConcurrent, 1)
        await probe.finish()
    }

    func testMissingVideoIsOmittedWithoutInventingCountersOrNativeTimestamp() async {
        let started = expectation(description: "collection started")
        let completed = expectation(description: "completion clock read")
        let gate = ReceiverProbeTestGate(onStart: { started.fulfill() })
        let clock = ReceiverProbeTestClock([100, 100]) { read in
            if read == 2 { completed.fulfill() }
        }
        let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                       now: { clock.read() })
        probe.request()
        await fulfillment(of: [started], timeout: 1)
        gate.release(WebRTCStatisticsSnapshot(inboundAudio: .init(packets: 99)))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertTrue(probe.snapshot().records.isEmpty)
        XCTAssertEqual(probe.snapshot().omittedVideoCount, 1)
        XCTAssertEqual(probe.snapshot().malformedClockCount, 0)
        XCTAssertEqual(probe.snapshot().regressingClockCount, 0)
        await probe.finish()
    }

    func testMalformedRequestClockDoesNotStartCollection() async {
        let neverStarted = expectation(description: "must not collect")
        neverStarted.isInverted = true
        let probe = StartupVideoReceiverStatisticsProbe(collect: {
            neverStarted.fulfill()
            return WebRTCStatisticsSnapshot()
        }, now: { 0 })
        probe.request()
        XCTAssertEqual(probe.snapshot().malformedClockCount, 1)
        XCTAssertEqual(probe.snapshot().regressingClockCount, 0)
        XCTAssertEqual(probe.snapshot().startedCount, 0)
        await probe.finish()
        await fulfillment(of: [neverStarted], timeout: 0.01)
    }

    func testNextRequestCannotRegressBehindPreviousCompletion() async {
        let started = expectation(description: "one collection started")
        let completed = expectation(description: "completion clock read")
        let gate = ReceiverProbeTestGate(onStart: { started.fulfill() })
        let clock = ReceiverProbeTestClock([100, 200, 199]) { read in
            if read == 2 { completed.fulfill() }
        }
        let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                       now: { clock.read() })
        probe.request()
        await fulfillment(of: [started], timeout: 1)
        gate.release(WebRTCStatisticsSnapshot(inboundVideo: .init(framesReceived: 1)))
        await fulfillment(of: [completed], timeout: 1)
        let retained = probe.snapshot().records
        probe.request()
        XCTAssertEqual(probe.snapshot().startedCount, 1)
        XCTAssertEqual(probe.snapshot().regressingClockCount, 1)
        XCTAssertEqual(probe.snapshot().malformedClockCount, 0)
        XCTAssertEqual(probe.snapshot().records, retained)
        await probe.finish()
    }

    func testMalformedAndRegressingCompletionClocksAreSeparateAndNeverAppend() async {
        for completedAt in [UInt64(0), UInt64(99)] {
            let started = expectation(description: "collection started \(completedAt)")
            let completed = expectation(description: "completion clock read \(completedAt)")
            let gate = ReceiverProbeTestGate(onStart: { started.fulfill() })
            let clock = ReceiverProbeTestClock([100, completedAt]) { read in
                if read == 2 { completed.fulfill() }
            }
            let probe = StartupVideoReceiverStatisticsProbe(collect: { await gate.collect() },
                                                           now: { clock.read() })
            probe.request()
            await fulfillment(of: [started], timeout: 1)
            gate.release(WebRTCStatisticsSnapshot(inboundVideo: .init(framesReceived: 1)))
            await fulfillment(of: [completed], timeout: 1)
            XCTAssertEqual(probe.snapshot().malformedClockCount, completedAt == 0 ? 1 : 0)
            XCTAssertEqual(probe.snapshot().regressingClockCount, completedAt == 99 ? 1 : 0)
            XCTAssertTrue(probe.snapshot().records.isEmpty)
            XCTAssertEqual(probe.snapshot().completedCount, 1)
            await probe.finish()
        }
    }
}

private final class ReceiverProbeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private let onRead: @Sendable (Int) -> Void
    private var count = 0

    init(_ values: [UInt64], onRead: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.values = values
        self.onRead = onRead
    }

    var readCount: Int { lock.withLock { count } }

    func read() -> UInt64 {
        let (number, value) = lock.withLock {
            count += 1
            return (count, count <= values.count ? values[count - 1] : 0)
        }
        onRead(number)
        return value
    }
}

private final class ReceiverProbeTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let onStart: @Sendable (Int) -> Void
    private let onCancel: @Sendable () -> Void
    private var continuations: [CheckedContinuation<WebRTCStatisticsSnapshot, Never>] = []
    private var startedCount = 0
    private var maximumCount = 0

    init(onStart: @escaping @Sendable () -> Void,
         onCancel: @escaping @Sendable () -> Void = {}) {
        self.onStart = { _ in onStart() }
        self.onCancel = onCancel
    }

    init(onNumberedStart: @escaping @Sendable (Int) -> Void) {
        onStart = onNumberedStart
        onCancel = {}
    }

    var maximumConcurrent: Int { lock.withLock { maximumCount } }
    var pendingCount: Int { lock.withLock { continuations.count } }

    func collect() async -> WebRTCStatisticsSnapshot {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let number = lock.withLock {
                    continuations.append(continuation)
                    startedCount += 1
                    maximumCount = max(maximumCount, continuations.count)
                    return startedCount
                }
                onStart(number)
            }
        } onCancel: {
            // Deliberately leave the continuation pending: the native callback may ignore
            // cancellation, and the probe must reject its eventual result after retirement.
            self.onCancel()
        }
    }

    func release(_ snapshot: WebRTCStatisticsSnapshot) {
        let continuation = lock.withLock { continuations.isEmpty ? nil : continuations.removeFirst() }
        guard let continuation else {
            XCTFail("No pending collection to release")
            return
        }
        continuation.resume(returning: snapshot)
    }
}
#endif
