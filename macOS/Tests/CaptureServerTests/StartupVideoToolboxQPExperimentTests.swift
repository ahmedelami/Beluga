#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
@preconcurrency import VideoToolbox
import XCTest

/// Encoder-only falsifier, NOT WebRTC/native acceptance or a production configuration.
/// Run the four fresh processes in fixed order: QP39, unset, unset, QP39. The sole arm
/// difference is setting MaxAllowedFrameQP. The 12-frame, 5-fps input/rate schedule is
/// frozen from diagnostic 2's initial ramp, without its network or adaptive feedback.
/// Reuse the original dense/moving pixels AND signed-contrast oracle. Increased output
/// alone is never a promotion criterion: report every decoded frame's quality and bytes.
final class StartupVideoToolboxQPExperimentTests: XCTestCase {
    func testNativeQP39Characterization() async throws { try await run(maximumQP: 39) }
    func testNativeUnsetQPCharacterization() async throws { try await run(maximumQP: nil) }
    /// Separate live-property mutability probe, not a new arm of the frozen ABBA.
    func testNativeStartupQP39Restoration() async throws {
        try await run(maximumQP: nil, restoreQPBeforeInput: 10)
    }

    private func run(maximumQP: Int?, restoreQPBeforeInput: Int? = nil) async throws {
        guard ProcessInfo.processInfo.environment["OPENSTEAMER_RUN_VT_QP_EXPERIMENT"] == "1" else {
            throw XCTSkip("Explicit encoder-only experiment; not a default gate")
        }
        let pattern = try StartupClarityPattern(denseContent: true, movingContent: true)
        let arm = restoreQPBeforeInput == nil ? (maximumQP == nil ? "unset" : "qp39") : "startup-restore39"
        let collector = VTQPOutputCollector()
        var session: VTCompressionSession?
        let specs: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        let createStatus = VTCompressionSessionCreate(
            allocator: nil, width: 1_080, height: 1_920, codecType: kCMVideoCodecType_H264,
            encoderSpecification: specs as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { reference, frameReference, status, flags, sample in
                guard let reference else { return }
                Unmanaged<VTQPOutputCollector>.fromOpaque(reference).takeUnretainedValue()
                    .append(index: Int(bitPattern: frameReference) - 1, status: status,
                            flags: flags.rawValue, sample: sample)
            }, refcon: Unmanaged.passUnretained(collector).toOpaque(),
            compressionSessionOut: &session)
        XCTAssertEqual(createStatus, noErr)
        let encoder = try XCTUnwrap(session)
        // Invalidate before collector release, even if a property or submission throws.
        var encoderInvalidated = false
        defer {
            withExtendedLifetime(collector) {
                if !encoderInvalidated { VTCompressionSessionInvalidate(encoder) }
            }
        }
        var properties: [[String: Any]] = []
        var hardware: [[String: Any]] = []
        var restorationReadbacks: [[String: Any]] = []
        defer {
            // Keep setup evidence even when an unsupported required property stops
            // the experiment before its first input (never call that a codec result).
            let setup: [String: Any] = ["arm": arm,
                                        "properties": properties, "hardware": hardware]
            if let data = try? JSONSerialization.data(withJSONObject: setup, options: [.sortedKeys]) {
                print("STARTUP_VT_QP_SETUP " + String(decoding: data, as: UTF8.self))
            }
        }
        func read(_ key: CFString) -> [String: Any] {
            var reference: Unmanaged<CFTypeRef>?
            let status = VTSessionCopyProperty(encoder, key: key, allocator: nil, valueOut: &reference)
            let value = reference?.takeRetainedValue()
            var result: [String: Any] = ["key": key as String, "status": status]
            if let value {
                result["typeID"] = CFGetTypeID(value)
                if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    result["boolean"] = (value as! NSNumber).boolValue
                } else if let value = value as? NSNumber { result["number"] = value }
                else if let value = value as? String { result["string"] = value }
                else if let value = value as? [NSNumber] { result["numbers"] = value }
            }
            return result
        }
        func readHardware(_ phase: String) {
            var result = read(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
            result["phase"] = phase
            hardware.append(result)
        }
        func set(_ key: CFString, _ value: CFTypeRef, index: Int? = nil,
                 allowUnsupported: Bool = false) throws {
            let status = VTSessionSetProperty(encoder, key: key, value: value)
            var result = read(key)
            result["setStatus"] = status
            if let index { result["beforeInput"] = index }
            properties.append(result)
            // The pinned SDK attempts this speed hint but continues when unsupported.
            // This exact nonfatal case must match across arms before interpretation.
            if allowUnsupported && status == kVTPropertyNotSupportedErr { return }
            // Unsupported controls cannot masquerade as an applied single-variable arm.
            XCTAssertEqual(status, noErr, key as String)
            guard status == noErr else { throw VTQPFailure.property(status) }
        }
        readHardware("created")
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue,
                allowUnsupported: true)
        if let maximumQP { try set(kVTCompressionPropertyKey_MaxAllowedFrameQP, maximumQP as CFNumber) }
        // Filled from the same SDK's advertised constrained-high maximum, not a new
        // baseline profile (which would change low-latency/hardware behavior as well).
        let codec = try XCTUnwrap(LKRTCDefaultVideoEncoderFactory().supportedCodecs().first {
            $0.name == "H264" && $0.parameters["profile-level-id"]?.hasPrefix("640c") == true
        })
        let profileID = try XCTUnwrap(codec.parameters["profile-level-id"])
        let levels: [String: CFString] = [
            "1e": kVTProfileLevel_H264_High_3_0, "1f": kVTProfileLevel_H264_High_3_1,
            "20": kVTProfileLevel_H264_High_3_2, "28": kVTProfileLevel_H264_High_4_0,
            "29": kVTProfileLevel_H264_High_4_1, "2a": kVTProfileLevel_H264_High_4_2,
            "32": kVTProfileLevel_H264_High_5_0, "33": kVTProfileLevel_H264_High_5_1,
            "34": kVTProfileLevel_H264_High_5_2
        ]
        let profile = try XCTUnwrap(levels[String(profileID.suffix(2))])
        try set(kVTCompressionPropertyKey_ProfileLevel, profile)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 7_200 as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240 as CFNumber)
        readHardware("configured")
        let qpReadback = read(kVTCompressionPropertyKey_MaxAllowedFrameQP)
        if let maximumQP {
            XCTAssertEqual(qpReadback["status"] as? Int32, noErr)
            XCTAssertEqual((qpReadback["number"] as? NSNumber)?.intValue, maximumQP)
        }
        var rates = [235_000, 235_000, 710_000, 720_000, 720_000, 720_000,
                     1_405_000, 2_662_000, 5_361_000, 5_361_000, 5_361_000, 5_619_000]
        if restoreQPBeforeInput != nil {
            XCTAssertEqual(qpReadback["status"] as? Int32, noErr)
            XCTAssertEqual((qpReadback["number"] as? NSNumber)?.intValue, -1)
            // Six extra tail inputs prove the same live session can produce frames
            // after restoration. The original 12-frame ABBA arms remain unchanged.
            rates += Array(repeating: 5_619_000, count: 6)
        }
        var inputs: [[String: Any]] = []
        let started = DispatchTime.now().uptimeNanoseconds
        var previousRate = 0
        for index in rates.indices {
            let target = started + UInt64(index) * 200_000_000
            let now = DispatchTime.now().uptimeNanoseconds
            if now < target { try await Task.sleep(nanoseconds: target - now) }
            if index == restoreQPBeforeInput {
                try set(kVTCompressionPropertyKey_MaxAllowedFrameQP, 39 as CFNumber, index: index)
            }
            if let restoreQPBeforeInput {
                var observation = read(kVTCompressionPropertyKey_MaxAllowedFrameQP)
                observation["beforeInput"] = index
                observation["elapsedMs"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                restorationReadbacks.append(observation)
                XCTAssertEqual(observation["status"] as? Int32, noErr)
                XCTAssertEqual((observation["number"] as? NSNumber)?.intValue,
                               index < restoreQPBeforeInput ? -1 : 39)
            }
            if index == 0 { try set(kVTCompressionPropertyKey_ExpectedFrameRate, 5 as CFNumber, index: index) }
            let rate = rates[index]
            if previousRate != rate {
                try set(kVTCompressionPropertyKey_AverageBitRate, rate as CFNumber, index: index)
                // Same pinned SDK VBR policy: 10x peak/1s and target average/5s.
                let limits = [NSNumber(value: rate * 10 / 8), 1,
                              NSNumber(value: rate / 8 * 5), 5] as CFArray
                try set(kVTCompressionPropertyKey_DataRateLimits, limits, index: index)
                previousRate = rate
            }
            let pts = CMTime(value: Int64(1_000 + index * 200), timescale: 1_000)
            let phase = (index * 6) % pattern.buffers.count
            let submitted = DispatchTime.now().uptimeNanoseconds
            var info = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: pattern.buffers[phase], presentationTimeStamp: pts,
                duration: .invalid,
                frameProperties: index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
                sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: index + 1), infoFlagsOut: &info)
            inputs.append(["index": index, "phase": phase, "ptsMs": 1_000 + index * 200,
                           "rateBps": rate, "elapsedMs": Double(submitted - started) / 1_000_000,
                           "latenessMs": Double(submitted - target) / 1_000_000,
                           "status": status, "flags": info.rawValue])
            XCTAssertEqual(status, noErr)
            XCTAssertLessThan(Double(submitted - target) / 1_000_000, 50,
                              "Scheduling slip invalidates the fixed-cadence comparison")
            if index == 0 { readHardware("firstSubmission") }
        }
        let completeStatus = VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        XCTAssertEqual(completeStatus, noErr)
        readHardware("completed")
        VTCompressionSessionInvalidate(encoder)
        encoderInvalidated = true
        let outputs = collector.snapshot()
        XCTAssertFalse(collector.overflowed)
        let synchronousDrops = Set(inputs.compactMap { input -> Int? in
            guard let flags = input["flags"] as? UInt32,
                  flags & VTEncodeInfoFlags.frameDropped.rawValue != 0 else { return nil }
            return input["index"] as? Int
        })
        XCTAssertEqual(Set(outputs.map(\.index)).count, outputs.count, "Duplicate completion callback")
        XCTAssertEqual(Set(outputs.map(\.index)).union(synchronousDrops), Set(rates.indices),
                       "Every accepted input needs output or an explicit terminal drop")
        XCTAssertTrue(Set(outputs.filter { $0.sample != nil }.map(\.index)).isDisjoint(with: synchronousDrops))
        XCTAssertTrue(outputs.allSatisfy { $0.status == noErr })
        XCTAssertTrue(outputs.allSatisfy { ($0.sample != nil) != ($0.flags & VTEncodeInfoFlags.frameDropped.rawValue != 0) })

        // Decode only after compression is fully drained: pixel analysis cannot slow
        // encoder callbacks or alter the treatment's input pacing.
        let renderer = StartupClarityRenderer()
        let samples = outputs.filter { $0.sample != nil }.sorted { $0.index < $1.index }
        // All-dropped is an important characterization outcome, not setup failure.
        if let firstSample = samples.first?.sample {
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(firstSample))
        var decoder: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { reference, frameReference, status, _, image, _, _ in
                guard let reference else { return }
                let collector = Unmanaged<VTQPDecodeCollector>.fromOpaque(reference).takeUnretainedValue()
                collector.append(index: Int(bitPattern: frameReference) - 1, status: status, image: image)
            }, decompressionOutputRefCon: nil)
        let decoded = VTQPDecodeCollector(renderer: renderer)
        callback.decompressionOutputRefCon = Unmanaged.passUnretained(decoded).toOpaque()
        let decodeCreate = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decoder)
        XCTAssertEqual(decodeCreate, noErr)
        let decodeSession = try XCTUnwrap(decoder)
        var decoderInvalidated = false
        defer {
            withExtendedLifetime(decoded) {
                if !decoderInvalidated { VTDecompressionSessionInvalidate(decodeSession) }
            }
        }
        for output in samples {
            let status = VTDecompressionSessionDecodeFrame(
                decodeSession, sampleBuffer: try XCTUnwrap(output.sample), flags: [],
                frameRefcon: UnsafeMutableRawPointer(bitPattern: output.index + 1), infoFlagsOut: nil)
            XCTAssertEqual(status, noErr)
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(decodeSession), noErr)
        VTDecompressionSessionInvalidate(decodeSession)
        decoderInvalidated = true
        XCTAssertTrue(decoded.statuses.allSatisfy { $0 == noErr })
        }
        let observations = renderer.snapshot()
        XCTAssertEqual(observations.count, samples.count)
        XCTAssertEqual(Set(observations.map { Int($0.timestamp) }), Set(samples.map(\.index)))
        if let restoreQPBeforeInput {
            XCTAssertTrue(observations.contains { Int($0.timestamp) >= restoreQPBeforeInput },
                          "Successful property readback is not post-restoration encoding proof")
            XCTAssertTrue(observations.allSatisfy {
                $0.width == 1_080 && $0.height == 1_920 && $0.signedIdealNormalizedContrast.minimum > 0.9
            }, "Restoration must retain the same pixel oracle")
        }
        let referenceRenderer = StartupClarityRenderer()
        for phase in pattern.buffers.indices {
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pattern.buffers[phase]),
                                       rotation: ._0, timeStampNs: Int64(phase + 1) * 200_000_000)
            frame.timeStamp = Int32(phase)
            referenceRenderer.renderFrame(frame)
        }
        let references = Dictionary(uniqueKeysWithValues: referenceRenderer.snapshot().map { (Int($0.timestamp), $0) })
        let report: [String: Any] = [
            "schemaVersion": restoreQPBeforeInput == nil ? 1 : 2, "scope": "isolated-video-toolbox-not-webrtc-replay",
            "arm": arm, "maximumQP": maximumQP as Any? ?? NSNull(),
            "restoreQPBeforeInput": restoreQPBeforeInput as Any? ?? NSNull(),
            "restorationReadbacks": restorationReadbacks,
            "profileLevelID": profileID, "profile": profile as String,
            "qpReadback": qpReadback, "hardware": hardware, "properties": properties,
            "inputs": inputs, "compressionDrained": completeStatus == noErr,
            "synchronousDropIndices": synchronousDrops.sorted(),
            "hasEncodedSamples": !samples.isEmpty,
            "outputs": outputs.map { output -> [String: Any] in
                ["index": output.index, "status": output.status, "flags": output.flags,
                 "elapsedMs": Double(output.uptime - started) / 1_000_000,
                 "bytes": output.sample.map(CMSampleBufferGetTotalSampleSize) ?? 0]
            },
            "decoded": observations.map { observation -> [String: Any] in
                let index = Int(observation.timestamp)
                let phase = (index * 6) % pattern.buffers.count
                let reference = references[phase]!
                let differences = zip(observation.denseLuma, reference.denseLuma).map { $0 - $1 }
                let rms = sqrt(differences.map { $0 * $0 }.reduce(0, +) / Double(differences.count))
                return ["index": index, "width": observation.width, "height": observation.height,
                 "contrast": observation.signedIdealNormalizedContrast.minimum,
                 "denseRMSE": rms, "expectedMotionPhase": phase,
                 "motionPhase": observation.motionPhase as Any? ?? NSNull()]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("STARTUP_VT_QP_EXPERIMENT " + String(decoding: data, as: UTF8.self))
    }
}

private enum VTQPFailure: Error { case property(OSStatus) }

private final class VTQPOutputCollector: @unchecked Sendable {
    struct Output {
        let index: Int
        let status: OSStatus
        let flags: UInt32
        let uptime: UInt64
        let sample: CMSampleBuffer?
    }
    private let lock = NSLock()
    private var outputs: [Output] = []
    private(set) var overflowed = false
    func append(index: Int, status: OSStatus, flags: UInt32, sample: CMSampleBuffer?) {
        lock.withLock {
            guard outputs.count < 32 else { overflowed = true; return }
            outputs.append(.init(index: index, status: status, flags: flags,
                                 uptime: DispatchTime.now().uptimeNanoseconds, sample: sample))
        }
    }
    func snapshot() -> [Output] { lock.withLock { outputs } }
}

private final class VTQPDecodeCollector: @unchecked Sendable {
    let renderer: StartupClarityRenderer
    private let lock = NSLock()
    private var recordedStatuses: [OSStatus] = []
    var statuses: [OSStatus] { lock.withLock { recordedStatuses } }
    init(renderer: StartupClarityRenderer) { self.renderer = renderer }
    func append(index: Int, status: OSStatus, image: CVImageBuffer?) {
        lock.withLock { if recordedStatuses.count < 32 { recordedStatuses.append(status) } }
        guard status == noErr, let image else { return }
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: image), rotation: ._0,
                                   timeStampNs: Int64(index + 1) * 200_000_000)
        frame.timeStamp = Int32(index)
        renderer.renderFrame(frame)
    }
}
#endif
