import Foundation
@testable import WebRTCTransport
import XCTest

final class WebRTCSelectedCandidatePairOutboundDiagnosticsTests: XCTestCase {
    func testSelectedPairPayloadBytesAndFingerprintAreAtomicAndOrderIndependent() throws {
        let pairID = "CP-private-local_private-remote"
        let records = [
            WebRTCStatisticsRecord(
                id: "transport-one",
                type: "transport",
                values: ["selectedCandidatePairId": pairID]
            ),
            WebRTCStatisticsRecord(
                id: "transport-two",
                type: "transport",
                values: ["selectedCandidatePairId": pairID]
            ),
            WebRTCStatisticsRecord(
                id: pairID,
                type: "candidate-pair",
                values: [
                    "state": "succeeded",
                    "bytesSent": NSNumber(value: UInt64.max),
                    "availableOutgoingBitrate": NSNumber(value: 1_500_000),
                    "currentRoundTripTime": NSNumber(value: 0.05),
                    "totalRoundTripTime": NSNumber(value: 0.15),
                    "responsesReceived": NSNumber(value: 3),
                ]
            ),
        ]

        for orderedRecords in [records, Array(records.reversed())] {
            let snapshot = WebRTCStatisticsParser.parse(records: orderedRecords)
            let outbound = try XCTUnwrap(snapshot.selectedCandidatePairOutbound)
            XCTAssertEqual(outbound.payloadBytesSent, UInt64.max)
            XCTAssertEqual(outbound.availableOutgoingBitrateBps, 1_500_000)
            XCTAssertEqual(snapshot.availableOutgoingBitrate, 1_500_000)

            guard case let .measurement(roundTrip)? = snapshot.roundTripTimeObservation else {
                return XCTFail("Expected matching RTT measurement")
            }
            XCTAssertEqual(
                outbound.selectedCandidatePairFingerprint,
                roundTrip.selectedCandidatePairFingerprint
            )
        }
    }

    func testMissingOrMalformedPayloadCounterCannotPublishPartialPairDiagnostics() {
        let invalidCounters: [Any?] = [
            nil,
            NSNumber(value: true),
            NSNumber(value: -1),
            NSNumber(value: 1.5),
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity),
            NSNumber(value: 9_007_199_254_740_992.0),
            "123",
            NSNull(),
        ]

        for invalidCounter in invalidCounters {
            var values: [String: Any] = [
                "state": "succeeded",
                "availableOutgoingBitrate": NSNumber(value: 1_500_000),
            ]
            if let invalidCounter {
                values["bytesSent"] = invalidCounter
            }
            let snapshot = parsePair(id: "pair", values: values)
            XCTAssertNil(
                snapshot.selectedCandidatePairOutbound,
                "Unexpectedly accepted \(String(describing: invalidCounter))"
            )
        }
    }

    func testMissingOrMalformedBandwidthCannotPublishPartialPairDiagnostics() {
        let invalidBandwidth: [Any?] = [
            nil,
            NSNumber(value: true),
            NSNumber(value: -1),
            NSNumber(value: Double.nan),
            NSNumber(value: Double.infinity),
            "1500000",
            NSNull(),
        ]

        for invalidValue in invalidBandwidth {
            var values: [String: Any] = [
                "state": "succeeded",
                "bytesSent": NSNumber(value: 123),
            ]
            if let invalidValue {
                values["availableOutgoingBitrate"] = invalidValue
            }
            XCTAssertNil(
                parsePair(id: "pair", values: values).selectedCandidatePairOutbound,
                "Unexpectedly accepted \(String(describing: invalidValue))"
            )
        }
    }

    func testLegacyTopLevelBandwidthRemainsAvailableWithoutAtomicPayloadCounter() {
        let snapshot = parsePair(
            id: "pair",
            values: [
                "state": "succeeded",
                "availableOutgoingBitrate": NSNumber(value: 1_500_000),
            ]
        )

        XCTAssertNil(snapshot.selectedCandidatePairOutbound)
        XCTAssertEqual(snapshot.availableOutgoingBitrate, 1_500_000)
    }

    func testPairIdentityMustBeNonemptyAndBoundedBeforeAnyDiagnosticsPublish() throws {
        let tooLong = String(repeating: "a", count: 513)
        let bounded = String(repeating: "a", count: 512)

        XCTAssertNil(
            parsePair(id: "", values: validPairValues).selectedCandidatePairOutbound
        )
        XCTAssertNil(
            parsePair(id: tooLong, values: validPairValues).selectedCandidatePairOutbound
        )
        XCTAssertNotNil(
            parsePair(id: bounded, values: validPairValues).selectedCandidatePairOutbound
        )
    }

    func testSnapshotCopiesAndCodableRoundTripPreserveAtomicPairDiagnostics() throws {
        let pair = WebRTCSelectedCandidatePairOutboundDiagnostics(
            selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
            payloadBytesSent: 12_345,
            availableOutgoingBitrateBps: 1_500_000
        )
        let original = WebRTCStatisticsSnapshot(
            collectedAt: Date(timeIntervalSinceReferenceDate: 123),
            collectionSequence: 37,
            selectedCandidatePairOutbound: pair,
            inboundAudio: WebRTCAudioStatistics(bytes: 100, packets: 10)
        )

        XCTAssertEqual(
            original.restoringRouteIfNeeded(WebRTCICERouteDiagnostics(kind: .direct))
                .selectedCandidatePairOutbound,
            pair
        )
        XCTAssertEqual(
            original.replacingInboundAudio(
                with: WebRTCAudioStatistics(bytes: 200, packets: 20)
            ).selectedCandidatePairOutbound,
            pair
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WebRTCStatisticsSnapshot.self,
                from: JSONEncoder().encode(original)
            ),
            original
        )
    }

    func testLegacyAndSyntheticSnapshotsDefaultPairDiagnosticsToNil() throws {
        XCTAssertNil(WebRTCStatisticsSnapshot().selectedCandidatePairOutbound)

        let legacyData = try JSONSerialization.data(
            withJSONObject: ["collectedAt": 0]
        )
        XCTAssertNil(
            try JSONDecoder().decode(WebRTCStatisticsSnapshot.self, from: legacyData)
                .selectedCandidatePairOutbound
        )
    }

    private var validPairValues: [String: Any] {
        [
            "state": "succeeded",
            "bytesSent": NSNumber(value: 123),
            "availableOutgoingBitrate": NSNumber(value: 1_500_000),
        ]
    }

    private func parsePair(
        id: String,
        values: [String: Any]
    ) -> WebRTCStatisticsSnapshot {
        WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport",
                type: "transport",
                values: ["selectedCandidatePairId": id]
            ),
            WebRTCStatisticsRecord(
                id: id,
                type: "candidate-pair",
                values: values
            ),
        ])
    }
}
