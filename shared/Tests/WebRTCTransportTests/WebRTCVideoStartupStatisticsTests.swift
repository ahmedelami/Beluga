import Foundation
@testable import WebRTCTransport
import XCTest

final class WebRTCVideoStartupStatisticsTests: XCTestCase {
    func testParsesOptionalEncoderDiagnosticsWithoutReplacingExistingEvidence() throws {
        let snapshot = WebRTCStatisticsParser.parse(
            records: [record(values: populatedValues)],
            collectionSequence: 73
        )
        let video = try XCTUnwrap(snapshot.outboundVideo)

        XCTAssertEqual(snapshot.collectionSequence, 73)
        XCTAssertNil(snapshot.route)
        XCTAssertNil(snapshot.availableOutgoingBitrate)
        XCTAssertEqual(video.bytes, 240_000)
        XCTAssertEqual(video.packets, 200)
        XCTAssertEqual(video.framesEncodedOrDecoded, 12)
        XCTAssertEqual(video.totalPacketSendDelay, 1.25)
        XCTAssertEqual(video.keyFramesEncoded, 2)
        XCTAssertEqual(video.totalEncodeTime, 0.072)
        XCTAssertEqual(video.hugeFramesSent, 1)
        XCTAssertEqual(video.qpSum, 192)
        XCTAssertEqual(video.nackCount, 3)
        XCTAssertEqual(video.pliCount, 4)
        XCTAssertEqual(video.qualityLimitationReason, .bandwidth)
        XCTAssertEqual(video.targetBitrate, 3_500_000)
    }

    func testAbsentOptionalFieldsAndLegacyJSONRemainUnknown() throws {
        let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
            record(values: ["kind": "video", "packetsSent": NSNumber(value: 5)]),
        ]).outboundVideo)
        XCTAssertEqual(video.packets, 5)
        assertStartupFieldsAbsent(video)
        assertStartupFieldsAbsent(WebRTCVideoStatistics())

        let legacy = try JSONDecoder().decode(
            WebRTCVideoStatistics.self,
            from: Data(#"{"bytes":100,"packets":5,"framesEncodedOrDecoded":2}"#.utf8)
        )
        XCTAssertEqual(legacy.bytes, 100)
        XCTAssertEqual(legacy.framesEncodedOrDecoded, 2)
        assertStartupFieldsAbsent(legacy)
    }

    func testOptionalEncoderDiagnosticsRoundTripWithoutChangingUnits() throws {
        let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
            record(values: populatedValues),
        ]).outboundVideo)
        let roundTrip = try JSONDecoder().decode(
            WebRTCVideoStatistics.self,
            from: JSONEncoder().encode(video)
        )
        XCTAssertEqual(roundTrip, video)
        XCTAssertEqual(roundTrip.totalEncodeTime, 0.072)
        XCTAssertEqual(roundTrip.targetBitrate, 3_500_000)
    }

    func testCounterDiagnosticsRejectMalformedValuesIndependently() throws {
        let counters: [(String, KeyPath<WebRTCVideoStatistics, UInt64?>)] = [
            ("keyFramesEncoded", \.keyFramesEncoded),
            ("hugeFramesSent", \.hugeFramesSent),
            ("qpSum", \.qpSum),
            ("nackCount", \.nackCount),
            ("pliCount", \.pliCount),
        ]
        let malformed: [Any] = [
            NSNull(), "12", NSNumber(value: true), NSNumber(value: -1),
            NSNumber(value: 1.5), NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity),
            NSNumber(value: UInt64.max), NSNumber(value: 9_007_199_254_740_992.0),
        ]
        for (key, path) in counters {
            for badValue in malformed {
                var values = populatedValues
                values[key] = badValue
                let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                    record(values: values),
                ]).outboundVideo)
                XCTAssertNil(video[keyPath: path], "\(key): \(badValue)")
                XCTAssertEqual(video.totalEncodeTime, 0.072)
                XCTAssertEqual(video.qualityLimitationReason, .bandwidth)
                XCTAssertEqual(video.packets, 200)
            }
            for zero in [NSNumber(value: UInt64(0)), NSNumber(value: 0.0)] {
                var values = populatedValues
                values[key] = zero
                let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                    record(values: values),
                ]).outboundVideo)
                XCTAssertEqual(video[keyPath: path], 0, key)
            }
        }
    }

    func testEncoderDoubleDiagnosticsRequireBoundedNonnegativeFiniteNumbers() throws {
        let doubles: [(String, KeyPath<WebRTCVideoStatistics, Double?>)] = [
            ("totalEncodeTime", \.totalEncodeTime),
            ("targetBitrate", \.targetBitrate),
        ]
        let malformed: [Any] = [
            NSNull(), "12", NSNumber(value: true), NSNumber(value: -0.001),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: -Double.infinity), NSNumber(value: 1_000_000_001.0),
        ]
        for (key, path) in doubles {
            for badValue in malformed {
                var values = populatedValues
                values[key] = badValue
                let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                    record(values: values),
                ]).outboundVideo)
                XCTAssertNil(video[keyPath: path], "\(key): \(badValue)")
                XCTAssertEqual(video.keyFramesEncoded, 2)
                XCTAssertEqual(video.packets, 200)
            }
            for value in [0.0, 0.125, 1_000_000_000.0] {
                var values = populatedValues
                values[key] = NSNumber(value: value)
                let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                    record(values: values),
                ]).outboundVideo)
                XCTAssertEqual(video[keyPath: path], value, key)
            }
        }
    }

    func testQualityReasonAcceptsOnlyExactBoundedNativeCategories() throws {
        for reason in [WebRTCVideoQualityLimitationReason.none, .cpu, .bandwidth, .other] {
            var values = populatedValues
            values["qualityLimitationReason"] = reason.rawValue
            let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                record(values: values),
            ]).outboundVideo)
            XCTAssertEqual(video.qualityLimitationReason, reason)
        }
        let malformedReasons: [Any] = [
            NSNull(), NSNumber(value: 1), "", "CPU", " bandwidth", "unknown",
            String(repeating: "private-native-text", count: 1_000),
        ]
        for badValue in malformedReasons {
            var values = populatedValues
            values["qualityLimitationReason"] = badValue
            let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: [
                record(values: values),
            ]).outboundVideo)
            XCTAssertNil(video.qualityLimitationReason)
            XCTAssertEqual(video.keyFramesEncoded, 2)
        }
    }

    func testInboundKeepsItsOwnQPAndFeedbackWithoutImportingEncoderOnlyFields() throws {
        var inbound = populatedValues
        inbound["bytesReceived"] = NSNumber(value: 120_000)
        inbound["packetsReceived"] = NSNumber(value: 100)
        inbound["framesDecoded"] = NSNumber(value: 6)
        inbound["qpSum"] = NSNumber(value: 84)
        inbound["nackCount"] = NSNumber(value: 8)
        inbound["pliCount"] = NSNumber(value: 9)
        let snapshot = WebRTCStatisticsParser.parse(records: [
            record(values: populatedValues),
            record(id: "screen-in", type: "inbound-rtp", values: inbound),
        ])
        let video = try XCTUnwrap(snapshot.inboundVideo)
        XCTAssertEqual(video.bytes, 120_000)
        XCTAssertEqual(video.packets, 100)
        XCTAssertEqual(video.framesEncodedOrDecoded, 6)
        XCTAssertNil(video.totalPacketSendDelay)
        XCTAssertNil(video.keyFramesEncoded)
        XCTAssertNil(video.totalEncodeTime)
        XCTAssertNil(video.hugeFramesSent)
        XCTAssertNil(video.qualityLimitationReason)
        XCTAssertNil(video.targetBitrate)
        XCTAssertEqual(video.qpSum, 84)
        XCTAssertEqual(video.nackCount, 8)
        XCTAssertEqual(video.pliCount, 9)
        XCTAssertEqual(snapshot.outboundVideo?.qpSum, 192)
        XCTAssertEqual(snapshot.outboundVideo?.nackCount, 3)
        XCTAssertEqual(snapshot.outboundVideo?.pliCount, 4)
    }

    func testEncoderDiagnosticsNeverSelectRepairOrAnAmbiguousSecondVideoStream() throws {
        var primary = populatedValues
        primary["codecId"] = "h264-codec"
        var repair = populatedValues
        repair["codecId"] = "rtx-codec"
        repair["keyFramesEncoded"] = NSNumber(value: 999)
        repair["qualityLimitationReason"] = "cpu"
        let records = [
            record(values: primary),
            record(id: "screen-rtx", values: repair),
            record(id: "h264-codec", type: "codec", values: ["mimeType": "video/H264"]),
            record(id: "rtx-codec", type: "codec", values: ["mimeType": "video/rtx"]),
        ]
        for ordered in [records, Array(records.reversed())] {
            let video = try XCTUnwrap(WebRTCStatisticsParser.parse(records: ordered).outboundVideo)
            XCTAssertEqual(video.keyFramesEncoded, 2)
            XCTAssertEqual(video.qualityLimitationReason, .bandwidth)

            let ambiguous = ordered + [record(id: "second-video", values: populatedValues)]
            XCTAssertNil(WebRTCStatisticsParser.parse(records: ambiguous).outboundVideo)
        }
    }

    private var populatedValues: [String: Any] {
        [
            "kind": "video",
            "bytesSent": NSNumber(value: 240_000),
            "packetsSent": NSNumber(value: 200),
            "framesEncoded": NSNumber(value: 12),
            "totalPacketSendDelay": NSNumber(value: 1.25),
            "keyFramesEncoded": NSNumber(value: 2),
            "totalEncodeTime": NSNumber(value: 0.072),
            "hugeFramesSent": NSNumber(value: 1),
            "qpSum": NSNumber(value: 192),
            "nackCount": NSNumber(value: 3),
            "pliCount": NSNumber(value: 4),
            "qualityLimitationReason": "bandwidth",
            "targetBitrate": NSNumber(value: 3_500_000),
        ]
    }

    private func record(
        id: String = "screen-out",
        type: String = "outbound-rtp",
        values: [String: Any]
    ) -> WebRTCStatisticsRecord {
        WebRTCStatisticsRecord(id: id, type: type, values: values)
    }

    private func assertStartupFieldsAbsent(
        _ video: WebRTCVideoStatistics,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(video.keyFramesEncoded, file: file, line: line)
        XCTAssertNil(video.totalEncodeTime, file: file, line: line)
        XCTAssertNil(video.hugeFramesSent, file: file, line: line)
        XCTAssertNil(video.qpSum, file: file, line: line)
        XCTAssertNil(video.nackCount, file: file, line: line)
        XCTAssertNil(video.pliCount, file: file, line: line)
        XCTAssertNil(video.qualityLimitationReason, file: file, line: line)
        XCTAssertNil(video.targetBitrate, file: file, line: line)
    }
}
