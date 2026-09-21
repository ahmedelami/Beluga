#if os(macOS)
import CryptoKit
import Darwin
import Foundation
@preconcurrency import LiveKitWebRTC
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

enum StartupVideoPacerMode: String, Sendable {
    case sdkDefault, zeroBurst, twentyMillisecondBurst
}

/// Explicitly loaded fixture artifact, never a release dependency or global SDK override.
final class StartupVideoPacerBridge: @unchecked Sendable {
    private typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias CreateDuration = @convention(c) (Int64) -> UnsafeMutableRawPointer?
    private typealias Verify = @convention(c) (UnsafeMutableRawPointer?, Int64) -> Int32
    private typealias WorkerID = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    private typealias CreateFactory = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias Snapshot = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private let makeZero: Create
    private let makeOrdinary: Create
    private let makeTwentyMillisecond: Create
    private let verify: Verify
    private let readWorkerID: WorkerID
    private let makeEstimatorFactory: CreateFactory
    private let readEstimatorSnapshot: Snapshot
    private let estimatorOwner: AnyObject?
    private let lock = NSLock()
    private var verifiedPeerCount = 0
    let artifactSHA256: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         observeEstimator: Bool = false, holdDelayGrowthInALR: Bool = false,
         skipProbesBelowCurrentEstimate: Bool = false,
         probeDurationMilliseconds: Int? = nil) throws {
        #if !DEBUG
        throw XCTSkip("Pacing injection is unavailable in release builds")
        #else
        guard environment["OPENSTEAMER_RUN_PACER_EXPERIMENT"] == "1" else {
            throw XCTSkip("Opt-in exact-artifact native pacing experiment")
        }
        if let probeDurationMilliseconds {
            guard [15, 40].contains(probeDurationMilliseconds), observeEstimator,
                  holdDelayGrowthInALR, skipProbesBelowCurrentEstimate else {
                throw WebRTCTransportError.nativeFailure("Probe duration requires a 15/40 ms held probe-cap observer")
            }
        }
        guard !holdDelayGrowthInALR || observeEstimator else {
            throw WebRTCTransportError.nativeFailure("ALR growth hold requires an estimator observer")
        }
        guard !skipProbesBelowCurrentEstimate || (holdDelayGrowthInALR && observeEstimator) else {
            throw WebRTCTransportError.nativeFailure("ALR probe cap requires held estimator observation")
        }
        guard let path = environment["OPENSTEAMER_PACER_BRIDGE_PATH"], path.hasPrefix("/"),
              let expected = environment["OPENSTEAMER_PACER_BRIDGE_SHA256"],
              expected.count == 64, expected.allSatisfy({ $0.isHexDigit }) else {
            throw WebRTCTransportError.nativeFailure("Missing pinned pacing experiment artifact")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == expected.lowercased() else {
            throw WebRTCTransportError.nativeFailure("Pacing experiment artifact identity mismatch")
        }
        // Objective-C classes register for the process lifetime; never unload their code.
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
              let zero = dlsym(handle, "BPCreateZeroBurstConfigurationRetained"),
              let ordinary = dlsym(handle, "BPCreateOrdinaryConfigurationRetained"),
              let twentyMillisecond = dlsym(handle, "BPCreateTwentyMillisecondBurstConfigurationRetained"),
              let readback = dlsym(handle, "BPVerifyCreatedPeerPacer"),
              let workerID = dlsym(handle, "BPGetPeerWorkerThreadID"),
              let observerCreate = dlsym(handle, "BPCreateEstimatorObserverRetained"),
              let holdObserverCreate = dlsym(handle, "BPCreateEstimatorALRGrowthHoldObserverRetained"),
              let probeCapObserverCreate = dlsym(handle, "BPCreateEstimatorALRProbeCapObserverRetained"),
              let factoryCreate = dlsym(handle, "BPCreateEstimatorFactoryRetained"),
              let snapshot = dlsym(handle, "BPCopyEstimatorSnapshotJSONRetained") else {
            throw WebRTCTransportError.nativeFailure("Pinned pacing experiment bridge did not load")
        }
        makeZero = unsafeBitCast(zero, to: Create.self)
        makeOrdinary = unsafeBitCast(ordinary, to: Create.self)
        makeTwentyMillisecond = unsafeBitCast(twentyMillisecond, to: Create.self)
        verify = unsafeBitCast(readback, to: Verify.self)
        readWorkerID = unsafeBitCast(workerID, to: WorkerID.self)
        makeEstimatorFactory = unsafeBitCast(factoryCreate, to: CreateFactory.self)
        readEstimatorSnapshot = unsafeBitCast(snapshot, to: Snapshot.self)
        if observeEstimator {
            let created: UnsafeMutableRawPointer?
            if let probeDurationMilliseconds {
                guard let create = dlsym(handle, "BPCreateEstimatorALRProbeDurationObserverRetained") else {
                    throw WebRTCTransportError.nativeFailure("Pinned bridge lacks the exact probe-duration owner")
                }
                created = unsafeBitCast(create, to: CreateDuration.self)(Int64(probeDurationMilliseconds))
            } else {
                let create = skipProbesBelowCurrentEstimate ? probeCapObserverCreate
                    : (holdDelayGrowthInALR ? holdObserverCreate : observerCreate)
                created = unsafeBitCast(create, to: Create.self)()
            }
            guard let pointer = created else {
                throw WebRTCTransportError.nativeFailure("Estimator observer preflight failed")
            }
            estimatorOwner = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        } else { estimatorOwner = nil }
        artifactSHA256 = digest
        #endif
    }

    var verifiedCount: Int { lock.withLock { verifiedPeerCount } }

    func estimatorSnapshot() throws -> StartupVideoNativeEstimatorSnapshot {
        guard let estimatorOwner,
              let pointer = readEstimatorSnapshot(Unmanaged.passUnretained(estimatorOwner).toOpaque()) else {
            throw WebRTCTransportError.nativeFailure("Estimator observer snapshot unavailable")
        }
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        guard let data = object as? Data else {
            throw WebRTCTransportError.nativeFailure("Estimator observer returned the wrong snapshot object")
        }
        return try StartupVideoNativeEstimatorSnapshot.decode(data)
    }

    private func createEstimatorFactory(encoder: any LKRTCVideoEncoderFactory,
                                        decoder: any LKRTCVideoDecoderFactory) throws -> LKRTCPeerConnectionFactory {
        guard let estimatorOwner,
              let pointer = makeEstimatorFactory(
                Unmanaged.passUnretained(encoder as AnyObject).toOpaque(),
                Unmanaged.passUnretained(decoder as AnyObject).toOpaque(),
                Unmanaged.passUnretained(estimatorOwner).toOpaque()) else {
            throw WebRTCTransportError.nativeFailure("Estimator factory preflight failed")
        }
        let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
        guard let factory = object as? LKRTCPeerConnectionFactory else {
            throw WebRTCTransportError.nativeFailure("Estimator bridge returned the wrong factory object")
        }
        return factory
    }

    func workerThreadID(of peer: WebRTCPeer) async throws -> UInt64 {
        #if DEBUG
        return try await peer.inspectVideoControlOnlyNativePeerForTesting { [self] native in
            let identity = readWorkerID(Unmanaged.passUnretained(native).toOpaque())
            guard identity != 0 else {
                throw WebRTCTransportError.nativeFailure("Native pacing worker identity not proven")
            }
            return identity
        }
        #else
        throw XCTSkip("Pacing injection is unavailable in release builds")
        #endif
    }

    func makeHost(configuration: WebRTCTransportConfiguration,
                  mode: StartupVideoPacerMode,
                  encoderBoundaryTrace: StartupVideoEncoderBoundaryTrace? = nil,
                  qpOwnerHook: StartupVideoQPOwnerHook? = nil) throws -> WebRTCPeer {
        #if DEBUG
        guard encoderBoundaryTrace == nil || (estimatorOwner != nil && mode == .sdkDefault) else {
            throw WebRTCTransportError.nativeFailure("Encoder boundary trace requires the isolated native observer")
        }
        guard qpOwnerHook == nil || encoderBoundaryTrace != nil else {
            throw WebRTCTransportError.nativeFailure("QP hook requires owned encoder-boundary tracing")
        }
        let factoryHook: (@Sendable (any LKRTCVideoEncoderFactory, any LKRTCVideoDecoderFactory) throws -> LKRTCPeerConnectionFactory)?
        if estimatorOwner != nil {
            factoryHook = { [self] encoder, decoder in
                let qpEncoder = try qpOwnerHook?.wrap(encoder) ?? encoder
                let observedEncoder = try encoderBoundaryTrace?.wrapFactory(qpEncoder) ?? qpEncoder
                return try createEstimatorFactory(encoder: observedEncoder, decoder: decoder)
            }
        } else {
            factoryHook = nil
        }
        return try WebRTCPeer.makeVideoControlOnlyHostForTesting(
            configuration: configuration,
            makeNativeConfiguration: { [self] in
                let make: Create
                switch mode {
                case .sdkDefault: make = makeOrdinary
                case .zeroBurst: make = makeZero
                case .twentyMillisecondBurst: make = makeTwentyMillisecond
                }
                guard let pointer = make() else {
                    throw WebRTCTransportError.nativeFailure("Pacing configuration preflight failed")
                }
                let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
                guard let configuration = object as? LKRTCConfiguration else {
                    throw WebRTCTransportError.nativeFailure("Pacing bridge returned the wrong object")
                }
                return configuration
            },
            verifyCreatedPeer: { [self] peer in
                let pointer = Unmanaged.passUnretained(peer).toOpaque()
                let wanted: Int64
                switch mode {
                case .sdkDefault: wanted = -1
                case .zeroBurst: wanted = 0
                case .twentyMillisecondBurst: wanted = 20
                }
                let contradicted: Int64 = mode == .zeroBurst ? -1 : 0
                guard verify(pointer, wanted) == 1, verify(pointer, contradicted) == 0 else {
                    throw WebRTCTransportError.nativeFailure("Actual peer pacing readback failed")
                }
                lock.withLock { verifiedPeerCount += 1 }
            },
            makeNativeFactory: factoryHook
        )
        #else
        throw XCTSkip("Pacing injection is unavailable in release builds")
        #endif
    }
}
#endif
