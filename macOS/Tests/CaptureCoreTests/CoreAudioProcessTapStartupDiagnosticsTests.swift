import AudioToolbox
import Foundation
import XCTest
@testable import CaptureCore

final class CoreAudioProcessTapStartupDiagnosticsTests: XCTestCase {
    func testClockIdentityOnlyExposesReviewedBuiltInUIDAndOtherwiseUsesBoundedDigest() {
        XCTAssertEqual(
            CoreAudioProcessTapStartupDiagnostics.clockUIDDiagnostic("BuiltInSpeakerDevice"),
            "BuiltInSpeakerDevice"
        )
        let addressLikeUID = "Bluetooth-AA:BB:CC:DD:EE:FF\nprivate-device-name"
        let value = CoreAudioProcessTapStartupDiagnostics.clockUIDDiagnostic(addressLikeUID)
        XCTAssertTrue(value.hasPrefix("sha256:"))
        XCTAssertEqual(value.count, 31)
        XCTAssertFalse(value.contains("Bluetooth"))
        XCTAssertFalse(value.contains("AA:BB"))
        XCTAssertFalse(value.contains("\n"))
        XCTAssertEqual(value, CoreAudioProcessTapStartupDiagnostics.clockUIDDiagnostic(addressLikeUID))
        XCTAssertNotEqual(value, CoreAudioProcessTapStartupDiagnostics.clockUIDDiagnostic("another-device"))
    }

    func testAPIStartSuccessDoesNotProveAnyCallbackProgress() {
        let diagnostics = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        diagnostics.recordAPIStartResult(noErr)

        XCTAssertEqual(diagnostics.apiStartStatus, noErr)
        XCTAssertEqual(
            diagnostics.observe(diagnostics.callbacks.progress, lifetimeID: diagnostics.lifetimeID),
            .awaitingFirstCallback
        )
        XCTAssertFalse(diagnostics.progressTracker.didObserveAdvancement)
        XCTAssertNil(
            diagnostics.observe(diagnostics.callbacks.progress, lifetimeID: diagnostics.lifetimeID),
            "An unchanged waiting state must not produce periodic log noise."
        )
    }

    func testFirstCallbackAndAdvancementRequireSeparateCurrentObservations() {
        let diagnostics = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        let counter = diagnostics.callbacks
        counter.recordValidCallback(frameCount: 0, hostTime: 90)
        XCTAssertEqual(counter.progress, CoreAudioProcessTapCallbackProgress())
        counter.recordValidCallback(frameCount: 480, hostTime: 100)
        counter.recordValidCallback(frameCount: 256, hostTime: 110)

        XCTAssertEqual(counter.progress.callbackCount, 2)
        XCTAssertEqual(counter.progress.frameCount, 736)
        XCTAssertEqual(counter.progress.firstCallbackHostTime, 100)
        XCTAssertEqual(counter.progress.latestCallbackHostTime, 110)
        XCTAssertEqual(
            diagnostics.observe(counter.progress, lifetimeID: diagnostics.lifetimeID),
            .firstValidCallback
        )
        XCTAssertFalse(diagnostics.progressTracker.didObserveAdvancement)
        XCTAssertNil(diagnostics.observe(counter.progress, lifetimeID: diagnostics.lifetimeID))

        counter.recordValidCallback(frameCount: 512, hostTime: 120)
        XCTAssertEqual(
            diagnostics.observe(counter.progress, lifetimeID: diagnostics.lifetimeID),
            .callbacksAdvancing
        )
        XCTAssertTrue(diagnostics.progressTracker.didObserveAdvancement)
        counter.recordValidCallback(frameCount: 480, hostTime: 130)
        XCTAssertNil(
            diagnostics.observe(counter.progress, lifetimeID: diagnostics.lifetimeID),
            "Startup progress logs stop after the bounded advancement proof."
        )
    }

    func testNewLifetimeStartsEmptyAndRejectsRetiredOrStaleSamples() {
        let retired = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        retired.callbacks.recordValidCallback(frameCount: 480, hostTime: 100)
        let retiredSample = retired.callbacks.progress
        retired.retire()
        XCTAssertNil(retired.observe(retiredSample, lifetimeID: retired.lifetimeID))
        retired.recordAPIStartResult(noErr)
        XCTAssertNil(retired.apiStartStatus)

        let replacement = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        XCTAssertNotEqual(replacement.lifetimeID, retired.lifetimeID)
        XCTAssertEqual(replacement.callbacks.progress, CoreAudioProcessTapCallbackProgress())
        XCTAssertNil(replacement.observe(retiredSample, lifetimeID: retired.lifetimeID))
        XCTAssertEqual(
            replacement.observe(replacement.callbacks.progress, lifetimeID: replacement.lifetimeID),
            .awaitingFirstCallback
        )
        XCTAssertFalse(replacement.progressTracker.didObserveAdvancement)
    }

    func testFailedStartRetainsStatusWithoutPublishingProgress() {
        let diagnostics = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        diagnostics.recordAPIStartResult(kAudioHardwareUnspecifiedError)
        XCTAssertEqual(diagnostics.apiStartStatus, kAudioHardwareUnspecifiedError)
        XCTAssertEqual(
            diagnostics.observe(diagnostics.callbacks.progress, lifetimeID: diagnostics.lifetimeID),
            .awaitingFirstCallback
        )
        diagnostics.retire()
        diagnostics.callbacks.recordValidCallback(frameCount: 480, hostTime: 100)
        XCTAssertNil(
            diagnostics.observe(diagnostics.callbacks.progress, lifetimeID: diagnostics.lifetimeID)
        )
        XCTAssertFalse(diagnostics.progressTracker.didObserveAdvancement)
    }

    func testFrozenOrInconsistentCountersCannotReportAdvancement() {
        let baseline = CoreAudioProcessTapCallbackProgress(
            callbackCount: 2, frameCount: 960,
            firstCallbackHostTime: 100, latestCallbackHostTime: 110
        )
        let invalidSamples = [
            baseline,
            CoreAudioProcessTapCallbackProgress(
                callbackCount: 2, frameCount: 1_440,
                firstCallbackHostTime: 100, latestCallbackHostTime: 120
            ),
            CoreAudioProcessTapCallbackProgress(
                callbackCount: 3, frameCount: 960,
                firstCallbackHostTime: 100, latestCallbackHostTime: 120
            ),
            CoreAudioProcessTapCallbackProgress(
                callbackCount: 3, frameCount: 1_440,
                firstCallbackHostTime: 100, latestCallbackHostTime: 110
            ),
            CoreAudioProcessTapCallbackProgress(
                callbackCount: 3, frameCount: 1_440,
                firstCallbackHostTime: 101, latestCallbackHostTime: 120
            ),
        ]
        for invalid in invalidSamples {
            var tracker = CoreAudioProcessTapStartupProgressTracker()
            XCTAssertEqual(tracker.observe(baseline), .firstValidCallback)
            XCTAssertNil(tracker.observe(invalid))
            XCTAssertFalse(tracker.didObserveAdvancement)
        }
    }

    func testQueueSnapshotObservesCompleteCallbackUpdatesWithoutBlockingControl() {
        let queues = CoreAudioProcessTapQueueTopology(labelPrefix: "opensteamer.tests.TapStartup")
        let diagnostics = CoreAudioProcessTapStartupDiagnostics(tapAutoStartRequested: true)
        let sampleReceived = expectation(description: "control received coherent PCM snapshot")
        queues.ioCallbackQueue.async {
            for index in 1...100 {
                diagnostics.callbacks.recordValidCallback(frameCount: 480, hostTime: UInt64(index))
            }
        }
        queues.ioCallbackQueue.async {
            let progress = diagnostics.callbacks.progress
            queues.asyncControl {
                XCTAssertEqual(progress.callbackCount, 100)
                XCTAssertEqual(progress.frameCount, 48_000)
                XCTAssertEqual(progress.firstCallbackHostTime, 1)
                XCTAssertEqual(progress.latestCallbackHostTime, 100)
                sampleReceived.fulfill()
            }
        }
        wait(for: [sampleReceived], timeout: 1)
    }
}
