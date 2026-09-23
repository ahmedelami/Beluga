import XCTest
@testable import WebRTCTransport

final class WebRTCWholePeerStatisticsRouteRevisionTests: XCTestCase {
    func testWholePeerReportIsRejectedAfterRouteRevisionChanges() throws {
        let snapshot = WebRTCStatisticsSnapshot(
            collectionSequence: 41,
            route: WebRTCICERouteDiagnostics(kind: .relayed),
            availableOutgoingBitrate: 900_000
        )
        let report = WebRTCWholePeerStatisticsRequestReport(
            snapshot: snapshot,
            routeRevision: 7
        )

        let current = try XCTUnwrap(
            report.snapshot(ifCurrentRouteRevision: 7)
        )
        XCTAssertEqual(current.collectionSequence, 41)
        XCTAssertEqual(current.route, snapshot.route)
        XCTAssertEqual(current.availableOutgoingBitrate, 900_000)

        XCTAssertNil(
            report.snapshot(ifCurrentRouteRevision: 8),
            "A report requested before a route change must not republish its stale route."
        )
        XCTAssertNil(
            report.snapshot(ifCurrentRouteRevision: 6),
            "Only exact route-revision equality can authorize a whole-peer report."
        )
    }
}
