import XCTest
@preconcurrency import LiveKitWebRTC
@testable import WebRTCTransport

final class WebRTCScreenVideoEncodingReplacementTests: XCTestCase {
    #if DEBUG && os(macOS)
    func testNativeConfigurationHooksRejectAudioTopologyBeforeConstructingAnything() {
        XCTAssertThrowsError(try WebRTCPeer.makeVideoControlOnlyHostForTesting(
            configuration: WebRTCTransportConfiguration(role: .host, iceServers: [], mediaTopology: .full),
            makeNativeConfiguration: { XCTFail("Audio topology reached native construction"); return LKRTCConfiguration() },
            verifyCreatedPeer: { _ in XCTFail("Audio topology created a native peer") }
        ))
    }

    func testNativeConfigurationHooksRejectViewerBeforeConstructingAnything() {
        XCTAssertThrowsError(try WebRTCPeer.makeVideoControlOnlyHostForTesting(
            configuration: WebRTCTransportConfiguration(role: .viewer, iceServers: [], mediaTopology: .videoControlOnly),
            makeNativeConfiguration: { XCTFail("Viewer reached host-only native construction"); return LKRTCConfiguration() },
            verifyCreatedPeer: { _ in XCTFail("Viewer created a native peer") }
        ))
    }
    #endif

    func testCurrentSpeculativeUpdateIsReplacedByFallback() async throws {
        try await withHost { host in
            _ = try await host.applyScreenVideoEncodingLimits(precedingFullLimits)
            let speculative = try await host.applyScreenVideoEncodingLimits(
                speculativeFullLimits
            )

            let replaced = try await host.replaceScreenVideoEncodingUpdateIfCurrent(
                speculative,
                with: fallbackLimits
            )

            XCTAssertTrue(replaced)
            try await assertApplied(fallbackLimits, on: host)
        }
    }

    func testStaleSpeculativeUpdateCannotOverwriteNewerNativeState() async throws {
        try await withHost { host in
            let stale = try await host.applyScreenVideoEncodingLimits(
                speculativeFullLimits
            )
            _ = try await host.applyScreenVideoEncodingLimits(newerLimits)

            let replaced = try await host.replaceScreenVideoEncodingUpdateIfCurrent(
                stale,
                with: fallbackLimits
            )

            XCTAssertFalse(replaced)
            try await assertApplied(newerLimits, on: host)
        }
    }

    private func makeHost() throws -> WebRTCPeer {
        try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .host,
                iceServers: [],
                maximumVideoBitrate: 12_000_000,
                mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false
            )
        )
    }

    private func withHost(
        _ operation: (WebRTCPeer) async throws -> Void
    ) async throws {
        let host = try makeHost()
        do {
            try await operation(host)
        } catch {
            await host.close(reason: .normal)
            throw error
        }
        await host.close(reason: .normal)
    }

    private func assertApplied(
        _ expected: WebRTCScreenVideoEncodingLimits,
        on host: WebRTCPeer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let observedLimits = await host.screenVideoEncodingLimitsForTesting()
        let actual = try XCTUnwrap(
            observedLimits,
            file: file,
            line: line
        )
        XCTAssertEqual(actual.maximumBitrateBps, expected.maximumBitrateBps, file: file, line: line)
        XCTAssertEqual(
            actual.maximumFramesPerSecond,
            expected.maximumFramesPerSecond,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.scaleResolutionDownBy,
            expected.scaleResolutionDownBy,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
        let observedTotalCeiling = await host.maximumTotalRTPBitrateBpsForTesting()
        XCTAssertEqual(
            observedTotalCeiling,
            expected.maximumTotalRTPBitrateBps,
            file: file,
            line: line
        )
    }

    private var precedingFullLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: 4_000_000,
            maximumFramesPerSecond: 5,
            scaleResolutionDownBy: 1,
            maximumTotalRTPBitrateBps: 8_000_000
        )
    }

    private var speculativeFullLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: 4_000_000,
            maximumFramesPerSecond: 13,
            scaleResolutionDownBy: 1,
            maximumTotalRTPBitrateBps: 8_000_000
        )
    }

    private var fallbackLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: 2_000_000,
            maximumFramesPerSecond: 30,
            scaleResolutionDownBy: 2,
            maximumTotalRTPBitrateBps: 4_000_000
        )
    }

    private var newerLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: 1_000_000,
            maximumFramesPerSecond: 10,
            scaleResolutionDownBy: 3,
            maximumTotalRTPBitrateBps: 3_000_000
        )
    }
}
