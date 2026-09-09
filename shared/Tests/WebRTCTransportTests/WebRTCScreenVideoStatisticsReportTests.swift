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
        XCTAssertEqual(
            first.nativeReportTimestampMicroseconds,
            second.nativeReportTimestampMicroseconds
        )
    }

    func testRouteRestorationPreservesTheNativeIdentityAndSnapshotFields() {
        let snapshot = WebRTCStatisticsSnapshot(
            collectedAt: Date(timeIntervalSince1970: 123),
            collectionSequence: 51,
            currentRoundTripTime: 0.004,
            roundTripTimeObservation: .unavailable,
            availableOutgoingBitrate: 1_800_000
        )
        let report = WebRTCScreenVideoStatisticsReport(
            snapshot: snapshot,
            nativeReportTimestampMicroseconds: 1_789_000_000_123_456
        )
        let route = WebRTCICERouteDiagnostics(kind: .direct)
        let restored = report.restoringRouteIfNeeded(route)

        XCTAssertEqual(restored.snapshot, snapshot.restoringRouteIfNeeded(route))
        XCTAssertEqual(restored.snapshot.route, route)
        XCTAssertEqual(
            restored.nativeReportTimestampMicroseconds,
            report.nativeReportTimestampMicroseconds
        )
    }

    func testExistingOrUnavailableRouteDoesNotReplaceTheReportIdentity() {
        let route = WebRTCICERouteDiagnostics(kind: .relayed)
        let report = WebRTCScreenVideoStatisticsReport(
            snapshot: WebRTCStatisticsSnapshot(
                collectionSequence: 52, route: route
            ),
            nativeReportTimestampMicroseconds: 7_000_001
        )

        for replacement in [nil, WebRTCICERouteDiagnostics(kind: .direct)] {
            let restored = report.restoringRouteIfNeeded(replacement)
            XCTAssertEqual(restored.snapshot, report.snapshot)
            XCTAssertEqual(
                restored.nativeReportTimestampMicroseconds,
                report.nativeReportTimestampMicroseconds
            )
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
        }
    }
}
