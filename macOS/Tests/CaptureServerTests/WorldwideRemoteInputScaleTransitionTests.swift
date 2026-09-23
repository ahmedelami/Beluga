import Foundation
@testable import CaptureServer
@testable import WebRTCTransport
import XCTest

private actor DelayedFallbackAdaptationProbe {
    private var policy = WorldwideScreenVideoAdaptationPolicy(
        configuredTotalRTPBitrateBps: 50_000_000,
        baseFramesPerSecond: 60
    )
    private var sampleCount = 0

    init() {
        _ = policy.bind(toPeerGeneration: 1)
    }

    func collectOneSample() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(450))
        } catch {
            return false
        }
        sampleCount += 1
        let recommendation = policy.update(
            peerGeneration: 1,
            isCaptureActive: true,
            availableOutgoingBitrateBps: 47_500_000,
            currentRoundTripTimeSeconds: 0.020,
            outboundVideoPacketsSent: UInt64(sampleCount * 100),
            outboundVideoTotalPacketSendDelaySeconds:
                Double(sampleCount) * 0.5
        )
        return recommendation?.tier != .full
    }

    func state() -> (tier: WorldwideScreenVideoAdaptationTier, samples: Int) {
        (policy.currentTier, sampleCount)
    }
}

/// Locks the remote-input authorization boundary to the exact live screen-format generation.
final class WorldwideRemoteInputScaleTransitionTests: XCTestCase {
    func testSupersededPreparedInputKeepsSuccessfulActiveTransitionViewOnly() {
        let capability = WebRTCInputCapability(
            inputSessionID: UUID(),
            screenRequestID: 73,
            supportsPrimaryDrag: true,
            supportsScroll: true
        )
        let authorization = WebRTCInputAuthorization()

        XCTAssertTrue(
            WorldwideScreenService.activeAcknowledgementInputStateIsCurrent(
                preparedCapability: capability,
                preparedAuthorization: authorization,
                activeCapability: nil,
                activeAuthorization: nil,
                preparedActivationIsCommitted: false
            ),
            "Losing input ownership must preserve the healthy view-only screen transition."
        )
        XCTAssertTrue(
            WorldwideScreenService.activeAcknowledgementInputStateIsCurrent(
                preparedCapability: capability,
                preparedAuthorization: authorization,
                activeCapability: capability,
                activeAuthorization: authorization,
                preparedActivationIsCommitted: true
            )
        )
        XCTAssertFalse(
            WorldwideScreenService.activeAcknowledgementInputStateIsCurrent(
                preparedCapability: capability,
                preparedAuthorization: authorization,
                activeCapability: capability,
                activeAuthorization: authorization,
                preparedActivationIsCommitted: false
            )
        )
        XCTAssertFalse(
            WorldwideScreenService.activeAcknowledgementInputStateIsCurrent(
                preparedCapability: capability,
                preparedAuthorization: authorization,
                activeCapability: capability,
                activeAuthorization: WebRTCInputAuthorization(),
                preparedActivationIsCommitted: true
            )
        )
        XCTAssertFalse(
            WorldwideScreenService.activeAcknowledgementInputStateIsCurrent(
                preparedCapability: capability,
                preparedAuthorization: authorization,
                activeCapability: capability,
                activeAuthorization: nil,
                preparedActivationIsCommitted: true
            )
        )
    }

    func testPostResumeFreshnessFenceRejectsQueuedPreRestorationStatistics() {
        let beforeResumeSequence: UInt64 = 40
        let minimumPostResumeSequence: UInt64 = 41
        var fence = WorldwideScreenVideoAdaptationFreshnessFence()

        XCTAssertTrue(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectedAt: Date(timeIntervalSince1970: 30),
                    collectionSequence: beforeResumeSequence
                )
            )
        )

        fence.beginPostResumeEpoch(
            minimumCollectionSequence: minimumPostResumeSequence
        )

        XCTAssertFalse(
            fence.admits(
                // Callback time is deliberately later than the post-resume report below. The
                // request sequence, not wall clock, must reject this queued old report.
                WebRTCStatisticsSnapshot(
                    collectedAt: Date(timeIntervalSince1970: 30),
                    collectionSequence: beforeResumeSequence
                )
            )
        )
        XCTAssertFalse(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectedAt: Date(timeIntervalSince1970: 30)
                )
            )
        )
        XCTAssertTrue(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectedAt: Date(timeIntervalSince1970: 10),
                    collectionSequence: minimumPostResumeSequence
                )
            )
        )

        fence.reset()
        XCTAssertTrue(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectionSequence: beforeResumeSequence
                )
            )
        )
    }

    func testLaterSenderMutationFenceRejectsSequenceAllocatedAfterShowFence() {
        var fence = WorldwideScreenVideoAdaptationFreshnessFence()
        fence.beginPostResumeEpoch(minimumCollectionSequence: 41)
        XCTAssertTrue(
            fence.admits(WebRTCStatisticsSnapshot(collectionSequence: 41))
        )

        // Sequence 42 was allocated after the Show boundary but before the native sender write.
        // The post-write boundary must reject it even if delivery occurs after Active ACK.
        fence.beginPostResumeEpoch(minimumCollectionSequence: 43)
        XCTAssertFalse(
            fence.admits(WebRTCStatisticsSnapshot(collectionSequence: 42))
        )
        XCTAssertTrue(
            fence.admits(WebRTCStatisticsSnapshot(collectionSequence: 43))
        )
    }

    func testExpiredNativeFallbackFencesReportReservedBeforeFallback() {
        var fence = WorldwideScreenVideoAdaptationFreshnessFence()
        fence.beginPostResumeEpoch(minimumCollectionSequence: 52)

        // This sequence was reserved while the bounded native operation could temporarily own
        // its proposed limits. The failure path must advance beyond it before publishing the
        // rollback/deadline fallback policy, even if delivery happens afterward.
        let reservedDuringNativeOperation: UInt64 = 52
        XCTAssertTrue(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectionSequence: reservedDuringNativeOperation
                )
            )
        )

        fence.beginPostResumeEpoch(
            minimumCollectionSequence: reservedDuringNativeOperation + 1
        )

        XCTAssertFalse(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectionSequence: reservedDuringNativeOperation
                )
            )
        )
        XCTAssertTrue(
            fence.admits(
                WebRTCStatisticsSnapshot(
                    collectionSequence: reservedDuringNativeOperation + 1
                )
            )
        )
    }

    func testPostResumeEpochUsesThePeerMonotonicCollectionBoundary() throws {
        let epoch = try serviceSlice(
            after: "    private func advanceScreenVideoStatisticsEpoch(using sourcePeer: WebRTCPeer?) {",
            before: "    private func automaticScreenMediaResumeTimedOut("
        )

        XCTAssertTrue(
            epoch.contains(
                "sourcePeer.minimumNextStatisticsCollectionSequence()"
            )
        )
        XCTAssertTrue(epoch.contains("minimumCollectionSequence:"))
        XCTAssertFalse(epoch.contains("Date()"))
        XCTAssertFalse(epoch.contains("collectedAt"))
    }

    func testSuccessorShowGateRejectsOrdinaryAdaptationAndStaleCleanup() {
        var gate = WorldwideScreenService.ShowAdaptationGate()
        XCTAssertTrue(gate.permits(ownerEpoch: nil))

        gate.begin(41)
        XCTAssertFalse(gate.permits(ownerEpoch: nil))
        XCTAssertFalse(gate.permits(ownerEpoch: 40))
        XCTAssertTrue(gate.permits(ownerEpoch: 41))

        gate.begin(42)
        gate.finish(41)
        XCTAssertEqual(gate.pendingVisibilityEpoch, 42)
        XCTAssertFalse(gate.permits(ownerEpoch: 41))
        XCTAssertTrue(gate.permits(ownerEpoch: 42))

        gate.finish(42)
        XCTAssertNil(gate.pendingVisibilityEpoch)
        XCTAssertTrue(gate.permits(ownerEpoch: nil))
    }

    func testFailedAutomaticResumeFencesTemporarySenderBeforeReleasingActor()
        throws {
        let failure = try serviceSlice(
            after: "    private func failAutomaticScreenMediaResume(",
            before: "    private func handleAutomaticScreenMediaEncoderProbeEvent("
        )
        let release = try XCTUnwrap(
            failure.range(of: "automaticScreenMediaResumeContext = nil")
        )
        let restoredPolicy = try XCTUnwrap(
            failure.range(of: "screenVideoAdaptationPolicy.automaticResumeAttemptFailed()",
                          range: release.upperBound..<failure.endIndex)
        )
        let fenced = try XCTUnwrap(
            failure.range(of: "beginPostResumeScreenVideoAdaptationEpoch()",
                          range: restoredPolicy.upperBound..<failure.endIndex)
        )
        let firstAwait = try XCTUnwrap(
            failure.range(of: "await sourcePeer.cancelScreenMediaResumeProbe(",
                          range: fenced.upperBound..<failure.endIndex)
        )
        XCTAssertLessThan(fenced.lowerBound, firstAwait.lowerBound)
    }

    func testShowTransitionGateAndNativeVisibilityTokenAreWiredAtMutationBoundaries()
        throws {
        let handler = try serviceSlice(
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "    /// Re-evaluates an exact forwarding token across a bounded live display transition."
        )
        XCTAssertTrue(handler.contains("screenVisibilityRequestID = request.id"))
        XCTAssertTrue(handler.contains("showAdaptationGate.begin(screenVisibilityCommandEpoch)"))
        XCTAssertTrue(handler.contains("showAdaptationGate.finish(gatedShowEpoch)"))

        let sampler = try serviceSlice(
            after: "    private func sampleScreenVideoAdaptationStatistics(",
            before: "    /// Applies a new sender ceiling only after the current capture and peer identities survive"
        )
        XCTAssertTrue(sampler.contains("showAdaptationGate.pendingVisibilityEpoch == nil"))

        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        XCTAssertTrue(adaptation.contains(
            "showAdaptationGate.permits(ownerEpoch: showTransitionOwnerEpoch)"
        ))
        XCTAssertTrue(adaptation.contains("expectedScreenVisibilityRequestID:"))

        let reconciliation = try serviceSlice(
            after: "    private func reconcileCurrentScreenVideoRecommendationBeforeActiveUse(",
            before: "    private func screenCaptureStartupOwnerIsCurrent("
        )
        XCTAssertTrue(reconciliation.contains(
            "showTransitionOwnerEpoch: owner.visibilityCommandEpoch"
        ))
    }

    func testSuccessorShowFencesPredecessorStatisticsBeforeSenderReconciliationAndACK()
        throws {
        let handler = try serviceSlice(
            after: "    private func handleControlRequest(_ request: WebRTCControlRequest) async {",
            before: "    /// Re-evaluates an exact forwarding token across a bounded live display transition."
        )
        let rearm = try XCTUnwrap(
            handler.range(of: "screenVideoAdaptationPolicy.beginFloorRecoveryVisibility(")
        )
        let freshnessEpoch = try XCTUnwrap(
            handler.range(
                of: "beginPostResumeScreenVideoAdaptationEpoch()",
                range: rearm.upperBound..<handler.endIndex
            )
        )
        let captureStart = try XCTUnwrap(
            handler.range(
                of: "let authorization = try await startScreenCaptureWithDisplayModeRetries()",
                range: freshnessEpoch.upperBound..<handler.endIndex
            )
        )
        let activeACK = try XCTUnwrap(
            handler.range(
                of: "try await peer.acknowledgeActiveControlRequestIfTransportHealthy(",
                range: captureStart.upperBound..<handler.endIndex
            )
        )
        let postACKEpoch = try XCTUnwrap(
            handler.range(
                of: "beginPostResumeScreenVideoAdaptationEpoch()",
                range: activeACK.upperBound..<handler.endIndex
            )
        )
        let activation = try XCTUnwrap(
            handler.range(
                of: "screenVideoAdaptationPolicy.activateFloorRecoveryVisibility(",
                range: postACKEpoch.upperBound..<handler.endIndex
            )
        )

        XCTAssertLessThan(rearm.lowerBound, freshnessEpoch.lowerBound)
        XCTAssertLessThan(freshnessEpoch.lowerBound, captureStart.lowerBound)
        XCTAssertLessThan(captureStart.lowerBound, activeACK.lowerBound)
        XCTAssertLessThan(activeACK.lowerBound, postACKEpoch.lowerBound)
        XCTAssertLessThan(postACKEpoch.lowerBound, activation.lowerBound)
    }

    func testEveryNativeRouteChangeInvalidatesVideoLatencyHistory() throws {
        let routeHandler = try serviceSlice(
            after: "        case .routeChanged(let route):",
            before: "        case .statistics(\n            let snapshot,"
        )

        XCTAssertTrue(
            routeHandler.contains(
                "screenVideoAdaptationPolicy.invalidateSelectedRoute()"
            )
        )
        XCTAssertTrue(
            routeHandler.contains(
                "advanceScreenVideoStatisticsEpoch(using: sourcePeer)"
            )
        )
        XCTAssertFalse(routeHandler.contains("if route.kind"))
    }

    func testVideoAdaptationRunsAfterCriticalMicrophoneHealthWork() throws {
        let statisticsHandler = try serviceSlice(
            after: "        case .statistics(\n            let snapshot,",
            before: "        case .iceCandidateError(let error):"
        )
        let microphoneFreshness = try XCTUnwrap(
            statisticsHandler.range(of: ".updateInboundMediaFreshness(")
        )
        let safeOutputMaintenance = try XCTUnwrap(
            statisticsHandler.range(
                of: "await maintainWorldwideSafeOutputInvariant()",
                range: microphoneFreshness.upperBound..<statisticsHandler.endIndex
            )
        )
        let videoAdaptation = try XCTUnwrap(
            statisticsHandler.range(
                of: "await adaptScreenVideoForNetworkConditions(",
                range: safeOutputMaintenance.upperBound..<statisticsHandler.endIndex
            )
        )

        XCTAssertLessThan(
            microphoneFreshness.lowerBound,
            safeOutputMaintenance.lowerBound
        )
        XCTAssertLessThan(
            safeOutputMaintenance.lowerBound,
            videoAdaptation.lowerBound
        )
        let wholePeerEvidence = try XCTUnwrap(
            statisticsHandler.range(
                of: "if wholePeerReportWasCollected,",
                range: safeOutputMaintenance.upperBound..<videoAdaptation.lowerBound
            )
        )
        XCTAssertLessThan(
            wholePeerEvidence.lowerBound,
            videoAdaptation.lowerBound
        )
        XCTAssertTrue(
            statisticsHandler.contains(
                "else if !wholePeerReportWasCollected,"
            )
        )
        XCTAssertTrue(
            statisticsHandler.contains(
                "Missing telemetry is not transport evidence"
            )
        )

        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        XCTAssertTrue(
            adaptation.contains(
                ".expireApplicationLimitedProbeWithoutReport("
            )
        )
        // Missing reports may also reconcile an unproven/failed native retirement. The
        // deadline/rollback behavioral tests cover that exception; ordinary media-health
        // ordering above remains unchanged by this supplementary wiring assertion.
        XCTAssertTrue(adaptation.contains("guard changedRecommendation != nil"))
        XCTAssertTrue(
            adaptation.contains("|| nativeSenderRequiresReconciliation else {")
        )
    }

    func testSuspensionInvalidationRequiresFreshOrderedShowWithoutLocalReactivation() throws {
        let handler = try serviceSlice(
            after: "        case .screenMediaSuspensionInvalidated(let reason):",
            before: "        case .screenMediaSuspensionReceived,"
        )
        let snapshot = try XCTUnwrap(
            handler.range(of: "screenMediaSuspension.diagnosticSnapshot")
        )
        let reasonLog = try XCTUnwrap(
            handler.range(
                of: "reason=\\(diagnosticReason)",
                range: snapshot.upperBound..<handler.endIndex
            )
        )
        let reset = try XCTUnwrap(
            handler.range(
                of: "resetAutomaticScreenMediaSuspensionState()",
                range: reasonLog.upperBound..<handler.endIndex
            )
        )
        let close = try XCTUnwrap(
            handler.range(
                of: "await stop()",
                range: reset.upperBound..<handler.endIndex
            )
        )

        XCTAssertLessThan(snapshot.lowerBound, reasonLog.lowerBound)
        XCTAssertLessThan(reasonLog.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, close.lowerBound)
        XCTAssertTrue(handler.contains("phase=\\(diagnostic.phase.rawValue)"))
        XCTAssertTrue(handler.contains("resumeAttemptWasInFlight"))
        XCTAssertTrue(handler.contains(".prefix(256)"))
        XCTAssertFalse(
            handler.contains(
                "diagnostic.requiresFreshMediaSessionAfterInvalidation"
            )
        )
        XCTAssertFalse(handler.contains("startScreenCapture"))
        XCTAssertFalse(handler.contains("acknowledgeActiveControlRequest"))
    }

    func testOrderedVisibilitySupersessionRetiresSuspensionWithoutTerminalInvalidation() throws {
        let receipt = try peerSlice(
            after: "    private func receiveControlRequest(_ request: WebRTCControlRequest) {",
            before: "    private func receiveControlAcknowledgement("
        )
        let ordinaryVisibility = try XCTUnwrap(
            receipt.range(
                of: "if request.command == .showScreen || request.command == .hideScreen"
            )
        )
        let retirement = try XCTUnwrap(
            receipt.range(
                of: "reason: \"An ordinary host visibility transition retired the covered suspension.\"",
                range: ordinaryVisibility.upperBound..<receipt.endIndex
            )
        )
        let retirementBlock = String(
            receipt[ordinaryVisibility.lowerBound..<retirement.upperBound]
        )
        let controlDelivery = try XCTUnwrap(
            receipt.range(
                of: "emit(.controlRequestReceived(request))",
                range: retirement.upperBound..<receipt.endIndex
            )
        )

        XCTAssertTrue(retirementBlock.contains("emitInvalidation: false"))
        XCTAssertTrue(retirementBlock.contains("disableHostVideo: true"))
        XCTAssertLessThan(retirement.lowerBound, controlDelivery.lowerBound)
        XCTAssertFalse(
            String(receipt[ordinaryVisibility.lowerBound..<controlDelivery.upperBound])
                .contains("emitInvalidation: true")
        )
    }

    func testClientDiagnosticsFreshnessCannotDriveMediaAdaptation() throws {
        let receiptHandler = try serviceSlice(
            after: "    private func handleScreenClientDiagnosticsHeartbeat(",
            before: "    private func observeScreenClientDiagnosticsFreshness("
        )
        XCTAssertTrue(
            receiptHandler.contains(
                "heartbeat.screenRequestID == activeScreenRequestID"
            )
        )
        XCTAssertTrue(receiptHandler.contains("if !matchesActiveScreen"))
        XCTAssertTrue(receiptHandler.contains("isCorrelated: matchesActiveScreen"))

        let isolatedConsumer = try serviceSlice(
            after: "    private func consumeScreenClientDiagnosticsEvents(",
            before: "    /// Updates transport health, routes protocol requests"
        )
        XCTAssertTrue(
            isolatedConsumer.contains(
                "handleScreenClientDiagnosticsHeartbeat(heartbeat)"
            )
        )
        XCTAssertTrue(isolatedConsumer.contains("case .laneFailure(let message)"))
        XCTAssertFalse(isolatedConsumer.contains("await stop()"))
        XCTAssertFalse(isolatedConsumer.contains("handlePeerEvent("))

        let statisticsHandler = try serviceSlice(
            after: "        case .statistics(\n            let snapshot,",
            before: "        case .iceCandidateError(let error):"
        )
        let adaptation = try XCTUnwrap(
            statisticsHandler.range(
                of: "await adaptScreenVideoForNetworkConditions("
            )
        )
        let diagnostics = try XCTUnwrap(
            statisticsHandler.range(
                of: "await observeScreenClientDiagnosticsFreshness(",
                range: adaptation.upperBound..<statisticsHandler.endIndex
            )
        )
        XCTAssertLessThan(adaptation.lowerBound, diagnostics.lowerBound)

        let freshness = try serviceSlice(
            after: "    private func observeScreenClientDiagnosticsFreshness(",
            before: "    /// Starts a fresh threshold window whenever statistics switch"
        )
        XCTAssertTrue(
            freshness.contains(
                "await sourcePeer.screenClientDiagnosticsIsNegotiated()"
            )
        )
        XCTAssertTrue(freshness.contains("warning=heartbeatMissing"))
        XCTAssertFalse(freshness.contains("screenVideoAdaptationPolicy"))
        XCTAssertFalse(freshness.contains("startScreenCapture"))
        XCTAssertFalse(freshness.contains("stopScreenCapture"))
        XCTAssertFalse(freshness.contains("await stop()"))
    }

    func testAdaptiveEncoderScalingPreservesAuthoritativeCaptureDimensions() throws {
        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    // MARK: - Screen control protocol"
        )
        let senderUpdate = try XCTUnwrap(
            adaptation.range(of: "recommendation.webRTCLimits")
        )
        let captureUpdate = try XCTUnwrap(
            adaptation.range(
                of: "capturer.adaptOutput(",
                range: senderUpdate.upperBound..<adaptation.endIndex
            )
        )
        let unchangedWidth = try XCTUnwrap(
            adaptation.range(
                of: "width: Int32(baseDimensions.width)",
                range: captureUpdate.upperBound..<adaptation.endIndex
            )
        )
        let unchangedHeight = try XCTUnwrap(
            adaptation.range(
                of: "height: Int32(baseDimensions.height)",
                range: unchangedWidth.upperBound..<adaptation.endIndex
            )
        )
        let tierFrameRate = try XCTUnwrap(
            adaptation.range(
                of: "recommendation.maximumFramesPerSecond",
                range: unchangedHeight.upperBound..<adaptation.endIndex
            )
        )

        XCTAssertLessThan(senderUpdate.lowerBound, captureUpdate.lowerBound)
        XCTAssertLessThan(captureUpdate.lowerBound, unchangedWidth.lowerBound)
        XCTAssertLessThan(unchangedWidth.lowerBound, unchangedHeight.lowerBound)
        XCTAssertLessThan(unchangedHeight.lowerBound, tierFrameRate.lowerBound)
        XCTAssertFalse(
            String(adaptation[captureUpdate.lowerBound..<tierFrameRate.upperBound])
                .contains("scaleResolutionDownBy")
        )

        let startup = try serviceSlice(
            after: "    private func startScreenCapture(\n",
            before: "    /// Waits only for the first exact image surface selected for this capture generation."
        )
        let startupSenderUpdate = try XCTUnwrap(
            startup.range(of: "encodingRecommendation.webRTCLimits")
        )
        let startupSenderEpoch = try XCTUnwrap(
            startup.range(
                of: "beginPostResumeScreenVideoAdaptationEpoch()",
                range: startupSenderUpdate.upperBound..<startup.endIndex
            )
        )
        let failedStartupInvalidation = try XCTUnwrap(
            startup.range(
                of: "} else {\n                // The direct write was ambiguous for this exact source owner.",
                range: startupSenderEpoch.upperBound..<startup.endIndex
            )
        )
        let clearedStartupCache = try XCTUnwrap(
            startup.range(
                of: "appliedScreenVideoRecommendation = nil",
                range: failedStartupInvalidation.upperBound..<startup.endIndex
            )
        )
        let forwardingInstall = try XCTUnwrap(
            startup.range(
                of: "sink.beginForwarding(",
                range: clearedStartupCache.upperBound..<startup.endIndex
            )
        )
        XCTAssertLessThan(
            startupSenderUpdate.lowerBound,
            startupSenderEpoch.lowerBound
        )
        XCTAssertLessThan(
            startupSenderEpoch.lowerBound,
            failedStartupInvalidation.lowerBound
        )
        XCTAssertLessThan(
            failedStartupInvalidation.lowerBound,
            clearedStartupCache.lowerBound
        )
        XCTAssertLessThan(
            clearedStartupCache.lowerBound,
            forwardingInstall.lowerBound
        )
        XCTAssertTrue(startup.contains("width: Int32(baseDimensions.width)"))
        XCTAssertTrue(startup.contains("height: Int32(baseDimensions.height)"))
    }

    func testFastVideoStatisticsSamplerDoesNotAccelerateMicrophoneHealthStream() throws {
        XCTAssertEqual(
            WorldwideScreenVideoAdaptationPolicy.sampleIntervalMilliseconds,
            500
        )
        XCTAssertEqual(
            WorldwideScreenService.screenVideoAdaptationStatisticsInterval,
            .milliseconds(500)
        )
        XCTAssertEqual(
            WorldwideScreenService.screenVideoAdaptationStatisticsTimeout,
            .milliseconds(400)
        )
        XCTAssertEqual(
            WorldwideScreenService
                .screenVideoAdaptationFallbackStatisticsInterval,
            .seconds(1)
        )
        XCTAssertLessThan(
            WorldwideScreenService.screenVideoAdaptationStatisticsTimeout,
            WorldwideScreenService.screenVideoAdaptationStatisticsInterval
        )

        let serviceConstants = try serviceSlice(
            after: "actor WorldwideScreenService {",
            before: "    private static let automaticScreenMediaResumeTimeout"
        )
        XCTAssertTrue(
            serviceConstants.contains(
                "WorldwideScreenVideoAdaptationPolicy.sampleIntervalMilliseconds"
            )
        )
        XCTAssertTrue(
            serviceConstants.contains(
                "screenVideoAdaptationStatisticsTimeout = Duration.milliseconds(400)"
            )
        )

        let startup = try serviceSlice(
            after: "    private func startPeer(iceServers: [RemoteICEServer]) async throws {",
            before: "    /// Consumes native peer events until normal stop or an unexpected stream end."
        )
        XCTAssertTrue(startup.contains("try await peer.startStatistics("))
        XCTAssertTrue(
            startup.contains(
                "interval: Self.screenVideoAdaptationFallbackStatisticsInterval"
            )
        )
        XCTAssertTrue(startup.contains("sampleScreenVideoAdaptationStatistics("))

        let sampler = try serviceSlice(
            after: "    private func sampleScreenVideoAdaptationStatistics(",
            before: "    /// Applies a new sender ceiling only after the current capture and peer identities survive"
        )
        XCTAssertTrue(sampler.contains("screenVideoStatisticsSnapshot("))
        XCTAssertTrue(
            sampler.contains(": Self.screenVideoAdaptationStatisticsTimeout")
        )
        XCTAssertTrue(
            sampler.contains("WorldwideScreenVideoSamplingCadence(startedAt: clock.now)")
        )
        XCTAssertTrue(sampler.contains("cadence.didFinishSample(at: now)"))
        XCTAssertTrue(sampler.contains("cadence.takeDueSample(at: clock.now)"))
        XCTAssertTrue(sampler.contains("if let report"))
        XCTAssertTrue(sampler.contains("capacityProbeOnly: capacityProbeOnly"))
        XCTAssertTrue(sampler.contains("report.nativeReportTimestampMicroseconds"))
        // Behavioral report/reducer tests cover the value semantics; guard the actual service
        // wiring too, so cached diagnostic route enrichment cannot become policy evidence.
        XCTAssertTrue(sampler.contains("case let snapshot = report.nativeSnapshot"))
        XCTAssertTrue(
            sampler.contains(
                "screenVideoAdaptationFastStatisticsAreAvailable = false"
            )
        )
        XCTAssertTrue(sampler.contains("allowsAutomaticResume: false"))
        XCTAssertFalse(sampler.contains("updateInboundMediaFreshness"))
        XCTAssertFalse(sampler.contains("maintainWorldwideSafeOutputInvariant"))

        let fastPeerSnapshot = try peerSlice(
            after: "    public func screenVideoStatisticsSnapshot(\n",
            before: "    private func collectStatistics("
        )
        XCTAssertTrue(fastPeerSnapshot.contains("-> WebRTCScreenVideoStatisticsReport?"))
        XCTAssertTrue(
            fastPeerSnapshot.contains("statistics(for: localVideoSender)")
        )
        XCTAssertTrue(
            fastPeerSnapshot.contains("screenVideoStatisticsRequestGate.begin()")
        )
        XCTAssertFalse(fastPeerSnapshot.contains("collectNativeStatistics("))
        XCTAssertFalse(
            fastPeerSnapshot.contains("currentIPhoneMicrophoneReceiverStatisticsCapture")
        )

        let ordinaryPeerSnapshot = try peerSlice(
            after: "    private func collectStatistics(",
            before: "    private func collectNativeStatistics("
        )
        XCTAssertTrue(
            ordinaryPeerSnapshot.contains(
                "currentIPhoneMicrophoneReceiverStatisticsCapture()"
            )
        )
        XCTAssertTrue(ordinaryPeerSnapshot.contains("async let nativeReportRequest"))
        XCTAssertTrue(
            ordinaryPeerSnapshot.contains("async let receiverStatisticsRequest")
        )

        let ordinaryNativeSnapshot = try peerSlice(
            after: "    private func collectNativeStatistics(",
            before: "    private func collectIPhoneMicrophoneReceiverStatistics("
        )
        XCTAssertTrue(
            ordinaryNativeSnapshot.contains(
                "wholePeerStatisticsRequestGate.begin()"
            )
        )
        let microphoneSnapshot = try peerSlice(
            after: "    private func collectIPhoneMicrophoneReceiverStatistics(",
            before: "    private func snapshotRestoringCurrentRouteIfNeeded("
        )
        XCTAssertTrue(
            microphoneSnapshot.contains(
                "iPhoneMicrophoneReceiverStatisticsRequestGate.begin()"
            )
        )

        let microphoneSenderSnapshot = try peerSlice(
            after: "    private func sampleIPhoneMicrophoneSenderStatistics(\n",
            before: "    private func sampleApprovedIPhoneMicrophoneOutboundRTPProgress("
        )
        XCTAssertTrue(
            microphoneSenderSnapshot.contains(
                "iPhoneMicrophoneSenderStatisticsRequestGate.begin()"
            )
        )
        XCTAssertTrue(
            microphoneSenderSnapshot.contains(
                "WebRTCBoundedCallback.value(timeout: callbackTimeout)"
            )
        )
        XCTAssertTrue(
            microphoneSenderSnapshot.contains(
                "iPhoneMicrophoneSenderStatisticsRequestGate.complete("
            )
        )
        XCTAssertFalse(
            microphoneSenderSnapshot.contains("withCheckedContinuation")
        )

        let periodicSampler = try peerSlice(
            after: "    public func startStatistics(interval: Duration = .seconds(1)) throws {",
            before: "    /// Revokes every media/input gate and idempotently releases the native peer."
        )
        XCTAssertTrue(
            periodicSampler.contains(
                "WebRTCFixedIntervalStatisticsSampler.run("
            )
        )
        XCTAssertFalse(periodicSampler.contains("Task.sleep(for: interval)"))
    }

    func testActiveAdaptationReactsWithinFiveSeconds() {
        let coldEvidenceBootstrapSamples = max(
            WorldwideScreenVideoAdaptationPolicy
                .roundTripTimeBootstrapSampleCount - 1,
            WorldwideScreenVideoAdaptationPolicy
                .requiredPositiveBandwidthBootstrapSampleCount
        )
        for interval in [
            WorldwideScreenVideoAdaptationPolicy.sampleIntervalMilliseconds,
            1_000,
        ] {
            let coldStrongCapacityMilliseconds = (
                coldEvidenceBootstrapSamples
                    + WorldwideScreenVideoAdaptationPolicy
                        .requiredHealthyUpgradeSampleCount
            ) * interval
            let coldApplicationLimitedFirstReactionMilliseconds = (
                coldEvidenceBootstrapSamples
                    + WorldwideScreenVideoAdaptationPolicy
                        .requiredApplicationLimitedUpgradeSampleCount
            ) * interval
            let coldMissingBandwidthFirstReactionMilliseconds = (
                WorldwideScreenVideoAdaptationPolicy
                    .roundTripTimeBootstrapSampleCount - 1
                    + WorldwideScreenVideoAdaptationPolicy
                        .requiredUnavailableBandwidthUpgradeSampleCount
            ) * interval
            let postFailureActiveReevaluationMilliseconds = (
                WorldwideScreenVideoAdaptationPolicy
                    .maximumActiveApplicationLimitedProbeCooldownSampleCount
                    + max(
                        WorldwideScreenVideoAdaptationPolicy
                            .requiredApplicationLimitedUpgradeSampleCount,
                        WorldwideScreenVideoAdaptationPolicy
                            .requiredUnavailableBandwidthUpgradeSampleCount
                    )
            ) * interval

            XCTAssertLessThan(coldStrongCapacityMilliseconds, 5_000)
            XCTAssertLessThan(
                coldApplicationLimitedFirstReactionMilliseconds,
                5_000
            )
            XCTAssertLessThan(
                coldMissingBandwidthFirstReactionMilliseconds,
                5_000
            )
            XCTAssertLessThan(
                postFailureActiveReevaluationMilliseconds,
                5_000
            )
            XCTAssertLessThan(interval, 5_000)
        }

        let fallbackInterval = WorldwideScreenVideoAdaptationPolicy
            .fallbackSampleIntervalMilliseconds
        XCTAssertEqual(fallbackInterval, 1_000)
        XCTAssertEqual(
            WorldwideScreenVideoAdaptationPolicy
                .requiredSuspendedHealthyUpgradeSampleCount
                * fallbackInterval,
            8_000
        )
        XCTAssertEqual(
            WorldwideScreenVideoAdaptationPolicy
                .requiredStableSuspensionResumeProbeSampleCount
                * fallbackInterval,
            16_000
        )
        XCTAssertEqual(
            WorldwideScreenVideoAdaptationPolicy
                .requiredMaximumSuspensionResumeProbeSampleCount
                * fallbackInterval,
            64_000
        )
    }

    func testFallbackWithFourHundredFiftyMillisecondStatsReactsWithinFiveSeconds()
        async {
        let probe = DelayedFallbackAdaptationProbe()
        let clock = ContinuousClock()
        let startedAt = clock.now

        await WebRTCFixedIntervalStatisticsSampler.run(
            interval: .seconds(1)
        ) {
            await probe.collectOneSample()
        }

        let elapsed = startedAt.duration(to: clock.now)
        let state = await probe.state()
        XCTAssertEqual(state.tier, .full)
        XCTAssertEqual(state.samples, 4)
        XCTAssertLessThan(elapsed, Duration.seconds(5))
    }

    func testFastAdaptationCannotRestartCaptureOrRevokeInput() throws {
        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )

        XCTAssertTrue(adaptation.contains("applyScreenVideoEncodingLimits("))
        XCTAssertTrue(adaptation.contains("capturer.adaptOutput("))
        XCTAssertTrue(
            adaptation.contains(
                "appliedScreenVideoRecommendation?.maximumFramesPerSecond"
            )
        )
        XCTAssertTrue(
            adaptation.contains(
                "!= recommendation.maximumFramesPerSecond"
            )
        )
        XCTAssertTrue(
            adaptation.contains(
                "guard isCaptureActive || allowsAutomaticResume else { return }"
            )
        )
        for forbidden in [
            "startScreenCapture",
            "stopScreenCapture",
            "updateScreenVideoFrameGeometry(nil)",
            "revokeCaptureAuthorization",
            "revokeRemoteInputAuthorization",
            "forceCover",
            "await stop()",
            "peer.close",
        ] {
            XCTAssertFalse(
                adaptation.contains(forbidden),
                "Fast adaptation must not perform lifecycle mutation: \(forbidden)"
            )
        }

        let peerEvents = try serviceSlice(
            after: "    private func handlePeerEvent(",
            before: "    private func resetScreenClientDiagnosticsFreshness()"
        )
        XCTAssertTrue(peerEvents.contains("allowsAutomaticResume: true"))
        XCTAssertTrue(
            peerEvents.contains(
                "!screenVideoAdaptationFastStatisticsAreAvailable"
            )
        )
    }

    func testFastAdaptationFencesRouteAndConcurrentPolicyChanges() throws {
        let evidencePreparation = try serviceSlice(
            after: "    private func prepareScreenVideoAdaptationEvidence(",
            before: "    private func sampleScreenVideoAdaptationStatistics("
        )
        XCTAssertTrue(evidencePreparation.contains("previousLane != lane"))
        XCTAssertTrue(evidencePreparation.contains("exceededMaximumGap"))
        XCTAssertTrue(
            evidencePreparation.contains("resetIncompleteEvidenceWindow()")
        )

        let sampler = try serviceSlice(
            after: "    private func sampleScreenVideoAdaptationStatistics(",
            before: "    /// Applies a new sender ceiling only after the current capture and peer identities survive"
        )
        XCTAssertTrue(
            sampler.contains(
                "let expectedPolicyRevision =\n                screenVideoAdaptationPolicyRevision"
            )
        )
        XCTAssertTrue(
            sampler.contains(
                "screenVideoAdaptationPolicyRevision\n                == expectedPolicyRevision"
            )
        )
        let request = try XCTUnwrap(sampler.range(of: "await sourcePeer.screenVideoStatisticsSnapshot("))
        for capturedBinding in [
            "let expectedVisibilityEpoch = screenVisibilityCommandEpoch",
            "let expectedCaptureSource = captureSource",
            "let expectedCaptureAuthorization = captureAuthorization",
        ] {
            XCTAssertLessThan(try XCTUnwrap(sampler.range(of: capturedBinding)).lowerBound, request.lowerBound)
        }
        for bindingCheck in [
            "screenVisibilityCommandEpoch == expectedVisibilityEpoch",
            "captureSource === expectedCaptureSource",
            "captureAuthorization === expectedCaptureAuthorization",
        ] {
            XCTAssertGreaterThan(try XCTUnwrap(sampler.range(of: bindingCheck)).lowerBound, request.lowerBound)
        }

        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        let applyingRevision = try XCTUnwrap(
            adaptation.range(of: "var applyingPolicyRevision = expectedPolicyRevision")
        )
        let consumedRevision = try XCTUnwrap(
            adaptation.range(of: "applyingPolicyRevision = screenVideoAdaptationPolicyRevision")
        )
        let nativeApply = try XCTUnwrap(
            adaptation.range(of: "await sourcePeer.applyScreenVideoEncodingLimits(")
        )
        XCTAssertLessThan(applyingRevision.lowerBound, consumedRevision.lowerBound)
        XCTAssertLessThan(consumedRevision.lowerBound, nativeApply.lowerBound)
        XCTAssertGreaterThanOrEqual(
            adaptation.components(
                separatedBy:
                    "screenVideoAdaptationPolicyRevision\n                        == applyingPolicyRevision"
            ).count - 1,
            1
        )
        XCTAssertTrue(adaptation.contains("expectedPolicyRevision: applyingPolicyRevision"))
        XCTAssertTrue(adaptation.contains("currentPolicyRevision: screenVideoAdaptationPolicyRevision"))
        XCTAssertTrue(
            adaptation.contains("screenVideoAdaptationPolicyRevision &+= 1")
        )

        let routeEvent = try serviceSlice(
            after: "        case .routeChanged(let route):",
            before: "        case .statistics(\n            let snapshot,"
        )
        let revision = try XCTUnwrap(
            routeEvent.range(of: "screenVideoAdaptationPolicyRevision &+= 1")
        )
        let invalidation = try XCTUnwrap(
            routeEvent.range(of: "invalidateSelectedRoute()")
        )
        XCTAssertLessThan(revision.lowerBound, invalidation.lowerBound)

        let fastPeerSnapshot = try peerSlice(
            after: "    public func screenVideoStatisticsSnapshot(\n",
            before: "    private func collectStatistics("
        )
        XCTAssertTrue(
            fastPeerSnapshot.contains(
                "let expectedRouteRevision = currentRouteRevision"
            )
        )
        XCTAssertTrue(
            fastPeerSnapshot.contains(
                "currentRouteRevision == expectedRouteRevision"
            )
        )
    }

    func testNativeFailureInvalidationIsOwnedAndStaleRollbackCannotWriteCache() throws {
        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        let staleBranch = try XCTUnwrap(adaptation.range(of: "nativeApply=stale"))
        let markApplied = try XCTUnwrap(adaptation.range(
            of: "proposedPolicy.markSpatialRecoveryApplied(at: applicationResumedAt)",
            range: staleBranch.upperBound..<adaptation.endIndex
        ))
        let staleRollback = String(adaptation[staleBranch.lowerBound..<markApplied.lowerBound])
        XCTAssertTrue(staleRollback.contains("rollbackScreenVideoEncodingUpdateIfCurrent("))
        XCTAssertTrue(staleRollback.contains(
            "screenVideoNativeApplicationGeneration\n                            == nativeApplicationGenerationBeforeRollback"
        ))
        XCTAssertTrue(staleRollback.contains("appliedScreenVideoRecommendation = nil"))
        XCTAssertFalse(staleRollback.contains("WorldwideScreenNativeApplicationCache"))

        let accepted = try XCTUnwrap(adaptation.range(of: "nativeApply=accepted"))
        let failureCatch = try XCTUnwrap(adaptation.range(
            of: "            } catch {",
            range: accepted.upperBound..<adaptation.endIndex
        ))
        let reconcileLog = try XCTUnwrap(adaptation.range(
            of: "Worldwide screen video adaptation needs native reconciliation:",
            range: failureCatch.upperBound..<adaptation.endIndex
        ))
        let failureAdmission = String(adaptation[failureCatch.upperBound..<reconcileLog.lowerBound])
        XCTAssertTrue(failureAdmission.contains("guard WorldwideScreenNativeApplicationCache.invalidateIfCurrent("))
        XCTAssertTrue(failureAdmission.contains("&appliedScreenVideoRecommendation"))
        XCTAssertTrue(failureAdmission.contains("expectedPolicyRevision: applyingPolicyRevision"))
        XCTAssertTrue(failureAdmission.contains("currentPolicyRevision: screenVideoAdaptationPolicyRevision"))
        for owner in [
            "peer === sourcePeer",
            "peerGeneration == sourcePeerGeneration",
            "captureSource === source",
            "captureSink === sink",
            "self.captureAuthorization === captureAuthorization",
            "self.captureForwardingAuthorization === forwardingAuthorization",
            "captureAuthorization.isValid",
            "forwardingAuthorization.isValid",
            "sink.allowsActiveUse(authorizedBy: forwardingAuthorization)",
            "captureVideoBaseDimensions == baseDimensions",
        ] {
            XCTAssertTrue(failureAdmission.contains(owner), "Missing resumed application owner: \(owner)")
        }
        XCTAssertFalse(failureAdmission.contains("appliedScreenVideoRecommendation = nil"))
        XCTAssertFalse(failureAdmission.contains("await "))
        XCTAssertTrue(failureAdmission.contains("return"))
    }

    func testBoundedNativeFailureFencesEvidenceBeforePublishingFallbackPolicy() throws {
        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        let accepted = try XCTUnwrap(adaptation.range(of: "nativeApply=accepted"))
        let failureCatch = try XCTUnwrap(
            adaptation.range(
                of: "            } catch {",
                range: accepted.upperBound..<adaptation.endIndex
            )
        )
        let failureReturn = try XCTUnwrap(
            adaptation.range(
                of: "                return\n            }\n        }",
                range: failureCatch.upperBound..<adaptation.endIndex
            )
        )
        let failure = String(
            adaptation[failureCatch.lowerBound..<failureReturn.upperBound]
        )
        let ownership = try XCTUnwrap(
            failure.range(
                of: "guard WorldwideScreenNativeApplicationCache.invalidateIfCurrent("
            )
        )
        let selectedFallback = try XCTUnwrap(
            failure.range(
                of: ".reconciledPolicyAfterCurrentOwnerFailure("
            )
        )
        let freshnessEpoch = try XCTUnwrap(
            failure.range(of: "advanceScreenVideoStatisticsEpoch(using: sourcePeer)")
        )
        let incompleteEvidenceReset = try XCTUnwrap(
            failure.range(of: "reconciledPolicy.resetIncompleteEvidenceWindow()")
        )
        let fallbackPublication = try XCTUnwrap(
            failure.range(of: "screenVideoAdaptationPolicy = reconciledPolicy")
        )
        let policyRevision = try XCTUnwrap(
            failure.range(
                of: "screenVideoAdaptationPolicyRevision &+= 1",
                range: fallbackPublication.upperBound..<failure.endIndex
            )
        )

        XCTAssertLessThan(ownership.lowerBound, selectedFallback.lowerBound)
        XCTAssertLessThan(selectedFallback.lowerBound, freshnessEpoch.lowerBound)
        XCTAssertLessThan(freshnessEpoch.lowerBound, incompleteEvidenceReset.lowerBound)
        XCTAssertLessThan(incompleteEvidenceReset.lowerBound, fallbackPublication.lowerBound)
        XCTAssertLessThan(fallbackPublication.lowerBound, policyRevision.lowerBound)
    }

    func testCacheMismatchFencesStartupEvidenceBeforeAndAfterPreWriteReport() throws {
        let adaptation = try serviceSlice(
            after: "    private func adaptScreenVideoForNetworkConditions(",
            before: "    private func beginAutomaticScreenMediaResumeIfPossible("
        )
        let mismatch = try XCTUnwrap(
            adaptation.range(of: "let nativeSenderRequiresReconciliation =")
        )
        let firstFence = try XCTUnwrap(
            adaptation.range(
                of: ".policyForSenderConfigurationReconciliation(",
                range: mismatch.upperBound..<adaptation.endIndex
            )
        )
        let reduction = try XCTUnwrap(
            adaptation.range(
                of: "changedRecommendation = proposedPolicy.update(",
                range: firstFence.upperBound..<adaptation.endIndex
            )
        )
        let secondFence = try XCTUnwrap(
            adaptation.range(
                of: ".policyForSenderConfigurationReconciliation(proposedPolicy)",
                range: reduction.upperBound..<adaptation.endIndex
            )
        )
        let nativeApply = try XCTUnwrap(
            adaptation.range(
                of: "await sourcePeer.applyScreenVideoEncodingLimits(",
                range: secondFence.upperBound..<adaptation.endIndex
            )
        )
        let acceptedEpoch = try XCTUnwrap(
            adaptation.range(
                of: "advanceScreenVideoStatisticsEpoch(using: sourcePeer)",
                range: nativeApply.upperBound..<adaptation.endIndex
            )
        )
        let unknownNativeBranch = try XCTUnwrap(
            adaptation.range(
                of: "if nativeSenderRequiresReconciliation {",
                range: acceptedEpoch.upperBound..<adaptation.endIndex
            )
        )
        let correctiveReset = try XCTUnwrap(
            adaptation.range(
                of: "proposedPolicy.resetForSenderConfigurationEpoch()",
                range: unknownNativeBranch.upperBound..<adaptation.endIndex
            )
        )
        let acceptedPolicyReset = try XCTUnwrap(
            adaptation.range(
                of: "proposedPolicy.resetForAcceptedSenderConfigurationEpoch(",
                range: correctiveReset.upperBound..<adaptation.endIndex
            )
        )
        let forcedApplyGate = try XCTUnwrap(
            adaptation.range(
                of: "if changedRecommendation != nil\n            || nativeSenderRequiresReconciliation {",
                range: secondFence.upperBound..<nativeApply.lowerBound
            )
        )

        XCTAssertLessThan(mismatch.lowerBound, firstFence.lowerBound)
        XCTAssertLessThan(firstFence.lowerBound, reduction.lowerBound)
        XCTAssertLessThan(reduction.lowerBound, secondFence.lowerBound)
        XCTAssertLessThan(secondFence.lowerBound, forcedApplyGate.lowerBound)
        XCTAssertLessThan(forcedApplyGate.lowerBound, nativeApply.lowerBound)
        XCTAssertLessThan(nativeApply.lowerBound, acceptedEpoch.lowerBound)
        XCTAssertLessThan(acceptedEpoch.lowerBound, unknownNativeBranch.lowerBound)
        XCTAssertLessThan(unknownNativeBranch.lowerBound, correctiveReset.lowerBound)
        XCTAssertLessThan(correctiveReset.lowerBound, acceptedPolicyReset.lowerBound)
    }

    func testAutomaticResumeKeepsFastAdaptationBlockedThroughEncoderRestore()
        throws {
        let sampler = try serviceSlice(
            after: "    private func sampleScreenVideoAdaptationStatistics(",
            before: "    /// Applies a new sender ceiling only after the current capture and peer identities survive"
        )
        let resumeOwnershipFence = try XCTUnwrap(
            sampler.range(of: "automaticScreenMediaResumeContext == nil")
        )
        let policyRevisionCapture = try XCTUnwrap(
            sampler.range(
                of: "let expectedPolicyRevision =",
                range: resumeOwnershipFence.upperBound..<sampler.endIndex
            )
        )
        let nativeStatisticsRequest = try XCTUnwrap(
            sampler.range(
                of: "screenVideoStatisticsSnapshot(",
                range: policyRevisionCapture.upperBound..<sampler.endIndex
            )
        )
        XCTAssertLessThan(
            resumeOwnershipFence.lowerBound,
            policyRevisionCapture.lowerBound
        )
        XCTAssertLessThan(
            resumeOwnershipFence.lowerBound,
            nativeStatisticsRequest.lowerBound
        )

        let finalization = try serviceSlice(
            after: "    private func handleAutomaticScreenMediaResumeRequest(",
            before: "    // MARK: - Screen control protocol"
        )
        let senderRestore = try XCTUnwrap(
            finalization.range(of: "applyScreenVideoEncodingLimits(")
        )
        let appliedRecommendation = try XCTUnwrap(
            finalization.range(
                of: "appliedScreenVideoRecommendation = recommendation",
                range: senderRestore.upperBound..<finalization.endIndex
            )
        )
        let contextRelease = try XCTUnwrap(
            finalization.range(
                of: "automaticScreenMediaResumeContext = nil",
                range: appliedRecommendation.upperBound..<finalization.endIndex
            )
        )
        XCTAssertLessThan(
            appliedRecommendation.lowerBound,
            contextRelease.lowerBound
        )
        let freshnessEpoch = try XCTUnwrap(
            finalization.range(
                of: "beginPostResumeScreenVideoAdaptationEpoch()",
                range: appliedRecommendation.upperBound..<contextRelease.lowerBound
            )
        )
        XCTAssertLessThan(
            freshnessEpoch.lowerBound,
            contextRelease.lowerBound
        )
        XCTAssertTrue(
            finalization.contains(
                "let finalizing = automaticScreenMediaResumeContext"
            )
        )
        XCTAssertFalse(
            finalization.contains(
                "automaticScreenMediaResumeContext == nil"
            )
        )
    }

    func testIrreversibleInputPostHoldsForwardingTokenAcrossFinalSinkCheck() throws {
        let method = try serviceSlice(
            after: "    private func injectRemoteInputIfAuthorized(",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        let inputAuthorization = try XCTUnwrap(
            method.range(
                of: "let result: WorldwideRemoteInputInjectionOutcome? ="
            )
        )
        let captureAuthorization = try XCTUnwrap(
            method.range(
                of: "try expectedCaptureAuthorization.withValidAuthorization {",
                range: inputAuthorization.upperBound..<method.endIndex
            )
        )
        let forwardingAuthorization = try XCTUnwrap(
            method.range(
                of: "try expectedForwardingAuthorization.withValidAuthorization {",
                range: captureAuthorization.upperBound..<method.endIndex
            )
        )
        let sinkCheck = try XCTUnwrap(
            method.range(
                of: "captureSink?.allowsActiveUseWhileAuthorizationHeld(",
                range: forwardingAuthorization.upperBound..<method.endIndex
            )
        )
        let injection = try XCTUnwrap(
            method.range(
                of: "return injectRemoteInput(request)",
                range: sinkCheck.upperBound..<method.endIndex
            )
        )
        let unlockedClassification = try XCTUnwrap(
            method.range(
                of: "return result ?? remoteInputCaptureUnavailableResult()",
                range: injection.upperBound..<method.endIndex
            )
        )

        XCTAssertLessThan(inputAuthorization.lowerBound, captureAuthorization.lowerBound)
        XCTAssertLessThan(captureAuthorization.lowerBound, forwardingAuthorization.lowerBound)
        XCTAssertLessThan(forwardingAuthorization.lowerBound, sinkCheck.lowerBound)
        XCTAssertLessThan(sinkCheck.lowerBound, injection.lowerBound)
        XCTAssertLessThan(injection.lowerBound, unlockedClassification.lowerBound)
        XCTAssertFalse(
            String(method[forwardingAuthorization.lowerBound..<injection.upperBound])
                .contains("captureSink?.allowsActiveUse(\n")
        )
        XCTAssertFalse(
            String(method[forwardingAuthorization.lowerBound..<injection.upperBound])
                .contains("remoteInputCaptureUnavailableResult()")
        )
    }

    func testDisplayModeCallbackClearsOldCoordinateMapBeforeTokenRevocationAndRebuild() throws {
        let sink = try serviceSlice(
            after: "    func displayModeDidChange() {",
            before: "    func screenVideoCaptureSource(\n        _ source: ScreenVideoCaptureSource,"
        )
        let stateTransition = try XCTUnwrap(
            sink.range(of: "let transition = lock.withLock")
        )
        let clearGeometry = try XCTUnwrap(
            sink.range(
                of: "remoteInputController.updateScreenVideoFrameGeometry(\n"
                    + "            nil,\n"
                    + "            ownerToken: remoteInputOwnerToken"
            )
        )
        let revokeToken = try XCTUnwrap(
            sink.range(
                of: "transition.retiredAuthorization?.revoke()",
                range: clearGeometry.upperBound..<sink.endIndex
            )
        )
        let scheduleRebuild = try XCTUnwrap(
            sink.range(
                of: "didRequireCaptureFormatRenegotiation(self)",
                range: revokeToken.upperBound..<sink.endIndex
            )
        )

        XCTAssertLessThan(stateTransition.lowerBound, clearGeometry.lowerBound)
        XCTAssertLessThan(clearGeometry.lowerBound, revokeToken.lowerBound)
        XCTAssertLessThan(revokeToken.lowerBound, scheduleRebuild.lowerBound)
    }

    func testOwnedFormatRebuildIsNonTerminalForTheInputCapability() throws {
        let admission = try serviceSlice(
            after: "    private func injectRemoteInputIfAuthorized(",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(admission.contains("return remoteInputCaptureUnavailableResult()"))

        let unavailable = try serviceSlice(
            after: "    private func remoteInputCaptureUnavailableResult()",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(unavailable.contains("screenCaptureTransitionIsOwned"))
        XCTAssertTrue(unavailable.contains(".rejected(.screenFormatChanging)"))
        XCTAssertTrue(unavailable.contains("formatOrigin: .captureGateUnavailable"))

        let feedback = try serviceSlice(
            after: "    private func transportFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        let transitionCase = try XCTUnwrap(
            feedback.range(of: "case .screenFormatChanging:")
        )
        let rateLimited = try XCTUnwrap(
            feedback.range(
                of: "reason = .rateLimited",
                range: transitionCase.upperBound..<feedback.endIndex
            )
        )
        let formatChangingFlag = try XCTUnwrap(
            feedback.range(
                of: "screenFormatChanging = true",
                range: rateLimited.upperBound..<feedback.endIndex
            )
        )
        let nonRevoking = try XCTUnwrap(
            feedback.range(
                of: "revokesSession = false",
                range: formatChangingFlag.upperBound..<feedback.endIndex
            )
        )
        XCTAssertLessThan(rateLimited.lowerBound, nonRevoking.lowerBound)
        XCTAssertLessThan(formatChangingFlag.lowerBound, nonRevoking.lowerBound)
    }

    func testPreConfigurationFenceRemainsOwnedAndNonTerminalForInputCapability() throws {
        let ownership = try serviceSlice(
            after: "    private var screenCaptureTransitionIsOwned: Bool {",
            before: "    /// A newer ordered request owns the screen state"
        )
        XCTAssertTrue(
            ownership.contains("currentSink.isDisplayConfigurationInProgress")
        )

        let sinkState = try serviceSlice(
            after: "    var isDisplayConfigurationInProgress: Bool {",
            before: "    /// Privacy-safe capture state sampled"
        )
        XCTAssertTrue(sinkState.contains("displayConfigurationInProgress"))
        XCTAssertTrue(sinkState.contains("forwardingPhase == .starting"))
        XCTAssertTrue(sinkState.contains("forwardingPhase == .active"))
        XCTAssertTrue(sinkState.contains("callbackGateAllowsEntry"))

        let request = try serviceSlice(
            after: "    private func handleRemoteInputRequest(",
            before: "    /// Holds input, capture, then the exact forwarding authorization"
        )
        XCTAssertTrue(request.contains("if feedback.revokesSession"))

        let unavailable = try serviceSlice(
            after: "    private func remoteInputCaptureUnavailableResult()",
            before: "    /// Maps validated wire actions onto the narrow macOS input controller surface."
        )
        XCTAssertTrue(unavailable.contains(".rejected(.screenFormatChanging)"))

        let feedback = try serviceSlice(
            after: "    private func transportFeedback(",
            before: "    /// Revokes the transport token and controller state synchronously."
        )
        let transitionCase = try XCTUnwrap(
            feedback.range(of: "case .screenFormatChanging:")
        )
        let formatChangingFlag = try XCTUnwrap(
            feedback.range(
                of: "screenFormatChanging = true",
                range: transitionCase.upperBound..<feedback.endIndex
            )
        )
        let nonRevoking = try XCTUnwrap(
            feedback.range(
                of: "revokesSession = false",
                range: formatChangingFlag.upperBound..<feedback.endIndex
            )
        )
        XCTAssertLessThan(transitionCase.lowerBound, nonRevoking.lowerBound)
        XCTAssertLessThan(formatChangingFlag.lowerBound, nonRevoking.lowerBound)
    }

    func testNativeRestartRetryPreservesInputOnlyForAnOwnedFormatTransition() throws {
        let startup = try serviceSlice(
            after: "    private func startScreenCapture(\n",
            before: "    /// Revokes visibility before awaiting native ScreenCaptureKit shutdown."
        )
        XCTAssertTrue(
            startup.contains(
                "revokeCaptureAuthorization(\n                    preservingRemoteInput: screenCaptureTransitionIsOwned"
            )
        )

        let revocation = try serviceSlice(
            after: "    private func revokeCaptureAuthorization(\n",
            before: "}\n\n/// Actor-owned handoff for sequential live capture-format rebuilds."
        )
        XCTAssertTrue(revocation.contains("preservingRemoteInput: Bool = false"))
        XCTAssertTrue(revocation.contains("if !preservingRemoteInput"))
        XCTAssertTrue(revocation.contains("revokeRemoteInputAuthorization()"))
    }

    func testFreshCaptureBoundsReplaceStaleInputBoundsBeforeFramesCanReopen() throws {
        let startup = try serviceSlice(
            after: "    private func startScreenCapture(\n",
            before: "    /// Waits only for the first exact image surface selected for this capture generation."
        )
        let displayIdentity = try XCTUnwrap(
            startup.range(of: "captureDisplayID = format.displayID")
        )
        let boundsSnapshot = try XCTUnwrap(
            startup.range(
                of: "captureAuthoritativeDisplayBounds = format.authoritativeDisplayBounds",
                range: displayIdentity.upperBound..<startup.endIndex
            )
        )
        let controllerUpdate = try XCTUnwrap(
            startup.range(
                of: "remoteInputController.updateAuthoritativeDisplayBounds(",
                range: boundsSnapshot.upperBound..<startup.endIndex
            )
        )
        let forwardingInstall = try XCTUnwrap(
            startup.range(
                of: "sink.beginForwarding(",
                range: controllerUpdate.upperBound..<startup.endIndex
            )
        )
        let sampleDelivery = try XCTUnwrap(
            startup.range(
                of: "source.beginSampleDelivery()",
                range: forwardingInstall.upperBound..<startup.endIndex
            )
        )

        XCTAssertLessThan(displayIdentity.lowerBound, boundsSnapshot.lowerBound)
        XCTAssertLessThan(boundsSnapshot.lowerBound, controllerUpdate.lowerBound)
        XCTAssertLessThan(controllerUpdate.lowerBound, forwardingInstall.lowerBound)
        XCTAssertLessThan(forwardingInstall.lowerBound, sampleDelivery.lowerBound)

        let arm = try serviceSlice(
            after: "    private func armRemoteInputIfAvailable(\n",
            before: "    /// Injects one request under revocable gates"
        )
        XCTAssertTrue(
            arm.contains(
                "authoritativeDisplayBounds: captureAuthoritativeDisplayBounds"
            )
        )
        XCTAssertTrue(arm.contains("initialFrameGeometry: initialFrameGeometry"))
    }

    private func serviceSlice(after startMarker: String, before endMarker: String) throws -> String {
        try sourceSlice(
            at: "macOS/Sources/CaptureServer/WorldwideScreenService.swift",
            after: startMarker,
            before: endMarker
        )
    }

    private func peerSlice(after startMarker: String, before endMarker: String) throws -> String {
        try sourceSlice(
            at: "shared/Sources/WebRTCTransport/WebRTCPeer.swift",
            after: startMarker,
            before: endMarker
        )
    }

    private func sourceSlice(
        at relativePath: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}
