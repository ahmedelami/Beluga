#if os(macOS)
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import RemoteSessionCore
@testable import CaptureServer
@testable import WebRTCTransport
import XCTest

private enum StartupClarityFailure: Error {
    case setup
    case timeout
}

private struct StartupClarityVariant: Sendable {
    let name: String
    let scale: Double
    let totalBitrateBps: Int
    let expectedWidth: Int
    let expectedHeight: Int
    let denseContent: Bool

    init(
        name: String,
        scale: Double,
        totalBitrateBps: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        denseContent: Bool = false
    ) {
        self.name = name
        self.scale = scale
        self.totalBitrateBps = totalBitrateBps
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
        self.denseContent = denseContent
    }
}

private actor StartupClarityState {
    var remoteTrack: WebRTCRemoteVideoTrack?
    var activeAcknowledged = false
    var viewerControlOpen = false
    var relayErrors: [String] = []

    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        if viewerSide, case .dataChannelStateChanged(let channelState) = event {
            viewerControlOpen = channelState == .open
        }
        if viewerSide, case .remoteVideoTrack(let track) = event {
            remoteTrack = track
        }
        if viewerSide,
           case .controlAcknowledgementReceived(let acknowledgement, _) = event,
           acknowledgement.state == .active {
            activeAcknowledged = true
        }
    }

    func recordRelayError(_ error: any Error) {
        relayErrors.append(String(describing: error))
    }
}

private final class StartupClarityPattern: @unchecked Sendable {
    static let width = 1_080
    static let height = 1_920
    static let dark: UInt8 = 20
    static let light: UInt8 = 235
    static let stripeWidths = [2, 4, 8]
    static let stripeRegionStarts = [40, 400, 760]
    static let stripeRegionWidth = 280
    static let stripeTop = 140
    static let stripeBottom = 1_020
    private static let denseTop = 1_120
    private static let denseBottom = 1_840
    private static let densePhotoLeft = 48
    private static let densePhotoRight = 536
    private static let denseTextLeft = 568
    private static let denseRight = 1_032
    private static let denseGlyphRows: [[UInt8]] = [
        [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110], // B
        [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111], // E
        [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111], // L
        [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // U
        [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110], // G
        [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001], // A
        [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001], // R
        [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001], // M
        [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110], // O
        [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100], // T
        [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110], // S
        [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110], // C
        [0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001], // N
        [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110], // 0
        [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111], // 2
        [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110], // 5
    ]

    let buffers: [CVPixelBuffer]

    init(denseContent: Bool = false) throws {
        buffers = try [false, true].map {
            try Self.makeBuffer(cursorOn: $0, denseContent: denseContent)
        }
    }

    private static func makeBuffer(
        cursorOn: Bool,
        denseContent: Bool
    ) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &result
        )
        guard status == kCVReturnSuccess,
              let result,
              CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess,
              let baseAddress = CVPixelBufferGetBaseAddress(result) else {
            throw StartupClarityFailure.setup
        }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(result)
        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixelValue(
                    x: x,
                    y: y,
                    cursorOn: cursorOn,
                    denseContent: denseContent
                )
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }
        return result
    }

    private static func pixelValue(
        x: Int,
        y: Int,
        cursorOn: Bool,
        denseContent: Bool
    ) -> UInt8 {
        if y < 96 {
            if cursorOn, (968..<1_032).contains(x), (16..<80).contains(y) {
                return light
            }
            return dark
        }

        for (index, start) in stripeRegionStarts.enumerated() {
            let end = start + stripeRegionWidth
            guard (start..<end).contains(x), (stripeTop..<stripeBottom).contains(y) else {
                continue
            }
            let border = 8
            if x < start + border || x >= end - border
                || y < stripeTop + border || y >= stripeBottom - border {
                return dark
            }
            let interiorX = x - (start + 16)
            return (interiorX / stripeWidths[index]).isMultiple(of: 2) ? dark : light
        }

        // Panel and row rules add larger reference edges alongside the fine-detail regions.
        if y == 1_080 || y == 1_081 || y == 1_880 || y == 1_881
            || x == 24 || x == 25 || x == 1_054 || x == 1_055 {
            return dark
        }

        if denseContent, (denseTop..<denseBottom).contains(y) {
            if (densePhotoLeft..<densePhotoRight).contains(x) {
                return densePhotoValue(x: x, y: y)
            }
            if (denseTextLeft..<denseRight).contains(x) {
                return denseTextValue(x: x, y: y)
            }
            if (densePhotoRight..<denseTextLeft).contains(x) {
                return 196
            }
        }

        // The scalar fixture remains unchanged for direct comparison with the original runs.
        if !denseContent, (48..<1_032).contains(x), (1_120..<1_840).contains(y) {
            let localX = (x - 48) % 48
            let localY = (y - 1_120) % 80
            let vertical = (4..<8).contains(localX) && (4..<68).contains(localY)
            let horizontal = (4..<36).contains(localX)
                && ((4..<8).contains(localY)
                    || (32..<36).contains(localY)
                    || (64..<68).contains(localY))
            if vertical || horizontal { return dark }
        }
        return light
    }

    private static func densePhotoValue(x: Int, y: Int) -> UInt8 {
        let localX = x - densePhotoLeft
        let localY = y - denseTop
        let fineTexture = (
            localX * 17
                + localY * 29
                + (localX / 4) * (localY / 4) * 3
        ) & 31
        let coarseTexture = ((localX / 13) * 37 + (localY / 11) * 19) & 15
        let horizon = 300 + ((localX / 24) & 15)
        var value: Int
        if localY < horizon {
            value = 52 + localY * 72 / max(1, horizon)
        } else {
            value = 116 + (localY - horizon) * 54 / max(1, denseBottom - denseTop - horizon)
        }
        value += fineTexture - 15
        value += coarseTexture - 7

        let headX = localX - 310
        let headY = localY - 245
        if headX * headX + headY * headY < 62 * 62 {
            value = 188 + (fineTexture - 15) / 2
        } else if (248..<372).contains(localX), (306..<650).contains(localY) {
            value = 66 + coarseTexture * 2
        }
        if abs(localY - (localX * 3 / 5 + 78)) <= 2 {
            value = 224
        }
        return UInt8(max(Int(dark), min(Int(light), value)))
    }

    private static func denseTextValue(x: Int, y: Int) -> UInt8 {
        let localX = x - denseTextLeft
        let localY = y - denseTop
        let cellWidth = 32
        let cellHeight = 48
        let cellColumn = localX / cellWidth
        let cellRow = localY / cellHeight
        let glyphIndex = (cellRow * 13 + cellColumn * 7) % denseGlyphRows.count
        let glyphLocalX = localX % cellWidth - 4
        let glyphLocalY = localY % cellHeight - 8
        if glyphLocalX >= 0, glyphLocalY >= 0 {
            let glyphX = glyphLocalX / 4
            let glyphY = glyphLocalY / 4
            guard (0..<5).contains(glyphX), (0..<7).contains(glyphY) else {
                return denseTextBackgroundValue(
                    cellRow: cellRow,
                    cellColumn: cellColumn,
                    localY: localY,
                    cellHeight: cellHeight
                )
            }
            let mask = denseGlyphRows[glyphIndex][glyphY]
            if (mask & (UInt8(1) << (4 - glyphX))) != 0 {
                return UInt8(28 + (glyphIndex * 7) % 30)
            }
        }
        return denseTextBackgroundValue(
            cellRow: cellRow,
            cellColumn: cellColumn,
            localY: localY,
            cellHeight: cellHeight
        )
    }

    private static func denseTextBackgroundValue(
        cellRow: Int,
        cellColumn: Int,
        localY: Int,
        cellHeight: Int
    ) -> UInt8 {
        if (40..<42).contains(localY % cellHeight) {
            return UInt8(150 + (cellRow * 9 + cellColumn * 3) % 30)
        }
        return UInt8(216 + (cellRow * 11 + cellColumn * 5) % 20)
    }
}

private final class StartupClarityRenderer:
    NSObject,
    LKRTCVideoRenderer,
    @unchecked Sendable
{
    struct Contrast: Sendable {
        let line2: Double
        let line4: Double
        let line8: Double

        var minimum: Double { min(line2, line4, line8) }
        var values: [Double] { [line2, line4, line8] }
    }

    struct Observation: Sendable {
        let receivedAt: ContinuousClock.Instant
        let timestamp: Int32
        let width: Int
        let height: Int
        let signedIdealNormalizedContrast: Contrast
    }

    private let lock = NSLock()
    private var timestamps: Set<Int32> = []
    private var observations: [Observation] = []

    func setSize(_: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let i420 = frame.buffer.toI420()
        let observation = Observation(
            receivedAt: .now,
            timestamp: frame.timeStamp,
            width: Int(frame.width),
            height: Int(frame.height),
            signedIdealNormalizedContrast: Self.measureContrast(i420)
        )
        lock.withLock {
            guard timestamps.insert(frame.timeStamp).inserted else { return }
            if observations.count < 1_024 {
                observations.append(observation)
            }
        }
    }

    func snapshot() -> [Observation] {
        lock.withLock { observations }
    }

    private static func measureContrast(
        _ buffer: any LKRTCI420BufferProtocol
    ) -> Contrast {
        let values = zip(
            StartupClarityPattern.stripeWidths,
            StartupClarityPattern.stripeRegionStarts
        ).map { lineWidth, regionStart in
            signedContrast(
                buffer,
                lineWidth: lineWidth,
                regionStart: regionStart
            )
        }
        return Contrast(line2: values[0], line4: values[1], line8: values[2])
    }

    /// Samples known dark/light stripe centers. Keeping the sign prevents inverted or aliased
    /// detail from looking sharp merely because neighboring decoded pixels differ.
    private static func signedContrast(
        _ buffer: any LKRTCI420BufferProtocol,
        lineWidth: Int,
        regionStart: Int
    ) -> Double {
        let interiorStart = regionStart + 16
        let interiorEnd = regionStart + StartupClarityPattern.stripeRegionWidth - 16
        let pairCount = max(1, (interiorEnd - interiorStart) / (2 * lineWidth))
        let sampleRows = [220, 360, 500, 640, 780, 920]
        var signedDifference = 0.0
        var count = 0
        for row in sampleRows {
            for pair in 0..<pairCount {
                let darkSourceX = interiorStart + pair * 2 * lineWidth + lineWidth / 2
                let lightSourceX = darkSourceX + lineWidth
                guard lightSourceX < interiorEnd else { continue }
                let dark = luma(buffer, sourceX: darkSourceX, sourceY: row)
                let light = luma(buffer, sourceX: lightSourceX, sourceY: row)
                signedDifference += light - dark
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let idealDifference = Double(
            Int(StartupClarityPattern.light) - Int(StartupClarityPattern.dark)
        )
        return signedDifference / Double(count) / idealDifference
    }

    private static func luma(
        _ buffer: any LKRTCI420BufferProtocol,
        sourceX: Int,
        sourceY: Int
    ) -> Double {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        let x = min(
            width - 1,
            max(0, sourceX * width / StartupClarityPattern.width)
        )
        let y = min(
            height - 1,
            max(0, sourceY * height / StartupClarityPattern.height)
        )
        return Double(buffer.dataY[y * Int(buffer.strideY) + x])
    }
}

private func startupClarityRelay(
    from: WebRTCPeer,
    to: WebRTCPeer,
    viewerSide: Bool,
    state: StartupClarityState,
    networkRelay: StartupVideoDatagramRelay? = nil
) -> Task<Void, Never> {
    Task {
        do {
            for await event in from.events {
                await state.observe(event, viewerSide: viewerSide)
                if case .outboundSignal(let payload) = event {
                    if let networkRelay {
                        if let rewritten = try networkRelay.rewrite(
                            payload, from: viewerSide ? .viewer : .host
                        ) {
                            try await to.handle(rewritten)
                        }
                    } else {
                        try await to.handle(payload)
                    }
                }
                if !viewerSide,
                   case .controlRequestReceived(let request) = event,
                   request.command == .showScreen {
                    try await from.acknowledgeActiveControlRequestIfTransportHealthy(
                        id: request.id,
                        authorization: WebRTCControlAuthorization()
                    )
                }
            }
        } catch {
            if !Task.isCancelled {
                await state.recordRelayError(error)
            }
        }
    }
}

private func startupClarityWait(
    timeout: Duration = .seconds(8),
    _ predicate: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw StartupClarityFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func startupClarityClose(
    host: WebRTCPeer,
    viewer: WebRTCPeer,
    relays: [Task<Void, Never>],
    pump: Task<Void, Never>?,
    track: WebRTCRemoteVideoTrack?,
    renderer: StartupClarityRenderer,
    networkRelay: StartupVideoDatagramRelay? = nil
) async {
    pump?.cancel()
    await pump?.value
    if let track {
        await MainActor.run { track.removeRenderer(renderer) }
    }
    await host.close(reason: .normal)
    await viewer.close(reason: .normal)
    for relay in relays { relay.cancel() }
    for relay in relays { await relay.value }
    await networkRelay?.stop()
}

private final class StartupClarityCaptureCadence: @unchecked Sendable {
    private let lock = NSLock()
    private var fps = 5

    func update(_ newFPS: Int) { lock.withLock { fps = min(60, max(1, newFPS)) } }
    var interval: Duration { lock.withLock { .nanoseconds(1_000_000_000 / fps) } }
}

private func startupClarityMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func startupClarityJSONNumber(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(
        format: "%.4f",
        locale: Locale(identifier: "en_US_POSIX"),
        value
    )
}

final class WebRTCStartupClarityExperimentTests: XCTestCase {
    // Diagnostic characterization, not a default CI gate. Run each method in a fresh
    // filtered process; native codec/probe initialization is process-scoped. Scalar
    // contrast is decoded-pixel evidence, not a claim about iPhone text readability.
    func testVariantASurvivalScaleCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "A_scale4_total905041",
                scale: 4,
                totalBitrateBps: 905_041,
                expectedWidth: 270,
                expectedHeight: 480
            )
        )
    }

    func testVariantBFullScaleSameCapCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "B_scale1_total905041",
                scale: 1,
                totalBitrateBps: 905_041,
                expectedWidth: 1_080,
                expectedHeight: 1_920
            )
        )
    }

    func testVariantCFullScaleBoundedCriticalCapCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "C_scale1_total1693440",
                scale: 1,
                totalBitrateBps: 1_693_440,
                expectedWidth: 1_080,
                expectedHeight: 1_920
            )
        )
    }

    func testDenseVariantASurvivalScaleCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "A_dense_scale4_total905041",
                scale: 4,
                totalBitrateBps: 905_041,
                expectedWidth: 270,
                expectedHeight: 480,
                denseContent: true
            )
        )
    }

    func testDenseVariantBFullScaleSameCapCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "B_dense_scale1_total905041",
                scale: 1,
                totalBitrateBps: 905_041,
                expectedWidth: 1_080,
                expectedHeight: 1_920,
                denseContent: true
            )
        )
    }

    func testDenseVariantCFullScaleBoundedCriticalCapCharacterization() async throws {
        try await run(
            StartupClarityVariant(
                name: "C_dense_scale1_total1693440",
                scale: 1,
                totalBitrateBps: 1_693_440,
                expectedWidth: 1_080,
                expectedHeight: 1_920,
                denseContent: true
            )
        )
    }

    func testDenseProductionPolicyNativeLoopbackCharacterization() async throws {
        try await runDenseProductionPolicyNativeLoopback()
    }

    func testDenseProductionPolicyDelayedNetworkWithDynamicFrameRateCharacterization() async throws {
        try await runDenseProductionPolicyNativeLoopback(oneWayDelayMilliseconds: 50,
                                                       followsPolicyFPS: true)
    }

    func testDelayedNetworkBlackoutPreventsDirectICEBypass() async throws {
        guard ProcessInfo.processInfo.environment[
            "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"
        ] == "1" else {
            throw XCTSkip("Opt-in fresh-process startup clarity characterization")
        }
        let host = try WebRTCPeer(configuration: WebRTCTransportConfiguration(
            role: .host, iceServers: [], mediaTopology: .videoControlOnly,
            supportsAudioClientDiagnostics: false))
        let viewer: WebRTCPeer
        do {
            viewer = try WebRTCPeer(configuration: WebRTCTransportConfiguration(
                role: .viewer, iceServers: [], mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false))
        } catch {
            await host.close(reason: .normal)
            throw error
        }
        let networkRelay: StartupVideoDatagramRelay
        do {
            networkRelay = try StartupVideoDatagramRelay(dropAll: true)
        } catch {
            await host.close(reason: .normal)
            await viewer.close(reason: .normal)
            throw error
        }
        let state = StartupClarityState()
        let renderer = StartupClarityRenderer()
        let relays = [
            startupClarityRelay(from: host, to: viewer, viewerSide: false, state: state,
                                networkRelay: networkRelay),
            startupClarityRelay(from: viewer, to: host, viewerSide: true, state: state,
                                networkRelay: networkRelay),
        ]
        do {
            try await host.start()
            try await Task.sleep(for: .seconds(3))
            let healthy = await host.isTransportHealthyForCapture()
            let evidence = networkRelay.snapshot()
            XCTAssertFalse(healthy, "No alternate native candidate may bypass the relay")
            XCTAssertEqual(evidence.mappedSideCount, 2)
            XCTAssertGreaterThan(evidence.hostToViewer.droppedDatagrams
                + evidence.viewerToHost.droppedDatagrams, 0)
            XCTAssertEqual(evidence.hostToViewer.forwardedDatagrams, 0)
            XCTAssertEqual(evidence.viewerToHost.forwardedDatagrams, 0)
            XCTAssertEqual(evidence.errorCount, 0)
            let errors = await state.relayErrors
            XCTAssertEqual(errors, [])
            print("STARTUP_NETWORK_BLACKOUT \(evidence)")
        } catch {
            await startupClarityClose(host: host, viewer: viewer, relays: relays,
                pump: nil, track: nil, renderer: renderer, networkRelay: networkRelay)
            throw error
        }
        await startupClarityClose(host: host, viewer: viewer, relays: relays,
            pump: nil, track: nil, renderer: renderer, networkRelay: networkRelay)
        XCTAssertTrue(networkRelay.snapshot().stopped)
        XCTAssertEqual(networkRelay.snapshot().pendingDatagrams, 0)
    }

    private func runDenseProductionPolicyNativeLoopback(
        oneWayDelayMilliseconds: Int? = nil, followsPolicyFPS: Bool = false
    ) async throws {
        guard ProcessInfo.processInfo.environment[
            "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"
        ] == "1" else {
            throw XCTSkip("Opt-in fresh-process startup clarity characterization")
        }

        let configuredTotalBitrateBps = 50_000_000
        let peerGeneration: UInt64 = 1
        let showEpoch: UInt64 = 1
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: configuredTotalBitrateBps,
            baseFramesPerSecond: 60
        )
        _ = policy.bind(toPeerGeneration: peerGeneration)
        policy.beginFloorRecoveryVisibility(
            peerGeneration: peerGeneration,
            showEpoch: showEpoch
        )
        var appliedRecommendation = policy.currentRecommendation

        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .host,
                iceServers: [],
                maximumVideoBitrate: configuredTotalBitrateBps,
                mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false
            )
        )
        let viewer: WebRTCPeer
        do {
            viewer = try WebRTCPeer(
                configuration: WebRTCTransportConfiguration(
                    role: .viewer,
                    iceServers: [],
                    mediaTopology: .videoControlOnly,
                    supportsAudioClientDiagnostics: false
                )
            )
        } catch {
            await host.close(reason: .normal)
            throw error
        }

        let networkRelay: StartupVideoDatagramRelay?
        do {
            if let oneWayDelayMilliseconds {
                networkRelay = try StartupVideoDatagramRelay(
                    oneWayDelayMilliseconds: oneWayDelayMilliseconds)
            } else {
                networkRelay = nil
            }
        } catch {
            await host.close(reason: .normal)
            await viewer.close(reason: .normal)
            throw error
        }
        let state = StartupClarityState()
        let renderer = StartupClarityRenderer()
        let relays = [
            startupClarityRelay(from: host, to: viewer, viewerSide: false, state: state,
                                networkRelay: networkRelay),
            startupClarityRelay(from: viewer, to: host, viewerSide: true, state: state,
                                networkRelay: networkRelay),
        ]
        var track: WebRTCRemoteVideoTrack?
        var pump: Task<Void, Never>?

        do {
            XCTAssertNil(host.externalAudioCapturer)
            XCTAssertNil(viewer.externalAudioCapturer)
            _ = try await host.applyScreenVideoEncodingLimits(
                appliedRecommendation.webRTCLimits
            )
            try await host.start()
            try await startupClarityWait {
                let healthy = await host.isTransportHealthyForCapture()
                let hasTrack = await state.remoteTrack != nil
                let viewerReady = await state.viewerControlOpen
                return healthy && hasTrack && viewerReady
            }
            let remoteTrackValue = await state.remoteTrack
            let remoteTrack = try XCTUnwrap(remoteTrackValue)
            track = remoteTrack
            await MainActor.run { remoteTrack.addRenderer(renderer) }
            _ = try await viewer.setScreenVisible(true)
            try await startupClarityWait { await state.activeAcknowledged }
            policy.activateFloorRecoveryVisibility(
                peerGeneration: peerGeneration,
                showEpoch: showEpoch
            )

            let capturer = try XCTUnwrap(host.externalVideoCapturer)
            capturer.adaptOutput(
                width: Int32(StartupClarityPattern.width),
                height: Int32(StartupClarityPattern.height),
                framesPerSecond: Int32(appliedRecommendation.maximumFramesPerSecond)
            )
            let pattern = try StartupClarityPattern(denseContent: true)
            let viewerBaseline = await viewer.statisticsSnapshot()
            let baselineBytes = viewerBaseline.inboundVideo?.bytes ?? 0
            let captureStartedAt = ContinuousClock.now
            capturer.capture(
                pixelBuffer: pattern.buffers[0],
                timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
            )
            // Cursor-only content separates native frame cadence from a moving-photo workload.
            // The original direct loopback stays fixed at 5 fps; the delayed case follows the
            // actual applied policy so intermediate/full FPS requests must reach the decoder.
            let captureCadence = StartupClarityCaptureCadence()
            captureCadence.update(appliedRecommendation.maximumFramesPerSecond)
            pump = Task.detached {
                var index = 1
                while !Task.isCancelled {
                    do { try await Task.sleep(for: captureCadence.interval) } catch { break }
                    guard !Task.isCancelled else { break }
                    capturer.capture(
                        pixelBuffer: pattern.buffers[index % pattern.buffers.count],
                        timestampNanoseconds: Int64(
                            clamping: DispatchTime.now().uptimeNanoseconds
                        )
                    )
                    index += 1
                }
            }

            var trace: [String] = [
                "{elapsedMs:0.000,lane:startup,bwe:null,tier:"
                    + "\(String(describing: appliedRecommendation.tier)),"
                    + "fps:\(appliedRecommendation.maximumFramesPerSecond),"
                    + "scale:\(startupClarityJSONNumber(appliedRecommendation.scaleResolutionDownBy))}"
            ]
            let clock = ContinuousClock()
            var cadence = WorldwideScreenVideoSamplingCadence(startedAt: captureStartedAt)
            let observationSeconds = followsPolicyFPS ? 12 : 10
            let deadline = captureStartedAt.advanced(by: .seconds(observationSeconds))
            var ordinaryReportCount = 0
            var capacityReportCount = 0
            var maximumRequestedFPS = appliedRecommendation.maximumFramesPerSecond
            var maximumNativeRTT = 0.0
            while ContinuousClock.now < deadline {
                let wake = min(cadence.nextDeadline, deadline)
                if ContinuousClock.now < wake {
                    try await clock.sleep(until: wake)
                }
                let requestStartedAt = ContinuousClock.now
                guard requestStartedAt < deadline else { break }
                guard let lane = cadence.takeDueSample(at: requestStartedAt) else { continue }
                let capacityOnly = lane == .capacityOnly
                let remaining = requestStartedAt.duration(to: deadline)
                let report = await host.screenVideoStatisticsSnapshot(
                    timeout: min(
                        capacityOnly ? .milliseconds(100) : .milliseconds(250),
                        remaining
                    )
                )
                let observedAt = ContinuousClock.now
                let previousRoute = policy.selectedRoute
                var proposedPolicy = policy
                let changedRecommendation: WorldwideScreenVideoEncodingRecommendation?
                if let report, capacityOnly {
                    capacityReportCount += 1
                    let snapshot = report.nativeSnapshot
                    changedRecommendation = proposedPolicy.updateCapacityProbe(
                        peerGeneration: peerGeneration,
                        isCaptureActive: true,
                        availableOutgoingBitrateBps: snapshot.availableOutgoingBitrate,
                        currentRoundTripTimeSeconds: snapshot.currentRoundTripTime,
                        roundTripTimeObservation: snapshot.roundTripTimeObservation,
                        collectionSequence: snapshot.collectionSequence,
                        nativeReportTimestampMicroseconds:
                            report.nativeReportTimestampMicroseconds,
                        selectedRoute: snapshot.route,
                        outboundVideoPacketsSent: snapshot.outboundVideo?.packets,
                        outboundVideoTotalPacketSendDelaySeconds:
                            snapshot.outboundVideo?.totalPacketSendDelay,
                        observedAt: observedAt
                    )
                } else if let report {
                    ordinaryReportCount += 1
                    let snapshot = report.nativeSnapshot
                    changedRecommendation = proposedPolicy.update(
                        peerGeneration: peerGeneration,
                        isCaptureActive: true,
                        availableOutgoingBitrateBps: snapshot.availableOutgoingBitrate,
                        currentRoundTripTimeSeconds: snapshot.currentRoundTripTime,
                        roundTripTimeObservation: snapshot.roundTripTimeObservation,
                        collectionSequence: snapshot.collectionSequence,
                        requireRoundTripTimeObservation: true,
                        selectedRoute: snapshot.route,
                        outboundVideoPacketsSent: snapshot.outboundVideo?.packets,
                        outboundVideoTotalPacketSendDelaySeconds:
                            snapshot.outboundVideo?.totalPacketSendDelay,
                        nativeReportTimestampMicroseconds:
                            report.nativeReportTimestampMicroseconds,
                        observedAt: observedAt
                    )
                } else {
                    changedRecommendation = proposedPolicy
                        .expireApplicationLimitedProbeWithoutReport(
                            peerGeneration: peerGeneration,
                            isCaptureActive: true,
                            observedAt: observedAt
                        )
                }

                let recommendation = changedRecommendation
                    ?? proposedPolicy.currentRecommendation
                if recommendation != appliedRecommendation {
                    _ = try await host.applyScreenVideoEncodingLimits(
                        recommendation.webRTCLimits
                    )
                    capturer.adaptOutput(
                        width: Int32(StartupClarityPattern.width),
                        height: Int32(StartupClarityPattern.height),
                        framesPerSecond: Int32(
                            recommendation.maximumFramesPerSecond
                        )
                    )
                    appliedRecommendation = recommendation
                    if followsPolicyFPS {
                        captureCadence.update(recommendation.maximumFramesPerSecond)
                    }
                    maximumRequestedFPS = max(maximumRequestedFPS,
                                              recommendation.maximumFramesPerSecond)
                }
                policy = proposedPolicy

                let snapshot = report?.nativeSnapshot
                if let rtt = snapshot?.currentRoundTripTime, rtt.isFinite {
                    maximumNativeRTT = max(maximumNativeRTT, rtt)
                }
                trace.append(
                    "{elapsedMs:"
                        + "\(startupClarityJSONNumber(startupClarityMilliseconds(captureStartedAt.duration(to: observedAt)))),"
                        + "lane:\(capacityOnly ? "capacityOnly" : "ordinary"),"
                        + "bwe:\(startupClarityJSONNumber(snapshot?.availableOutgoingBitrate)),"
                        + "tier:\(String(describing: recommendation.tier)),"
                        + "fps:\(recommendation.maximumFramesPerSecond),"
                        + "scale:\(startupClarityJSONNumber(recommendation.scaleResolutionDownBy)),"
                        + "sequence:\(snapshot?.collectionSequence.map(String.init) ?? "null"),"
                        + "nativeTimestamp:"
                        + "\(startupClarityJSONNumber(report?.nativeReportTimestampMicroseconds)),"
                        + "rtt:\(startupClarityJSONNumber(snapshot?.currentRoundTripTime)),"
                        + "route:\(snapshot?.route?.kind.rawValue ?? "unknown"),"
                        + "diagnosticRouteDiffers:\(report?.snapshot.route != snapshot?.route),"
                        + "routeChanged:\(snapshot?.route != previousRoute),"
                        + "routeLocalPresent:\(snapshot?.route?.local != nil),"
                        + "routeRemotePresent:\(snapshot?.route?.remote != nil),"
                        + "latencyPressure:\(policy.lastSampleHasLatencyPressure),"
                        + "rttDisposition:\(policy.roundTripTimeDisposition),"
                        + "spatialDisproved:\(policy.startupSpatialModeIsDisproved),"
                        + "packets:\(snapshot?.outboundVideo?.packets.map(String.init) ?? "null"),"
                        + "packetDelay:"
                        + "\(startupClarityJSONNumber(snapshot?.outboundVideo?.totalPacketSendDelay))}"
                )
                let sampleFinishedAt = ContinuousClock.now
                cadence.didFinishSample(at: sampleFinishedAt)
                cadence.setCapacityProbeEnabled(
                    policy.applicationLimitedProbeOriginTier != nil,
                    at: sampleFinishedAt
                )
            }

            let observations = renderer.snapshot()
            var decodedTransitions: [String] = []
            var previousGeometry: String?
            var previousContrastBucket: Int?
            for observation in observations {
                let geometry = "\(observation.width)x\(observation.height)"
                let minimumContrast = observation.signedIdealNormalizedContrast.minimum
                let contrastBucket = Int((minimumContrast * 20).rounded())
                guard geometry != previousGeometry
                        || contrastBucket != previousContrastBucket else {
                    continue
                }
                previousGeometry = geometry
                previousContrastBucket = contrastBucket
                decodedTransitions.append(
                    "{elapsedMs:"
                        + "\(startupClarityJSONNumber(startupClarityMilliseconds(captureStartedAt.duration(to: observation.receivedAt)))),"
                        + "geometry:\(geometry),"
                        + "contrast2:"
                        + "\(startupClarityJSONNumber(observation.signedIdealNormalizedContrast.line2)),"
                        + "contrast4:"
                        + "\(startupClarityJSONNumber(observation.signedIdealNormalizedContrast.line4)),"
                        + "contrast8:"
                        + "\(startupClarityJSONNumber(observation.signedIdealNormalizedContrast.line8))}"
                )
            }
            let viewerFinal = await viewer.statisticsSnapshot()
            let finalBytes = viewerFinal.inboundVideo?.bytes ?? baselineBytes
            let inboundByteDelta = finalBytes >= baselineBytes
                ? finalBytes - baselineBytes
                : 0
            let transportHealthy = await host.isTransportHealthyForCapture()
            let lastWindowStart = deadline.advanced(by: .seconds(-2))
            let finalDecodedFPS = Double(observations.filter {
                $0.receivedAt >= lastWindowStart && $0.receivedAt < deadline
            }.count) / 2
            print(
                "STARTUP_POLICY_NATIVE_LOOPBACK {denseContent:true,contentMotion:cursorOnly,"
                    + "followsPolicyFPS:\(followsPolicyFPS),"
                    + "oneWayDelayMs:\(oneWayDelayMilliseconds ?? 0),"
                    + "maximumRequestedFPS:\(maximumRequestedFPS),finalDecodedFPS:\(finalDecodedFPS),"
                    + "maximumNativeRTT:\(startupClarityJSONNumber(maximumNativeRTT)),"
                    + "ordinaryReports:\(ordinaryReportCount),"
                    + "capacityReports:\(capacityReportCount),"
                    + "finalInboundByteDelta:\(inboundByteDelta),"
                    + "policyTrace:[\(trace.joined(separator: ","))],"
                    + "decodedTransitions:[\(decodedTransitions.joined(separator: ","))]}"
            )

            XCTAssertTrue(transportHealthy)
            XCTAssertGreaterThan(ordinaryReportCount, 0)
            XCTAssertGreaterThan(finalBytes, baselineBytes)
            XCTAssertFalse(observations.isEmpty)
            if let oneWayDelayMilliseconds {
                XCTAssertGreaterThanOrEqual(maximumNativeRTT,
                    Double(oneWayDelayMilliseconds) / 1_000,
                    "The native ICE path must actually traverse the delayed datagrams")
                XCTAssertTrue(observations.allSatisfy {
                    $0.width == StartupClarityPattern.width
                        && $0.height == StartupClarityPattern.height
                        && $0.signedIdealNormalizedContrast.minimum > 0.9
                }, "A lossless delayed path must retain actual decoded startup detail")
                XCTAssertGreaterThan(maximumRequestedFPS, 5,
                                     "Healthy discovery must eventually improve motion")
                XCTAssertGreaterThan(finalDecodedFPS, 5,
                                     "The frame-rate improvement must reach the decoder")
            }
            if let networkRelay {
                let evidence = networkRelay.snapshot()
                print("STARTUP_NETWORK_RELAY \(evidence)")
                XCTAssertEqual(evidence.mappedSideCount, 2)
                XCTAssertGreaterThan(evidence.hostToViewer.forwardedDatagrams, 0)
                XCTAssertGreaterThan(evidence.viewerToHost.forwardedDatagrams, 0)
                XCTAssertEqual(evidence.errorCount, 0)
                // Prove the decoded media, not just ICE, uses this exact path.
                networkRelay.setDropAll(true)
                try await Task.sleep(for: .seconds(1))
                let drainedFrameCount = renderer.snapshot().count
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(renderer.snapshot().count, drainedFrameCount,
                               "Decoded media must stop after relay blackout and drain")
            }
            let relayErrors = await state.relayErrors
            XCTAssertEqual(relayErrors, [])
        } catch {
            await startupClarityClose(
                host: host,
                viewer: viewer,
                relays: relays,
                pump: pump,
                track: track,
                renderer: renderer,
                networkRelay: networkRelay
            )
            throw error
        }

        await startupClarityClose(
            host: host,
            viewer: viewer,
            relays: relays,
            pump: pump,
            track: track,
            renderer: renderer,
            networkRelay: networkRelay
        )
    }

    private func run(_ variant: StartupClarityVariant) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"] == "1" else {
            throw XCTSkip("Opt-in fresh-process startup clarity characterization")
        }
        let host = try WebRTCPeer(
            configuration: WebRTCTransportConfiguration(
                role: .host,
                iceServers: [],
                mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false
            )
        )
        let viewer: WebRTCPeer
        do {
            viewer = try WebRTCPeer(
                configuration: WebRTCTransportConfiguration(
                    role: .viewer,
                    iceServers: [],
                    mediaTopology: .videoControlOnly,
                    supportsAudioClientDiagnostics: false
                )
            )
        } catch {
            await host.close(reason: .normal)
            throw error
        }

        let state = StartupClarityState()
        let renderer = StartupClarityRenderer()
        let relays = [
            startupClarityRelay(from: host, to: viewer, viewerSide: false, state: state),
            startupClarityRelay(from: viewer, to: host, viewerSide: true, state: state),
        ]
        var track: WebRTCRemoteVideoTrack?
        var pump: Task<Void, Never>?

        do {
            XCTAssertNil(host.externalAudioCapturer)
            XCTAssertNil(viewer.externalAudioCapturer)
            _ = try await host.applyScreenVideoEncodingLimits(
                WebRTCScreenVideoEncodingLimits(
                    maximumBitrateBps: 1_192_320,
                    maximumFramesPerSecond: 5,
                    scaleResolutionDownBy: variant.scale,
                    maximumTotalRTPBitrateBps: variant.totalBitrateBps
                )
            )
            try await host.start()
            try await startupClarityWait {
                let healthy = await host.isTransportHealthyForCapture()
                let hasTrack = await state.remoteTrack != nil
                return healthy && hasTrack
            }
            let remoteTrackValue = await state.remoteTrack
            let remoteTrack = try XCTUnwrap(remoteTrackValue)
            track = remoteTrack
            await MainActor.run { remoteTrack.addRenderer(renderer) }
            _ = try await viewer.setScreenVisible(true)
            try await startupClarityWait { await state.activeAcknowledged }

            let capturer = try XCTUnwrap(host.externalVideoCapturer)
            capturer.adaptOutput(
                width: Int32(StartupClarityPattern.width),
                height: Int32(StartupClarityPattern.height),
                framesPerSecond: 5
            )
            let pattern = try StartupClarityPattern(
                denseContent: variant.denseContent
            )
            let baselineStatistics = await viewer.statisticsSnapshot()
            let baselineBytes = baselineStatistics.inboundVideo?.bytes ?? 0
            let captureStartedAt = ContinuousClock.now
            capturer.capture(
                pixelBuffer: pattern.buffers[0],
                timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
            )
            pump = Task.detached {
                var index = 1
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                    guard !Task.isCancelled else { break }
                    capturer.capture(
                        pixelBuffer: pattern.buffers[index % pattern.buffers.count],
                        timestampNanoseconds: Int64(
                            clamping: DispatchTime.now().uptimeNanoseconds
                        )
                    )
                    index += 1
                }
            }

            let deadline = captureStartedAt.advanced(by: .seconds(5))
            var firstBytesAt: ContinuousClock.Instant?
            var firstBytesValue: UInt64?
            var lastStatistics = baselineStatistics
            while ContinuousClock.now < deadline {
                let statistics = await viewer.statisticsSnapshot()
                lastStatistics = statistics
                if firstBytesAt == nil,
                   let bytes = statistics.inboundVideo?.bytes,
                   bytes > baselineBytes {
                    firstBytesAt = .now
                    firstBytesValue = bytes
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining > .zero {
                    try await Task.sleep(for: min(.milliseconds(50), remaining))
                }
            }

            let observations = renderer.snapshot()
            let first = observations.first
            let later = observations.last {
                captureStartedAt.duration(to: $0.receivedAt) >= .seconds(1)
            } ?? observations.last
            let sharpnessThreshold = 0.20
            let firstFullGeometry = observations.first {
                $0.width == StartupClarityPattern.width
                    && $0.height == StartupClarityPattern.height
            }
            let firstSharp = observations.first {
                $0.signedIdealNormalizedContrast.minimum >= sharpnessThreshold
            }
            let firstFullAndSharp = observations.first {
                $0.width == StartupClarityPattern.width
                    && $0.height == StartupClarityPattern.height
                    && $0.signedIdealNormalizedContrast.minimum >= sharpnessThreshold
            }
            let finalBytes = lastStatistics.inboundVideo?.bytes ?? baselineBytes
            let finalFrames = lastStatistics.inboundVideo?.framesEncodedOrDecoded ?? 0
            let senderReport = await host.screenVideoStatisticsSnapshot(
                timeout: .milliseconds(500)
            )
            let senderStatistics = senderReport?.snapshot
            let senderPacketsSent = senderStatistics?.outboundVideo?.packets.map {
                String($0)
            } ?? "null"
            let firstDelay = first.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
            }
            let laterDelay = later.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
            }
            let firstBytesDelay = firstBytesAt.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0))
            }
            let fullDelay = firstFullGeometry.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
            }
            let sharpDelay = firstSharp.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
            }
            let fullSharpDelay = firstFullAndSharp.map {
                startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
            }
            let firstContrast = first?.signedIdealNormalizedContrast
            let laterContrast = later?.signedIdealNormalizedContrast
            let firstByteDelta = (firstBytesValue ?? baselineBytes) - baselineBytes
            let finalByteDelta = finalBytes >= baselineBytes
                ? finalBytes - baselineBytes
                : 0
            let decodedPixelsPerSource2 = Double(variant.expectedWidth) * 2 / 1_080
            let decodedPixelsPerSource4 = Double(variant.expectedWidth) * 4 / 1_080
            let decodedPixelsPerSource8 = Double(variant.expectedWidth) * 8 / 1_080

            print(
                "STARTUP_CLARITY {"
                    + "\"variant\":\"\(variant.name)\","
                    + "\"contentMode\":\"\(variant.denseContent ? "dense" : "scalar")\","
                    + "\"denseContent\":\(variant.denseContent),"
                    + "\"firstDecodedMs\":\(startupClarityJSONNumber(firstDelay)),"
                    + "\"laterFrameMs\":\(startupClarityJSONNumber(laterDelay)),"
                    + "\"firstWidth\":\(first?.width ?? 0),\"firstHeight\":\(first?.height ?? 0),"
                    + "\"firstSignedContrast2\":\(startupClarityJSONNumber(firstContrast?.line2)),"
                    + "\"firstSignedContrast4\":\(startupClarityJSONNumber(firstContrast?.line4)),"
                    + "\"firstSignedContrast8\":\(startupClarityJSONNumber(firstContrast?.line8)),"
                    + "\"laterSignedContrast2\":\(startupClarityJSONNumber(laterContrast?.line2)),"
                    + "\"laterSignedContrast4\":\(startupClarityJSONNumber(laterContrast?.line4)),"
                    + "\"laterSignedContrast8\":\(startupClarityJSONNumber(laterContrast?.line8)),"
                    + "\"decodedPixelsPer2SourcePixels\":\(startupClarityJSONNumber(decodedPixelsPerSource2)),"
                    + "\"decodedPixelsPer4SourcePixels\":\(startupClarityJSONNumber(decodedPixelsPerSource4)),"
                    + "\"decodedPixelsPer8SourcePixels\":\(startupClarityJSONNumber(decodedPixelsPerSource8)),"
                    + "\"sharpnessThreshold\":\(startupClarityJSONNumber(sharpnessThreshold)),"
                    + "\"fullGeometryMs\":\(startupClarityJSONNumber(fullDelay)),"
                    + "\"sharpFrameMs\":\(startupClarityJSONNumber(sharpDelay)),"
                    + "\"fullGeometryAndSharpMs\":\(startupClarityJSONNumber(fullSharpDelay)),"
                    + "\"firstInboundBytesMs\":\(startupClarityJSONNumber(firstBytesDelay)),"
                    + "\"firstInboundBytesDelta\":\(firstByteDelta),"
                    + "\"finalInboundBytesDelta\":\(finalByteDelta),"
                    + "\"finalFramesDecoded\":\(finalFrames),"
                    + "\"senderAvailableOutgoingBitrate\":"
                    + "\(startupClarityJSONNumber(senderStatistics?.availableOutgoingBitrate)),"
                    + "\"senderPacketsSent\":\(senderPacketsSent),"
                    + "\"senderTotalPacketSendDelay\":"
                    + "\(startupClarityJSONNumber(senderStatistics?.outboundVideo?.totalPacketSendDelay)),"
                    + "\"rendererFrameCount\":\(observations.count)}"
            )

            let firstObservation = try XCTUnwrap(first)
            XCTAssertEqual(firstObservation.width, variant.expectedWidth)
            XCTAssertEqual(firstObservation.height, variant.expectedHeight)
            XCTAssertGreaterThan(firstObservation.receivedAt, captureStartedAt)
            XCTAssertGreaterThan(finalBytes, baselineBytes)
            XCTAssertGreaterThan(finalFrames, 0)
            XCTAssertNotNil(firstBytesAt)
            XCTAssertTrue(
                observations.allSatisfy { observation in
                    observation.width > 0
                        && observation.height > 0
                        && observation.signedIdealNormalizedContrast.values.allSatisfy {
                            $0.isFinite && (-2...2).contains($0)
                        }
                }
            )
            XCTAssertNil(lastStatistics.inboundAudio)
            XCTAssertNil(lastStatistics.outboundAudio)
            let relayErrors = await state.relayErrors
            XCTAssertEqual(relayErrors, [])
        } catch {
            await startupClarityClose(
                host: host,
                viewer: viewer,
                relays: relays,
                pump: pump,
                track: track,
                renderer: renderer
            )
            throw error
        }

        await startupClarityClose(
            host: host,
            viewer: viewer,
            relays: relays,
            pump: pump,
            track: track,
            renderer: renderer
        )
    }
}
#endif
