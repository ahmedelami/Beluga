import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideScreenFormatRenegotiationSupersessionTests: XCTestCase {
    func testNewVisibilityCommandSupersedesRetiredRebuildFailure() {
        XCTAssertTrue(
            superseded(
                visibilityCommandEpoch: 7,
                currentVisibilityCommandEpoch: 8
            )
        )
    }

    func testNewPeerRecoveryOrStoppedServiceSupersedesRetiredRebuildFailure() {
        XCTAssertTrue(superseded(peerGeneration: 2, currentPeerGeneration: 3))
        XCTAssertTrue(superseded(recoveryEpoch: 4, currentRecoveryEpoch: 5))
        XCTAssertTrue(superseded(serviceIsStopped: true))
    }

    func testUnchangedLifecycleKeepsTerminalRebuildFailureFailClosed() {
        XCTAssertFalse(superseded())
    }

    func testProductionCatchChecksSupersessionBeforeTerminalSessionStop() throws {
        let source = try serviceSource()
        let method = try sourceSlice(
            in: source,
            after: "    private func renegotiateScreenCaptureFormat(",
            before: "    /// A newer visibility command, peer, recovery epoch, or completed service owns any failure"
        )
        let visibilitySnapshot = try XCTUnwrap(
            method.range(of: "let visibilityCommandEpoch = screenVisibilityCommandEpoch")
        )
        let replacementStart = try XCTUnwrap(
            method.range(of: "_ = try await startScreenCaptureWithDisplayModeRetries(")
        )
        let supersessionCheck = try XCTUnwrap(
            method.range(of: "let wasSuperseded = Self.screenFormatRenegotiationWasSuperseded(")
        )
        let supersededReturn = try XCTUnwrap(
            method.range(
                of: "if wasSuperseded {",
                range: supersessionCheck.upperBound..<method.endIndex
            )
        )
        let terminalStop = try XCTUnwrap(
            method.range(
                of: "await stop()",
                range: supersededReturn.upperBound..<method.endIndex
            )
        )
        let protectedRegion = String(
            method[supersededReturn.lowerBound..<terminalStop.lowerBound]
        )

        XCTAssertLessThan(visibilitySnapshot.lowerBound, replacementStart.lowerBound)
        XCTAssertLessThan(replacementStart.lowerBound, supersessionCheck.lowerBound)
        XCTAssertLessThan(supersessionCheck.lowerBound, supersededReturn.lowerBound)
        XCTAssertTrue(protectedRegion.contains("return"))
        XCTAssertFalse(protectedRegion.contains("await stop()"))
    }

    func testDisplayModeRetryCannotRestartAfterItsLifecycleOwnerChanges() throws {
        let source = try serviceSource()
        let retry = try sourceSlice(
            in: source,
            after: "    private func startScreenCaptureWithDisplayModeRetries(",
            before: "    private nonisolated static func isDisplayModeChangedDuringScreenStart("
        )
        let entryCheck = try XCTUnwrap(
            retry.range(of: "guard screenCaptureStartupOwnerIsCurrent(owner) else")
        )
        let nativeStart = try XCTUnwrap(
            retry.range(
                of: "let authorization = try await startScreenCapture(",
                range: entryCheck.upperBound..<retry.endIndex
            )
        )
        let postStartCheck = try XCTUnwrap(
            retry.range(
                of: "guard screenCaptureStartupOwnerIsCurrent(owner) else",
                range: nativeStart.upperBound..<retry.endIndex
            )
        )
        let senderReconciliation = try XCTUnwrap(
            retry.range(
                of: "try await reconcileCurrentScreenVideoRecommendationBeforeActiveUse(",
                range: postStartCheck.upperBound..<retry.endIndex
            )
        )
        let postReconciliationCheck = try XCTUnwrap(
            retry.range(
                of: "guard screenCaptureStartupOwnerIsCurrent(owner),",
                range: senderReconciliation.upperBound..<retry.endIndex
            )
        )
        let successfulReturn = try XCTUnwrap(
            retry.range(
                of: "return authorization",
                range: postReconciliationCheck.upperBound..<retry.endIndex
            )
        )
        let retrySleep = try XCTUnwrap(
            retry.range(
                of: "try await Task.sleep(for: .milliseconds(125))",
                range: successfulReturn.upperBound..<retry.endIndex
            )
        )
        let postSleepCheck = try XCTUnwrap(
            retry.range(
                of: "guard screenCaptureStartupOwnerIsCurrent(owner)",
                range: retrySleep.upperBound..<retry.endIndex
            )
        )
        let recursiveStart = try XCTUnwrap(
            retry.range(
                of: "return try await startScreenCaptureWithDisplayModeRetries(",
                range: postSleepCheck.upperBound..<retry.endIndex
            )
        )
        let recursiveOwner = try XCTUnwrap(
            retry.range(
                of: "owner: owner",
                range: recursiveStart.upperBound..<retry.endIndex
            )
        )

        XCTAssertLessThan(entryCheck.lowerBound, nativeStart.lowerBound)
        XCTAssertLessThan(nativeStart.lowerBound, postStartCheck.lowerBound)
        XCTAssertLessThan(postStartCheck.lowerBound, senderReconciliation.lowerBound)
        XCTAssertLessThan(senderReconciliation.lowerBound, postReconciliationCheck.lowerBound)
        XCTAssertLessThan(postReconciliationCheck.lowerBound, successfulReturn.lowerBound)
        XCTAssertTrue(retry.contains("let reusedActiveCapture ="))
        XCTAssertTrue(retry.contains("forceNativeApplication: reusedActiveCapture"))
        XCTAssertLessThan(successfulReturn.lowerBound, retrySleep.lowerBound)
        XCTAssertLessThan(retrySleep.lowerBound, postSleepCheck.lowerBound)
        XCTAssertLessThan(postSleepCheck.lowerBound, recursiveStart.lowerBound)
        XCTAssertLessThan(recursiveStart.lowerBound, recursiveOwner.lowerBound)

        let renegotiation = try sourceSlice(
            in: source,
            after: "    private func renegotiateScreenCaptureFormat(",
            before: "    /// A newer visibility command, peer, recovery epoch, or completed service owns any failure"
        )
        XCTAssertTrue(renegotiation.contains("let startupOwner = ScreenCaptureStartupOwner("))
        XCTAssertTrue(renegotiation.contains("owner: startupOwner"))
    }

    func testActiveCaptureReuseReconcilesNativeSenderBeforeReturningTowardActiveACK()
        throws {
        let source = try serviceSource()
        let helper = try sourceSlice(
            in: source,
            after: "    private func reconcileCurrentScreenVideoRecommendationBeforeActiveUse(",
            before: "    private func screenCaptureStartupOwnerIsCurrent("
        )
        let mismatch = try XCTUnwrap(
            helper.range(
                of: "appliedScreenVideoRecommendation\n                != screenVideoAdaptationPolicy.currentRecommendation"
            )
        )
        let reconcile = try XCTUnwrap(
            helper.range(
                of: "await adaptScreenVideoForNetworkConditions(",
                range: mismatch.upperBound..<helper.endIndex
            )
        )
        let appliedPostcondition = try XCTUnwrap(
            helper.range(
                of: "appliedScreenVideoRecommendation\n                == screenVideoAdaptationPolicy.currentRecommendation",
                range: reconcile.upperBound..<helper.endIndex
            )
        )

        XCTAssertLessThan(mismatch.lowerBound, reconcile.lowerBound)
        XCTAssertLessThan(reconcile.lowerBound, appliedPostcondition.lowerBound)
        XCTAssertTrue(helper.contains("guard forceNativeApplication"))
        XCTAssertTrue(helper.contains("expectedPolicyRevision: expectedPolicyRevision"))
        XCTAssertTrue(helper.contains("allowsAutomaticResume: false"))
        XCTAssertTrue(helper.contains("forceNativeReconciliation: forceNativeApplication"))
        XCTAssertTrue(
            helper.contains(
                "screenVideoNativeApplicationGeneration\n                != expectedNativeApplicationGeneration"
            )
        )
    }

    func testCommittedResumeGeometrySupersessionConsumesPolicyRestoration() throws {
        let source = try serviceSource()
        let method = try sourceSlice(
            in: source,
            after: "    private func renegotiateScreenCaptureFormat(",
            before: "    /// A newer visibility command, peer, recovery epoch, or completed service owns any failure"
        )
        let committedBranch = try XCTUnwrap(
            method.range(of: "if context.finalAcknowledgementCommit.isCommitted {")
        )
        let successConsumption = try XCTUnwrap(
            method.range(
                of: "screenVideoAdaptationPolicy.automaticResumeAttemptSucceeded()",
                range: committedBranch.upperBound..<method.endIndex
            )
        )
        let contextClear = try XCTUnwrap(
            method.range(
                of: "automaticScreenMediaResumeContext = nil",
                range: successConsumption.upperBound..<method.endIndex
            )
        )

        XCTAssertLessThan(committedBranch.lowerBound, successConsumption.lowerBound)
        XCTAssertLessThan(successConsumption.lowerBound, contextClear.lowerBound)
    }

    func testLiveFormatRebuildStartsFreshAdaptationEvidenceEpochBeforeStoppingSource()
        throws {
        let source = try serviceSource()
        let method = try sourceSlice(
            in: source,
            after: "    private func renegotiateScreenCaptureFormat(",
            before: "    /// A newer visibility command, peer, recovery epoch, or completed service owns any failure"
        )
        let owner = try XCTUnwrap(
            method.range(of: "let startupOwner = ScreenCaptureStartupOwner(")
        )
        let epoch = try XCTUnwrap(
            method.range(
                of: "beginPostResumeScreenVideoAdaptationEpoch(\n            rearmDemandProvenSpatialAuthority: true\n        )",
                range: owner.upperBound..<method.endIndex
            )
        )
        let nativeStop = try XCTUnwrap(
            method.range(
                of: "try await source.stop()",
                range: epoch.upperBound..<method.endIndex
            )
        )

        XCTAssertLessThan(owner.lowerBound, epoch.lowerBound)
        XCTAssertLessThan(epoch.lowerBound, nativeStop.lowerBound)

        let epochMethod = try sourceSlice(
            in: source,
            after: "    private func advanceScreenVideoStatisticsEpoch(using sourcePeer: WebRTCPeer?) {",
            before: "    private func automaticScreenMediaResumeTimedOut("
        )
        XCTAssertTrue(epochMethod.contains("minimumNextStatisticsCollectionSequence()"))
        XCTAssertTrue(epochMethod.contains("resetForCaptureGeometryEpoch()"))
        XCTAssertTrue(epochMethod.contains("resetForSenderConfigurationEpoch()"))
        XCTAssertTrue(epochMethod.contains("screenVideoAdaptationEvidenceLane = nil"))
        XCTAssertTrue(epochMethod.contains("screenVideoAdaptationLastEvidenceTime = nil"))
        XCTAssertTrue(epochMethod.contains("screenVideoAdaptationPolicyRevision &+= 1"))
    }

    private func superseded(
        visibilityCommandEpoch: UInt64 = 7,
        currentVisibilityCommandEpoch: UInt64 = 7,
        peerGeneration: UInt64 = 2,
        currentPeerGeneration: UInt64 = 2,
        recoveryEpoch: UInt64 = 4,
        currentRecoveryEpoch: UInt64 = 4,
        serviceIsStopped: Bool = false
    ) -> Bool {
        WorldwideScreenService.screenFormatRenegotiationWasSuperseded(
            visibilityCommandEpoch: visibilityCommandEpoch,
            currentVisibilityCommandEpoch: currentVisibilityCommandEpoch,
            peerGeneration: peerGeneration,
            currentPeerGeneration: currentPeerGeneration,
            recoveryEpoch: recoveryEpoch,
            currentRecoveryEpoch: currentRecoveryEpoch,
            serviceIsStopped: serviceIsStopped
        )
    }

    private func serviceSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/WorldwideScreenService.swift"
            ),
            encoding: .utf8
        )
    }

    private func sourceSlice(
        in source: String,
        after startMarker: String,
        before endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        return String(source[start..<end])
    }
}
