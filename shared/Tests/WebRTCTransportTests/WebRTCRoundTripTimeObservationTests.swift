import Foundation
@testable import WebRTCTransport
import XCTest

final class WebRTCRoundTripTimeObservationTests: XCTestCase {
    func testSelectedPairPublishesOnlyItsFingerprintAndCumulativeWatermark() throws {
        let snapshot = parsePair()
        let parsedMeasurement = try measurement(in: snapshot)

        XCTAssertEqual(
            parsedMeasurement.selectedCandidatePairFingerprint,
            "47d8bd46877831ccd61c1cfac962cd4143bc818c7d5fd0989de4f061ce60351e"
        )
        XCTAssertEqual(parsedMeasurement.totalRoundTripTimeSeconds, 0.15)
        XCTAssertEqual(parsedMeasurement.responsesReceived, 3)
        XCTAssertEqual(snapshot.currentRoundTripTime, 0.05)
        XCTAssertEqual(snapshot.collectionSequence, 37)

        let rawID = "CP-private-local_private-remote"
        let encoded = try JSONEncoder().encode(parsePair(id: rawID))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(rawID))
        XCTAssertNotEqual(
            try self.measurement(in: parsePair(id: rawID))
                .selectedCandidatePairFingerprint,
            parsedMeasurement.selectedCandidatePairFingerprint
        )
    }

    func testMissingNativeMetadataIsExplicitlyUnavailableNeverLegacyNil() {
        XCTAssertEqual(
            WebRTCStatisticsParser.parse(records: []).roundTripTimeObservation,
            .unavailable
        )
        for key in ["currentRoundTripTime", "totalRoundTripTime", "responsesReceived"] {
            var values = validValues
            values.removeValue(forKey: key)
            XCTAssertEqual(
                parsePair(values: values).roundTripTimeObservation,
                .unavailable,
                key
            )
        }
    }

    func testMalformedTimesAndCountersCannotCreateMeasurementEvidence() {
        let invalidTimes: [Any] = [
            NSNumber(value: true), NSNumber(value: -0.1),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            "0.05", NSNull(),
        ]
        let invalidCounters: [Any] = [
            NSNumber(value: true), NSNumber(value: -1), NSNumber(value: 1.5),
            NSNumber(value: Double.nan), NSNumber(value: Double.infinity),
            NSNumber(value: 18_446_744_073_709_551_616.0),
            "3", NSNull(),
        ]
        for (key, invalidValues) in [
            ("currentRoundTripTime", invalidTimes),
            ("totalRoundTripTime", invalidTimes),
            ("responsesReceived", invalidCounters),
        ] {
            for value in invalidValues {
                var values = validValues
                values[key] = value
                XCTAssertEqual(
                    parsePair(values: values).roundTripTimeObservation,
                    .unavailable,
                    "\(key): \(value)"
                )
            }
        }
        var inconsistent = validValues
        inconsistent["totalRoundTripTime"] = NSNumber(value: 0.01)
        XCTAssertEqual(
            parsePair(values: inconsistent).roundTripTimeObservation,
            .unavailable
        )
    }

    func testPiggybackCanAdvanceTotalWithoutAnyRegularResponse() throws {
        var values = validValues
        values["responsesReceived"] = NSNumber(value: 0)
        let first = try measurement(in: parsePair(values: values))
        values["totalRoundTripTime"] = NSNumber(value: 0.2)
        let second = try measurement(in: parsePair(values: values))

        XCTAssertEqual(first.responsesReceived, 0)
        XCTAssertEqual(second.responsesReceived, 0)
        XCTAssertEqual(
            first.selectedCandidatePairFingerprint,
            second.selectedCandidatePairFingerprint
        )
        XCTAssertGreaterThan(second.totalRoundTripTimeSeconds, first.totalRoundTripTimeSeconds)
    }

    func testExactNativeUInt64AndZeroTimeRemainRepresentable() throws {
        var values = validValues
        values["responsesReceived"] = NSNumber(value: UInt64.max)
        XCTAssertEqual(
            try measurement(in: parsePair(values: values)).responsesReceived,
            UInt64.max
        )
        values["responsesReceived"] = NSNumber(value: 0)
        values["currentRoundTripTime"] = NSNumber(value: 0)
        values["totalRoundTripTime"] = NSNumber(value: 0)
        XCTAssertEqual(
            try measurement(in: parsePair(values: values)).totalRoundTripTimeSeconds,
            0
        )
    }

    func testPairFingerprintRequiresNonemptyBoundedUTF8Identity() throws {
        for id in ["", String(repeating: "a", count: 513), String(repeating: "é", count: 257)] {
            XCTAssertEqual(parsePair(id: id).roundTripTimeObservation, .unavailable)
        }
        for id in [String(repeating: "a", count: 512), String(repeating: "é", count: 256)] {
            let fingerprint = try measurement(in: parsePair(id: id))
                .selectedCandidatePairFingerprint
            XCTAssertEqual(fingerprint.utf8.count, 64)
            XCTAssertTrue(fingerprint.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            })
        }
    }

    func testAmbiguousSelectedPairCannotPublishAnotherPairsWatermark() {
        let snapshot = WebRTCStatisticsParser.parse(records: [
            WebRTCStatisticsRecord(
                id: "transport-one", type: "transport",
                values: ["selectedCandidatePairId": "pair-one"]
            ),
            WebRTCStatisticsRecord(
                id: "transport-two", type: "transport",
                values: ["selectedCandidatePairId": "pair-two"]
            ),
            WebRTCStatisticsRecord(id: "pair-one", type: "candidate-pair", values: validValues),
            WebRTCStatisticsRecord(id: "pair-two", type: "candidate-pair", values: validValues),
        ])
        XCTAssertEqual(snapshot.roundTripTimeObservation, .unavailable)
    }

    func testSnapshotCodablePreservesObservationAndDecodesLegacyAbsence() throws {
        let native = parsePair()
        let unavailable = WebRTCStatisticsSnapshot(roundTripTimeObservation: .unavailable)
        let legacy = WebRTCStatisticsSnapshot(currentRoundTripTime: 0.05)
        for snapshot in [native, unavailable, legacy] {
            let data = try JSONEncoder().encode(snapshot)
            XCTAssertEqual(
                try JSONDecoder().decode(WebRTCStatisticsSnapshot.self, from: data),
                snapshot
            )
        }
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyObject["roundTripTimeObservation"])
        XCTAssertNil(
            try JSONDecoder().decode(WebRTCStatisticsSnapshot.self, from: legacyData)
                .roundTripTimeObservation
        )
    }

    func testNativeRouteRestorationPreservesObservationAndOtherSnapshotFields() throws {
        let route = WebRTCICERouteDiagnostics(kind: .direct)
        for observation in try copyObservations() {
            let original = copyFixture(observation: observation)
            let restored = original.restoringRouteIfNeeded(route)
            XCTAssertEqual(restored, copyFixture(observation: observation, route: route))
            XCTAssertEqual(original.restoringRouteIfNeeded(nil), original)
            XCTAssertEqual(
                restored.restoringRouteIfNeeded(WebRTCICERouteDiagnostics(kind: .relayed)),
                restored
            )
        }
    }

    func testNativeAudioReplacementAndComposedCopiesPreserveObservation() throws {
        let route = WebRTCICERouteDiagnostics(kind: .direct)
        let receivedAudio = WebRTCAudioStatistics(bytes: 900, packets: 90)
        for observation in try copyObservations() {
            let original = copyFixture(observation: observation)
            let replaced = original.replacingInboundAudio(with: receivedAudio)
            XCTAssertEqual(
                replaced,
                copyFixture(observation: observation, inboundAudio: receivedAudio)
            )
            XCTAssertEqual(
                original.replacingInboundAudio(with: nil),
                copyFixture(observation: observation, inboundAudio: nil)
            )
            XCTAssertEqual(
                original.restoringRouteIfNeeded(route)
                    .replacingInboundAudio(with: receivedAudio),
                copyFixture(observation: observation, route: route, inboundAudio: receivedAudio)
            )
            XCTAssertEqual(original, copyFixture(observation: observation))
        }
    }

    private func copyObservations() throws -> [WebRTCRoundTripTimeObservation?] {
        [.measurement(try measurement(in: parsePair())), .unavailable, nil]
    }

    private func copyFixture(
        observation: WebRTCRoundTripTimeObservation?,
        route: WebRTCICERouteDiagnostics? = nil,
        inboundAudio: WebRTCAudioStatistics? = WebRTCAudioStatistics(bytes: 300, packets: 30)
    ) -> WebRTCStatisticsSnapshot {
        WebRTCStatisticsSnapshot(
            collectedAt: Date(timeIntervalSinceReferenceDate: 123),
            collectionSequence: 37,
            route: route,
            currentRoundTripTime: 0.05,
            roundTripTimeObservation: observation,
            availableOutgoingBitrate: 1_500_000,
            jitter: 0.001,
            outboundVideo: WebRTCVideoStatistics(bytes: 400, packets: 40),
            inboundVideo: WebRTCVideoStatistics(bytes: 500, packets: 50),
            audioSource: WebRTCAudioStatistics(bytes: 100, packets: 10),
            outboundAudio: WebRTCAudioStatistics(bytes: 200, packets: 20),
            inboundAudio: inboundAudio,
            remoteInboundAudio: WebRTCAudioStatistics(bytes: 600, packets: 60)
        )
    }

    private var validValues: [String: Any] {
        [
            "state": "succeeded",
            "currentRoundTripTime": NSNumber(value: 0.05),
            "totalRoundTripTime": NSNumber(value: 0.15),
            "responsesReceived": NSNumber(value: 3),
        ]
    }

    private func parsePair(
        id: String = "pair",
        values: [String: Any]? = nil
    ) -> WebRTCStatisticsSnapshot {
        WebRTCStatisticsParser.parse(
            records: [
                WebRTCStatisticsRecord(
                    id: "transport", type: "transport",
                    values: ["selectedCandidatePairId": id]
                ),
                WebRTCStatisticsRecord(id: id, type: "candidate-pair", values: values ?? validValues),
            ],
            collectionSequence: 37
        )
    }

    private func measurement(
        in snapshot: WebRTCStatisticsSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> WebRTCRoundTripTimeMeasurement {
        let observation = try XCTUnwrap(snapshot.roundTripTimeObservation, file: file, line: line)
        guard case let .measurement(measurement) = observation else {
            XCTFail("Expected native measurement", file: file, line: line)
            throw NSError(domain: "WebRTCRoundTripTimeObservationTests", code: 1)
        }
        return measurement
    }
}
