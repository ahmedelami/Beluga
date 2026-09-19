#if os(macOS)
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

private actor StartupProbeState {
    var track: WebRTCRemoteVideoTrack?
    var acknowledged = false
    var errors = 0
    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        if viewerSide, case .remoteVideoTrack(let track) = event { self.track = track }
        if viewerSide, case .controlAcknowledgementReceived(let ack, _) = event,
           ack.state == .active { acknowledged = true }
    }
    func failed() { errors += 1 }
}

private final class StartupProbeRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: Set<Int32> = []
    private var wrongGeometry = false
    func setSize(_: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock {
            timestamps.insert(frame.timeStamp)
            wrongGeometry = wrongGeometry || frame.width != 270 || frame.height != 480
        }
    }
    func snapshot() -> (count: Int, wrongGeometry: Bool) {
        lock.withLock { (timestamps.count, wrongGeometry) }
    }
}

private final class StartupProbePixels: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
    init() throws {
        buffers = try [UInt8(0x40), UInt8(0x44)].map { value in
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 1080, 1920,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer,
                  CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
                throw StartupProbeFailure.setup
            }
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(value), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }
    }
}

private enum StartupProbeFailure: Error { case setup, timeout }

private func startupProbeRelay(from: WebRTCPeer, to: WebRTCPeer,
    viewerSide: Bool, state: StartupProbeState) -> Task<Void, Never> {
    Task {
        do {
            for await event in from.events {
                await state.observe(event, viewerSide: viewerSide)
                if case .outboundSignal(let payload) = event { try await to.handle(payload) }
                if !viewerSide, case .controlRequestReceived(let request) = event,
                   request.command == .showScreen {
                    try await from.acknowledgeActiveControlRequestIfTransportHealthy(
                        id: request.id, authorization: WebRTCControlAuthorization())
                }
            }
        } catch { if !Task.isCancelled { await state.failed() } }
    }
}

private func startupProbeWait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw StartupProbeFailure.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func startupProbeClose(host: WebRTCPeer, viewer: WebRTCPeer,
    relays: [Task<Void, Never>], pump: Task<Void, Never>?,
    track: WebRTCRemoteVideoTrack?, renderer: StartupProbeRenderer) async {
    pump?.cancel()
    await pump?.value
    if let track { await MainActor.run { track.removeRenderer(renderer) } }
    await host.close(reason: .normal)
    await viewer.close(reason: .normal)
    for task in relays { task.cancel() }
    for task in relays { await task.value }
}

final class WebRTCStartupProbeActivationTests: XCTestCase {
    // Run alone in a fresh test process: factory configuration and native diagnostics have
    // process scope. This test must never configure field trials itself.
    func testProductionInitializerActivatesTinyPacketCapacityProbe() async throws {
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let viewer: WebRTCPeer
        do { viewer = try WebRTCPeer.makeHeadlessViewerForTesting(configuration: .init(role: .viewer, iceServers: [])) }
        catch { await host.close(reason: .normal); throw StartupProbeFailure.setup }
        let state = StartupProbeState(), renderer = StartupProbeRenderer()
        let relays = [startupProbeRelay(from: host, to: viewer, viewerSide: false, state: state),
                      startupProbeRelay(from: viewer, to: host, viewerSide: true, state: state)]
        var pump: Task<Void, Never>?
        var track: WebRTCRemoteVideoTrack?
        do {
            let initial = WebRTCScreenVideoEncodingLimits(maximumBitrateBps: 39_744_000,
                maximumFramesPerSecond: 5, scaleResolutionDownBy: 4, maximumTotalRTPBitrateBps: 486_001)
            let raised = WebRTCScreenVideoEncodingLimits(maximumBitrateBps: 39_744_000,
                maximumFramesPerSecond: 5, scaleResolutionDownBy: 4, maximumTotalRTPBitrateBps: 1_538_822)
            _ = try await host.applyScreenVideoEncodingLimits(initial)
            try await host.start()
            try await startupProbeWait {
                let healthy = await host.isTransportHealthyForCapture()
                let hasTrack = await state.track != nil
                return healthy && hasTrack
            }
            let trackValue = await state.track
            let remoteTrack = try XCTUnwrap(trackValue)
            track = remoteTrack
            await MainActor.run { remoteTrack.addRenderer(renderer) }
            _ = try await viewer.setScreenVisible(true)
            try await startupProbeWait { await state.acknowledged }
            let capturer = try XCTUnwrap(host.externalVideoCapturer)
            capturer.adaptOutput(width: 1080, height: 1920, framesPerSecond: 5)
            let pixels = try StartupProbePixels()
            pump = Task.detached {
                var index = 0
                while !Task.isCancelled {
                    capturer.capture(pixelBuffer: pixels.buffers[index % 2],
                        timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds))
                    index += 1
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                }
            }
            var nativeEvents: [WebRTCNativeProbeEvent] = []
            func drain() {
                let batch = WebRTCNativeProbeDiagnostics.drain()
                XCTAssertEqual(batch.droppedEventCount, 0)
                nativeEvents.append(contentsOf: batch.events)
            }
            for _ in 0..<15 { drain(); try await Task.sleep(for: .milliseconds(200)) }
            let baselineReportValue = await host.screenVideoStatisticsSnapshot(timeout: .milliseconds(250))
            let baselineReport = try XCTUnwrap(baselineReportValue)
            let baselineBWE = try XCTUnwrap(baselineReport.snapshot.availableOutgoingBitrate)
            XCTAssertTrue(baselineBWE.isFinite && baselineBWE > 0 && baselineBWE < 1_000_000,
                          "The native baseline must still need discovery; an already recovered setup is invalid.")
            guard baselineBWE.isFinite && baselineBWE > 0 && baselineBWE < 1_000_000 else { throw StartupProbeFailure.setup }
            let before = renderer.snapshot()
            XCTAssertGreaterThanOrEqual(before.count, 5)
            XCTAssertFalse(before.wrongGeometry)
            let originalLimits = await host.screenVideoEncodingLimitsForTesting()
            let originalPriority = await host.screenVideoPriorityForTesting()
            let viewerBaseline = await viewer.statisticsSnapshot()
            let beforeBytes = try XCTUnwrap(viewerBaseline.inboundVideo?.bytes)
            drain()
            let watermark = nativeEvents.last?.sequence ?? 0
            let started = ContinuousClock.now
            let deadline = started.advanced(by: .milliseconds(3500))
            _ = try await host.applyScreenVideoEncodingLimits(raised)
            var capacityAdvanced = false, nativeFeedback = false, activeCluster = false
            var receiverAdvanced = false, nativeTimingPreserved = false
            var firstCapacityDelay: Duration?
            while ContinuousClock.now < deadline {
                drain()
                let newEvents = nativeEvents.filter { $0.sequence > watermark }
                activeCluster = activeCluster || newEvents.contains { $0.kind == .clusterCreated && $0.bitrateBps == 1_538_822 && $0.isActive == true }
                nativeFeedback = nativeFeedback || newEvents.contains { $0.kind == .probeSucceeded && ($0.bitrateBps ?? 0) >= 1_000_000 && ($0.receiveBitrateBps ?? 0) >= 1_000_000 }
                nativeTimingPreserved = nativeTimingPreserved || newEvents.contains { event in
                    guard event.kind == .probeSucceeded,
                          (event.bitrateBps ?? 0) >= 1_000_000,
                          (event.receiveBitrateBps ?? 0) >= 1_000_000,
                          case .microseconds(let send)? = event.sendInterval,
                          case .microseconds(let receive)? = event.receiveInterval else { return false }
                    return (1...1_000_000).contains(send) && (1...1_000_000).contains(receive)
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                if let report = await host.screenVideoStatisticsSnapshot(timeout: min(.milliseconds(250), remaining)),
                   report.nativeReportTimestampMicroseconds > baselineReport.nativeReportTimestampMicroseconds,
                   let bwe = report.snapshot.availableOutgoingBitrate, bwe.isFinite,
                   bwe >= 1_200_000 && bwe > baselineBWE * 1.5 {
                    capacityAdvanced = ContinuousClock.now < deadline
                    if capacityAdvanced && firstCapacityDelay == nil {
                        firstCapacityDelay = started.duration(to: .now)
                    }
                }
                let received = renderer.snapshot()
                XCTAssertFalse(received.wrongGeometry)
                if capacityAdvanced && received.count > before.count {
                    let receiverStats = await viewer.statisticsSnapshot()
                    receiverAdvanced = (receiverStats.inboundVideo?.bytes ?? 0) > beforeBytes && ContinuousClock.now < deadline
                }
                let audio = try XCTUnwrap(host.externalAudioCapturer).diagnosticsForTesting()
                XCTAssertFalse(audio.isEnabled)
                XCTAssertEqual(audio.receivedBufferCount, 0)
                XCTAssertEqual(audio.admInputCallbackCount, 0)
                XCTAssertEqual(audio.customDeviceDeliveredFrames, 0)
                XCTAssertEqual(audio.customDeviceRenderInvocations, 0)
                if capacityAdvanced && nativeFeedback && nativeTimingPreserved && activeCluster && receiverAdvanced { break }
                let sleepRemaining = ContinuousClock.now.duration(to: deadline)
                if sleepRemaining > .zero { try await Task.sleep(for: min(.milliseconds(100), sleepRemaining)) }
            }
            let finalLimits = await host.screenVideoEncodingLimitsForTesting()
            let finalPriority = await host.screenVideoPriorityForTesting()
            let totalCap = await host.maximumTotalRTPBitrateBpsForTesting()
            XCTAssertEqual(finalLimits, originalLimits)
            XCTAssertEqual(finalPriority, originalPriority)
            XCTAssertEqual(totalCap, 1_538_822)
            _ = try await host.applyScreenVideoEncodingLimits(initial)
            let restoredCap = await host.maximumTotalRTPBitrateBpsForTesting()
            XCTAssertEqual(restoredCap, 486_001)
            print("STARTUP_PROBE baselineBps=\(baselineBWE) activeCluster=\(activeCluster) "
                + "feedback=\(nativeFeedback) timingPreserved=\(nativeTimingPreserved) capacityAdvanced=\(capacityAdvanced) "
                + "firstCapacityDelay=\(String(describing: firstCapacityDelay)) "
                + "receiverAdvanced=\(receiverAdvanced) decodedBefore=\(before.count) "
                + "decodedAfter=\(renderer.snapshot().count)")
            XCTAssertTrue(activeCluster, "The real production initializer must make the raised cluster immediately eligible.")
            XCTAssertTrue(nativeFeedback, "A created cluster is not actual successful native probe feedback.")
            XCTAssertTrue(nativeTimingPreserved, "Actual SDK callbacks must retain both finite probe intervals through the collector.")
            XCTAssertTrue(capacityAdvanced, "Tiny-packet capacity must advance by the original 3.5-second deadline.")
            XCTAssertTrue(receiverAdvanced, "Fresh bandwidth must coincide with actual unchanged-geometry receiver delivery.")
            let errors = await state.errors
            XCTAssertEqual(errors, 0)
        } catch {
            await startupProbeClose(host: host, viewer: viewer, relays: relays, pump: pump, track: track, renderer: renderer)
            throw error
        }
        await startupProbeClose(host: host, viewer: viewer, relays: relays, pump: pump, track: track, renderer: renderer)
    }
}
#endif
