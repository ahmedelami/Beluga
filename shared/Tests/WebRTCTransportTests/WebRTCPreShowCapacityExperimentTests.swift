#if os(macOS)
import Foundation
import RemoteSessionCore
@testable import WebRTCTransport
import XCTest

private enum PreShowCapacityFailure: Error {
    case timeout
}

private actor PreShowCapacityState {
    var observedRemoteVideoTrack = false
    var controlRequestCount = 0
    var relayErrors: [String] = []

    func observe(_ event: WebRTCTransportEvent, viewerSide: Bool) {
        if viewerSide, case .remoteVideoTrack = event {
            observedRemoteVideoTrack = true
        }
        if case .controlRequestReceived = event {
            controlRequestCount += 1
        }
    }

    func record(_ error: any Error) {
        relayErrors.append(String(describing: error))
    }
}

private struct PreShowCapacitySample {
    let elapsedMilliseconds: Double
    let availableOutgoingBitrate: Double?
    let outboundVideoBytes: UInt64
    let encodedFrames: UInt64
}

private func preShowCapacityRelay(
    from: WebRTCPeer,
    to: WebRTCPeer,
    viewerSide: Bool,
    state: PreShowCapacityState
) -> Task<Void, Never> {
    Task {
        do {
            for await event in from.events {
                await state.observe(event, viewerSide: viewerSide)
                if case .outboundSignal(let payload) = event {
                    try await to.handle(payload)
                }
                // Deliberately do not acknowledge control requests. This experiment never sends
                // Show and must remain entirely before the screen-visibility privacy boundary.
            }
        } catch {
            if !Task.isCancelled {
                await state.record(error)
            }
        }
    }
}

private func preShowCapacityWait(
    timeout: Duration = .seconds(10),
    _ predicate: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else {
            throw PreShowCapacityFailure.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func preShowCapacityMilliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
        + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func preShowCapacityNumber(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "null" }
    return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func preShowCapacityClose(
    host: WebRTCPeer,
    viewer: WebRTCPeer,
    relays: [Task<Void, Never>]
) async {
    await host.close(reason: .normal)
    await viewer.close(reason: .normal)
    for relay in relays { relay.cancel() }
    for relay in relays { await relay.value }
}

final class WebRTCPreShowCapacityExperimentTests: XCTestCase {
    // Run alone in a fresh test process. Native probe diagnostics are process-scoped and count
    // both fixture peers. This is characterization: BWE and successful feedback may remain absent.
    func testProductionTransportCapacityBeforeShowOrFirstFrameCharacterization() async throws {
        guard ProcessInfo.processInfo.environment[
            "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT"
        ] == "1" else {
            throw XCTSkip(
                "Set OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT=1 in a fresh test process."
            )
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

        let state = PreShowCapacityState()
        let relays = [
            preShowCapacityRelay(from: host, to: viewer, viewerSide: false, state: state),
            preShowCapacityRelay(from: viewer, to: host, viewerSide: true, state: state),
        ]

        do {
            XCTAssertNil(host.externalAudioCapturer)
            XCTAssertNil(viewer.externalAudioCapturer)

            _ = WebRTCNativeProbeDiagnostics.drain()
            _ = try await host.applyScreenVideoEncodingLimits(
                WebRTCScreenVideoEncodingLimits(
                    maximumBitrateBps: 1_192_320,
                    maximumFramesPerSecond: 5,
                    scaleResolutionDownBy: 4,
                    maximumTotalRTPBitrateBps: 905_041
                )
            )
            try await host.start()
            try await preShowCapacityWait {
                let healthy = await host.isTransportHealthyForCapture()
                let observedTrack = await state.observedRemoteVideoTrack
                return healthy && observedTrack
            }

            var nativeEvents: [WebRTCNativeProbeEvent] = []
            func drainNativeEvents() {
                let batch = WebRTCNativeProbeDiagnostics.drain()
                XCTAssertEqual(batch.droppedEventCount, 0)
                nativeEvents.append(contentsOf: batch.events)
            }

            drainNativeEvents()
            let preRaiseCreated = nativeEvents.filter { $0.kind == .clusterCreated }.count
            let preRaiseSucceeded = nativeEvents.filter { $0.kind == .probeSucceeded }.count
            let raiseWatermark = nativeEvents.last?.sequence ?? 0
            let baselineReport = await host.screenVideoStatisticsSnapshot(
                timeout: .milliseconds(250)
            )
            let baselineTimestamp = baselineReport?.nativeReportTimestampMicroseconds
            let baselineBWE = baselineReport?.snapshot.availableOutgoingBitrate
            var maximumOutboundVideoBytes = baselineReport?.snapshot.outboundVideo?.bytes ?? 0
            var maximumEncodedFrames = baselineReport?.snapshot.outboundVideo?.framesEncodedOrDecoded ?? 0

            let startedAt = ContinuousClock.now
            _ = try await host.applyScreenVideoEncodingLimits(
                WebRTCScreenVideoEncodingLimits(
                    maximumBitrateBps: 1_192_320,
                    maximumFramesPerSecond: 5,
                    scaleResolutionDownBy: 1,
                    maximumTotalRTPBitrateBps: 1_693_440
                )
            )
            let deadline = startedAt.advanced(by: .seconds(3))
            var samples: [PreShowCapacitySample] = []
            while ContinuousClock.now < deadline {
                drainNativeEvents()
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { break }
                if let report = await host.screenVideoStatisticsSnapshot(
                    timeout: min(.milliseconds(200), remaining)
                ) {
                    let bytes = report.snapshot.outboundVideo?.bytes ?? 0
                    let frames = report.snapshot.outboundVideo?.framesEncodedOrDecoded ?? 0
                    maximumOutboundVideoBytes = max(maximumOutboundVideoBytes, bytes)
                    maximumEncodedFrames = max(maximumEncodedFrames, frames)
                    samples.append(
                        PreShowCapacitySample(
                            elapsedMilliseconds: preShowCapacityMilliseconds(
                                startedAt.duration(to: .now)
                            ),
                            availableOutgoingBitrate: report.snapshot.availableOutgoingBitrate,
                            outboundVideoBytes: bytes,
                            encodedFrames: frames
                        )
                    )
                }
                let sleepRemaining = ContinuousClock.now.duration(to: deadline)
                if sleepRemaining > .zero {
                    try await Task.sleep(for: min(.milliseconds(100), sleepRemaining))
                }
            }
            drainNativeEvents()

            let postRaiseEvents = nativeEvents.filter { $0.sequence > raiseWatermark }
            let created = postRaiseEvents.filter { $0.kind == .clusterCreated }
            let succeeded = postRaiseEvents.filter { $0.kind == .probeSucceeded }
            let intervals = succeeded.map { event in
                let send = event.sendInterval?.diagnosticToken ?? "nil"
                let receive = event.receiveInterval?.diagnosticToken ?? "nil"
                return "\(send)/\(receive)"
            }.joined(separator: ",")
            let sampleLog = samples.map { sample in
                "{ms:\(preShowCapacityNumber(sample.elapsedMilliseconds)),"
                    + "bwe:\(preShowCapacityNumber(sample.availableOutgoingBitrate)),"
                    + "bytes:\(sample.outboundVideoBytes),frames:\(sample.encodedFrames)}"
            }.joined(separator: ",")
            let hasFreshBWE = samples.contains { sample in
                guard let bwe = sample.availableOutgoingBitrate else { return false }
                return bwe.isFinite && bwe > 0
            }
            let finalReport = await host.screenVideoStatisticsSnapshot(timeout: .milliseconds(250))
            if let final = finalReport?.snapshot.outboundVideo {
                maximumOutboundVideoBytes = max(maximumOutboundVideoBytes, final.bytes ?? 0)
                maximumEncodedFrames = max(maximumEncodedFrames, final.framesEncodedOrDecoded ?? 0)
            }
            let finalTimestamp = finalReport?.nativeReportTimestampMicroseconds
            let statisticsAdvanced = baselineTimestamp.map { baseline in
                finalTimestamp.map { $0 > baseline } ?? false
            } ?? (finalTimestamp != nil)

            print(
                "PRE_SHOW_CAPACITY {scope:process,baselineBWE:"
                    + "\(preShowCapacityNumber(baselineBWE)),"
                    + "statisticsAdvanced:\(statisticsAdvanced),freshBWE:\(hasFreshBWE),"
                    + "preRaiseCreated:\(preRaiseCreated),preRaiseSucceeded:\(preRaiseSucceeded),"
                    + "postRaiseCreated:\(created.count),postRaiseSucceeded:\(succeeded.count),"
                    + "successIntervals:\(intervals.isEmpty ? "none" : intervals),"
                    + "maximumSentVideoBytes:\(maximumOutboundVideoBytes),"
                    + "zeroSentVideoBytes:\(maximumOutboundVideoBytes == 0),"
                    + "maximumEncodedFrames:\(maximumEncodedFrames),samples:[\(sampleLog)]}"
            )

            XCTAssertTrue(statisticsAdvanced)
            XCTAssertEqual(maximumEncodedFrames, 0, "No video frame was submitted before Show.")
            let controlRequestCount = await state.controlRequestCount
            let relayErrors = await state.relayErrors
            XCTAssertEqual(controlRequestCount, 0)
            XCTAssertEqual(relayErrors, [])
        } catch {
            await preShowCapacityClose(host: host, viewer: viewer, relays: relays)
            throw error
        }
        await preShowCapacityClose(host: host, viewer: viewer, relays: relays)
    }
}
#endif
