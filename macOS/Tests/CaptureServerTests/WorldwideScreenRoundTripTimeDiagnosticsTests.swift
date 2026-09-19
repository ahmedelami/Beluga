@testable import CaptureServer
import WebRTCTransport
import XCTest

final class WorldwideScreenRoundTripTimeDiagnosticsTests: XCTestCase {
    func testMissingAndUnavailableObservationsHaveNoNumericEvidence() {
        let observations: [WebRTCRoundTripTimeObservation?] = [nil, .unavailable]
        for observation in observations {
            let fields = WorldwideScreenRoundTripTimeDiagnostics(observation: observation)
            XCTAssertNil(fields.totalMicroseconds)
            XCTAssertNil(fields.responsesReceived)
        }
    }

    func testPiggybackProgressIsVisibleEvenWhenResponseCountDoesNotAdvance() {
        let first = fields(total: 0.150, responses: 0)
        let second = fields(total: 0.155, responses: 0)
        XCTAssertEqual(first.totalMicroseconds, 150_000)
        XCTAssertEqual(second.totalMicroseconds, 155_000)
        XCTAssertEqual(first.responsesReceived, second.responsesReceived)
    }

    func testUnrepresentableTotalsCannotTrapTheHostLogger() {
        for total in [Double.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            XCTAssertNil(fields(total: total, responses: .max).totalMicroseconds)
        }
        XCTAssertEqual(fields(total: 0, responses: .max).responsesReceived, .max)
    }

    private func fields(total: Double, responses: UInt64)
        -> WorldwideScreenRoundTripTimeDiagnostics {
        WorldwideScreenRoundTripTimeDiagnostics(observation: .measurement(.init(
            selectedCandidatePairFingerprint: String(repeating: "a", count: 64),
            totalRoundTripTimeSeconds: total,
            responsesReceived: responses
        )))
    }
}
