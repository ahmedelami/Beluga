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

enum StartupVideoDefaultPacingEstimatorProfile: String, CaseIterable, Sendable {
    case control, alrProbeCap

    var pacerMode: StartupVideoPacerMode { .sdkDefault }
    var holdDelayGrowthInALR: Bool { self == .alrProbeCap }
    var skipProbesBelowCurrentEstimate: Bool { self == .alrProbeCap }

    static func validateProbeDurationFixture(milliseconds: Int,
                                             oneWayDelayMilliseconds: Int?, followsPolicyFPS: Bool,
                                             hasCapacityExperiment: Bool, hasOtherObserver: Bool) throws {
        guard [15, 40].contains(milliseconds), !hasOtherObserver else {
            throw WebRTCTransportError.nativeFailure("Probe duration cannot borrow another delayed cohort")
        }
        try Self.alrProbeCap.validateOriginalDelayedFixture(
            oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
            hasCapacityExperiment: hasCapacityExperiment)
    }

    func validateOriginalDelayedFixture(oneWayDelayMilliseconds: Int?, followsPolicyFPS: Bool,
                                        hasCapacityExperiment: Bool) throws {
        guard oneWayDelayMilliseconds == 50, followsPolicyFPS, !hasCapacityExperiment else {
            throw WebRTCTransportError.nativeFailure("Default-pacing observer must retain the original delayed fixture")
        }
    }
}

private struct StartupCapacityExperiment: Sendable {
    let bitsPerSecond: UInt64
    var movingContent = false
    var warmupMilliseconds = 0
    var shapeInitialCapture = false
    var capacityDropAndRecovery = false
    var spatialRecoveryEnabled = false
    var requiresSpatialRecovery = false
    var secondCapacityDrop = false
    var collectTrafficTiming = false
    var collectReceiverTiming = false
    var pacerMode: StartupVideoPacerMode?
    var pacingFactor: Double?
    var observeEstimator = false
    var holdDelayGrowthInALR = false
    var skipProbesBelowCurrentEstimate = false
    var probeDurationMilliseconds: Int? = nil
    var observeEncoderBoundary = false
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

// Shared by the encoder-only diagnostic so its pixels cannot drift from this fixture.
final class StartupClarityPattern: @unchecked Sendable {
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

    init(denseContent: Bool = false, movingContent: Bool = false) throws {
        buffers = try (0..<(movingContent ? 8 : 2)).map {
            try Self.makeBuffer(cursorOn: !$0.isMultiple(of: 2),
                                denseContent: denseContent, motionPhase: movingContent ? $0 : 0)
        }
    }

    private static func makeBuffer(
        cursorOn: Bool,
        denseContent: Bool,
        motionPhase: Int
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
                    denseContent: denseContent,
                    motionPhase: motionPhase
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
        denseContent: Bool,
        motionPhase: Int
    ) -> UInt8 {
        if y < 96 {
            if (16..<80).contains(y), (48..<528).contains(x) {
                return (motionPhase & (1 << ((x - 48) / 160))) == 0 ? dark : light
            }
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
                return densePhotoValue(x: x + motionPhase * 12, y: y)
            }
            if (denseTextLeft..<denseRight).contains(x) {
                return denseTextValue(x: x, y: y + motionPhase * 8)
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

final class StartupClarityRenderer:
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
        let callbackStartedAt: ContinuousClock.Instant
        let receivedAt: ContinuousClock.Instant
        let timestamp: Int32
        let width: Int
        let height: Int
        let signedIdealNormalizedContrast: Contrast
        let denseLuma: [Double]
        let motionPhase: Int?
    }

    private let lock = NSLock()
    private var timestamps: Set<Int32> = []
    private var observations: [Observation] = []

    func setSize(_: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let callbackStartedAt = ContinuousClock.now
        let i420 = frame.buffer.toI420()
        let observation = Observation(
            callbackStartedAt: callbackStartedAt,
            receivedAt: .now,
            timestamp: frame.timeStamp,
            width: Int(frame.width),
            height: Int(frame.height),
            signedIdealNormalizedContrast: Self.measureContrast(i420),
            denseLuma: stride(from: 1_140, to: 1_820, by: 40).flatMap { y in
                stride(from: 64, to: 1_020, by: 40).map { x in
                    Self.luma(i420, sourceX: x, sourceY: y)
                }
            },
            motionPhase: Self.readMotionPhase(i420)
        )
        lock.withLock {
            guard observations.count < 1_024,
                  timestamps.insert(frame.timeStamp).inserted else { return }
            observations.append(observation)
        }
    }

    func snapshot() -> [Observation] {
        lock.withLock { observations }
    }

    private static func readMotionPhase(_ buffer: any LKRTCI420BufferProtocol) -> Int? {
        var phase = 0
        for bit in 0..<3 {
            let value = luma(buffer, sourceX: 128 + bit * 160, sourceY: 48)
            guard value < 80 || value > 175 else { return nil }
            if value > 175 { phase |= 1 << bit }
        }
        return phase
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
    private var submissions: [ContinuousClock.Instant] = []

    func update(_ newFPS: Int) { lock.withLock { fps = min(60, max(1, newFPS)) } }
    var interval: Duration { lock.withLock { .nanoseconds(1_000_000_000 / fps) } }
    func record(_ instant: ContinuousClock.Instant) {
        lock.withLock { if submissions.count < 1_024 { submissions.append(instant) } }
    }
    func snapshot() -> [ContinuousClock.Instant] { lock.withLock { submissions } }
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

    func testSerializedAmpleColdStill() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000))
    }

    func testSerializedAmpleWarmStill() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, warmupMilliseconds: 2_000))
    }

    func testSerializedWeakColdStill() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000))
    }

    func testSerializedWeakWarmStill() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, warmupMilliseconds: 2_000))
    }

    func testSerializedAmpleColdMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true))
    }

    func testSerializedAmpleWarmMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   warmupMilliseconds: 2_000))
    }

    func testSerializedWeakColdMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true))
    }

    func testSerializedWeakWarmMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   warmupMilliseconds: 2_000))
    }

    func testSerializedAmpleShapedMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   shapeInitialCapture: true))
    }

    func testSerializedWeakShapedMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   shapeInitialCapture: true))
    }

    func testSerializedMovingCapacityDropAndRecovery() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true))
    }

    func testSpatialRecoveryDisabledMovingDropAndRecovery() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true))
    }

    func testSpatialRecoveryEnabledMovingDropAndRecovery() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
                                   requiresSpatialRecovery: true))
    }

    func testSpatialRecoveryEnabledMovingSecondCapacityDrop() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
                                   requiresSpatialRecovery: true, secondCapacityDrop: true))
    }

    func testSpatialRecoveryEnabledSteadyAmpleMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   spatialRecoveryEnabled: true))
    }

    func testSpatialRecoveryEnabledSteadyWeakMoving() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   spatialRecoveryEnabled: true))
    }

    func testSteadyWeakPacketTimingAndPolicyShadow() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true))
    }

    func testPacerNativeConfigurationReadbackAndIsolation() async throws {
        let bridge = try StartupVideoPacerBridge()
        for mode in [StartupVideoPacerMode.sdkDefault, .zeroBurst, .twentyMillisecondBurst, .sdkDefault] {
            let host: WebRTCPeer
            do {
                host = try bridge.makeHost(configuration: WebRTCTransportConfiguration(
                    role: .host, iceServers: [], maximumVideoBitrate: 50_000_000,
                    mediaTopology: .videoControlOnly, supportsAudioClientDiagnostics: false), mode: mode)
            } catch {
                XCTFail("Actual native pacing construction/readback rejected: \(error)")
                return
            }
            XCTAssertNil(host.externalAudioCapturer)
            await host.close(reason: .normal)
        }
        XCTAssertEqual(bridge.verifiedCount, 4)
        print("PACER_NATIVE_CONFIGURATION_READBACK_PASS peers=4 artifact=\(bridge.artifactSHA256)")
        fflush(nil)
    }

    func testDefaultBurstSteadyWeakPacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true,
                                   pacerMode: .sdkDefault))
    }

    func testPacerNativeWorkerThreadBinding() async throws {
        let bridge = try StartupVideoPacerBridge()
        let host = try bridge.makeHost(configuration: WebRTCTransportConfiguration(
            role: .host, iceServers: [], mediaTopology: .videoControlOnly,
            supportsAudioClientDiagnostics: false), mode: .twentyMillisecondBurst)
        let viewer: WebRTCPeer
        do {
            viewer = try WebRTCPeer(configuration: .init(
                role: .viewer, iceServers: [], mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false))
        } catch { await host.close(reason: .normal); throw error }
        do {
            let hostID = try await bridge.workerThreadID(of: host)
            let viewerID = try await bridge.workerThreadID(of: viewer)
            let repeatedHostID = try await bridge.workerThreadID(of: host)
            let repeatedViewerID = try await bridge.workerThreadID(of: viewer)
            XCTAssertNotEqual(hostID, viewerID, "Host and viewer need independently bound worker threads")
            XCTAssertEqual(hostID, repeatedHostID)
            XCTAssertEqual(viewerID, repeatedViewerID)
            print("PACER_NATIVE_WORKER_BINDING_PASS distinct=\(hostID != viewerID) stable=\(hostID == repeatedHostID && viewerID == repeatedViewerID)")
        } catch {
            await host.close(reason: .normal); await viewer.close(reason: .normal); throw error
        }
        await host.close(reason: .normal)
        await viewer.close(reason: .normal)
    }

    #if DEBUG
    func testNativeEstimatorObserverConstruction() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process estimator experiment")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverConstruction",
            observeEstimator: true) {
            let bridge = try StartupVideoPacerBridge(observeEstimator: true)
            defer { withExtendedLifetime(bridge) {} }
            let host = try bridge.makeHost(configuration: WebRTCTransportConfiguration(
                role: .host, iceServers: [], mediaTopology: .videoControlOnly,
                supportsAudioClientDiagnostics: false), mode: .twentyMillisecondBurst)
            do {
                let workerID = try await bridge.workerThreadID(of: host)
                XCTAssertNotEqual(workerID, 0)
                XCTAssertNil(host.externalAudioCapturer)
                XCTAssertNil(host.macDecodedAudioSource)
                let snapshot = try bridge.estimatorSnapshot()
                XCTAssertEqual(snapshot.schemaVersion, 2, "Require the probe-capable native projection")
                XCTAssertEqual(snapshot.factoryRequestCount, 1)
                XCTAssertEqual(snapshot.interceptionCount, 1, "Must intercept the actual SDK initializer")
                XCTAssertEqual(snapshot.controllerCreateCount, 0, "Controller must await native network admission")
                XCTAssertEqual(snapshot.selectorFailureCount, 0)
                XCTAssertEqual(snapshot.lifetimeFailureCount, 0)
                XCTAssertEqual(snapshot.unexpectedFactoryCount, 0)
                XCTAssertEqual(snapshot.events.count, 0)
                print("ESTIMATOR_NATIVE_CONSTRUCTION_PASS interceptions=\(snapshot.interceptionCount) workerBound=\(workerID != 0)")
                fflush(nil)
            } catch { await host.close(reason: .normal); throw error }
            await host.close(reason: .normal)
            let closed = try bridge.estimatorSnapshot()
            XCTAssertEqual(closed.liveLoggerCount, 0)
            XCTAssertEqual(closed.loggerCreatedCount, 0)
            XCTAssertEqual(closed.loggerDestroyedCount, 0)
            XCTAssertEqual(closed.lifetimeFailureCount, 0)
        }
    }

    func testNativeEstimatorObserverWeak() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process estimator experiment")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverWeak",
            observeEstimator: true) {
            try await self.runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                spatialRecoveryEnabled: true, collectTrafficTiming: true,
                pacerMode: .twentyMillisecondBurst, pacingFactor: 1, observeEstimator: true))
        }
    }

    func testNativeEstimatorObserverDelayedDynamic() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process baseline estimator diagnostic")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverDelayedDynamic",
            observeEstimator: true) {
            try await self.runDenseProductionPolicyNativeLoopback(oneWayDelayMilliseconds: 50,
                followsPolicyFPS: true, observeBaselineEstimator: true)
        }
    }

    func testNativeEstimatorALRGrowthHoldWeak() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process ALR growth hold experiment")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldWeak",
            observeEstimator: true, holdDelayGrowthInALR: true) {
            try await self.runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                spatialRecoveryEnabled: true, collectTrafficTiming: true,
                pacerMode: .twentyMillisecondBurst, pacingFactor: 1,
                observeEstimator: true, holdDelayGrowthInALR: true))
        }
    }

    func testNativeEstimatorDefaultPacingDelayedDynamicControl() async throws {
        try await runDefaultPacingDelayed(.control,
            selectedTest: "testNativeEstimatorDefaultPacingDelayedDynamicControl")
    }

    func testNativeEstimatorALRProbeCapDefaultPacingDelayedDynamic() async throws {
        try await runDefaultPacingDelayed(.alrProbeCap,
            selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingDelayedDynamic")
    }

    func testNativeEstimatorALRProbeDuration15DelayedControl() async throws {
        try await runProbeDurationDelayed(.control15,
            selectedTest: "testNativeEstimatorALRProbeDuration15DelayedControl")
    }

    func testNativeEstimatorALRProbeDuration40DelayedCandidate() async throws {
        try await runProbeDurationDelayed(.candidate40,
            selectedTest: "testNativeEstimatorALRProbeDuration40DelayedCandidate")
    }

    func testNativeEstimatorALRProbeDuration15MovingWeakControl() async throws {
        try await runProbeDurationMovingWeak(.control15,
            selectedTest: "testNativeEstimatorALRProbeDuration15MovingWeakControl")
    }

    func testNativeEstimatorALRProbeDuration40MovingWeakCandidate() async throws {
        try await runProbeDurationMovingWeak(.candidate40,
            selectedTest: "testNativeEstimatorALRProbeDuration40MovingWeakCandidate")
    }

    func testNativeEstimatorALRProbeDuration15MovingRecoveryControl() async throws {
        try await runProbeDurationMovingRecovery(.control15,
            selectedTest: "testNativeEstimatorALRProbeDuration15MovingRecoveryControl")
    }

    func testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate() async throws {
        try await runProbeDurationMovingRecovery(.candidate40,
            selectedTest: "testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate")
    }

    func testNativeEncoderBoundaryMovingRecoveryDiagnostic() async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process encoder boundary diagnostic")
        }
        let experiment = StartupCapacityExperiment(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true, requiresSpatialRecovery: true,
            collectTrafficTiming: true, collectReceiverTiming: true,
            pacerMode: .sdkDefault, pacingFactor: 1, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationMilliseconds: 15, observeEncoderBoundary: true)
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEncoderBoundaryMovingRecoveryDiagnostic",
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationExperiment: .control15, observeEncoderBoundary: true) {
            try await self.runCapacity(experiment)
        }
    }

    private func runProbeDurationMovingRecovery(_ duration: WebRTCStartupProbeDurationExperiment,
                                                selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process moving-recovery probe-duration comparison")
        }
        let experiment = StartupCapacityExperiment(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true, requiresSpatialRecovery: true,
            collectTrafficTiming: true, collectReceiverTiming: true,
            pacerMode: .sdkDefault, pacingFactor: 1, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationMilliseconds: duration == .control15 ? 15 : 40)
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationExperiment: duration) {
            try await self.runCapacity(experiment)
        }
    }

    private func runProbeDurationMovingWeak(_ duration: WebRTCStartupProbeDurationExperiment,
                                            selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process moving-weak probe-duration comparison")
        }
        let experiment = StartupCapacityExperiment(bitsPerSecond: 800_000, movingContent: true,
            spatialRecoveryEnabled: true, collectTrafficTiming: true, collectReceiverTiming: true,
            pacerMode: .sdkDefault, pacingFactor: 1, observeEstimator: true,
            holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationMilliseconds: duration == .control15 ? 15 : 40)
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationExperiment: duration) {
            try await self.runCapacity(experiment)
        }
    }

    private func runProbeDurationDelayed(_ duration: WebRTCStartupProbeDurationExperiment,
                                         selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process probe-duration comparison")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            probeDurationExperiment: duration) {
            try await self.runDenseProductionPolicyNativeLoopback(oneWayDelayMilliseconds: 50,
                followsPolicyFPS: true, probeDurationMilliseconds: duration == .control15 ? 15 : 40)
        }
    }

    private func runDefaultPacingDelayed(_ profile: StartupVideoDefaultPacingEstimatorProfile,
                                         selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process default-pacing cohort")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: profile.holdDelayGrowthInALR,
            skipProbesBelowCurrentEstimate: profile.skipProbesBelowCurrentEstimate,
            defaultPacingCohort: true) {
            try await self.runDenseProductionPolicyNativeLoopback(oneWayDelayMilliseconds: 50,
                followsPolicyFPS: true, defaultPacingEstimatorProfile: profile)
        }
    }

    func testNativeEstimatorALRProbeCapDefaultPacingWeak() async throws {
        try await runDefaultPacingALRProbeCap(.init(bitsPerSecond: 800_000, movingContent: true,
            spatialRecoveryEnabled: true), selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingWeak")
    }

    func testNativeEstimatorALRProbeCapDefaultPacingDisabledRecovery() async throws {
        try await runDefaultPacingALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true), selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingDisabledRecovery")
    }

    func testNativeEstimatorALRProbeCapDefaultPacingEnabledRecovery() async throws {
        try await runDefaultPacingALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true, requiresSpatialRecovery: true),
            selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingEnabledRecovery")
    }

    func testNativeEstimatorALRProbeCapDefaultPacingSecondDrop() async throws {
        try await runDefaultPacingALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
            requiresSpatialRecovery: true, secondCapacityDrop: true),
            selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingSecondDrop")
    }

    func testNativeEstimatorALRProbeCapDefaultPacingAmple() async throws {
        try await runDefaultPacingALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            spatialRecoveryEnabled: true), selectedTest: "testNativeEstimatorALRProbeCapDefaultPacingAmple")
    }

    private func runDefaultPacingALRProbeCap(_ experiment: StartupCapacityExperiment,
                                            selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process default-pacing cohort")
        }
        var observed = experiment
        observed.collectTrafficTiming = true
        observed.collectReceiverTiming = true
        observed.pacerMode = .sdkDefault
        observed.pacingFactor = 1
        observed.observeEstimator = true
        observed.holdDelayGrowthInALR = true
        observed.skipProbesBelowCurrentEstimate = true
        let configured = observed
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true,
            defaultPacingCohort: true) {
            try await self.runCapacity(configured)
        }
    }

    func testNativeEstimatorALRGrowthHoldDisabledRecovery() async throws {
        try await runALRGrowthHold(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true), selectedTest: "testNativeEstimatorALRGrowthHoldDisabledRecovery")
    }

    func testNativeEstimatorALRGrowthHoldEnabledRecovery() async throws {
        try await runALRGrowthHold(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true, requiresSpatialRecovery: true),
            selectedTest: "testNativeEstimatorALRGrowthHoldEnabledRecovery")
    }

    func testNativeEstimatorALRGrowthHoldSecondDrop() async throws {
        try await runALRGrowthHold(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
            requiresSpatialRecovery: true, secondCapacityDrop: true),
            selectedTest: "testNativeEstimatorALRGrowthHoldSecondDrop")
    }

    func testNativeEstimatorALRGrowthHoldAmple() async throws {
        try await runALRGrowthHold(.init(bitsPerSecond: 8_000_000, movingContent: true,
            spatialRecoveryEnabled: true), selectedTest: "testNativeEstimatorALRGrowthHoldAmple")
    }

    private func runALRGrowthHold(_ experiment: StartupCapacityExperiment, selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process ALR growth hold experiment")
        }
        var observed = experiment
        observed.collectTrafficTiming = true
        observed.pacerMode = .twentyMillisecondBurst
        observed.pacingFactor = 1
        observed.observeEstimator = true
        observed.holdDelayGrowthInALR = true
        let configured = observed
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true) {
            try await self.runCapacity(configured)
        }
    }

    func testNativeEstimatorALRProbeCapWeak() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 800_000, movingContent: true,
            spatialRecoveryEnabled: true), selectedTest: "testNativeEstimatorALRProbeCapWeak")
    }

    func testNativeEstimatorALRProbeCapDisabledRecovery() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true), selectedTest: "testNativeEstimatorALRProbeCapDisabledRecovery")
    }

    func testNativeEstimatorALRProbeCapEnabledRecovery() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true, requiresSpatialRecovery: true),
            selectedTest: "testNativeEstimatorALRProbeCapEnabledRecovery")
    }

    func testNativeEstimatorALRProbeCapSecondDrop() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
            requiresSpatialRecovery: true, secondCapacityDrop: true),
            selectedTest: "testNativeEstimatorALRProbeCapSecondDrop")
    }

    func testNativeEstimatorALRProbeCapAmple() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            spatialRecoveryEnabled: true), selectedTest: "testNativeEstimatorALRProbeCapAmple")
    }

    func testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic() async throws {
        try await runALRProbeCap(.init(bitsPerSecond: 8_000_000, movingContent: true,
            capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
            requiresSpatialRecovery: true, secondCapacityDrop: true, collectReceiverTiming: true),
            selectedTest: "testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic")
    }

    private func runALRProbeCap(_ experiment: StartupCapacityExperiment, selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process ALR probe cap experiment")
        }
        var observed = experiment
        observed.collectTrafficTiming = true
        observed.pacerMode = .twentyMillisecondBurst
        observed.pacingFactor = 1
        observed.observeEstimator = true
        observed.holdDelayGrowthInALR = true
        observed.skipProbesBelowCurrentEstimate = true
        let configured = observed
        try await WebRTCPeer.withStartupPacingExperimentForTesting(factor: .control,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest,
            observeEstimator: true, holdDelayGrowthInALR: true, skipProbesBelowCurrentEstimate: true) {
            try await self.runCapacity(configured)
        }
    }

    func testPacingFactorControlWeak() async throws {
        try await runPacingFactorWeak(.control, selectedTest: "testPacingFactorControlWeak")
    }

    func testPacingFactorCandidateWeak() async throws {
        try await runPacingFactorWeak(.candidate, selectedTest: "testPacingFactorCandidateWeak")
    }

    private func runPacingFactorWeak(_ factor: WebRTCStartupPacingFactor, selectedTest: String) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] != nil else {
            throw XCTSkip("Opt-in fresh-process pacing-factor experiment")
        }
        try await WebRTCPeer.withStartupPacingExperimentForTesting(
            factor: factor,
            selectedTest: "CaptureServerTests.WebRTCStartupClarityExperimentTests/" + selectedTest
        ) {
            try await self.runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                            spatialRecoveryEnabled: true, collectTrafficTiming: true,
                                            pacerMode: .twentyMillisecondBurst, pacingFactor: factor.value))
        }
    }
    #endif

    func testZeroBurstSteadyWeakPacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true,
                                   pacerMode: .zeroBurst))
    }

    func testTwentyMillisecondBurstSteadyWeakPacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 800_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true,
                                   pacerMode: .twentyMillisecondBurst))
    }

    func testZeroBurstSteadyAmplePacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true,
                                   pacerMode: .zeroBurst))
    }

    func testZeroBurstDropRecoveryPacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
                                   requiresSpatialRecovery: true, collectTrafficTiming: true,
                                   pacerMode: .zeroBurst))
    }

    func testZeroBurstSecondDropPacketTiming() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
                                   requiresSpatialRecovery: true, secondCapacityDrop: true,
                                   collectTrafficTiming: true, pacerMode: .zeroBurst))
    }

    func testSteadyAmplePacketTimingAndPolicyShadow() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   spatialRecoveryEnabled: true, collectTrafficTiming: true))
    }

    func testDropRecoveryPacketTimingAndPolicyShadow() async throws {
        try await runCapacity(.init(bitsPerSecond: 8_000_000, movingContent: true,
                                   capacityDropAndRecovery: true, spatialRecoveryEnabled: true,
                                   requiresSpatialRecovery: true, collectTrafficTiming: true))
    }

    private static func advanceCapacityPolicy(
        _ policy: inout WorldwideScreenVideoAdaptationPolicy,
        report: WebRTCScreenVideoStatisticsReport?, capacityOnly: Bool,
        peerGeneration: UInt64, at observedAt: ContinuousClock.Instant,
        diagnostics: ((WorldwideScreenCapacityProbeDiagnostics) -> Void)? = nil
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        guard let report else {
            return policy.expireApplicationLimitedProbeWithoutReport(
                peerGeneration: peerGeneration, isCaptureActive: true, observedAt: observedAt)
        }
        let snapshot = report.nativeSnapshot
        if capacityOnly {
            return policy.updateCapacityProbe(
                peerGeneration: peerGeneration, isCaptureActive: true,
                availableOutgoingBitrateBps: snapshot.availableOutgoingBitrate,
                currentRoundTripTimeSeconds: snapshot.currentRoundTripTime,
                roundTripTimeObservation: snapshot.roundTripTimeObservation,
                collectionSequence: snapshot.collectionSequence,
                nativeReportTimestampMicroseconds: report.nativeReportTimestampMicroseconds,
                selectedRoute: snapshot.route,
                outboundVideoPacketsSent: snapshot.outboundVideo?.packets,
                outboundVideoTotalPacketSendDelaySeconds: snapshot.outboundVideo?.totalPacketSendDelay,
                observedAt: observedAt, diagnostics: diagnostics)
        }
        return policy.update(
            peerGeneration: peerGeneration, isCaptureActive: true,
            availableOutgoingBitrateBps: snapshot.availableOutgoingBitrate,
            currentRoundTripTimeSeconds: snapshot.currentRoundTripTime,
            roundTripTimeObservation: snapshot.roundTripTimeObservation,
            collectionSequence: snapshot.collectionSequence,
            requireRoundTripTimeObservation: true,
            selectedRoute: snapshot.route,
            outboundVideoPacketsSent: snapshot.outboundVideo?.packets,
            outboundVideoTotalPacketSendDelaySeconds: snapshot.outboundVideo?.totalPacketSendDelay,
            nativeReportTimestampMicroseconds: report.nativeReportTimestampMicroseconds,
            spatialRecoveryFrames: snapshot.outboundVideo.flatMap { video in
                guard let frames = video.framesEncodedOrDecoded,
                      let width = video.frameWidth, let height = video.frameHeight else { return nil }
                return WorldwideScreenSpatialRecoveryFrameEvidence(
                    encodedFrames: frames, encodedWidth: width, encodedHeight: height,
                    sourceWidth: StartupClarityPattern.width, sourceHeight: StartupClarityPattern.height)
            }, observedAt: observedAt)
    }

    private func runCapacity(_ experiment: StartupCapacityExperiment) async throws {
        try await runDenseProductionPolicyNativeLoopback(
            oneWayDelayMilliseconds: 2, followsPolicyFPS: true, experiment: experiment)
    }

    private static func isFullPixelSharp(_ frame: StartupClarityRenderer.Observation) -> Bool {
        frame.width == StartupClarityPattern.width && frame.height == StartupClarityPattern.height
            && frame.signedIdealNormalizedContrast.minimum > 0.9
    }

    private static func changedContentCount(_ frames: [StartupClarityRenderer.Observation]) -> Int {
        zip(frames, frames.dropFirst()).filter { before, after in
            guard before.width == after.width, before.height == after.height,
                  let firstPhase = before.motionPhase, let secondPhase = after.motionPhase,
                  firstPhase != secondPhase else { return false }
            var difference = 0.0
            for (old, new) in zip(before.denseLuma, after.denseLuma) { difference += abs(old - new) }
            return difference / Double(after.denseLuma.count) > 4
        }.count
    }

    private static func hasSustainedSpatialRecovery(
        _ observations: [StartupClarityRenderer.Observation],
        after restoredAt: ContinuousClock.Instant
    ) -> Bool {
        guard let first = observations.first(where: {
            $0.receivedAt >= restoredAt && isFullPixelSharp($0)
        }) else { return false }
        let end = first.receivedAt.advanced(by: .seconds(2))
        guard first.receivedAt <= restoredAt.advanced(by: .seconds(4)),
              let boundary = observations.first(where: { $0.receivedAt >= end }),
              boundary.receivedAt <= end.advanced(by: .milliseconds(500)) else { return false }
        let sustained = observations.filter { $0.receivedAt >= first.receivedAt && $0.receivedAt <= end }
        guard sustained.allSatisfy(isFullPixelSharp), changedContentCount(sustained) >= 8 else { return false }
        let includingBoundary = observations.filter {
            $0.receivedAt >= first.receivedAt && $0.receivedAt <= boundary.receivedAt
        }
        guard includingBoundary.allSatisfy(isFullPixelSharp) else { return false }
        return zip(includingBoundary, includingBoundary.dropFirst()).allSatisfy { before, after in
            before.receivedAt.duration(to: after.receivedAt) <= .milliseconds(500)
        }
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
        oneWayDelayMilliseconds: Int? = nil, followsPolicyFPS: Bool = false,
        experiment: StartupCapacityExperiment? = nil, observeBaselineEstimator: Bool = false,
        defaultPacingEstimatorProfile: StartupVideoDefaultPacingEstimatorProfile? = nil,
        probeDurationMilliseconds: Int? = nil
    ) async throws {
        guard ProcessInfo.processInfo.environment[
            "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"
        ] == "1" else {
            throw XCTSkip("Opt-in fresh-process startup clarity characterization")
        }

        guard !observeBaselineEstimator || (experiment == nil && followsPolicyFPS
                                            && oneWayDelayMilliseconds == 50
                                            && defaultPacingEstimatorProfile == nil
                                            && probeDurationMilliseconds == nil) else {
            throw WebRTCTransportError.nativeFailure("Baseline observer must retain the original delayed fixture")
        }
        try defaultPacingEstimatorProfile?.validateOriginalDelayedFixture(
            oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
            hasCapacityExperiment: experiment != nil)
        if let probeDurationMilliseconds {
            try StartupVideoDefaultPacingEstimatorProfile.validateProbeDurationFixture(
                milliseconds: probeDurationMilliseconds,
                oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
                hasCapacityExperiment: experiment != nil,
                hasOtherObserver: defaultPacingEstimatorProfile != nil || observeBaselineEstimator)
        }
        guard experiment?.observeEncoderBoundary != true || experiment?.probeDurationMilliseconds != nil else {
            throw WebRTCTransportError.nativeFailure("Encoder boundary trace requires its exact duration profile")
        }
        if let experiment, let duration = experiment.probeDurationMilliseconds {
            if experiment.observeEncoderBoundary {
                try StartupVideoEncoderBoundaryProfile.validate(
                    durationMilliseconds: duration, bitsPerSecond: experiment.bitsPerSecond,
                    oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
                    movingContent: experiment.movingContent, warmupMilliseconds: experiment.warmupMilliseconds,
                    shapeInitialCapture: experiment.shapeInitialCapture,
                    capacityDropAndRecovery: experiment.capacityDropAndRecovery,
                    spatialRecoveryEnabled: experiment.spatialRecoveryEnabled,
                    requiresSpatialRecovery: experiment.requiresSpatialRecovery,
                    secondCapacityDrop: experiment.secondCapacityDrop,
                    collectTrafficTiming: experiment.collectTrafficTiming,
                    collectReceiverTiming: experiment.collectReceiverTiming,
                    pacerMode: experiment.pacerMode, pacingFactor: experiment.pacingFactor,
                    observeEstimator: experiment.observeEstimator,
                    holdDelayGrowthInALR: experiment.holdDelayGrowthInALR,
                    skipProbesBelowCurrentEstimate: experiment.skipProbesBelowCurrentEstimate,
                    hasOtherObserver: probeDurationMilliseconds != nil
                        || defaultPacingEstimatorProfile != nil || observeBaselineEstimator)
            } else if experiment.requiresSpatialRecovery {
                try StartupVideoProbeDurationMovingRecoveryProfile.validate(
                    durationMilliseconds: duration, bitsPerSecond: experiment.bitsPerSecond,
                    oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
                    movingContent: experiment.movingContent, warmupMilliseconds: experiment.warmupMilliseconds,
                    shapeInitialCapture: experiment.shapeInitialCapture,
                    capacityDropAndRecovery: experiment.capacityDropAndRecovery,
                    spatialRecoveryEnabled: experiment.spatialRecoveryEnabled,
                    requiresSpatialRecovery: experiment.requiresSpatialRecovery,
                    secondCapacityDrop: experiment.secondCapacityDrop,
                    collectTrafficTiming: experiment.collectTrafficTiming,
                    collectReceiverTiming: experiment.collectReceiverTiming,
                    pacerMode: experiment.pacerMode, pacingFactor: experiment.pacingFactor,
                    observeEstimator: experiment.observeEstimator,
                    holdDelayGrowthInALR: experiment.holdDelayGrowthInALR,
                    skipProbesBelowCurrentEstimate: experiment.skipProbesBelowCurrentEstimate,
                    hasOtherObserver: probeDurationMilliseconds != nil
                        || defaultPacingEstimatorProfile != nil || observeBaselineEstimator)
            } else {
                try StartupVideoProbeDurationMovingWeakProfile.validate(
                    durationMilliseconds: duration, bitsPerSecond: experiment.bitsPerSecond,
                    oneWayDelayMilliseconds: oneWayDelayMilliseconds, followsPolicyFPS: followsPolicyFPS,
                    movingContent: experiment.movingContent, warmupMilliseconds: experiment.warmupMilliseconds,
                    shapeInitialCapture: experiment.shapeInitialCapture,
                    capacityDropAndRecovery: experiment.capacityDropAndRecovery,
                    spatialRecoveryEnabled: experiment.spatialRecoveryEnabled,
                    requiresSpatialRecovery: experiment.requiresSpatialRecovery,
                    secondCapacityDrop: experiment.secondCapacityDrop,
                    collectTrafficTiming: experiment.collectTrafficTiming,
                    collectReceiverTiming: experiment.collectReceiverTiming,
                    pacerMode: experiment.pacerMode, pacingFactor: experiment.pacingFactor,
                    observeEstimator: experiment.observeEstimator,
                    holdDelayGrowthInALR: experiment.holdDelayGrowthInALR,
                    skipProbesBelowCurrentEstimate: experiment.skipProbesBelowCurrentEstimate,
                    hasOtherObserver: probeDurationMilliseconds != nil
                        || defaultPacingEstimatorProfile != nil || observeBaselineEstimator)
            }
        }
        let effectiveProbeDurationMilliseconds = probeDurationMilliseconds ?? experiment?.probeDurationMilliseconds
        let delayedEstimatorProfile = defaultPacingEstimatorProfile
            ?? (probeDurationMilliseconds != nil ? .alrProbeCap : (observeBaselineEstimator ? .control : nil))

        // XCTest writes lifecycle records on stderr. Flush the larger stdout JSON before
        // returning, so buffering cannot splice its pass record into a diagnostic line.
        defer { fflush(nil) }

        let configuredTotalBitrateBps = 50_000_000
        let peerGeneration: UInt64 = 1
        let showEpoch: UInt64 = 1
        let showReservedAt = ContinuousClock.now
        var policy = WorldwideScreenVideoAdaptationPolicy(
            configuredTotalRTPBitrateBps: configuredTotalBitrateBps,
            baseFramesPerSecond: 60,
            spatialRecoveryEnabled: experiment?.spatialRecoveryEnabled ?? true
        )
        _ = policy.bind(toPeerGeneration: peerGeneration)
        policy.beginFloorRecoveryVisibility(
            peerGeneration: peerGeneration,
            showEpoch: showEpoch, at: showReservedAt
        )
        var shadowPolicy: WorldwideScreenVideoAdaptationPolicy?
        var shadowComparison = StartupVideoPolicyShadow()
        if experiment?.collectTrafficTiming == true {
            var shadow = WorldwideScreenVideoAdaptationPolicy(
                configuredTotalRTPBitrateBps: configuredTotalBitrateBps,
                baseFramesPerSecond: 60, spatialRecoveryEnabled: false)
            _ = shadow.bind(toPeerGeneration: peerGeneration)
            shadow.beginFloorRecoveryVisibility(
                peerGeneration: peerGeneration, showEpoch: showEpoch, at: showReservedAt)
            shadowPolicy = shadow
            shadowComparison.compare(candidate: policy, shadow: shadow,
                                     stage: .initial, at: showReservedAt)
            if !shadowComparison.isComparing { shadowPolicy = nil }
        }
        var appliedRecommendation = policy.currentRecommendation

        // Precompute before ICE starts: generating the fixture must not accidentally warm
        // the estimator or count as transport/first-frame latency in the cold comparison.
        let preparedPattern = try experiment.map {
            try StartupClarityPattern(denseContent: true, movingContent: $0.movingContent)
        }

        let hostConfiguration = WebRTCTransportConfiguration(
            role: .host, iceServers: [], maximumVideoBitrate: configuredTotalBitrateBps,
            mediaTopology: .videoControlOnly, supportsAudioClientDiagnostics: false
        )
        let pacerMode: StartupVideoPacerMode? = delayedEstimatorProfile?.pacerMode ?? experiment?.pacerMode
        let pacingFactor: Double? = delayedEstimatorProfile != nil ? 1 : experiment?.pacingFactor
        let observeEstimator = delayedEstimatorProfile != nil || experiment?.observeEstimator == true
        let qpOwnerHook = try StartupVideoQPOwnerHook.requested(eligible: experiment?.observeEncoderBoundary == true)
        let encoderBoundaryTrace = experiment?.observeEncoderBoundary == true
            ? StartupVideoEncoderBoundaryTrace() : nil
        let nativeEncoderLogObserver = experiment?.observeEncoderBoundary == true
            ? StartupVideoNativeEncoderLogObserver.start() : nil
        var completedNativeTeardown = false
        defer {
            if let qpOwnerHook {
                do {
                    let snapshot = try qpOwnerHook.finish()
                    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                    print("STARTUP_VT_QP_OWNER " + String(decoding: data, as: UTF8.self))
                    if completedNativeTeardown {
                        XCTAssertTrue(snapshot["combinedVerified"] as? Bool == true,
                                      "QP diagnostic requires actual owned and retired native property observations")
                    }
                } catch { XCTFail("QP diagnostic ownership evidence failed: \(error)") }
                fflush(nil)
            }
            if let nativeEncoderLogObserver {
                let snapshot = nativeEncoderLogObserver.finish()
                if let data = try? JSONEncoder().encode(snapshot), let json = String(data: data, encoding: .utf8) {
                    print("STARTUP_NATIVE_ENCODER_LOG " + json)
                } else {
                    XCTFail("Native encoder log observations must encode as bounded scalars")
                }
                if completedNativeTeardown {
                    XCTAssertTrue(snapshot.isVerified, "Native encoder logging must remain structurally valid")
                }
                fflush(nil)
            }
            if let encoderBoundaryTrace {
                let snapshot = encoderBoundaryTrace.finish()
                if let data = try? JSONEncoder().encode(snapshot), let json = String(data: data, encoding: .utf8) {
                    print("STARTUP_ENCODER_BOUNDARY_TRACE " + json)
                } else {
                    XCTFail("Encoder boundary snapshot must encode without nonfinite or payload data")
                }
                if completedNativeTeardown {
                    XCTAssertTrue(snapshot.isVerified, "Encoder boundary trace must contain valid owned observations")
                }
                fflush(nil)
            }
        }
        let pacerBridge = try pacerMode.map { _ in
            try StartupVideoPacerBridge(observeEstimator: observeEstimator,
                holdDelayGrowthInALR: delayedEstimatorProfile?.holdDelayGrowthInALR
                    ?? (experiment?.holdDelayGrowthInALR == true),
                skipProbesBelowCurrentEstimate: delayedEstimatorProfile?.skipProbesBelowCurrentEstimate
                    ?? (experiment?.skipProbesBelowCurrentEstimate == true),
                probeDurationMilliseconds: effectiveProbeDurationMilliseconds)
        }
        // The observer owner must outlive callbacks, blackout, and native teardown.
        defer { withExtendedLifetime(pacerBridge) {} }
        let nativePacingObserver = pacingFactor.map { _ in StartupVideoNativePacingObserver.start() }
        let host: WebRTCPeer
        if let mode = pacerMode, let pacerBridge {
            host = try pacerBridge.makeHost(configuration: hostConfiguration, mode: mode,
                encoderBoundaryTrace: encoderBoundaryTrace, qpOwnerHook: qpOwnerHook)
        } else {
            host = try WebRTCPeer(configuration: hostConfiguration)
        }
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

        let nativePacingBinding: StartupVideoNativePacingBinding?
        do {
            if nativePacingObserver != nil, let pacerBridge {
                let hostID = try await pacerBridge.workerThreadID(of: host)
                let viewerID = try await pacerBridge.workerThreadID(of: viewer)
                guard hostID != viewerID else {
                    throw WebRTCTransportError.nativeFailure("Ambiguous native pacing worker ownership")
                }
                nativePacingBinding = .init(hostWorkerID: hostID, viewerWorkerID: viewerID,
                                           registeredAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            } else { nativePacingBinding = nil }
        } catch {
            await host.close(reason: .normal)
            await viewer.close(reason: .normal)
            throw error
        }

        let networkRelay: StartupVideoDatagramRelay?
        do {
            if let oneWayDelayMilliseconds {
                networkRelay = try StartupVideoDatagramRelay(
                    oneWayDelayMilliseconds: oneWayDelayMilliseconds,
                    hostToViewerBitsPerSecond: experiment?.bitsPerSecond,
                    viewerToHostBitsPerSecond: experiment == nil ? nil : 8_000_000,
                    collectTrafficTiming: experiment?.collectTrafficTiming == true)
            } else {
                networkRelay = nil
            }
        } catch {
            await host.close(reason: .normal)
            await viewer.close(reason: .normal)
            throw error
        }

        let receiverStatisticsProbe = experiment?.collectReceiverTiming == true
            ? StartupVideoReceiverStatisticsProbe(collect: { await viewer.statisticsSnapshot() }) : nil
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
            let transportReadyAt = ContinuousClock.now
            var warmupTrace: [[String: Any]] = []
            if let experiment, experiment.warmupMilliseconds > 0 {
                let warmupDeadline = transportReadyAt.advanced(
                    by: .milliseconds(experiment.warmupMilliseconds))
                while ContinuousClock.now < warmupDeadline {
                    let report = await host.screenVideoStatisticsSnapshot(timeout: .milliseconds(100))
                    let snapshot = report?.nativeSnapshot
                    XCTAssertEqual(snapshot?.outboundVideo?.framesEncodedOrDecoded ?? 0, 0,
                                   "Pre-Show warmup cannot encode any screen pixels")
                    warmupTrace.append([
                        "elapsedMs": startupClarityMilliseconds(transportReadyAt.duration(to: .now)),
                        "bwe": snapshot?.availableOutgoingBitrate as Any? ?? NSNull(),
                        "sequence": snapshot?.collectionSequence as Any? ?? NSNull(),
                        "nativeTimestamp": report?.nativeReportTimestampMicroseconds as Any? ?? NSNull(),
                        "encodedFrames": snapshot?.outboundVideo?.framesEncodedOrDecoded as Any? ?? NSNull()
                    ])
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTAssertFalse(warmupTrace.isEmpty)
                XCTAssertTrue(renderer.snapshot().isEmpty)
            }
            let showRequestedAt = ContinuousClock.now
            _ = try await viewer.setScreenVisible(true)
            try await startupClarityWait { await state.activeAcknowledged }
            policy.activateFloorRecoveryVisibility(
                peerGeneration: peerGeneration,
                showEpoch: showEpoch
            )
            shadowPolicy?.activateFloorRecoveryVisibility(
                peerGeneration: peerGeneration, showEpoch: showEpoch)

            let capturer = try XCTUnwrap(host.externalVideoCapturer)
            capturer.adaptOutput(
                width: Int32(StartupClarityPattern.width),
                height: Int32(StartupClarityPattern.height),
                framesPerSecond: Int32(experiment?.shapeInitialCapture == true
                    ? 1 : appliedRecommendation.maximumFramesPerSecond)
            )
            let pattern = try preparedPattern ?? StartupClarityPattern(denseContent: true)
            let viewerBaseline = await viewer.statisticsSnapshot()
            let baselineBytes = viewerBaseline.inboundVideo?.bytes ?? 0
            let captureStartedAt = ContinuousClock.now
            let captureStartedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            try encoderBoundaryTrace?.arm(captureStartedAtUptimeNanoseconds: captureStartedUptimeNanoseconds)
            try nativeEncoderLogObserver?.arm(captureStartedAtUptimeNanoseconds: captureStartedUptimeNanoseconds)
            capturer.capture(
                pixelBuffer: pattern.buffers[0],
                timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds)
            )
            // Cursor-only content separates native frame cadence from a moving-photo workload.
            // The original direct loopback stays fixed at 5 fps; the delayed case follows the
            // actual applied policy so intermediate/full FPS requests must reach the decoder.
            let captureCadence = StartupClarityCaptureCadence()
            var captureFPS = experiment?.shapeInitialCapture == true
                ? 1 : appliedRecommendation.maximumFramesPerSecond
            captureCadence.update(captureFPS)
            captureCadence.record(captureStartedAt)
            let usesResponsiveCadence = experiment != nil
            let movingContent = experiment?.movingContent == true
            pump = Task.detached {
                var index = 1
                var lastSubmission = captureStartedAt
                while !Task.isCancelled {
                    do {
                        if usesResponsiveCadence {
                            // Recompute after each bounded sleep so a capture-rate change does
                            // not remain hidden behind an old one-second sleep.
                            while !Task.isCancelled {
                                let remaining = ContinuousClock.now.duration(
                                    to: lastSubmission.advanced(by: captureCadence.interval))
                                if remaining <= .zero { break }
                                try await Task.sleep(for: min(.milliseconds(10), remaining))
                            }
                        } else {
                            try await Task.sleep(for: captureCadence.interval)
                        }
                    } catch { break }
                    guard !Task.isCancelled else { break }
                    let submittedAt = ContinuousClock.now
                    let elapsedMs = startupClarityMilliseconds(captureStartedAt.duration(to: submittedAt))
                    // Source motion continues in wall time even when fewer frames are sampled.
                    let phase = movingContent ? Int(elapsedMs * 30 / 1_000) : index
                    capturer.capture(
                        pixelBuffer: pattern.buffers[phase % pattern.buffers.count],
                        timestampNanoseconds: Int64(
                            clamping: DispatchTime.now().uptimeNanoseconds
                        )
                    )
                    captureCadence.record(submittedAt)
                    lastSubmission = submittedAt
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
            let observationSeconds = experiment?.secondCapacityDrop == true ? 20
                : (experiment?.capacityDropAndRecovery == true ? 16 : (followsPolicyFPS ? 12 : 10))
            let deadline = captureStartedAt.advanced(by: .seconds(observationSeconds))
            var ordinaryReportCount = 0
            var capacityReportCount = 0
            var maximumRequestedFPS = appliedRecommendation.maximumFramesPerSecond
            var maximumNativeRTT = 0.0
            var capacityStage = 0
            var capacityTrace: [[String: Any]] = []
            var capacityChanges: [[String: Any]] = []
            var shadowMatchedStartupDisproofAtMs: Double?
            var firstCapacityDropAt: ContinuousClock.Instant?
            var capacityRestoredAt: ContinuousClock.Instant?
            var secondCapacityDropAt: ContinuousClock.Instant?
            while ContinuousClock.now < deadline {
                let wake = min(cadence.nextDeadline, deadline)
                if ContinuousClock.now < wake {
                    try await clock.sleep(until: wake)
                }
                let requestStartedAt = ContinuousClock.now
                guard requestStartedAt < deadline else { break }
                let elapsedMs = startupClarityMilliseconds(captureStartedAt.duration(to: requestStartedAt))
                if experiment?.capacityDropAndRecovery == true {
                    var stage = elapsedMs >= 8_000 ? 2 : (elapsedMs >= 4_000 ? 1 : 0)
                    if experiment?.secondCapacityDrop == true, elapsedMs >= 14_000,
                       let restoredAt = capacityRestoredAt,
                       Self.hasSustainedSpatialRecovery(renderer.snapshot(), after: restoredAt) {
                        stage = 3
                    }
                    stage = max(capacityStage, stage)
                    if stage != capacityStage {
                        let relay = try XCTUnwrap(networkRelay)
                        let bandwidth: UInt64 = stage == 1 || stage == 3 ? 800_000 : 8_000_000
                        let changeStartedAt = ContinuousClock.now
                        try relay.setBandwidth(bitsPerSecond: bandwidth, from: .host)
                        let changedAt = ContinuousClock.now
                        // Bound the real synchronous mutation instead of treating the desired
                        // 4/8/14-second schedule as the time the link actually changed.
                        XCTAssertLessThanOrEqual(startupClarityMilliseconds(
                            changeStartedAt.duration(to: changedAt)), 20)
                        if stage == 1 { firstCapacityDropAt = changedAt }
                        // Use the earlier bound for the recovery deadline: this cannot make
                        // a later actual link mutation appear to recover faster than it did.
                        if stage == 2 { capacityRestoredAt = changeStartedAt }
                        if stage == 3 { secondCapacityDropAt = changedAt }
                        capacityChanges.append([
                            "elapsedMs": startupClarityMilliseconds(captureStartedAt.duration(to: changedAt)),
                            "mutationStartedMs": startupClarityMilliseconds(captureStartedAt.duration(to: changeStartedAt)),
                            "bitsPerSecond": bandwidth, "stage": stage
                        ])
                        capacityStage = stage
                    }
                }
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
                var capacityEvaluation: WorldwideScreenCapacityProbeDiagnostics?
                if report != nil {
                    if capacityOnly { capacityReportCount += 1 } else { ordinaryReportCount += 1 }
                }
                let changedRecommendation = Self.advanceCapacityPolicy(
                    &proposedPolicy, report: report, capacityOnly: capacityOnly,
                    peerGeneration: peerGeneration, at: observedAt,
                    diagnostics: { capacityEvaluation = $0 })
                if var shadow = shadowPolicy {
                    // Share the native object, including pair identity and route. The shadow
                    // never applies sender limits or changes which samples the real peer takes.
                    _ = Self.advanceCapacityPolicy(
                        &shadow, report: report, capacityOnly: capacityOnly,
                        peerGeneration: peerGeneration, at: observedAt)
                    shadowComparison.compare(candidate: proposedPolicy, shadow: shadow,
                                             stage: .beforeApply, at: observedAt)
                    // End the shared-input comparison before either native limits or
                    // resumed-time expiry can hide the first different decision.
                    shadowPolicy = shadowComparison.isComparing ? shadow : nil
                    if shadowComparison.isComparing, proposedPolicy.startupSpatialModeIsDisproved,
                       shadowMatchedStartupDisproofAtMs == nil {
                        shadowMatchedStartupDisproofAtMs = startupClarityMilliseconds(
                            captureStartedAt.duration(to: observedAt))
                    }
                }

                let recommendation = changedRecommendation
                    ?? proposedPolicy.currentRecommendation
                if recommendation != appliedRecommendation {
                    let limits = recommendation.webRTCLimits
                    let ordinaryFallbackLimits = proposedPolicy.recommendation(
                        for: proposedPolicy.currentTier).webRTCLimits
                    let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
                        deadline: proposedPolicy.spatialRecoveryDeadline,
                        now: { .now },
                        apply: { try await host.applyScreenVideoEncodingLimits(limits) },
                        rollback: { update in
                            try await host.replaceScreenVideoEncodingUpdateIfCurrent(
                                update, with: ordinaryFallbackLimits)
                        }
                    )
                    guard case .applied(let update) = outcome else {
                        if case .expired(let rollbackWasProven) = outcome {
                            print("SPATIAL_RECOVERY_NATIVE_APPLICATION_EXPIRED rollbackProven=\(rollbackWasProven)")
                        }
                        throw WebRTCTransportError.nativeFailure(
                            "The native spatial recovery update expired before publication.")
                    }
                    let resumedAt = ContinuousClock.now
                    _ = proposedPolicy.expireApplicationLimitedProbeWithoutReport(
                        peerGeneration: 1, isCaptureActive: true, observedAt: resumedAt)
                    proposedPolicy.markSpatialRecoveryApplied(at: resumedAt)
                    if var shadow = shadowPolicy {
                        _ = shadow.expireApplicationLimitedProbeWithoutReport(
                            peerGeneration: peerGeneration, isCaptureActive: true, observedAt: resumedAt)
                        shadow.markSpatialRecoveryApplied(at: resumedAt)
                        shadowComparison.compare(candidate: proposedPolicy, shadow: shadow,
                                                 stage: .afterApply, at: resumedAt)
                        shadowPolicy = shadowComparison.isComparing ? shadow : nil
                    }
                    guard proposedPolicy.currentRecommendation == recommendation else {
                        let rollbackWasProven = try await host.replaceScreenVideoEncodingUpdateIfCurrent(
                            update, with: proposedPolicy.currentRecommendation.webRTCLimits)
                        print("SPATIAL_RECOVERY_CALLER_RESUME_EXPIRED rollbackProven=\(rollbackWasProven)")
                        throw WebRTCTransportError.nativeFailure(
                            "The encoding proposal expired before the caller resumed.")
                    }
                    appliedRecommendation = recommendation
                    maximumRequestedFPS = max(maximumRequestedFPS,
                                              recommendation.maximumFramesPerSecond)
                }
                policy = proposedPolicy
                let requestedCaptureFPS = experiment?.shapeInitialCapture == true && elapsedMs < 2_000
                    ? 1 : recommendation.maximumFramesPerSecond
                if captureFPS != requestedCaptureFPS {
                    capturer.adaptOutput(
                        width: Int32(StartupClarityPattern.width),
                        height: Int32(StartupClarityPattern.height),
                        framesPerSecond: Int32(requestedCaptureFPS))
                    captureFPS = requestedCaptureFPS
                    if followsPolicyFPS { captureCadence.update(captureFPS) }
                }

                let snapshot = report?.nativeSnapshot
                if let rtt = snapshot?.currentRoundTripTime, rtt.isFinite {
                    maximumNativeRTT = max(maximumNativeRTT, rtt)
                }
                if experiment != nil, let relay = networkRelay?.snapshot() {
                    let video = snapshot?.outboundVideo
                    let ordinary = policy.recommendation(for: policy.currentTier)
                    let nativeRTTObservationKind: String
                    var nativeRTTTotalSeconds: Double?
                    var nativeRTTResponses: UInt64?
                    switch snapshot?.roundTripTimeObservation {
                    case nil:
                        nativeRTTObservationKind = "missing"
                    case .some(.unavailable):
                        nativeRTTObservationKind = "unavailable"
                    case .some(.measurement(let measurement)):
                        nativeRTTObservationKind = "measurement"
                        let total = measurement.totalRoundTripTimeSeconds
                        if total.isFinite, total >= 0, total <= 1_000_000_000 {
                            nativeRTTTotalSeconds = total
                        }
                        nativeRTTResponses = measurement.responsesReceived
                    }
                    capacityTrace.append([
                        "elapsedMs": startupClarityMilliseconds(captureStartedAt.duration(to: observedAt)),
                        "lane": capacityOnly ? "capacityOnly" : "ordinary",
                        "tier": String(describing: policy.currentTier),
                        "nativeTimestamp": report?.nativeReportTimestampMicroseconds as Any? ?? NSNull(),
                        "collectionSequence": snapshot?.collectionSequence as Any? ?? NSNull(),
                        "currentVideoCapBps": recommendation.maximumBitrateBps,
                        "currentTotalCapBps": recommendation.maximumTotalRTPBitrateBps,
                        "ordinaryVideoCapBps": ordinary.maximumBitrateBps,
                        "ordinaryTotalCapBps": ordinary.maximumTotalRTPBitrateBps,
                        "probeOrigin": policy.applicationLimitedProbeOriginTier.map {
                            String(describing: $0)
                        } as Any? ?? NSNull(),
                        "probeDeadlineRemainingMs": policy.applicationLimitedProbeDeadline.map {
                            startupClarityMilliseconds(observedAt.duration(to: $0))
                        } as Any? ?? NSNull(),
                        "rttDisposition": policy.roundTripTimeDisposition.rawValue,
                        "fastProbeReason": capacityEvaluation?.reason.rawValue as Any? ?? NSNull(),
                        "fastProbeDeltaPackets": capacityEvaluation?.deltaPackets as Any? ?? NSNull(),
                        "fastProbeDeltaSendDelayMicros": capacityEvaluation?.deltaSendDelayMicroseconds as Any? ?? NSNull(),
                        "fastProbeQueueMicros": capacityEvaluation?.averageQueueMicroseconds as Any? ?? NSNull(),
                        "rttObservationAgeMs": policy.roundTripTimeObservationAge.map {
                            startupClarityMilliseconds($0)
                        } as Any? ?? NSNull(),
                        "lastOrdinaryPacketDelayMs": policy.lastAveragePacketSendDelaySeconds.map {
                            $0 * 1_000
                        } as Any? ?? NSNull(),
                        "latencyPressure": policy.lastSampleHasLatencyPressure,
                        "recoveryDeadlineRemainingMs": policy.spatialRecoveryDeadline.map {
                            startupClarityMilliseconds(observedAt.duration(to: $0))
                        } as Any? ?? NSNull(),
                        "bwe": snapshot?.availableOutgoingBitrate as Any? ?? NSNull(),
                        "rtt": snapshot?.currentRoundTripTime as Any? ?? NSNull(),
                        "nativeRouteUnavailable": snapshot?.route == nil,
                        "nativeRTTObservationUnavailable": snapshot?.roundTripTimeObservation == .unavailable,
                        "nativeRTTObservationKind": nativeRTTObservationKind,
                        "nativeRTTTotalRoundTripTimeSeconds": nativeRTTTotalSeconds as Any? ?? NSNull(),
                        "nativeRTTResponsesReceived": nativeRTTResponses as Any? ?? NSNull(),
                        "packets": video?.packets as Any? ?? NSNull(),
                        "bytes": video?.bytes as Any? ?? NSNull(),
                        "totalPacketSendDelay": video?.totalPacketSendDelay as Any? ?? NSNull(),
                        "framesEncoded": video?.framesEncodedOrDecoded as Any? ?? NSNull(),
                        "encodedWidth": video?.frameWidth as Any? ?? NSNull(),
                        "encodedHeight": video?.frameHeight as Any? ?? NSNull(),
                        "keyFramesEncoded": video?.keyFramesEncoded as Any? ?? NSNull(),
                        "hugeFramesSent": video?.hugeFramesSent as Any? ?? NSNull(),
                        "totalEncodeTime": video?.totalEncodeTime as Any? ?? NSNull(),
                        "qpSum": video?.qpSum as Any? ?? NSNull(),
                        "nackCount": video?.nackCount as Any? ?? NSNull(),
                        "pliCount": video?.pliCount as Any? ?? NSNull(),
                        "targetBitrate": video?.targetBitrate as Any? ?? NSNull(),
                        "qualityLimitationReason": video?.qualityLimitationReason?.rawValue as Any? ?? NSNull(),
                        "scale": recommendation.scaleResolutionDownBy,
                        "captureFPS": captureFPS,
                        "spatialDisproved": policy.startupSpatialModeIsDisproved,
                        "spatialRecoveryPhase": policy.spatialRecoveryPhase,
                        "spatialRecoveryAttemptCount": policy.spatialRecoveryAttemptCount,
                        "spatialRecoveryTrialActive": policy.spatialRecoveryIsTrialActive,
                        "recoverySparseProbeIsHolding": policy.spatialRecoverySparseProbeIsHolding,
                        "shadowStillEqual": shadowPolicy != nil,
                        "shadowComparedSamples": shadowComparison.comparisonCount,
                        "capacityBps": relay.hostToViewer.configuredBitsPerSecond as Any? ?? NSNull(),
                        "queuedBytes": relay.hostToViewer.pendingBytes,
                        "forwardedBytes": relay.hostToViewer.forwardedBytes,
                        "maxSerializationDelayNs": relay.hostToViewer.maximumSerializationDelayNanoseconds,
                        "expiredDatagrams": relay.hostToViewer.expiredDatagrams,
                        "overflowDatagrams": relay.hostToViewer.overflowDatagrams
                        , "maximumDeliveryLatenessNs": relay.hostToViewer.maximumDeliveryLatenessNanoseconds
                        , "maximumReleaseBatchBytes": relay.hostToViewer.maximumReleaseBatchBytes
                    ])
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
                    policy.applicationLimitedProbeOriginTier != nil || policy.spatialRecoveryIsTrialActive,
                    at: sampleFinishedAt
                )
                // Diagnostic work never awaits, feeds policy, or changes the host sampling lane.
                if !capacityOnly { receiverStatisticsProbe?.request() }
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
            let viewerFinal: WebRTCStatisticsSnapshot
            if let receiverStatisticsProbe {
                viewerFinal = await receiverStatisticsProbe.finishAndCollectFinalSnapshot()
            } else {
                viewerFinal = await viewer.statisticsSnapshot()
            }
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
            let nativePacingBatch = nativePacingObserver?.snapshot()
            let nativePacingWitness: StartupVideoNativePacingWitnessSummary?
            if let nativePacingBatch, let nativePacingBinding, let factor = pacingFactor {
                nativePacingWitness = StartupVideoNativePacingWitness.evaluate(batch: nativePacingBatch, binding: nativePacingBinding,
                    captureStartedAtUptimeNanoseconds: captureStartedUptimeNanoseconds, expectedFactor: factor)
            } else { nativePacingWitness = nil }
            let nativeEstimatorSnapshot = observeEstimator ? try pacerBridge?.estimatorSnapshot() : nil
            let nativeEstimatorWitness = nativeEstimatorSnapshot.flatMap { snapshot in
                nativePacingBinding.map {
                    snapshot.evaluate(hostWorkerID: $0.hostWorkerID,
                        captureStartedAtUptimeNanoseconds: captureStartedUptimeNanoseconds)
                }
            }
            let estimatorEvidenceProfile = delayedEstimatorProfile
                ?? (experiment?.probeDurationMilliseconds != nil ? .alrProbeCap : nil)
            if let delayedEstimatorProfile = estimatorEvidenceProfile {
                var baselineEvidence: [String: Any] = [
                    "pacerMode": StartupVideoPacerMode.sdkDefault.rawValue,
                    "defaultPacingProfile": delayedEstimatorProfile.rawValue,
                    "holdDelayGrowthInALR": delayedEstimatorProfile.holdDelayGrowthInALR,
                    "skipProbesBelowCurrentEstimate": delayedEstimatorProfile.skipProbesBelowCurrentEstimate,
                    "pinnedSourceDefaultPacingWindowMilliseconds": 40,
                    "runtimePacingWindowMeasured": false,
                    "pacerNativeReadbacks": pacerBridge?.verifiedCount ?? 0,
                    "captureStartedUptimeNanoseconds": captureStartedUptimeNanoseconds,
                    "nativePacingBatch": try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(nativePacingBatch))),
                    "nativePacingBinding": try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(nativePacingBinding))),
                    "nativePacingWitness": try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(nativePacingWitness))),
                    "nativeEstimatorSnapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(nativeEstimatorSnapshot))),
                    "nativeEstimatorWitness": try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(nativeEstimatorWitness)))
                ]
                let marker: String
                if let probeDurationMilliseconds = effectiveProbeDurationMilliseconds {
                    let witness = StartupVideoProbeDurationWitness.evaluate(
                        snapshot: try XCTUnwrap(nativeEstimatorSnapshot),
                        hostWorkerID: try XCTUnwrap(nativePacingBinding).hostWorkerID,
                        captureStartedAtUptimeNanoseconds: captureStartedUptimeNanoseconds,
                        expectedMilliseconds: probeDurationMilliseconds)
                    XCTAssertTrue(witness.isVerified, "Native initial probe byte budget must match the selected arm")
                    baselineEvidence["probeDurationMilliseconds"] = probeDurationMilliseconds
                    baselineEvidence["probeRequestBudgetVerified"] = witness.isVerified
                    baselineEvidence["runtimeProbeDurationReadback"] = false
                    baselineEvidence["initialProbeClusterIDs"] = witness.initialProbeClusterIDs
                    baselineEvidence["initialProbeBitratesBps"] = witness.initialProbeBitratesBps
                    baselineEvidence["initialProbeMinimumBytes"] = witness.initialProbeMinimumBytes
                    baselineEvidence["initialProbeMinimumProbes"] = witness.initialProbeMinimumProbes
                    baselineEvidence["probeDurationWitness"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(witness))
                    if experiment?.probeDurationMilliseconds != nil {
                        marker = experiment?.requiresSpatialRecovery == true
                            ? "STARTUP_PROBE_DURATION_RECOVERY_ESTIMATOR " : "STARTUP_PROBE_DURATION_WEAK_ESTIMATOR "
                    } else {
                        marker = "STARTUP_PROBE_DURATION_ESTIMATOR "
                    }
                } else {
                    marker = defaultPacingEstimatorProfile == nil
                        ? "STARTUP_BASELINE_ESTIMATOR " : "STARTUP_DEFAULT_PACING_ESTIMATOR "
                }
                let data = try JSONSerialization.data(withJSONObject: baselineEvidence, options: [.sortedKeys])
                print(marker + String(decoding: data, as: UTF8.self))
                fflush(nil)
                XCTAssertEqual(pacerBridge?.verifiedCount, 1)
                XCTAssertEqual(nativePacingWitness?.isVerified, true)
                XCTAssertEqual(nativeEstimatorWitness?.isVerified, true)
            }
            if let experiment {
                let first = try XCTUnwrap(observations.first)
                let decoded: [[String: Any]] = observations.enumerated().map { index, observation in
                    let previous = index > 0 ? observations[index - 1] : nil
                    var lumaDifference = 0.0
                    if let previous {
                        for (old, new) in zip(previous.denseLuma, observation.denseLuma) {
                            lumaDifference += abs(old - new)
                        }
                        lumaDifference /= Double(observation.denseLuma.count)
                    }
                    return [
                        "elapsedMs": startupClarityMilliseconds(captureStartedAt.duration(to: observation.receivedAt)),
                        "callbackStartedMs": startupClarityMilliseconds(captureStartedAt.duration(to: observation.callbackStartedAt)),
                        "conversionDurationMs": startupClarityMilliseconds(observation.callbackStartedAt.duration(to: observation.receivedAt)),
                        "rtpTimestamp": UInt32(bitPattern: observation.timestamp),
                        "width": observation.width, "height": observation.height,
                        "contrast": observation.signedIdealNormalizedContrast.minimum,
                        "densePixelDifference": lumaDifference,
                        "motionPhase": observation.motionPhase as Any? ?? NSNull(),
                        "motionPhaseChanged": previous?.motionPhase != nil && observation.motionPhase != nil
                            && previous?.motionPhase != observation.motionPhase,
                        "sameGeometry": previous?.width == observation.width && previous?.height == observation.height
                    ]
                }
                if experiment.movingContent {
                    XCTAssertGreaterThan(decoded.filter {
                        ($0["densePixelDifference"] as? Double ?? 0) > 4
                            && $0["sameGeometry"] as? Bool == true
                            && $0["motionPhaseChanged"] as? Bool == true
                    }.count, 1, "Moving content must reach actual decoded pixels")
                }
                let recoveryFirstSharp = capacityRestoredAt.flatMap { restoredAt in
                    observations.first { $0.receivedAt >= restoredAt && Self.isFullPixelSharp($0) }
                }
                let trafficTiming = networkRelay?.snapshot().trafficTiming
                let trafficTimingJSON: Any
                if let trafficTiming {
                    trafficTimingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trafficTiming))
                } else {
                    trafficTimingJSON = NSNull()
                }
                let firstShadowDivergence: [String: Any]? = shadowComparison.firstDivergence.map {
                    ["elapsedMs": startupClarityMilliseconds(captureStartedAt.duration(to: $0.observedAt)),
                     "stage": $0.stage.rawValue, "differences": $0.differences,
                     "candidateStartupDisproved": $0.candidate.startupDisproved,
                     "shadowStartupDisproved": $0.shadow.startupDisproved,
                     "candidateScale": $0.candidate.recommendation.scaleResolutionDownBy,
                     "shadowScale": $0.shadow.recommendation.scaleResolutionDownBy]
                }
                let pacingBatchJSON: Any = try nativePacingBatch.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()
                let pacingWitnessJSON: Any = try nativePacingWitness.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()
                let pacingBindingJSON: Any = try nativePacingBinding.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()
                let estimatorSnapshotJSON: Any = try nativeEstimatorSnapshot.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()
                let estimatorWitnessJSON: Any = try nativeEstimatorWitness.map {
                    try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                } ?? NSNull()
                let receiverTimingBatch = receiverStatisticsProbe?.snapshot()
                let result: [String: Any] = [
                    "capacityBps": experiment.bitsPerSecond, "movingContent": experiment.movingContent,
                    "warmupMs": experiment.warmupMilliseconds,
                    "shapeInitialCapture": experiment.shapeInitialCapture,
                    "capacityDropAndRecovery": experiment.capacityDropAndRecovery,
                    "spatialRecoveryEnabled": experiment.spatialRecoveryEnabled,
                    "collectTrafficTiming": experiment.collectTrafficTiming,
                    "collectReceiverTiming": experiment.collectReceiverTiming,
                    "receiverTiming": try receiverTimingBatch.map {
                        try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
                    } ?? NSNull(),
                    "pacerMode": experiment.pacerMode?.rawValue as Any? ?? NSNull(),
                    "pacerBridgeSHA256": pacerBridge?.artifactSHA256 as Any? ?? NSNull(),
                    "pacerNativeReadbacks": pacerBridge?.verifiedCount ?? 0,
                    "pacingFactor": experiment.pacingFactor as Any? ?? NSNull(),
                    "nativePacingBatch": pacingBatchJSON,
                    "nativePacingBinding": pacingBindingJSON,
                    "nativePacingWitness": pacingWitnessJSON,
                    "observeEstimator": experiment.observeEstimator,
                    "observeEncoderBoundary": experiment.observeEncoderBoundary,
                    "holdDelayGrowthInALR": experiment.holdDelayGrowthInALR,
                    "skipProbesBelowCurrentEstimate": experiment.skipProbesBelowCurrentEstimate,
                    "nativeEstimatorSnapshot": estimatorSnapshotJSON,
                    "nativeEstimatorWitness": estimatorWitnessJSON,
                    "captureStartedUptimeNanoseconds": captureStartedUptimeNanoseconds,
                    "trafficTiming": trafficTimingJSON,
                    "shadowComparedSamples": shadowComparison.comparisonCount,
                    "firstShadowDivergence": firstShadowDivergence as Any? ?? NSNull(),
                    "shadowMatchedStartupDisproofAtMs": shadowMatchedStartupDisproofAtMs as Any? ?? NSNull(),
                    "requiresSpatialRecovery": experiment.requiresSpatialRecovery,
                    "secondCapacityDrop": experiment.secondCapacityDrop,
                    "observationDurationMs": observationSeconds * 1_000,
                    "recoveryDeadlineMs": 4_000,
                    "requiredSustainedRecoveryMs": 2_000,
                    "requiresSharpUntilNextCapacityDrop": experiment.requiresSpatialRecovery,
                    "restoreTiming": "synchronous-mutation-lower-bound",
                    "capacityChanges": capacityChanges,
                    "restoredAtMs": capacityRestoredAt.map {
                        startupClarityMilliseconds(captureStartedAt.duration(to: $0))
                    } as Any? ?? NSNull(),
                    "recoveryFirstSharpMs": recoveryFirstSharp.map {
                        startupClarityMilliseconds(captureStartedAt.duration(to: $0.receivedAt))
                    } as Any? ?? NSNull(),
                    "firstFrameFromCaptureMs": startupClarityMilliseconds(captureStartedAt.duration(to: first.receivedAt)),
                    "firstFrameFromShowMs": startupClarityMilliseconds(showRequestedAt.duration(to: first.receivedAt)),
                    "firstFrameFromTransportReadyMs": startupClarityMilliseconds(transportReadyAt.duration(to: first.receivedAt)),
                    "finalDecodedFPS": finalDecodedFPS, "warmup": warmupTrace,
                    "sourceSubmissionMs": captureCadence.snapshot().map {
                        startupClarityMilliseconds(captureStartedAt.duration(to: $0))
                    },
                    "trace": capacityTrace, "decoded": decoded
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print("STARTUP_CAPACITY_EXPERIMENT " + String(decoding: data, as: UTF8.self))
                fflush(nil)
                if experiment.collectReceiverTiming {
                    let batch = try XCTUnwrap(receiverTimingBatch)
                    XCTAssertEqual(batch.saturatedCount, 0)
                    XCTAssertEqual(batch.malformedClockCount, 0)
                    XCTAssertEqual(batch.regressingClockCount, 0)
                    let complete = batch.records.filter {
                        $0.requestedUptimeNanoseconds >= captureStartedUptimeNanoseconds
                            && $0.collectionSequence != nil
                            && $0.inboundVideo.framesReceived != nil
                            && $0.inboundVideo.framesDropped != nil
                            && $0.inboundVideo.framesEncodedOrDecoded != nil
                            && $0.inboundVideo.jitterBufferDelay != nil
                            && $0.inboundVideo.jitterBufferEmittedCount != nil
                            && $0.inboundVideo.totalDecodeTime != nil
                    }
                    let advancing = zip(complete, complete.dropFirst()).filter { before, after in
                        (after.collectionSequence ?? 0) > (before.collectionSequence ?? 0)
                            && (after.inboundVideo.framesReceived ?? 0) > (before.inboundVideo.framesReceived ?? 0)
                            && (after.inboundVideo.framesEncodedOrDecoded ?? 0) > (before.inboundVideo.framesEncodedOrDecoded ?? 0)
                            && (after.inboundVideo.jitterBufferEmittedCount ?? 0) > (before.inboundVideo.jitterBufferEmittedCount ?? 0)
                    }
                    XCTAssertGreaterThanOrEqual(advancing.count, 3,
                        "Receiver diagnosis requires actual parsed advancing inbound counters")
                }
                if experiment.collectTrafficTiming {
                    let timing = try XCTUnwrap(trafficTiming)
                    XCTAssertFalse(timing.counterSaturated)
                    XCTAssertEqual(timing.omittedBindingEvents, 0)
                    XCTAssertEqual(timing.invalidTimingDatagrams, 0)
                    XCTAssertFalse(timing.bindingEvents.isEmpty)
                    XCTAssertGreaterThan(shadowComparison.comparisonCount, 0)
                    if let firstShadowDivergence {
                        XCTAssertEqual(firstShadowDivergence["candidateStartupDisproved"] as? Bool, true,
                                       "Candidate authority cannot change the cold-start prefix")
                        XCTAssertEqual(firstShadowDivergence["shadowStartupDisproved"] as? Bool, true)
                    }
                    if experiment.requiresSpatialRecovery {
                        XCTAssertNotNil(firstShadowDivergence,
                                        "The positive comparison must exercise actual recovery-policy divergence")
                    }
                }
                if experiment.pacerMode != nil {
                    XCTAssertEqual(pacerBridge?.verifiedCount, 1,
                                   "The exact streaming host must have a native pacing readback")
                }
                if experiment.pacingFactor != nil {
                    XCTAssertEqual(nativePacingWitness?.isVerified, true,
                                   "Pacing factor requires exact-host native consumer evidence")
                }
                if experiment.observeEstimator {
                    XCTAssertEqual(nativeEstimatorWitness?.isVerified, true,
                        "Actual host estimator events must be bound and numerically verified")
                }
                XCTAssertLessThanOrEqual(networkRelay?.snapshot().maximumPendingBytes ?? Int.max, 4 * 1_024 * 1_024)
                XCTAssertGreaterThan(networkRelay?.snapshot().hostToViewer.maximumSerializationDelayNanoseconds ?? 0, 0)
                XCTAssertLessThanOrEqual(maximumRequestedFPS, 60)
                XCTAssertGreaterThan(finalDecodedFPS, 0, "The bounded impaired path must still deliver video")
                if experiment.spatialRecoveryEnabled {
                    let submissions = captureCadence.snapshot()
                    XCTAssertLessThan(submissions.count, 1_024, "Saturated source timing is not evidence")
                    XCTAssertLessThan(observations.count, 1_024, "Saturated decoder timing is not evidence")
                    for (before, after) in zip(submissions, submissions.dropFirst()) {
                        let interval = startupClarityMilliseconds(before.duration(to: after))
                        XCTAssertGreaterThanOrEqual(interval, 16,
                                                   "Actual source submissions must stay within 60 fps")
                        XCTAssertLessThanOrEqual(interval, 1_100,
                                                "Policy must not stop the acknowledged source")
                    }
                    if !experiment.capacityDropAndRecovery {
                        XCTAssertTrue(observations.allSatisfy(Self.isFullPixelSharp),
                                      "Recovery cannot regress unchanged steady-link startup clarity")
                        XCTAssertGreaterThanOrEqual(finalDecodedFPS, experiment.bitsPerSecond >= 8_000_000 ? 10 : 4)
                    }
                }
                if experiment.requiresSpatialRecovery {
                    let firstDropAt = try XCTUnwrap(firstCapacityDropAt)
                    let restoredAt = try XCTUnwrap(capacityRestoredAt)
                    XCTAssertTrue(observations.contains {
                        $0.receivedAt >= firstDropAt && $0.receivedAt < restoredAt
                            && ($0.width < StartupClarityPattern.width || $0.height < StartupClarityPattern.height)
                    }, "The fixture must prove actual degradation before recovery")
                    let firstRecovered = try XCTUnwrap(recoveryFirstSharp,
                                                       "Recovery requires full-pixel decoded detail, not intent")
                    XCTAssertLessThanOrEqual(startupClarityMilliseconds(
                        restoredAt.duration(to: firstRecovered.receivedAt)), 4_000,
                        "Predeclared four-second spatial recovery deadline")
                    XCTAssertTrue(Self.hasSustainedSpatialRecovery(observations, after: restoredAt),
                                  "Full pixels must remain sharp for two seconds with actual changing content")
                    let recoveredIntervalEnd = secondCapacityDropAt ?? deadline
                    XCTAssertTrue(observations.filter {
                        $0.receivedAt >= firstRecovered.receivedAt && $0.receivedAt < recoveredIntervalEnd
                    }.allSatisfy(Self.isFullPixelSharp),
                    "Recovered detail must not blur again before another actual capacity drop")
                    for (before, after) in zip(observations, observations.dropFirst()) {
                        XCTAssertLessThanOrEqual(startupClarityMilliseconds(
                            before.receivedAt.duration(to: after.receivedAt)), 2_500,
                            "Recovery must not replace live video with a decoder blackout")
                    }
                    if experiment.secondCapacityDrop {
                        let secondDropAt = try XCTUnwrap(secondCapacityDropAt,
                                                       "Second pressure follows actual sustained recovery")
                        XCTAssertGreaterThanOrEqual(startupClarityMilliseconds(
                            firstRecovered.receivedAt.duration(to: secondDropAt)), 2_000)
                        XCTAssertTrue(observations.contains {
                            $0.receivedAt >= secondDropAt
                                && ($0.width < StartupClarityPattern.width || $0.height < StartupClarityPattern.height)
                        }, "Fresh second pressure must revoke full-pixel recovery")
                        XCTAssertGreaterThanOrEqual(observations.last?.receivedAt ?? captureStartedAt,
                                                    deadline.advanced(by: .seconds(-2)),
                                                    "The visible floor must continue through final pressure")
                    }
                    let relay = try XCTUnwrap(networkRelay).snapshot()
                    XCTAssertEqual(relay.hostToViewer.overflowDatagrams, 0)
                    XCTAssertEqual(relay.hostToViewer.expiredDatagrams, 0)
                    XCTAssertEqual(relay.hostToViewer.backpressureDatagrams, 0)
                    XCTAssertEqual(relay.viewerToHost.overflowDatagrams, 0)
                    XCTAssertEqual(relay.viewerToHost.expiredDatagrams, 0)
                    XCTAssertEqual(relay.viewerToHost.backpressureDatagrams, 0)
                }
            } else if let oneWayDelayMilliseconds {
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
                XCTAssertLessThan(drainedFrameCount, 1_024,
                                  "A saturated observation ledger cannot prove blackout")
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(renderer.snapshot().count, drainedFrameCount,
                               "Decoded media must stop after relay blackout and drain")
            }
            let relayErrors = await state.relayErrors
            XCTAssertEqual(relayErrors, [])
        } catch {
            await receiverStatisticsProbe?.finish()
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

        await receiverStatisticsProbe?.finish()
        await startupClarityClose(
            host: host,
            viewer: viewer,
            relays: relays,
            pump: pump,
            track: track,
            renderer: renderer,
            networkRelay: networkRelay
        )
        if observeEstimator {
            let closed = try XCTUnwrap(pacerBridge).estimatorSnapshot()
            XCTAssertEqual(closed.liveLoggerCount, 0, "Native close must release its estimator logger")
            XCTAssertEqual(closed.loggerCreatedCount, 1)
            XCTAssertEqual(closed.loggerDestroyedCount, 1)
            XCTAssertEqual(closed.lifetimeFailureCount, 0)
            print("ESTIMATOR_NATIVE_TEARDOWN live=\(closed.liveLoggerCount) created=\(closed.loggerCreatedCount) destroyed=\(closed.loggerDestroyedCount) failures=\(closed.lifetimeFailureCount)")
            fflush(nil)
        }
        completedNativeTeardown = true
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
