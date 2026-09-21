#if os(macOS)
import Foundation
import XCTest

final class StartupVideoDatagramSchedulerTests: XCTestCase {
    private let millisecond: UInt64 = 1_000_000

    func testTrafficTimingRelayCollectionIsOptIn() async throws {
        let ordinary = try StartupVideoDatagramRelay()
        let measured: StartupVideoDatagramRelay
        do {
            measured = try StartupVideoDatagramRelay(collectTrafficTiming: true)
        } catch {
            await ordinary.stop()
            throw error
        }
        XCTAssertNil(ordinary.snapshot().trafficTiming)
        XCTAssertEqual(measured.snapshot().trafficTiming?.bindingEvents.count, 0)
        XCTAssertEqual(measured.snapshot().trafficTiming?.hostToViewer.forwardedDatagrams, 0)
        await ordinary.stop()
        await measured.stop()
        XCTAssertTrue(ordinary.snapshot().stopped)
        XCTAssertTrue(measured.snapshot().stopped)
    }

    func testTrafficTimingMeasuresBindingBehindMediaBurstVersusIdenticalBytesInReverseOrder() throws {
        func run(bindingFirst: Bool) throws -> StartupVideoDatagramTrafficMeasurements {
            var scheduler = try StartupVideoDatagramScheduler(
                oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 800_000)
            var packets = Array(repeating: trafficMediaPacket(), count: 13)
            packets.insert(trafficBindingPacket(), at: bindingFirst ? 0 : packets.count)
            for packet in packets { XCTAssertTrue(scheduler.enqueue(packet, from: .host, at: 0)) }
            var traffic = StartupVideoDatagramTrafficMeasurements()
            while let deadline = scheduler.nextDeadline {
                for packet in scheduler.takeDue(at: deadline, generation: scheduler.generation) {
                    traffic.recordSendResult(packet, sentByteCount: packet.bytes.count, at: deadline)
                }
            }
            return traffic
        }
        let burst = try run(bindingFirst: false)
        let reverse = try run(bindingFirst: true)
        XCTAssertEqual(burst.bindingEvents.count, 1)
        XCTAssertEqual(reverse.bindingEvents.count, 1)
        XCTAssertEqual(burst.bindingEvents.first?.modeledResidenceNanoseconds, 158_800_000)
        XCTAssertEqual(reverse.bindingEvents.first?.modeledResidenceNanoseconds, 2_800_000)
        XCTAssertEqual(burst.bindingEvents.first?.actualResidenceNanoseconds, 158_800_000)
        XCTAssertEqual(reverse.bindingEvents.first?.actualResidenceNanoseconds, 2_800_000)
        XCTAssertEqual(burst.bindingEvents.first?.callbackLatenessNanoseconds, 0)
        XCTAssertEqual(reverse.bindingEvents.first?.callbackLatenessNanoseconds, 0)
        for traffic in [burst, reverse] {
            XCTAssertEqual(traffic.hostToViewer.forwardedDatagrams, 14)
            XCTAssertEqual(traffic.hostToViewer.forwardedBytes, 15_680)
            XCTAssertEqual(traffic.hostToViewer.rtpV2ShapedDatagrams, 13)
            XCTAssertEqual(traffic.hostToViewer.rtpV2ShapedBytes, 15_600)
            XCTAssertEqual(traffic.hostToViewer.otherBytes, 80)
            XCTAssertEqual(traffic.hostToViewer.bindingRequests, 1)
            XCTAssertEqual(traffic.viewerToHost.forwardedBytes, 0)
        }
    }

    func testTrafficTimingSeparatesCallbackLatenessFromModeledResidence() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, hostToViewerBitsPerSecond: 800_000)
        scheduler.enqueue(trafficBindingPacket(), from: .host, at: 0)
        let packet = try XCTUnwrap(scheduler.takeDue(at: 12_800_000, generation: 0).first)
        var traffic = StartupVideoDatagramTrafficMeasurements()
        traffic.recordSendResult(packet, sentByteCount: 80, at: 12_800_000)
        let event = try XCTUnwrap(traffic.bindingEvents.first)
        XCTAssertEqual(event.receivedAtNanoseconds, 0)
        XCTAssertEqual(event.deliveryDeadlineNanoseconds, 2_800_000)
        XCTAssertEqual(event.sentAtNanoseconds, 12_800_000)
        XCTAssertEqual(event.modeledResidenceNanoseconds, 2_800_000)
        XCTAssertEqual(event.callbackLatenessNanoseconds, 10_000_000)
        XCTAssertEqual(event.actualResidenceNanoseconds, 12_800_000)
        XCTAssertEqual(traffic.hostToViewer.maximumBindingCallbackLatenessNanoseconds, 10_000_000)
    }

    func testTrafficTimingValidatesBindingHeadersAndKeepsOnlyScalarClassifications() throws {
        typealias Traffic = StartupVideoDatagramTrafficMeasurements
        for (type, expected) in [(UInt16(0x0001), Traffic.BindingClass.request),
                                 (0x0011, .indication), (0x0101, .successResponse), (0x0111, .errorResponse)] {
            XCTAssertEqual(Traffic.bindingClass(in: trafficBindingPacket(type: type)), expected)
        }
        let valid = trafficBindingPacket()
        for count in 0..<20 { XCTAssertNil(Traffic.bindingClass(in: Data(valid.prefix(count)))) }
        for (index, value) in [(0, UInt8(0xc0)), (4, 0), (2, 1), (3, 59)] {
            var invalid = valid
            invalid[index] = value
            XCTAssertNil(Traffic.bindingClass(in: invalid))
        }
        XCTAssertNil(Traffic.bindingClass(in: Data(valid.dropLast())))
        XCTAssertNil(Traffic.bindingClass(in: valid + Data([0])))
        XCTAssertNil(Traffic.bindingClass(in: trafficBindingPacket(type: 0x0003)))
        var traffic = Traffic()
        traffic.recordSendResult(trafficDatagram(valid, from: .host), sentByteCount: 80, at: 20)
        traffic.recordSendResult(trafficDatagram(trafficBindingPacket(type: 0x0101), from: .viewer),
                                 sentByteCount: 80, at: 30)
        XCTAssertEqual(traffic.hostToViewer.bindingRequests, 1)
        XCTAssertEqual(traffic.hostToViewer.bindingSuccessResponses, 0)
        XCTAssertEqual(traffic.viewerToHost.bindingSuccessResponses, 1)
        XCTAssertEqual(traffic.bindingEvents.map(\.direction), ["hostToViewer", "viewerToHost"])
        let encoded = try JSONEncoder().encode(traffic)
        let decoded = try JSONDecoder().decode(Traffic.self, from: encoded)
        XCTAssertEqual(decoded.bindingEvents.count, 2)
        XCTAssertEqual(decoded.hostToViewer.forwardedBytes, 80)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let event = try XCTUnwrap((object["bindingEvents"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(event.keys), Set([
            "direction", "bindingClass", "byteCount", "receivedAtNanoseconds",
            "deliveryDeadlineNanoseconds", "sentAtNanoseconds", "modeledResidenceNanoseconds",
            "callbackLatenessNanoseconds", "actualResidenceNanoseconds",
        ]))
    }

    func testTrafficTimingRTPClassificationIsOnlyPublicV2HeaderShape() {
        typealias Traffic = StartupVideoDatagramTrafficMeasurements
        var media = trafficMediaPacket()
        XCTAssertTrue(Traffic.isRTPV2Shaped(media))
        media[0] = 0xa0 // Padding is encrypted; never inspect its value or claim padding bytes.
        media[media.count - 1] = 0xff
        XCTAssertTrue(Traffic.isRTPV2Shaped(media))
        media[0] = 0x40
        XCTAssertFalse(Traffic.isRTPV2Shaped(media))
        media[0] = 0x8f
        XCTAssertFalse(Traffic.isRTPV2Shaped(Data(media.prefix(12))))
        XCTAssertFalse(Traffic.isRTPV2Shaped(Data(media.prefix(11))))
        XCTAssertFalse(Traffic.isRTPV2Shaped(trafficBindingPacket()))
    }

    func testTrafficTimingIsBoundedAndCountersContinueAfterEventSaturation() {
        var traffic = StartupVideoDatagramTrafficMeasurements()
        for index in 0..<300 {
            traffic.recordSendResult(trafficDatagram(trafficBindingPacket()),
                                     sentByteCount: 80, at: UInt64(20 + index))
        }
        XCTAssertEqual(traffic.bindingEvents.count, 256)
        XCTAssertEqual(traffic.omittedBindingEvents, 44)
        XCTAssertEqual(traffic.bindingEvents.first?.sentAtNanoseconds, 20)
        XCTAssertEqual(traffic.bindingEvents.last?.sentAtNanoseconds, 275)
        XCTAssertEqual(traffic.hostToViewer.forwardedDatagrams, 300)
        XCTAssertEqual(traffic.hostToViewer.bindingRequests, 300)
        XCTAssertEqual(traffic.hostToViewer.forwardedBytes, 24_000)
        XCTAssertEqual(traffic.hostToViewer.maximumBindingActualResidenceNanoseconds, 309)
        XCTAssertFalse(traffic.counterSaturated)
        var value = UInt64.max - 1
        var saturated = false
        StartupVideoDatagramTrafficMeasurements.increment(&value, saturated: &saturated)
        XCTAssertEqual(value, UInt64.max)
        XCTAssertFalse(saturated)
        StartupVideoDatagramTrafficMeasurements.increment(&value, saturated: &saturated)
        XCTAssertEqual(value, UInt64.max)
        XCTAssertTrue(saturated)
        StartupVideoDatagramTrafficMeasurements.increment(&value, by: 0, saturated: &saturated)
        XCTAssertTrue(saturated)
    }

    func testTrafficTimingRejectsFailedSendsAndMalformedTimesWithoutInventingDelivery() {
        var traffic = StartupVideoDatagramTrafficMeasurements()
        let packet = trafficDatagram(trafficBindingPacket())
        traffic.recordSendResult(packet, sentByteCount: -1, at: 30) // sendto/EAGAIN
        traffic.recordSendResult(packet, sentByteCount: 79, at: 30)
        XCTAssertEqual(traffic.unsuccessfulSendAttempts, 2)
        XCTAssertEqual(traffic.hostToViewer.forwardedDatagrams, 0)
        XCTAssertTrue(traffic.bindingEvents.isEmpty)
        traffic.recordSendResult(packet, sentByteCount: 80, at: 19)
        traffic.recordSendResult(.init(sequence: 0, from: .host, bytes: packet.bytes,
                                       receivedAt: 21, deliveryDeadline: 20), sentByteCount: 80, at: 30)
        XCTAssertEqual(traffic.invalidTimingDatagrams, 2)
        XCTAssertEqual(traffic.hostToViewer.forwardedDatagrams, 2)
        XCTAssertEqual(traffic.hostToViewer.bindingRequests, 2)
        XCTAssertTrue(traffic.bindingEvents.isEmpty)
        XCTAssertEqual(traffic.hostToViewer.maximumBindingActualResidenceNanoseconds, 0)
    }

    func testTrafficTimingExcludesOverflowExpiryBlackoutAndBackpressurePackets() throws {
        var scheduler = try StartupVideoDatagramScheduler(
            oneWayDelayNanoseconds: 2 * millisecond, maximumQueuedBytes: 80,
            maximumQueueAgeNanoseconds: 5 * millisecond)
        var traffic = StartupVideoDatagramTrafficMeasurements()
        scheduler.enqueue(trafficBindingPacket(), from: .host, at: 0)
        XCTAssertFalse(scheduler.enqueue(trafficBindingPacket(), from: .host, at: 0))
        for packet in scheduler.takeDue(at: 5 * millisecond, generation: 0) {
            traffic.recordSendResult(packet, sentByteCount: packet.bytes.count, at: 5 * millisecond)
        }
        XCTAssertEqual(scheduler.counters(from: .host).overflowDatagrams, 1)
        XCTAssertEqual(scheduler.counters(from: .host).expiredDatagrams, 1)
        scheduler.enqueue(trafficBindingPacket(), from: .host, at: 6 * millisecond)
        let oldGeneration = scheduler.generation
        scheduler.discardPending()
        XCTAssertTrue(scheduler.takeDue(at: 8 * millisecond, generation: oldGeneration).isEmpty)
        scheduler.enqueue(trafficBindingPacket(), from: .host, at: 8 * millisecond)
        let packet = try XCTUnwrap(scheduler.takeDue(at: 10 * millisecond,
                                                    generation: scheduler.generation).first)
        scheduler.recordBackpressure(from: packet.from)
        traffic.recordSendResult(packet, sentByteCount: -1, at: 10 * millisecond)
        XCTAssertTrue(scheduler.takeDue(at: 11 * millisecond, generation: scheduler.generation).isEmpty)
        XCTAssertEqual(scheduler.counters(from: .host).backpressureDatagrams, 1)
        XCTAssertEqual(traffic.hostToViewer.forwardedDatagrams, 0)
        XCTAssertEqual(traffic.unsuccessfulSendAttempts, 1)
        XCTAssertTrue(traffic.bindingEvents.isEmpty)
    }

    private func trafficBindingPacket(type: UInt16 = 0x0001) -> Data {
        var bytes = Data(repeating: 0, count: 80)
        bytes[0] = UInt8(type >> 8)
        bytes[1] = UInt8(type & 0xff)
        bytes[3] = 60
        bytes[4] = 0x21
        bytes[5] = 0x12
        bytes[6] = 0xa4
        bytes[7] = 0x42
        return bytes
    }

    private func trafficMediaPacket() -> Data {
        var bytes = Data(repeating: 0, count: 1_200)
        bytes[0] = 0x80
        bytes[1] = 96
        return bytes
    }

    private func trafficDatagram(
        _ bytes: Data, from direction: StartupVideoDatagramScheduler.Direction = .host
    ) -> StartupVideoDatagramScheduler.Datagram {
        .init(sequence: 0, from: direction, bytes: bytes, receivedAt: 10, deliveryDeadline: 20)
    }

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
