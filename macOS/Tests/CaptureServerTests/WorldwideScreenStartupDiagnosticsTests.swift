import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenStartupDiagnosticsTests: XCTestCase {
    func testOptionalRouteEnrichmentIsNotProofOfAChangedPair() {
        let original = route(network: nil)
        let enriched = route(network: "wifi")
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: original, to: enriched), .metadataEnrichment)
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: enriched, to: original), .metadataChanged)
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: enriched, to: route(network: "ethernet")), .metadataChanged)
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: enriched, to: enriched), .unchanged)
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: nil, to: original), .firstBinding)
        XCTAssertEqual(WorldwideScreenStartupDiagnostics.routeDifference(from: original, to: nil), .unavailable)
    }

    func testNativePairContinuityIsIndependentOfRouteMetadataAndPreservesABA() {
        var diagnostics = WorldwideScreenStartupDiagnostics()
        XCTAssertEqual(observe(&diagnostics, sequence: 1, pair: "a"), .firstObserved)
        // The route event carries no pair identity. The next native report can show that the
        // fingerprint stayed the same even if optional metadata triggered invalidation.
        XCTAssertEqual(observe(&diagnostics, sequence: 2, pair: "a"), .unchanged)
        XCTAssertEqual(observe(&diagnostics, sequence: 3, pair: "b"), .changed)
        XCTAssertEqual(observe(&diagnostics, sequence: 4, pair: "a"), .changed)
    }

    func testCachedReorderedAndMalformedReportsDoNotReplaceNativePairIdentity() {
        var diagnostics = WorldwideScreenStartupDiagnostics()
        XCTAssertEqual(observe(&diagnostics, sequence: 10, pair: "a"), .firstObserved)
        XCTAssertEqual(observe(&diagnostics, sequence: 10, pair: "b"), .rejectedReport)
        XCTAssertEqual(observe(&diagnostics, sequence: 9, pair: "b"), .rejectedReport)
        // Advance native time independently so the sequence fence, not the timestamp fence,
        // must reject duplicate and reordered collections.
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 1, showEpoch: 1, collectionSequence: 10,
            nativeTimestamp: 11_000, observation: measurement("b")
        ), .rejectedReport)
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 1, showEpoch: 1, collectionSequence: 9,
            nativeTimestamp: 12_000, observation: measurement("b")
        ), .rejectedReport)
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 1, showEpoch: 1, collectionSequence: 11,
            nativeTimestamp: 10_000, observation: measurement("b")
        ), .rejectedReport)
        XCTAssertEqual(observe(&diagnostics, sequence: 12, pair: "a"), .unchanged)
        for invalid: Double? in [nil, .nan, .infinity, -.infinity, -1, 0, .greatestFiniteMagnitude] {
            XCTAssertEqual(diagnostics.observePair(
                peerGeneration: 1, showEpoch: 1, collectionSequence: 13,
                nativeTimestamp: invalid, observation: measurement("b")
            ), .unavailable)
        }
        XCTAssertEqual(observe(&diagnostics, sequence: 14, pair: "a"), .unchanged)
    }

    func testMissingObservationDoesNotInventContinuityOrLoseTheLastComparison() {
        var diagnostics = WorldwideScreenStartupDiagnostics()
        XCTAssertEqual(observe(&diagnostics, sequence: 1, pair: "a"), .firstObserved)
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 1, showEpoch: 1, collectionSequence: 2,
            nativeTimestamp: 2_000, observation: .unavailable
        ), .unavailable)
        XCTAssertEqual(observe(&diagnostics, sequence: 3, pair: "a"), .unchanged)
        XCTAssertEqual(observe(&diagnostics, sequence: 4, pair: "x"), .unavailable)
        XCTAssertEqual(observe(&diagnostics, sequence: 5, pair: "a"), .unchanged)
    }

    func testPeerAndShowReplacementCannotBorrowAnEarlierPair() {
        var diagnostics = WorldwideScreenStartupDiagnostics()
        XCTAssertEqual(observe(&diagnostics, sequence: 1, pair: "a"), .firstObserved)
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 1, showEpoch: 2, collectionSequence: 2,
            nativeTimestamp: 2_000, observation: measurement("a")
        ), .firstObserved)
        XCTAssertEqual(diagnostics.observePair(
            peerGeneration: 2, showEpoch: 2, collectionSequence: 1,
            nativeTimestamp: 1_000, observation: measurement("a")
        ), .firstObserved)
    }

    func testTransitionFormattingIsReadOnlyAndNeverLogsCandidateStrings() {
        var before = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60
        )
        before.beginFloorRecoveryVisibility(peerGeneration: 1, showEpoch: 1)
        let preserved = before
        let hostileRoute = route(network: "wifi\nsecret=203.0.113.20")
        let fields = WorldwideScreenStartupDiagnostics.transitionFields(
            before: before, after: before, incomingRoute: hostileRoute
        )
        XCTAssertEqual(fields, "startupSpatialBefore=active startupSpatialAfter=active routeMetadataDelta=firstBinding policyRouteWasBound=false")
        XCTAssertEqual(before, preserved)
        XCTAssertEqual(before.currentRecommendation.scaleResolutionDownBy, 1)
        XCTAssertEqual(before.currentRecommendation.maximumFramesPerSecond, 5)
        XCTAssertFalse(fields.contains("secret"))
        XCTAssertFalse(fields.contains("203.0.113.20"))
    }

    private func route(network: String?) -> WebRTCICERouteDiagnostics {
        WebRTCICERouteDiagnostics(kind: .direct,
            local: .init(type: .host, transport: "udp", networkType: network),
            remote: .init(type: .serverReflexive, transport: "udp"))
    }

    private func measurement(_ pair: String) -> WebRTCRoundTripTimeObservation {
        .measurement(.init(selectedCandidatePairFingerprint: String(repeating: pair, count: 64),
                           totalRoundTripTimeSeconds: 0.05, responsesReceived: 1))
    }

    private func observe(
        _ diagnostics: inout WorldwideScreenStartupDiagnostics, sequence: UInt64, pair: String
    ) -> WorldwideScreenStartupDiagnostics.PairContinuity {
        diagnostics.observePair(peerGeneration: 1, showEpoch: 1,
            collectionSequence: sequence, nativeTimestamp: Double(sequence) * 1_000,
            observation: measurement(pair))
    }
}
