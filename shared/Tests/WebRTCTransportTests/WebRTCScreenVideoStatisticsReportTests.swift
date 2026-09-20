import Foundation
@testable import WebRTCTransport
import XCTest

final class WebRTCScreenVideoStatisticsReportTests: XCTestCase {
    func testCachedReportIdentityIsIndependentOfRequestSequenceAndCallbackDate() {
        let timestamp = 1_789_000_000_123_456.0
        let first = WebRTCScreenVideoStatisticsReport(
            snapshot: WebRTCStatisticsSnapshot(
                collectedAt: Date(timeIntervalSince1970: 100),
                collectionSequence: 41
            ),
            nativeReportTimestampMicroseconds: timestamp
        )
        let second = WebRTCScreenVideoStatisticsReport(
            snapshot: WebRTCStatisticsSnapshot(
                collectedAt: Date(timeIntervalSince1970: 101),
                collectionSequence: 42
            ),
            nativeReportTimestampMicroseconds: timestamp
        )

        XCTAssertNotEqual(
            first.snapshot.collectionSequence, second.snapshot.collectionSequence
        )
        XCTAssertNotEqual(first.snapshot.collectedAt, second.snapshot.collectedAt)
        XCTAssertEqual(first.nativeSnapshot, first.snapshot)
        XCTAssertEqual(second.nativeSnapshot, second.snapshot)
        XCTAssertEqual(
            first.nativeReportTimestampMicroseconds,
            second.nativeReportTimestampMicroseconds
        )
    }

    func testRouteRestorationPreservesTheNativeIdentityAndSnapshotFields() {
        let snapshot = populatedSnapshot(route: nil)
        let report = WebRTCScreenVideoStatisticsReport(
            snapshot: snapshot,
            nativeReportTimestampMicroseconds: 1_789_000_000_123_456
        )
        let route = WebRTCICERouteDiagnostics(kind: .direct)
        let restored = report.restoringRouteIfNeeded(route)

        XCTAssertEqual(restored.snapshot, snapshot.restoringRouteIfNeeded(route))
        XCTAssertEqual(restored.snapshot.route, route)
        XCTAssertEqual(restored.nativeSnapshot, snapshot)
        XCTAssertNil(restored.nativeSnapshot.route)
        XCTAssertEqual(
            restored.nativeReportTimestampMicroseconds,
            report.nativeReportTimestampMicroseconds
        )
    }

    func testRepeatedDiagnosticCopiesNeverPromoteFallbackRouteToNativeEvidence() {
        let native = populatedSnapshot(route: nil)
        var report = WebRTCScreenVideoStatisticsReport(
            snapshot: native,
            nativeReportTimestampMicroseconds: 7_000_002
        )
        let fallback = WebRTCICERouteDiagnostics(
            kind: .direct,
            local: WebRTCCandidateDiagnostics(type: .host, transport: "udp"),
            remote: WebRTCCandidateDiagnostics(type: .host, transport: "udp")
        )
        let expectedDiagnostic = native.restoringRouteIfNeeded(fallback)

        for route in [fallback, nil, WebRTCICERouteDiagnostics(kind: .relayed), fallback] {
            report = report.restoringRouteIfNeeded(route)

            XCTAssertEqual(report.nativeSnapshot, native)
            XCTAssertNil(report.nativeSnapshot.route)
            XCTAssertEqual(report.snapshot, expectedDiagnostic)
            XCTAssertEqual(report.nativeReportTimestampMicroseconds, 7_000_002)
        }
    }

    func testExistingOrUnavailableRouteDoesNotReplaceTheReportIdentity() {
        let route = WebRTCICERouteDiagnostics(
            kind: .direct,
            local: WebRTCCandidateDiagnostics(type: .host, transport: "udp", networkType: "wifi"),
            remote: WebRTCCandidateDiagnostics(type: .host, transport: "udp", networkType: "ethernet")
        )
        let native = populatedSnapshot(route: route)
        var report = WebRTCScreenVideoStatisticsReport(
            snapshot: native,
            nativeReportTimestampMicroseconds: 7_000_001
        )

        for replacement in [nil, WebRTCICERouteDiagnostics(kind: .direct),
                            WebRTCICERouteDiagnostics(kind: .relayed), nil] {
            let restored = report.restoringRouteIfNeeded(replacement)
            XCTAssertEqual(restored.snapshot, native)
            XCTAssertEqual(restored.nativeSnapshot, native)
            XCTAssertEqual(restored.nativeSnapshot.route?.local?.networkType, "wifi")
            XCTAssertEqual(restored.nativeSnapshot.route?.remote?.networkType, "ethernet")
            XCTAssertEqual(
                restored.nativeReportTimestampMicroseconds,
                report.nativeReportTimestampMicroseconds
            )
            report = restored
        }
    }

    func testCopyDoesNotSanitizeInvalidNativeValuesIntoFreshEvidence() {
        for timestamp in [Double.nan, .infinity, -.infinity, -1, 0] {
            let report = WebRTCScreenVideoStatisticsReport(
                snapshot: WebRTCStatisticsSnapshot(collectionSequence: 53),
                nativeReportTimestampMicroseconds: timestamp
            )
            let restored = report.restoringRouteIfNeeded(
                WebRTCICERouteDiagnostics(kind: .direct)
            )

            XCTAssertEqual(
                restored.nativeReportTimestampMicroseconds.bitPattern,
                timestamp.bitPattern
            )
            XCTAssertEqual(restored.nativeSnapshot, report.nativeSnapshot)
            XCTAssertNil(restored.nativeSnapshot.route)
        }
    }

    private func populatedSnapshot(route: WebRTCICERouteDiagnostics?) -> WebRTCStatisticsSnapshot {
        WebRTCStatisticsSnapshot(
            collectedAt: Date(timeIntervalSince1970: 123),
            collectionSequence: 51,
            route: route,
            currentRoundTripTime: 0.004,
            roundTripTimeObservation: .measurement(WebRTCRoundTripTimeMeasurement(
                selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
                totalRoundTripTimeSeconds: 0.12,
                responsesReceived: 30
            )),
            availableOutgoingBitrate: 1_800_000,
            jitter: 0.001,
            outboundVideo: videoStatistics(seed: 1),
            inboundVideo: videoStatistics(seed: 2),
            audioSource: audioStatistics(seed: 3),
            outboundAudio: audioStatistics(seed: 4),
            inboundAudio: audioStatistics(seed: 5),
            remoteInboundAudio: audioStatistics(seed: 6)
        )
    }

    private func videoStatistics(seed: UInt64) -> WebRTCVideoStatistics {
        WebRTCVideoStatistics(
            bytes: seed * 10_000,
            packets: seed * 100,
            packetsLost: Int64(seed),
            totalPacketSendDelay: Double(seed) * 0.002,
            framesPerSecond: Double(seed) * 5,
            frameWidth: Int(seed) * 540,
            frameHeight: Int(seed) * 960,
            framesEncodedOrDecoded: seed * 30
        )
    }

    private func audioStatistics(seed: UInt64) -> WebRTCAudioStatistics {
        WebRTCAudioStatistics(
            bytes: seed * 1_000,
            packets: seed * 10,
            packetsLost: Int64(seed),
            packetsDiscarded: seed + 1,
            jitter: Double(seed) * 0.001,
            jitterBufferDelay: Double(seed) * 0.1,
            jitterBufferEmittedCount: seed * 20,
            jitterBufferTargetDelay: Double(seed) * 0.2,
            jitterBufferMinimumDelay: Double(seed) * 0.01,
            totalSamplesReceived: seed * 48_000,
            concealedSamples: seed + 2,
            silentConcealedSamples: seed + 3,
            concealmentEvents: seed + 4,
            insertedSamplesForDeceleration: seed + 5,
            removedSamplesForAcceleration: seed + 6,
            totalAudioEnergy: Double(seed) * 0.3,
            totalSamplesDuration: Double(seed),
            audioLevel: Double(seed) * 0.04,
            totalPacketSendDelay: Double(seed) * 0.005,
            nackCount: seed + 7,
            targetBitrate: Double(seed) * 32_000,
            roundTripTime: Double(seed) * 0.006
        )
    }
}
