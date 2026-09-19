import Foundation
import WebRTCTransport

/// Content-free log fields. Candidate identity is deliberately not exposed here.
struct WorldwideScreenRoundTripTimeDiagnostics: Equatable, Sendable {
    let totalMicroseconds: UInt64?
    let responsesReceived: UInt64?

    init(observation: WebRTCRoundTripTimeObservation?) {
        guard case let .measurement(measurement) = observation else {
            totalMicroseconds = nil
            responsesReceived = nil
            return
        }
        totalMicroseconds = UInt64(exactly: (
            measurement.totalRoundTripTimeSeconds * 1_000_000
        ).rounded())
        responsesReceived = measurement.responsesReceived
    }
}
