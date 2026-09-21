#if DEBUG && os(macOS)
import Foundation
@preconcurrency import LiveKitWebRTC
import XCTest
@testable import WebRTCTransport

final class WebRTCNativeConfigurationHookTests: XCTestCase {
    private enum ExpectedFailure: Error, Equatable {
        case verificationRejected
    }

    private final class HookObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var makeCount = 0
        private var verifyCount = 0
        private var factoryCount = 0
        private var nativePeer: LKRTCPeerConnection?
        private var reenteredPeer: WebRTCPeer?

        func recordMake() {
            lock.withLock { makeCount += 1 }
        }

        func recordFactory() { lock.withLock { factoryCount += 1 } }
        var factoriesMade: Int { lock.withLock { factoryCount } }

        func recordVerification(_ peer: LKRTCPeerConnection) {
            lock.withLock {
                verifyCount += 1
                nativePeer = peer
            }
        }

        var counts: (made: Int, verified: Int) {
            lock.withLock { (makeCount, verifyCount) }
        }

        var retainedNativePeer: LKRTCPeerConnection? {
            lock.withLock { nativePeer }
        }

        func recordReenteredPeer(_ peer: WebRTCPeer) {
            lock.withLock { reenteredPeer = peer }
        }

        var retainedReenteredPeer: WebRTCPeer? {
            lock.withLock { reenteredPeer }
        }
    }

    func testSuccessfulConstructionRestoresNativeConfigurationHooks() async throws {
        let observations = HookObservations()
        let host = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
            configuration: videoOnlyHostConfiguration,
            makeNativeConfiguration: {
                observations.recordMake()
                return LKRTCConfiguration()
            },
            verifyCreatedPeer: { observations.recordVerification($0) }
        )
        XCTAssertNil(host.externalAudioCapturer)
        await host.close(reason: .normal)
        assertOneConstruction(observations)

        // No replacement hook scope: the ordinary initializer must see no prior hooks.
        let ordinary = try WebRTCPeer(configuration: videoOnlyHostConfiguration)
        XCTAssertNil(ordinary.externalAudioCapturer)
        await ordinary.close(reason: .normal)
        assertOneConstruction(observations)
    }

    func testRejectedVerificationClosesNativePeerAndRestoresHooks() async throws {
        let observations = HookObservations()
        do {
            let unexpectedHost = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
                configuration: videoOnlyHostConfiguration,
                makeNativeConfiguration: {
                    observations.recordMake()
                    return LKRTCConfiguration()
                },
                verifyCreatedPeer: {
                    observations.recordVerification($0)
                    throw ExpectedFailure.verificationRejected
                }
            )
            await unexpectedHost.close(reason: .normal)
            XCTFail("A rejected native peer must not escape construction")
        } catch {
            XCTAssertEqual(error as? ExpectedFailure, .verificationRejected)
        }

        assertOneConstruction(observations)
        let rejectedPeer = try XCTUnwrap(observations.retainedNativePeer)
        defer { rejectedPeer.close() }
        XCTAssertEqual(rejectedPeer.signalingState, .closed,
                       "Construction failure must close the retained native peer")

        let ordinary = try WebRTCPeer(configuration: videoOnlyHostConfiguration)
        XCTAssertNil(ordinary.externalAudioCapturer)
        await ordinary.close(reason: .normal)
        assertOneConstruction(observations)
    }

    func testFactoryHookRunsOnlyOnceAndOrdinaryConstructionRemainsUnchanged() async throws {
        let observations = HookObservations()
        let host = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
            configuration: videoOnlyHostConfiguration,
            makeNativeConfiguration: { observations.recordMake(); return LKRTCConfiguration() },
            verifyCreatedPeer: { observations.recordVerification($0) },
            makeNativeFactory: { encoder, decoder in
                observations.recordFactory()
                return LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                    bypassVoiceProcessing: true, encoderFactory: encoder,
                    decoderFactory: decoder, audioProcessingModule: nil)
            }
        )
        XCTAssertNil(host.externalAudioCapturer)
        XCTAssertNil(host.macDecodedAudioSource)
        await host.close(reason: .normal)
        assertOneConstruction(observations)
        XCTAssertEqual(observations.factoriesMade, 1)
        let ordinary = try WebRTCPeer(configuration: videoOnlyHostConfiguration)
        await ordinary.close(reason: .normal)
        XCTAssertEqual(observations.factoriesMade, 1, "Factory hook must not escape its constructor scope")
    }

    func testFactoryThrowRestoresScopeBeforeOrdinaryConstruction() async throws {
        let observations = HookObservations()
        do {
            let unexpected = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
                configuration: videoOnlyHostConfiguration,
                makeNativeConfiguration: { observations.recordMake(); return LKRTCConfiguration() },
                verifyCreatedPeer: { observations.recordVerification($0) },
                makeNativeFactory: { _, _ in
                    observations.recordFactory()
                    throw ExpectedFailure.verificationRejected
                }
            )
            await unexpected.close(reason: .normal)
            XCTFail("A throwing factory must not silently fall back to ordinary construction")
        } catch { XCTAssertEqual(error as? ExpectedFailure, .verificationRejected) }
        XCTAssertEqual(observations.factoriesMade, 1)
        XCTAssertEqual(observations.counts.made, 0)
        XCTAssertEqual(observations.counts.verified, 0)
        let ordinary = try WebRTCPeer(configuration: videoOnlyHostConfiguration)
        await ordinary.close(reason: .normal)
        XCTAssertEqual(observations.factoriesMade, 1)
    }

    func testDelayedChildCannotReuseFactoryHookAfterSuccessfulConstruction() async throws {
        try await assertDelayedChildCannotReuseFactoryHook(parentFactoryThrows: false)
    }

    func testSynchronousReentryCannotReuseFactoryHookBeforeRetirement() async throws {
        let observations = HookObservations()
        let configuration = videoOnlyHostConfiguration
        do {
            let host = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
                configuration: configuration,
                makeNativeConfiguration: { observations.recordMake(); return LKRTCConfiguration() },
                verifyCreatedPeer: { observations.recordVerification($0) },
                makeNativeFactory: { encoder, decoder in
                    observations.recordFactory()
                    // A missing one-use guard must fail without recursively entering the hook.
                    guard observations.factoriesMade == 1 else {
                        throw ExpectedFailure.verificationRejected
                    }
                    do {
                        let unexpected = try WebRTCPeer(configuration: configuration)
                        observations.recordReenteredPeer(unexpected)
                        XCTFail("Synchronous reentry must be rejected before the parent hook retires")
                    } catch {
                        XCTAssertEqual(error as? WebRTCTransportError,
                            .nativeFailure("Expired or reused native construction hook"))
                    }
                    return LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                        bypassVoiceProcessing: true, encoderFactory: encoder,
                        decoderFactory: decoder, audioProcessingModule: nil)
                }
            )
            await host.close(reason: .normal)
        } catch {
            if let unexpected = observations.retainedReenteredPeer {
                await unexpected.close(reason: .normal)
            }
            throw error
        }
        if let unexpected = observations.retainedReenteredPeer {
            await unexpected.close(reason: .normal)
        }
        XCTAssertEqual(observations.factoriesMade, 1,
                       "Reentry must not invoke the factory hook a second time")
        assertOneConstruction(observations)
    }

    func testDelayedChildCannotReuseFactoryHookAfterThrowingConstruction() async throws {
        try await assertDelayedChildCannotReuseFactoryHook(parentFactoryThrows: true)
    }

    func testWrongTopologyCannotInvokeFactoryHook() async throws {
        let observations = HookObservations()
        for configuration in [
            WebRTCTransportConfiguration(role: .host, iceServers: [], mediaTopology: .full),
            WebRTCTransportConfiguration(role: .viewer, iceServers: [], mediaTopology: .full),
            WebRTCTransportConfiguration(role: .viewer, iceServers: [], mediaTopology: .videoControlOnly)
        ] {
            do {
                let unexpected = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
                    configuration: configuration,
                    makeNativeConfiguration: { observations.recordMake(); return LKRTCConfiguration() },
                    verifyCreatedPeer: { observations.recordVerification($0) },
                    makeNativeFactory: { _, _ in
                        observations.recordFactory()
                        throw ExpectedFailure.verificationRejected
                    }
                )
                await unexpected.close(reason: .normal)
                XCTFail("Wrong topology must be rejected before any factory work")
            } catch { XCTAssertEqual(error as? WebRTCTransportError, .invalidRole) }
        }
        XCTAssertEqual(observations.factoriesMade, 0)
        XCTAssertEqual(observations.counts.made, 0)
        XCTAssertEqual(observations.counts.verified, 0)
    }

    private func assertDelayedChildCannotReuseFactoryHook(
        parentFactoryThrows: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let observations = HookObservations()
        let configuration = videoOnlyHostConfiguration
        let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let inherited = AsyncStream<Task<Void, Never>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer {
            release.continuation.finish()
            inherited.continuation.finish()
        }

        do {
            let host = try WebRTCPeer.makeVideoControlOnlyHostForTesting(
                configuration: configuration,
                makeNativeConfiguration: { observations.recordMake(); return LKRTCConfiguration() },
                verifyCreatedPeer: { observations.recordVerification($0) },
                makeNativeFactory: { encoder, decoder in
                    observations.recordFactory()
                    // Keep a broken guard bounded to one child, even if it reenters this hook.
                    if observations.factoriesMade == 1 {
                        let child = Task {
                            var iterator = release.stream.makeAsyncIterator()
                            guard await iterator.next() != nil else { return }
                            do {
                                let unexpected = try WebRTCPeer(configuration: configuration)
                                await unexpected.close(reason: .normal)
                                XCTFail("An inherited hook must expire when its constructor exits", file: file, line: line)
                            } catch {
                                XCTAssertEqual(error as? WebRTCTransportError,
                                    .nativeFailure("Expired or reused native construction hook"),
                                    file: file, line: line)
                            }
                        }
                        inherited.continuation.yield(child)
                    }
                    if parentFactoryThrows { throw ExpectedFailure.verificationRejected }
                    return LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine,
                        bypassVoiceProcessing: true, encoderFactory: encoder,
                        decoderFactory: decoder, audioProcessingModule: nil)
                }
            )
            await host.close(reason: .normal)
            XCTAssertFalse(parentFactoryThrows, "The parent factory must propagate its failure", file: file, line: line)
        } catch {
            guard parentFactoryThrows else { throw error }
            XCTAssertEqual(error as? ExpectedFailure, .verificationRejected, file: file, line: line)
        }

        inherited.continuation.finish()
        var inheritedIterator = inherited.stream.makeAsyncIterator()
        let inheritedTask = await inheritedIterator.next()
        let child = try XCTUnwrap(inheritedTask, file: file, line: line)
        XCTAssertEqual(observations.factoriesMade, 1, file: file, line: line)
        release.continuation.yield(())
        release.continuation.finish()
        await child.value

        XCTAssertEqual(observations.factoriesMade, 1,
                       "The delayed child must be rejected before invoking the factory hook", file: file, line: line)
        XCTAssertEqual(observations.counts.made, parentFactoryThrows ? 0 : 1, file: file, line: line)
        XCTAssertEqual(observations.counts.verified, parentFactoryThrows ? 0 : 1, file: file, line: line)

        let ordinary = try WebRTCPeer(configuration: configuration)
        XCTAssertNil(ordinary.externalAudioCapturer, file: file, line: line)
        XCTAssertNil(ordinary.macDecodedAudioSource, file: file, line: line)
        await ordinary.close(reason: .normal)
        XCTAssertEqual(observations.factoriesMade, 1, file: file, line: line)
        XCTAssertEqual(observations.counts.made, parentFactoryThrows ? 0 : 1, file: file, line: line)
        XCTAssertEqual(observations.counts.verified, parentFactoryThrows ? 0 : 1, file: file, line: line)
    }

    private func assertOneConstruction(
        _ observations: HookObservations,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let counts = observations.counts
        XCTAssertEqual(counts.made, 1, file: file, line: line)
        XCTAssertEqual(counts.verified, 1, file: file, line: line)
    }

    private var videoOnlyHostConfiguration: WebRTCTransportConfiguration {
        WebRTCTransportConfiguration(
            role: .host,
            iceServers: [],
            maximumVideoBitrate: 12_000_000,
            mediaTopology: .videoControlOnly,
            supportsAudioClientDiagnostics: false
        )
    }
}
#endif
