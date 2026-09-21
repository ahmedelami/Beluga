#if os(macOS)
import CryptoKit
import Darwin
import Foundation
@preconcurrency import LiveKitWebRTC
@testable import WebRTCTransport

/// Test-only bridge to an explicitly preloaded, sealed public-VideoToolbox hook.
/// This does not alter the SDK binary, codec mode, settings, callback, or native result.
/// Only sessions synchronously created by this video-only host's encoder are eligible.
final class StartupVideoQPOwnerHook: @unchecked Sendable {
    private typealias Begin = @convention(c) (UInt64, UInt64, UInt32, Int32, Int32) -> Int32
    private typealias End = @convention(c) () -> Int32
    private typealias StartupWindow = @convention(c) () -> UInt64
    private typealias Copy = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private let begin: Begin
    private let end: End
    private let copy: Copy
    private let free: Free
    private let lock = NSLock()
    private var owners: UInt64 = 0
    private var scopeFailures = 0
    private var factoryWrapped = false
    private var finished = false
    let mode: UInt32
    let artifactSHA256: String

    static func requested(eligible: Bool,
                          environment: [String: String] = ProcessInfo.processInfo.environment) throws -> StartupVideoQPOwnerHook? {
        guard environment["OPENSTEAMER_VT_QP_MODE"] != nil else { return nil }
        guard eligible, environment["OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"] == "1",
              environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] == "1" else {
            throw WebRTCTransportError.nativeFailure("QP hook requires the exact video-only encoder-boundary diagnostic")
        }
        return try StartupVideoQPOwnerHook(environment: environment)
    }

    private init(environment: [String: String]) throws {
        #if !DEBUG
        throw WebRTCTransportError.nativeFailure("QP hook is forbidden in release tests")
        #else
        switch environment["OPENSTEAMER_VT_QP_MODE"] {
        case "control": mode = 0
        case "unset": mode = 1
        case "startup": mode = 2
        default: throw WebRTCTransportError.nativeFailure("Unknown QP diagnostic arm")
        }
        guard let path = environment["OPENSTEAMER_VT_QP_HOOK_PATH"], path.hasPrefix("/"),
              environment["DYLD_INSERT_LIBRARIES"] == path,
              let expected = environment["OPENSTEAMER_VT_QP_HOOK_SHA256"],
              expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw WebRTCTransportError.nativeFailure("QP hook requires one explicit fresh-process artifact")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path)))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased(),
              let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD),
              let beginPointer = dlsym(handle, "VTQPBegin"), let endPointer = dlsym(handle, "VTQPEnd"),
              let copyPointer = dlsym(handle, "VTQPCopyReportJSON"),
              let freePointer = dlsym(handle, "VTQPFreeReportJSON"),
              let loadedPointer = dlsym(handle, "VTQPIsInterposerLoaded") else {
            throw WebRTCTransportError.nativeFailure("QP diagnostic image was not preloaded with the sealed identity")
        }
        begin = unsafeBitCast(beginPointer, to: Begin.self)
        end = unsafeBitCast(endPointer, to: End.self)
        copy = unsafeBitCast(copyPointer, to: Copy.self)
        free = unsafeBitCast(freePointer, to: Free.self)
        guard unsafeBitCast(loadedPointer, to: End.self)() == 1 else {
            throw WebRTCTransportError.nativeFailure("QP diagnostic hook did not identify itself")
        }
        if mode == 2 {
            guard let pointer = dlsym(handle, "VTQPStartupWindowNanoseconds"),
                  unsafeBitCast(pointer, to: StartupWindow.self)() == 2_000_000_000 else {
                throw WebRTCTransportError.nativeFailure("Startup QP hook requires the fixed two-second native admission boundary")
            }
        }
        artifactSHA256 = digest
        // Never dlclose an interposed image while the native SDK remains loaded.
        #endif
    }

    func wrap(_ downstream: any LKRTCVideoEncoderFactory) throws -> any LKRTCVideoEncoderFactory {
        let admitted = lock.withLock {
            guard !factoryWrapped, !finished else { scopeFailures += 1; return false }
            factoryWrapped = true
            return true
        }
        guard admitted else { throw WebRTCTransportError.nativeFailure("QP hook factory owner reused") }
        return QPOwnerEncoderFactory(downstream: downstream, hook: self)
    }

    fileprivate func newOwner(codec: LKRTCVideoCodecInfo) -> UInt64 {
        lock.withLock {
            guard !finished, owners < 64, codec.name == "H264" else { scopeFailures += 1; return 0 }
            owners += 1
            return owners
        }
    }

    fileprivate func scoped<Result>(owner: UInt64, generation: UInt64, width: Int32, height: Int32,
                                     _ body: () -> Result) -> Result {
        let entered = begin(owner, generation, mode, width, height) == 1
        if !entered { lock.withLock { scopeFailures += 1 } }
        defer {
            if entered, end() != 1 { lock.withLock { scopeFailures += 1 } }
        }
        // A diagnostic failure never invents a native result or swallows callbacks.
        return body()
    }

    func finish() throws -> [String: Any] {
        let swiftState = lock.withLock { () -> (UInt64, Int, Bool) in
            if finished { scopeFailures += 1 }
            finished = true
            return (owners, scopeFailures, factoryWrapped)
        }
        guard let pointer = copy() else {
            throw WebRTCTransportError.nativeFailure("QP hook cannot retire while native owners remain active")
        }
        defer { free(pointer) }
        let data = Data(bytes: pointer, count: strnlen(pointer, 1_048_576))
        guard var report = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebRTCTransportError.nativeFailure("QP hook returned malformed evidence")
        }
        report["swiftOwnerCount"] = swiftState.0
        report["swiftScopeFailures"] = swiftState.1
        report["factoryWrapped"] = swiftState.2
        report["artifactSHA256"] = artifactSHA256
        report["requestedMode"] = mode == 0 ? "control" : (mode == 1 ? "unset" : "startup")
        report["combinedVerified"] = report["isVerified"] as? Bool == true
            && swiftState.0 > 0 && swiftState.1 == 0 && swiftState.2
        return report
    }
}

private final class QPOwnerEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    let downstream: any LKRTCVideoEncoderFactory
    let hook: StartupVideoQPOwnerHook
    init(downstream: any LKRTCVideoEncoderFactory, hook: StartupVideoQPOwnerHook) {
        self.downstream = downstream; self.hook = hook
        super.init()
    }
    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard let encoder = downstream.createEncoder(info) else { return nil }
        return QPOwnerEncoder(downstream: encoder, hook: hook, owner: hook.newOwner(codec: info))
    }
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { downstream.supportedCodecs() }
    func implementations() -> [LKRTCVideoCodecInfo] { downstream.implementations?() ?? downstream.supportedCodecs() }
    func encoderSelector() -> (any LKRTCVideoEncoderSelector)? { downstream.encoderSelector?() }
    func queryCodecSupport(_ info: LKRTCVideoCodecInfo, scalabilityMode: String?) -> LKRTCVideoEncoderCodecSupport {
        downstream.queryCodecSupport?(info, scalabilityMode: scalabilityMode) ?? LKRTCVideoEncoderCodecSupport(supported: false)
    }
    override func responds(to selector: Selector!) -> Bool {
        switch NSStringFromSelector(selector) {
        case "implementations", "encoderSelector", "queryCodecSupport:scalabilityMode:":
            (downstream as AnyObject).responds(to: selector)
        default: super.responds(to: selector)
        }
    }
}

private final class QPOwnerEncoder: NSObject, LKRTCVideoEncoder {
    let downstream: any LKRTCVideoEncoder
    let hook: StartupVideoQPOwnerHook
    let owner: UInt64
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var width: Int32 = 0
    private var height: Int32 = 0
    init(downstream: any LKRTCVideoEncoder, hook: StartupVideoQPOwnerHook, owner: UInt64) {
        self.downstream = downstream; self.hook = hook; self.owner = owner
        super.init()
    }
    private func scoped<Result>(_ body: () -> Result) -> Result {
        let state = lock.withLock { (generation, width, height) }
        return hook.scoped(owner: owner, generation: state.0, width: state.1, height: state.2, body)
    }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.withLock {
            generation += 1
            width = Int32(clamping: settings.width)
            height = Int32(clamping: settings.height)
        }
        return scoped { downstream.startEncode(with: settings, numberOfCores: numberOfCores) }
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        scoped { downstream.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes) }
    }
    func release() -> Int { scoped { downstream.release() } }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        scoped { downstream.setBitrate(bitrateKbit, framerate: framerate) }
    }
    func setCallback(_ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?) {
        downstream.setCallback(callback)
    }
    func implementationName() -> String { downstream.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { downstream.scalingSettings() }
    var resolutionAlignment: Int { downstream.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { downstream.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { downstream.supportsNativeHandle }
}
#endif
