#if os(macOS)
import AudioToolbox
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

private enum StartupLifecycleFailure: Error { case setup, timeout }

private actor StartupLifecycleState {
    var video: WebRTCRemoteVideoTrack?
    var audio: WebRTCRemoteAudioTrack?
    var acknowledgements: [UInt64: WebRTCScreenState] = [:]
    var errors = 0
    var connections = [0, 0]

    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        if case .peerStateChanged(.connected) = event { connections[viewerSide ? 1 : 0] += 1 }
        if viewerSide, case .remoteVideoTrack(let track) = event { video = track }
        if viewerSide, case .remoteAudioTrack(let track) = event { audio = track }
        if viewerSide, case .controlAcknowledgementReceived(let ack, _) = event {
            acknowledgements[ack.id] = ack.state
        }
    }
    func failed() { errors += 1 }
}

private final class StartupLifecycleVideo: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestamp: Int32?
    private var count = 0
    private var wrongGeometry = false
    private var lastLuma: UInt8 = 0
    func setSize(_: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let luma = frame.buffer.toI420().dataY[0]
        lock.withLock {
            if frame.timeStamp != lastTimestamp { count += 1; lastTimestamp = frame.timeStamp }
            wrongGeometry = wrongGeometry || frame.width != 270 || frame.height != 480
            lastLuma = luma
        }
    }
    func snapshot() -> (count: Int, luma: UInt8, wrongGeometry: Bool) {
        lock.withLock { (count, lastLuma, wrongGeometry) }
    }
}

private final class StartupLifecycleAudio: @unchecked Sendable {
    struct Batch: Sendable {
        let time: ContinuousClock.Instant
        let frames: Int
        let valid: Bool
        let energy: Double
        let recognizedPhase: Int?
    }
    private let lock = NSLock()
    private var batches: [Batch] = []
    private var overflow = false

    func observe(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        var valid = buffer.format.channelCount == 2 && buffer.format.sampleRate == 48_000
            && frames > 0 && frames <= 1_920
        var amplitudes = [Double](repeating: 0, count: 6)
        var energy = 0.0
        if valid {
            for channel in 0..<2 {
                for phase in 0..<3 {
                    let frequency = Double((500 + phase * 200) * (channel + 1))
                    var sine = 0.0, cosine = 0.0
                    for frame in 0..<frames {
                        let index = buffer.format.isInterleaved ? frame * 2 + channel : frame
                        let plane = buffer.format.isInterleaved ? 0 : channel
                        let sample: Double
                        switch buffer.format.commonFormat {
                        case .pcmFormatInt16:
                            if let data = buffer.int16ChannelData { sample = Double(data[plane][index]) / 32_768 }
                            else { valid = false; sample = 0 }
                        case .pcmFormatFloat32:
                            if let data = buffer.floatChannelData { sample = Double(data[plane][index]) }
                            else { valid = false; sample = 0 }
                        default: valid = false; sample = 0
                        }
                        if !sample.isFinite { valid = false; continue }
                        let angle = 2 * Double.pi * frequency * Double(frame) / 48_000
                        sine += sample * sin(angle); cosine += sample * cos(angle)
                        if phase == 0 { energy += sample * sample }
                    }
                    amplitudes[channel * 3 + phase] = 2 * hypot(sine, cosine) / Double(frames)
                }
            }
        }
        let recognized = (0..<3).first { phase in
            amplitudes[phase] > 0.035 && amplitudes[3 + phase] > 0.035
                && (0..<3).filter { $0 != phase }.allSatisfy {
                    amplitudes[phase] > amplitudes[$0] * 2
                        && amplitudes[3 + phase] > amplitudes[3 + $0] * 2
                }
        }
        let batch = Batch(time: .now, frames: frames, valid: valid,
            energy: frames > 0 ? energy / Double(frames * 2) : 0, recognizedPhase: recognized)
        lock.withLock {
            if batches.count < 3_000 { batches.append(batch) } else { overflow = true }
        }
    }

    func snapshot(since time: ContinuousClock.Instant) -> (batches: [Batch], overflow: Bool) {
        lock.withLock { (batches.filter { $0.time >= time }, overflow) }
    }
}

private final class StartupLifecyclePump: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = 0
    private var videoEnabled = false
    private var videoAttempts = 0
    private let audio: MacExternalAudioCapturer
    private let video: MacExternalVideoCapturer
    private let pixels: [CVPixelBuffer]

    init(audio: MacExternalAudioCapturer, video: MacExternalVideoCapturer) throws {
        self.audio = audio; self.video = video
        pixels = try [UInt8(0x30), UInt8(0xB0)].map { value in
            var result: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 1080, 1920, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
                let result, CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else {
                throw StartupLifecycleFailure.setup
            }
            memset(CVPixelBufferGetBaseAddress(result), Int32(value), CVPixelBufferGetDataSize(result))
            CVPixelBufferUnlockBaseAddress(result, [])
            return result
        }
    }

    func set(phase: Int, videoEnabled: Bool) {
        lock.withLock { self.phase = phase; self.videoEnabled = videoEnabled }
    }

    func videoAttemptCount() -> Int { lock.withLock { videoAttempts } }

    func run(viewer: WebRTCPeer) async {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(24))
        let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var samples = [Int16](repeating: 0, count: 960), tick = 0
        var next = clock.now
        while !Task.isCancelled && clock.now < deadline {
            let state = lock.withLock { (phase, videoEnabled) }
            for frame in 0..<480 {
                for channel in 0..<2 {
                    let frequency = Double((500 + state.0 * 200) * (channel + 1))
                    samples[frame * 2 + channel] = Int16((6_000 * sin(
                        2 * Double.pi * frequency * Double(tick * 480 + frame) / 48_000)).rounded())
                }
            }
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                withUnsafePointer(to: &list) {
                    audio.capture(audioBufferList: $0, format: format, frameCount: 480,
                        presentationTime: CMTime(value: Int64(tick * 480), timescale: 48_000))
                }
            }
            if state.1 && tick.isMultiple(of: 20) {
                lock.withLock { videoAttempts += 1 }
                video.capture(pixelBuffer: pixels[state.0 == 2 ? 1 : 0],
                    timestampNanoseconds: Int64(clamping: DispatchTime.now().uptimeNanoseconds))
            }
            _ = await viewer.pullHeadlessMacViewerAudioForTesting()
            tick += 1
            next = next.advanced(by: .milliseconds(10))
            if next < clock.now { next = clock.now.advanced(by: .milliseconds(10)) }
            do { try await clock.sleep(until: next) } catch { break }
        }
    }
}

private func startupLifecycleRelay(from: WebRTCPeer, to: WebRTCPeer,
    viewerSide: Bool, state: StartupLifecycleState) -> Task<Void, Never> {
    Task {
        do {
            for await event in from.events {
                await state.observe(event, viewerSide: viewerSide)
                if case .outboundSignal(let payload) = event { try await to.handle(payload) }
                if !viewerSide, case .controlRequestReceived(let request) = event {
                    if request.command == .showScreen {
                        try await from.acknowledgeActiveControlRequestIfTransportHealthy(
                            id: request.id, authorization: WebRTCControlAuthorization())
                    } else if request.command == .hideScreen {
                        try await from.acknowledgeControlRequest(id: request.id, state: .inactive)
                    }
                }
            }
        } catch { if !Task.isCancelled { await state.failed() } }
    }
}

private func startupLifecycleWait(timeout: Duration = .seconds(5),
    _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw StartupLifecycleFailure.timeout }
        try await Task.sleep(for: .milliseconds(20))
    }
}

final class WebRTCStartupProbeLifecycleTests: XCTestCase {
    // Run this filter alone in a fresh process. Configuration is production-owned; diagnostics
    // count both fixture peers and must never be presented as a single peer's probe ownership.
    func testNativeProbingPreservesStereoAcrossSamePeerShowHideShow() async throws {
        let host = try WebRTCPeer(configuration: .init(role: .host, iceServers: []))
        let viewer: WebRTCPeer
        do { viewer = try WebRTCPeer.makeHeadlessViewerForTesting(configuration: .init(role: .viewer, iceServers: [])) }
        catch { await host.close(reason: .normal); throw error }
        let state = StartupLifecycleState(), video = StartupLifecycleVideo(), audio = StartupLifecycleAudio()
        let audioRenderer = WebRTCAudioPCMRenderer { audio.observe($0) }
        let relays = [startupLifecycleRelay(from: host, to: viewer, viewerSide: false, state: state),
                      startupLifecycleRelay(from: viewer, to: host, viewerSide: true, state: state)]
        var pumpTask: Task<Void, Never>?
        var videoTrack: WebRTCRemoteVideoTrack?, audioTrack: WebRTCRemoteAudioTrack?
        var nativeEvents: [WebRTCNativeProbeEvent] = []
        var failure: Error?
        func drain() {
            let batch = WebRTCNativeProbeDiagnostics.drain()
            XCTAssertEqual(batch.droppedEventCount, 0)
            XCTAssertLessThan(nativeEvents.count + batch.events.count, 512)
            nativeEvents.append(contentsOf: batch.events.prefix(max(0, 512 - nativeEvents.count)))
        }
        func dwell(_ duration: Duration) async throws {
            let until = ContinuousClock.now.advanced(by: duration)
            repeat { drain(); try await Task.sleep(for: .milliseconds(100)) } while ContinuousClock.now < until
        }
        func limits(_ cap: Int) -> WebRTCScreenVideoEncodingLimits {
            .init(maximumBitrateBps: 39_744_000, maximumFramesPerSecond: 5,
                scaleResolutionDownBy: 4, maximumTotalRTPBitrateBps: cap)
        }
        func checkAudio(since start: ContinuousClock.Instant, phase: Int) {
            let observed = audio.snapshot(since: start)
            XCTAssertFalse(observed.overflow)
            XCTAssertFalse(observed.batches.isEmpty)
            XCTAssertTrue(observed.batches.allSatisfy(\.valid))
            let total = observed.batches.reduce(0) { $0 + $1.frames }
            let recognized = observed.batches.filter { $0.recognizedPhase == phase }.reduce(0) { $0 + $1.frames }
            XCTAssertGreaterThanOrEqual(recognized, 24_000, "Fresh channel-specific PCM must advance in every phase.")
            XCTAssertGreaterThan(Double(recognized), Double(total) * 0.8)
            let duration = start.duration(to: .now).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            XCTAssertGreaterThan(Double(total), seconds * 48_000 * 0.7,
                "Sparse callbacks must not masquerade as sustained headless playback.")
        }
        do {
            _ = try await host.applyScreenVideoEncodingLimits(limits(486_001))
            try await host.start()
            try await startupLifecycleWait(timeout: .seconds(10)) {
                let healthy = await host.isTransportHealthyForCapture()
                let hasVideo = await state.video != nil
                let hasAudio = await state.audio != nil
                return healthy && hasVideo && hasAudio
            }
            let receivedVideo = await state.video, receivedAudio = await state.audio
            let vt = try XCTUnwrap(receivedVideo), at = try XCTUnwrap(receivedAudio)
            videoTrack = vt; audioTrack = at
            await MainActor.run { vt.addRenderer(video) }
            at.addRendererForTesting(audioRenderer); at.setEnabled(true)
            let authorization = WebRTCAudioAuthorization()
            try await host.enableSystemAudioIfTransportHealthy(authorization: authorization)
            let capturer = try XCTUnwrap(host.externalAudioCapturer)
            let screen = try XCTUnwrap(host.externalVideoCapturer)
            screen.adaptOutput(width: 1080, height: 1920, framesPerSecond: 5)
            let pump = try StartupLifecyclePump(audio: capturer, video: screen)
            pumpTask = Task.detached { await pump.run(viewer: viewer) }
            let show = try await viewer.setScreenVisible(true)
            try await startupLifecycleWait { await state.acknowledgements[show] == .active }
            pump.set(phase: 0, videoEnabled: true)
            try await startupLifecycleWait { video.snapshot().count >= 5 }
            try await dwell(.milliseconds(500))
            let audioStarted = ContinuousClock.now
            let beforeConnections = await state.connections
            let beforeInput = capturer.diagnosticsForTesting()
            XCTAssertEqual(beforeConnections, [1, 1])
            XCTAssertTrue(beforeInput.usesCustomStereoDevice)
            XCTAssertTrue(beforeInput.customDeviceRecording)
            drain()
            let beforeRaiseSequence = nativeEvents.last?.sequence ?? 0
            let firstProbeStarted = ContinuousClock.now
            _ = try await host.applyScreenVideoEncodingLimits(limits(1_538_822))
            let raisedCap = await host.maximumTotalRTPBitrateBpsForTesting()
            XCTAssertEqual(raisedCap, 1_538_822)
            try await dwell(.seconds(1))
            let raisedEvents = nativeEvents.filter { $0.sequence > beforeRaiseSequence }
            XCTAssertTrue(raisedEvents.contains {
                $0.kind == .clusterCreated && $0.isActive == true && $0.bitrateBps == 1_538_822
            }, "Audio must overlap this raised-cap probe, not only initial connection probes.")
            XCTAssertTrue(raisedEvents.contains {
                $0.kind == .probeSucceeded && ($0.receiveBitrateBps ?? 0) >= 1_000_000
            }, "The raised-cap window must include actual feedback while stereo PCM advances.")
            checkAudio(since: audioStarted, phase: 0)
            XCTAssertLessThan(video.snapshot().luma, 100)

            pump.set(phase: 1, videoEnabled: true)
            let hide = try await viewer.setScreenVisible(false)
            XCTAssertGreaterThan(hide, show)
            try await startupLifecycleWait { await state.acknowledgements[hide] == .inactive }
            let inactive = await host.screenVideoEncodingActivityForTesting()
            XCTAssertEqual(inactive, [false])
            _ = try await host.applyScreenVideoEncodingLimits(limits(486_001))
            let hiddenCap = await host.maximumTotalRTPBitrateBpsForTesting()
            XCTAssertEqual(hiddenCap, 486_001)
            XCTAssertLessThan(firstProbeStarted.duration(to: .now), .milliseconds(3_500))
            try await dwell(.milliseconds(750))
            let hiddenVideoCount = video.snapshot().count, hiddenStarted = ContinuousClock.now
            let hiddenAttempts = pump.videoAttemptCount()
            let hiddenNativeCount = nativeEvents.count
            // Include a complete native five-second ALR interval without requiring a probe.
            try await dwell(.seconds(6))
            XCTAssertGreaterThanOrEqual(pump.videoAttemptCount() - hiddenAttempts, 20,
                "Continue synthetic submissions so source silence cannot mask broken Hide gating.")
            XCTAssertEqual(video.snapshot().count, hiddenVideoCount, "No new decoded picture after the explicit drain.")
            checkAudio(since: hiddenStarted, phase: 1)
            let hiddenEventCount = nativeEvents.count - hiddenNativeCount
            XCTAssertTrue(authorization.isValid)
            let audioStillEnabled = await host.isSystemAudioEnabledForTesting
            XCTAssertTrue(audioStillEnabled)
            // Hidden padding/control traffic is allowed; only decoded picture cessation is asserted.
            XCTAssertGreaterThanOrEqual(nativeEvents.count, hiddenNativeCount)

            let resumed = try await viewer.setScreenVisible(true)
            XCTAssertGreaterThan(resumed, hide)
            try await startupLifecycleWait { await state.acknowledgements[resumed] == .active }
            pump.set(phase: 2, videoEnabled: true)
            let resumedProbeStarted = ContinuousClock.now
            _ = try await host.applyScreenVideoEncodingLimits(limits(1_538_822))
            try await startupLifecycleWait(timeout: .milliseconds(1500)) {
                video.snapshot().count >= hiddenVideoCount + 3 && video.snapshot().luma > 140
            }
            try await dwell(.milliseconds(500))
            let resumedStarted = ContinuousClock.now
            try await dwell(.seconds(1))
            checkAudio(since: resumedStarted, phase: 2)
            _ = try await host.applyScreenVideoEncodingLimits(limits(486_001))
            XCTAssertLessThan(resumedProbeStarted.duration(to: .now), .milliseconds(3500))
            let finalCap = await host.maximumTotalRTPBitrateBpsForTesting()
            XCTAssertEqual(finalCap, 486_001)
            XCTAssertFalse(video.snapshot().wrongGeometry)
            let finalConnections = await state.connections, errors = await state.errors
            XCTAssertEqual(finalConnections, beforeConnections, "Show/Hide must not reconnect either peer.")
            XCTAssertEqual(errors, 0)
            let finalInput = capturer.diagnosticsForTesting()
            XCTAssertGreaterThan(finalInput.customDeviceDeliveredFrames, beforeInput.customDeviceDeliveredFrames)
            XCTAssertEqual(finalInput.customDeviceDeliveryFailures, beforeInput.customDeviceDeliveryFailures)
            XCTAssertEqual(finalInput.customDeviceRecordingGeneration, beforeInput.customDeviceRecordingGeneration)
            let entire = audio.snapshot(since: audioStarted).batches
            XCTAssertTrue(entire.allSatisfy { $0.valid && $0.energy > 0.0001 })
            for pair in zip(entire, entire.dropFirst()) {
                XCTAssertLessThan(pair.0.time.duration(to: pair.1.time), .milliseconds(150),
                    "A later healthy callback must not erase a lifecycle playout stall.")
            }
            drain()
            XCTAssertTrue(nativeEvents.contains { $0.kind == .clusterCreated && $0.isActive == true })
            XCTAssertTrue(nativeEvents.contains { $0.kind == .probeSucceeded })
            print("STARTUP_LIFECYCLE_PROBES scope=process created="
                + String(nativeEvents.filter { $0.kind == .clusterCreated }.count)
                + " feedback=" + String(nativeEvents.filter { $0.kind == .probeSucceeded }.count)
                + " hiddenEvents=" + String(hiddenEventCount))
        } catch { failure = error }
        pumpTask?.cancel(); await pumpTask?.value
        if let videoTrack { await MainActor.run { videoTrack.removeRenderer(video) } }
        if let audioTrack { audioTrack.removeRendererForTesting(audioRenderer); audioTrack.setEnabled(false) }
        let hostClosed = await host.close(reason: .normal), viewerClosed = await viewer.close(reason: .normal)
        for relay in relays { relay.cancel() }
        for relay in relays { await relay.value }
        XCTAssertTrue(hostClosed); XCTAssertTrue(viewerClosed)
        if let failure { throw failure }
    }
}
#endif
