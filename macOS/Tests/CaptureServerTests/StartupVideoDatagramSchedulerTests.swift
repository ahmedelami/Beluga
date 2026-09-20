#if os(macOS)
import Foundation
import XCTest

final class StartupVideoDatagramSchedulerTests: XCTestCase {
    private let millisecond: UInt64 = 1_000_000

    func testReleaseMeasurementsExposeCatchUpBatchAndRealDispatchLateness() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 1_000_000
        )
        for _ in 0..<18 {
            scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        }
        let due = scheduler.takeDue(at: 150 * millisecond, generation: 0)
        XCTAssertEqual(due.count, 18)
        var batch = StartupVideoDatagramReleaseMeasurements.Batch()
        for packet in due {
            batch.recordAttempt(byteCount: packet.bytes.count,
                                deliveryDeadline: packet.deliveryDeadline, at: 150 * millisecond)
        }
        var measurements = StartupVideoDatagramReleaseMeasurements()
        measurements.record(batch)
        XCTAssertEqual(measurements.maximumReleaseBatchDatagrams, 18)
        XCTAssertEqual(measurements.maximumReleaseBatchBytes, 18_000)
        XCTAssertEqual(measurements.maximumDeliveryLatenessNanoseconds, 142 * millisecond)
        XCTAssertEqual(scheduler.counters(from: .host).maximumSerializationDelayNanoseconds, 144 * millisecond)
    }

    func testReleaseMeasurementsRetainIndependentMaximaAcrossBatches() {
        var first = StartupVideoDatagramReleaseMeasurements.Batch()
        first.recordAttempt(byteCount: 1_000, deliveryDeadline: millisecond, at: 10 * millisecond)
        var second = StartupVideoDatagramReleaseMeasurements.Batch()
        second.recordAttempt(byteCount: 100, deliveryDeadline: 12 * millisecond, at: 12 * millisecond)
        second.recordAttempt(byteCount: 100, deliveryDeadline: 13 * millisecond, at: 12 * millisecond)
        second.recordAttempt(byteCount: 100, deliveryDeadline: 14 * millisecond, at: 14 * millisecond)
        var measurements = StartupVideoDatagramReleaseMeasurements()
        measurements.record(first)
        measurements.record(second)
        measurements.record(StartupVideoDatagramReleaseMeasurements.Batch())
        XCTAssertEqual(measurements.maximumReleaseBatchDatagrams, 3)
        XCTAssertEqual(measurements.maximumReleaseBatchBytes, 1_000)
        XCTAssertEqual(measurements.maximumDeliveryLatenessNanoseconds, 9 * millisecond)
    }

    func testReleaseMeasurementDirectionsRemainIndependentAndMalformedSizesAreRejected() {
        var first = StartupVideoDatagramReleaseMeasurements.Batch()
        first.recordAttempt(byteCount: 1_000, deliveryDeadline: 0, at: 5 * millisecond)
        first.recordAttempt(byteCount: -1, deliveryDeadline: 0, at: UInt64.max)
        first.recordAttempt(byteCount: 65_536, deliveryDeadline: 0, at: UInt64.max)
        var second = StartupVideoDatagramReleaseMeasurements.Batch()
        second.recordAttempt(byteCount: 0, deliveryDeadline: millisecond, at: millisecond)
        var host = StartupVideoDatagramReleaseMeasurements()
        var viewer = StartupVideoDatagramReleaseMeasurements()
        host.record(first)
        viewer.record(second)
        XCTAssertEqual(host.maximumReleaseBatchDatagrams, 1)
        XCTAssertEqual(host.maximumReleaseBatchBytes, 1_000)
        XCTAssertEqual(host.maximumDeliveryLatenessNanoseconds, 5 * millisecond)
        XCTAssertEqual(viewer.maximumReleaseBatchDatagrams, 1)
        XCTAssertEqual(viewer.maximumReleaseBatchBytes, 0)
        XCTAssertEqual(viewer.maximumDeliveryLatenessNanoseconds, 0)
    }

    func testUnlimitedDefaultPreservesFixedDelayAndArrivalOrder() throws {
        var scheduler = try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 50 * millisecond)
        XCTAssertTrue(scheduler.enqueue(Data([1]), from: .host, at: 0))
        XCTAssertTrue(scheduler.enqueue(Data([2]), from: .viewer, at: 5 * millisecond))
        XCTAssertEqual(scheduler.nextDeadline, 50 * millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 49 * millisecond, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 50 * millisecond, generation: 0).map(\.bytes), [Data([1])])
        XCTAssertEqual(scheduler.takeDue(at: 55 * millisecond, generation: 0).map(\.bytes), [Data([2])])
        XCTAssertEqual(scheduler.counters(from: .host).serializationDelayNanoseconds, 0)
        XCTAssertEqual(scheduler.pendingBytes, 0)
        XCTAssertNil(scheduler.nextDeadline)
    }

    func testByteTimeConservationAndPropagationAreIndependent() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 8_000_000
        )
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0))
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 2, count: 500), from: .host, at: 0))
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 3, count: 1_500), from: .host, at: 0))
        XCTAssertEqual(scheduler.nextDeadline, millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 3 * millisecond - 1, generation: 0).isEmpty)
        let first = scheduler.takeDue(at: 3 * millisecond, generation: 0)
        XCTAssertEqual(first.map(\.bytes.count), [1_000])
        XCTAssertEqual(first.map(\.deliveryDeadline), [3 * millisecond])
        let second = scheduler.takeDue(at: 3_500_000, generation: 0)
        XCTAssertEqual(second.map(\.bytes.count), [500])
        XCTAssertEqual(second.map(\.deliveryDeadline), [3_500_000])
        let third = scheduler.takeDue(at: 5 * millisecond, generation: 0)
        XCTAssertEqual(third.map(\.bytes.count), [1_500])
        XCTAssertEqual(third.map(\.deliveryDeadline), [5 * millisecond])
        XCTAssertEqual(scheduler.counters(from: .host).serializationDelayNanoseconds, 5_500_000)
        XCTAssertEqual(scheduler.counters(from: .host).maximumSerializationDelayNanoseconds, 3 * millisecond)
        XCTAssertEqual(scheduler.pendingDatagrams, 0)
    }

    func testDirectionsDoNotConsumeEachOthersSerializationCapacity() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0,
            hostToViewerBitsPerSecond: 800_000,
            viewerToHostBitsPerSecond: 8_000_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(repeating: 2, count: 1_000), from: .viewer, at: 0)
        XCTAssertEqual(scheduler.takeDue(at: millisecond, generation: 0).map(\.from), [.viewer])
        XCTAssertEqual(scheduler.counters(from: .host).pendingBytes, 1_000)
        XCTAssertEqual(scheduler.counters(from: .viewer).pendingBytes, 0)
        XCTAssertEqual(scheduler.takeDue(at: 10 * millisecond, generation: 0).map(\.from), [.host])
    }

    func testRateIncreaseRetainsPartiallySerializedWorkWithoutRetroactiveCredit() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        try scheduler.setBandwidth(8_000_000, from: .host, at: 5 * millisecond)
        XCTAssertEqual(scheduler.counters(from: .host).configuredBitsPerSecond, 8_000_000)
        XCTAssertEqual(scheduler.nextDeadline, 5_500_000)
        XCTAssertTrue(scheduler.takeDue(at: 5_499_999, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 5_500_000, generation: 0).map(\.bytes.count), [1_000])
        XCTAssertEqual(scheduler.counters(from: .host).serializationDelayNanoseconds, 5_500_000)
    }

    func testRateDecreaseDoesNotRestartPacketAndDoesNotAffectReverseLink() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0,
            hostToViewerBitsPerSecond: 8_000_000,
            viewerToHostBitsPerSecond: 8_000_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(repeating: 2, count: 1_000), from: .viewer, at: 0)
        try scheduler.setBandwidth(800_000, from: .host, at: 500_000)
        XCTAssertEqual(scheduler.takeDue(at: millisecond, generation: 0).map(\.from), [.viewer])
        XCTAssertTrue(scheduler.takeDue(at: 5_499_999, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 5_500_000, generation: 0).map(\.from), [.host])
    }

    func testRestoringUnlimitedRateCompletesRemainingWorkOnlyAtChangeBoundary() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        try scheduler.setBandwidth(nil, from: .host, at: 5 * millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 7 * millisecond - 1, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 7 * millisecond, generation: 0).map(\.deliveryDeadline), [7 * millisecond])
    }

    func testAlreadySerializedPacketsKeepTheirPropagationDeadlineAcrossRateChanges() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 50 * millisecond, hostToViewerBitsPerSecond: 8_000_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        try scheduler.setBandwidth(1, from: .host, at: 2 * millisecond)
        XCTAssertEqual(scheduler.nextDeadline, 51 * millisecond)
        XCTAssertEqual(scheduler.takeDue(at: 51 * millisecond, generation: 0).count, 1)
    }

    func testIdleTimeDoesNotAccumulateBurstCredit() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000
        )
        XCTAssertTrue(scheduler.takeDue(at: 1_000 * millisecond, generation: 0).isEmpty)
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 1_000 * millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 1_010 * millisecond - 1, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 1_010 * millisecond, generation: 0).count, 1)
    }

    func testCoarseAndFineClocksConserveTheSameServiceWithoutTimerBurstCredit() throws {
        for fineClock in [false, true] {
            var scheduler = try StartupVideoDatagramScheduler(
                oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 800_000
            )
            for value in UInt8(1)...3 {
                scheduler.enqueue(Data(repeating: value, count: 1_000), from: .host, at: 0)
            }
            var delivered: [StartupVideoDatagramScheduler.Datagram] = []
            if fineClock {
                for tick in 1...32 {
                    delivered += scheduler.takeDue(at: UInt64(tick) * millisecond, generation: 0)
                }
            } else {
                delivered = scheduler.takeDue(at: 32 * millisecond, generation: 0)
            }
            XCTAssertEqual(delivered.map(\.deliveryDeadline), [12, 22, 32].map { UInt64($0) * millisecond })
            XCTAssertEqual(delivered.map { $0.bytes.first! }, [1, 2, 3])
            XCTAssertEqual(scheduler.counters(from: .host).serializationDelayNanoseconds, 60 * millisecond)
        }
    }

    func testCapacityChangeAtExactCompletionOnlyAffectsTheFollowingPacket() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(repeating: 2, count: 1_000), from: .host, at: 0)
        try scheduler.setBandwidth(8_000_000, from: .host, at: 10 * millisecond)
        XCTAssertEqual(scheduler.takeDue(at: 10 * millisecond, generation: 0).map(\.deliveryDeadline), [10 * millisecond])
        XCTAssertEqual(scheduler.takeDue(at: 11 * millisecond, generation: 0).map(\.deliveryDeadline), [11 * millisecond])
    }

    func testFractionalNanosecondSerializationRoundsUpNeverExceedingCapacity() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 3,
            maximumQueueAgeNanoseconds: 10_000_000_000
        )
        scheduler.enqueue(Data([1]), from: .host, at: 0)
        XCTAssertEqual(scheduler.nextDeadline, 2_666_666_667)
        XCTAssertTrue(scheduler.takeDue(at: 2_666_666_666, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 2_666_666_667, generation: 0).count, 1)
    }

    func testByteAndDatagramBoundsIncludePacketsAlreadyInPropagation() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 50 * millisecond,
            maximumQueuedBytes: 10, maximumQueuedDatagrams: 2
        )
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 1, count: 6), from: .host, at: 0))
        XCTAssertFalse(scheduler.enqueue(Data(repeating: 2, count: 5), from: .viewer, at: 0))
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 3, count: 4), from: .viewer, at: 0))
        XCTAssertFalse(scheduler.enqueue(Data(), from: .host, at: 0))
        XCTAssertEqual(scheduler.pendingBytes, 10)
        XCTAssertEqual(scheduler.maximumPendingBytes, 10)
        XCTAssertEqual(scheduler.pendingDatagrams, 2)
        XCTAssertEqual(scheduler.counters(from: .host).overflowDatagrams, 1)
        XCTAssertEqual(scheduler.counters(from: .viewer).overflowDatagrams, 1)
        XCTAssertEqual(scheduler.takeDue(at: 50 * millisecond, generation: 0).count, 2)
        XCTAssertTrue(scheduler.enqueue(Data(repeating: 4, count: 10), from: .host, at: 50 * millisecond))
        XCTAssertEqual(scheduler.maximumPendingBytes, 10)
    }

    func testExpiryDropsUnserializedPacketAndDoesNotReservePhantomCapacity() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000,
            maximumQueueAgeNanoseconds: 5 * millisecond
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(repeating: 2, count: 100), from: .host, at: 4 * millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 5 * millisecond, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.counters(from: .host).expiredDatagrams, 1)
        XCTAssertEqual(scheduler.pendingBytes, 100)
        XCTAssertEqual(scheduler.takeDue(at: 6 * millisecond, generation: 0).map(\.bytes.count), [100])
        XCTAssertEqual(scheduler.counters(from: .host).serializationDelayNanoseconds, 2 * millisecond)
    }

    func testDelayedTimerChargesExpiringPacketUntilItsExpiryThenServicesNextPacket() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000,
            maximumQueueAgeNanoseconds: 5 * millisecond
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(repeating: 2, count: 100), from: .host, at: 4 * millisecond)
        let delivered = scheduler.takeDue(at: 6 * millisecond, generation: 0)
        XCTAssertEqual(delivered.map(\.bytes.count), [100])
        XCTAssertEqual(delivered.map(\.deliveryDeadline), [6 * millisecond])
        XCTAssertEqual(scheduler.counters(from: .host).expiredDatagrams, 1)
        XCTAssertEqual(scheduler.pendingBytes, 0)
    }

    func testQueueAgeIsStrictEvenWhenTimerCallbackArrivesAfterDeliveryWasDue() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, maximumQueueAgeNanoseconds: 5 * millisecond
        )
        scheduler.enqueue(Data([1]), from: .host, at: 0)
        XCTAssertTrue(scheduler.takeDue(at: 5 * millisecond, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.counters(from: .host).expiredDatagrams, 1)
        XCTAssertEqual(scheduler.pendingDatagrams, 0)
        XCTAssertNil(scheduler.nextDeadline)
    }

    func testZeroLengthPacketCannotOvertakeInProgressPacket() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        scheduler.enqueue(Data(), from: .host, at: millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 9 * millisecond, generation: 0).isEmpty)
        XCTAssertEqual(scheduler.takeDue(at: 10 * millisecond, generation: 0).map(\.bytes.count), [1_000, 0])
    }

    func testBackpressureIsOneDropWithoutRetryQueueOrLaterFlush() throws {
        var scheduler = try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0)
        scheduler.enqueue(Data([1]), from: .host, at: 0)
        let attempted = scheduler.takeDue(at: 0, generation: 0)
        XCTAssertEqual(attempted.count, 1)
        scheduler.recordBackpressure(from: attempted[0].from)
        XCTAssertEqual(scheduler.counters(from: .host).backpressureDatagrams, 1)
        XCTAssertEqual(scheduler.pendingDatagrams, 0)
        XCTAssertEqual(scheduler.pendingBytes, 0)
        XCTAssertTrue(scheduler.takeDue(at: 1_000 * millisecond, generation: 0).isEmpty)
    }

    func testBlackoutRevokesOldTimersWithoutLettingThemFlushNewGeneration() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: 0)
        let oldGeneration = scheduler.generation
        scheduler.discardPending()
        XCTAssertEqual(scheduler.pendingBytes, 0)
        XCTAssertEqual(scheduler.counters(from: .host).discardedDatagrams, 1)
        scheduler.enqueue(Data([2]), from: .host, at: millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 500 * millisecond, generation: oldGeneration).isEmpty)
        XCTAssertEqual(scheduler.pendingBytes, 1)
        // The stale callback must not advance the clock to its supplied time.
        XCTAssertEqual(scheduler.takeDue(at: 3_010_000, generation: scheduler.generation).map(\.bytes), [Data([2])])
    }

    func testStopDropsBothDirectionsAndPermanentlyRejectsNewWork() throws {
        var scheduler = try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 50 * millisecond)
        scheduler.enqueue(Data([1]), from: .host, at: 0)
        scheduler.enqueue(Data([2]), from: .viewer, at: 0)
        scheduler.discardPending(stop: true)
        XCTAssertTrue(scheduler.stopped)
        XCTAssertEqual(scheduler.pendingBytes, 0)
        XCTAssertEqual(scheduler.counters(from: .host).discardedDatagrams, 1)
        XCTAssertEqual(scheduler.counters(from: .viewer).discardedDatagrams, 1)
        XCTAssertFalse(scheduler.enqueue(Data([3]), from: .host, at: 0))
        XCTAssertThrowsError(try scheduler.setBandwidth(8_000_000, from: .host, at: 0))
        XCTAssertTrue(scheduler.takeDue(at: 500 * millisecond, generation: scheduler.generation).isEmpty)
        XCTAssertNil(scheduler.nextDeadline)
    }

    func testInvalidConfigurationAndClockChangesDoNotCreateUnboundedOrUnmeteredWork() throws {
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 500_000_001))
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 0))
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0, maximumQueuedBytes: 4_194_305))
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0, maximumQueuedDatagrams: 4_097))
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0, maximumQueueAgeNanoseconds: 0))
        XCTAssertThrowsError(try StartupVideoDatagramScheduler(oneWayDelayNanoseconds: 0, maximumQueueAgeNanoseconds: 10_000_000_001))
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 0, hostToViewerBitsPerSecond: 800_000
        )
        scheduler.enqueue(Data(repeating: 1, count: 1_000), from: .host, at: millisecond)
        XCTAssertThrowsError(try scheduler.setBandwidth(nil, from: .host, at: 0))
        XCTAssertThrowsError(try scheduler.setBandwidth(0, from: .host, at: 2 * millisecond))
        XCTAssertFalse(scheduler.enqueue(Data([2]), from: .viewer, at: 0))
        XCTAssertEqual(scheduler.counters(from: .host).configuredBitsPerSecond, 800_000)
        XCTAssertEqual(scheduler.takeDue(at: 11 * millisecond, generation: 0).count, 1)
    }
}
#endif
