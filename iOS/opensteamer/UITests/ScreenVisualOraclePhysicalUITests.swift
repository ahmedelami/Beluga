import UIKit
import XCTest

/// Screen-only release oracle for the already-installed production-bundle candidate. The guarded
/// shell driver proves device/build/host identity and an already-visible screen before it starts
/// the per-run Mac challenge. It does not prove TestFlight receipt provenance. The test only
/// observes that presentation: it never launches, activates, taps, backgrounds, creates, hides,
/// or disconnects the production app/session.
/// This test observes the iPhone's final composited pixels; renderer counters are only session
/// fences and can never make the test pass by themselves.
@MainActor
final class ScreenVisualOraclePhysicalUITests: XCTestCase {
    private static let productionBundleIdentifier = "com.elamin.opensteamer"
    private let app = XCUIApplication(bundleIdentifier: productionBundleIdentifier)

    private let observationDuration: TimeInterval = 13
    private let sampleInterval: TimeInterval = 0.30
    private let maximumConsecutiveUndecodableSamples = 3
    private let maximumSameSymbolHoldDuration: TimeInterval = 4.25

    func testInstalledProductionBundleFinalPixelsTrackFreshMacChallenge() throws {
        continueAfterFailure = false

        XCTAssertEqual(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER"
            ],
            Self.productionBundleIdentifier,
            "Run this physical test only through the guarded visual-oracle driver."
        )
        XCTAssertNotNil(validatedNonce)
        XCTAssertNotNil(validatedExpectedBuild)
        XCTAssertEqual(
            ProcessInfo.processInfo.environment[
                "OPENSTEAMER_SCREEN_ORACLE_OBSERVE_EXISTING_SCREEN"
            ],
            "1",
            "The oracle may only observe a runner-proven existing screen presentation."
        )
        guard app.state == .runningForeground else {
            XCTFail(
                "Open the connected Mac screen in Beluga before running the observe-only oracle; "
                    + "the test will not activate or launch it."
            )
            return
        }
        let nonce = try XCTUnwrap(validatedNonce)
        let expectedBuild = try XCTUnwrap(validatedExpectedBuild)
        var tracker = try XCTUnwrap(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                requiredDistinctSymbolCount: 4,
                maximumConsecutiveUndecodableFrames:
                    maximumConsecutiveUndecodableSamples
            )
        )
        var continuityTracker = try XCTUnwrap(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: maximumSameSymbolHoldDuration
            )
        )

        let initial = try XCTUnwrap(
            waitForAcknowledgedScreen(timeout: 15),
            "The runner-proven existing screen was not visible with a live renderer. Last state: \(screenObservation)"
        )
        let videoFrame = initial.videoFrame
        let videoContentFrame = try XCTUnwrap(
            PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
                container: videoFrame,
                sourceWidth: initial.video.width,
                sourceHeight: initial.video.height
            ),
            "The decoded video dimensions could not be mapped into the final screen."
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        var sampleLines: [String] = []
        var observedIndices: [Int] = []
        var totalDecodedSamples = 0
        var consecutiveUndecodableSamples = 0
        var maximumUndecodableRun = 0
        var lastVideo = initial.video

        while ProcessInfo.processInfo.systemUptime - startedAt < observationDuration {
            XCTAssertEqual(app.state, .runningForeground)
            assertNoConnectionError()

            let current = try currentScreenEvidence(
                expectedAcknowledgement: initial.acknowledgement,
                expectedRendererID: initial.video.rendererID,
                expectedVideoFrame: videoFrame,
                expectedVideoWidth: initial.video.width,
                expectedVideoHeight: initial.video.height
            )
            lastVideo = current.video

            let finalPixels = try XCTUnwrap(
                captureVideoFrame(videoContentFrame),
                "Could not read the actual composited iPhone video pixels."
            )
            if let symbol = finalPixels.decode(nonce: nonce) {
                let observedAt = ProcessInfo.processInfo.systemUptime
                consecutiveUndecodableSamples = 0
                totalDecodedSamples += 1
                _ = tracker.observe(symbol)
                XCTAssertNotEqual(
                    continuityTracker.observe(symbol, at: observedAt),
                    .rejected,
                    "The final iPhone pixels froze or stopped following the ordered challenge."
                )
                if observedIndices.last != symbol.index {
                    observedIndices.append(symbol.index)
                }
                sampleLines.append(
                    "t=\(elapsed(startedAt)) index=\(symbol.index) frames=\(current.video.frameCount)"
                )
            } else {
                consecutiveUndecodableSamples += 1
                _ = tracker.observeUndecodableFrame()
                maximumUndecodableRun = max(
                    maximumUndecodableRun,
                    consecutiveUndecodableSamples
                )
                sampleLines.append(
                    "t=\(elapsed(startedAt)) index=none frames=\(current.video.frameCount)"
                )
                XCTAssertNotEqual(
                    tracker.state,
                    .rejected,
                    "The final iPhone display stopped showing the fresh challenge for too long."
                )
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(sampleInterval)
            )
        }

        // End on a decoded final-composite frame. A bounded retry avoids making an H.264 symbol
        // transition flaky, while the same gap budget still rejects a persistent black tail.
        let terminalDeadline = Date().addingTimeInterval(
            sampleInterval * Double(maximumConsecutiveUndecodableSamples + 1)
        )
        var terminalSymbol: PhysicalScreenSequenceSymbol?
        while Date() < terminalDeadline, terminalSymbol == nil {
            let current = try currentScreenEvidence(
                expectedAcknowledgement: initial.acknowledgement,
                expectedRendererID: initial.video.rendererID,
                expectedVideoFrame: videoFrame,
                expectedVideoWidth: initial.video.width,
                expectedVideoHeight: initial.video.height
            )
            lastVideo = current.video
            let finalPixels = try XCTUnwrap(captureVideoFrame(videoContentFrame))
            if let symbol = finalPixels.decode(nonce: nonce) {
                let observedAt = ProcessInfo.processInfo.systemUptime
                terminalSymbol = symbol
                consecutiveUndecodableSamples = 0
                totalDecodedSamples += 1
                _ = tracker.observe(symbol)
                XCTAssertNotEqual(
                    continuityTracker.observe(symbol, at: observedAt),
                    .rejected,
                    "The final iPhone pixels ended frozen or out of sequence."
                )
                if observedIndices.last != symbol.index {
                    observedIndices.append(symbol.index)
                }
                sampleLines.append(
                    "t=\(elapsed(startedAt)) terminalIndex=\(symbol.index) frames=\(current.video.frameCount)"
                )
            } else {
                consecutiveUndecodableSamples += 1
                maximumUndecodableRun = max(
                    maximumUndecodableRun,
                    consecutiveUndecodableSamples
                )
                _ = tracker.observeUndecodableFrame()
                XCTAssertNotEqual(
                    tracker.state,
                    .rejected,
                    "The final iPhone display remained black, stale, obscured, or unrelated."
                )
                RunLoop.current.run(
                    until: Date().addingTimeInterval(sampleInterval)
                )
            }
        }

        let maximumSameSymbolHoldText = String(
            format: "%.2f",
            continuityTracker.maximumObservedSameSymbolHoldDuration
        )
        let evidence = XCTAttachment(
            string:
                "schema=opensteamer.screen-visual-oracle.v1\n"
                + "build=\(expectedBuild)\n"
                + "nonce=\(nonce)\n"
                + "session=\(initial.acknowledgement.sessionGeneration.uuidString.lowercased())\n"
                + "renderer=\(initial.video.rendererID.uuidString.lowercased())\n"
                + "decodedSamples=\(totalDecodedSamples)\n"
                + "maximumUndecodableRun=\(maximumUndecodableRun)\n"
                + "maximumSameSymbolHold=\(maximumSameSymbolHoldText)\n"
                + "observedIndices=\(observedIndices.map(String.init).joined(separator: ","))\n"
                + sampleLines.joined(separator: "\n")
        )
        evidence.name = "Nonce-bound final iPhone screen evidence"
        evidence.lifetime = .keepAlways
        add(evidence)

        XCTAssertEqual(
            tracker.state,
            .satisfied,
            "The final iPhone pixels did not show four fresh challenge symbols in order."
        )
        XCTAssertEqual(
            continuityTracker.state,
            .satisfied,
            "The final pixels did not continue into a fresh ordered challenge cycle."
        )
        XCTAssertNotNil(
            terminalSymbol,
            "The observation did not end on a fresh nonce-bound final iPhone frame."
        )
        XCTAssertGreaterThanOrEqual(totalDecodedSamples, 12)
        XCTAssertGreaterThanOrEqual(
            observedIndices.count,
            5,
            "The final pixels completed one cycle but did not keep following the changing source."
        )
        XCTAssertGreaterThan(lastVideo.frameCount, initial.video.frameCount)
        XCTAssertGreaterThan(lastVideo.timestampNanoseconds, initial.video.timestampNanoseconds)

        let marker =
            "OPENSTEAMER_SCREEN_VISUAL_ORACLE_V1"
                + " build=\(expectedBuild)"
                + " nonce=\(nonce)"
                + " session=\(initial.acknowledgement.sessionGeneration.uuidString.lowercased())"
                + " renderer=\(initial.video.rendererID.uuidString.lowercased())"
                + " decodedSamples=\(totalDecodedSamples)"
                + " maximumUndecodableRun=\(maximumUndecodableRun)"
                + " maximumSameSymbolHold=\(maximumSameSymbolHoldText)"
                + " symbols=\(observedIndices.map(String.init).joined(separator: ","))\n"
        FileHandle.standardOutput.write(Data(marker.utf8))
    }

    private struct ScreenEvidence {
        let acknowledgement: PhysicalScreenAcknowledgementSnapshot
        let video: PhysicalVideoRenderSnapshot
        let videoFrame: CGRect
    }

    private var validatedNonce: String? {
        guard let nonce = ProcessInfo.processInfo.environment[
            "OPENSTEAMER_SCREEN_ORACLE_NONCE"
        ], nonce.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return nonce
    }

    private var validatedExpectedBuild: String? {
        guard let build = ProcessInfo.processInfo.environment[
            "OPENSTEAMER_SCREEN_ORACLE_EXPECTED_BUILD"
        ], build.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return build
    }

    private func waitForAcknowledgedScreen(timeout: TimeInterval) -> ScreenEvidence? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard app.state == .runningForeground, !hasConnectionError else { return nil }
            let videoElement = element("worldwideMacScreenVideo")
            let acknowledgementElement = element("worldwideScreenAcknowledgementOracle")
            if videoElement.exists,
               videoElement.frame.width > 1,
               videoElement.frame.height > 1,
               acknowledgementElement.exists,
               acknowledgementElement.label == "Screen live",
               let encodedVideo = videoElement.value as? String,
               let video = PhysicalVideoRenderSnapshot(accessibilityValue: encodedVideo),
               video.frameCount > 0,
               video.width > 0,
               video.height > 0,
               let encodedAcknowledgement = acknowledgementElement.value as? String,
               let acknowledgement = PhysicalScreenAcknowledgementSnapshot(
                    accessibilityValue: encodedAcknowledgement
               ),
               acknowledgement.command == .show,
               acknowledgement.state == .active {
                return ScreenEvidence(
                    acknowledgement: acknowledgement,
                    video: video,
                    videoFrame: videoElement.frame
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func currentScreenEvidence(
        expectedAcknowledgement: PhysicalScreenAcknowledgementSnapshot,
        expectedRendererID: UUID,
        expectedVideoFrame: CGRect,
        expectedVideoWidth: Int,
        expectedVideoHeight: Int
    ) throws -> ScreenEvidence {
        let videoElement = element("worldwideMacScreenVideo")
        let acknowledgementElement = element("worldwideScreenAcknowledgementOracle")
        XCTAssertTrue(videoElement.exists)
        XCTAssertTrue(acknowledgementElement.exists)
        XCTAssertEqual(acknowledgementElement.label, "Screen live")
        XCTAssertEqual(videoElement.frame, expectedVideoFrame)

        let acknowledgement = try XCTUnwrap(
            (acknowledgementElement.value as? String).flatMap(
                PhysicalScreenAcknowledgementSnapshot.init(accessibilityValue:)
            )
        )
        XCTAssertEqual(acknowledgement, expectedAcknowledgement)
        let video = try XCTUnwrap(
            (videoElement.value as? String).flatMap(
                PhysicalVideoRenderSnapshot.init(accessibilityValue:)
            )
        )
        XCTAssertEqual(video.rendererID, expectedRendererID)
        XCTAssertEqual(video.width, expectedVideoWidth)
        XCTAssertEqual(video.height, expectedVideoHeight)
        return ScreenEvidence(
            acknowledgement: acknowledgement,
            video: video,
            videoFrame: videoElement.frame
        )
    }

    private func captureVideoFrame(_ videoFrame: CGRect) -> PhysicalScreenSequenceFrame? {
        PhysicalScreenSequenceScreenshotSampler.sample(
            screenshot: XCUIScreen.main.screenshot().image,
            regionInPoints: videoFrame
        )
    }

    private func assertNoConnectionError(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in connectionErrorIdentifiers {
            XCTAssertFalse(element(identifier).exists, file: file, line: line)
        }
        XCTAssertFalse(
            app.staticTexts[
                "The Mac disconnected. Reconnect to the saved paired Mac when it is available."
            ].exists,
            file: file,
            line: line
        )
    }

    private var hasConnectionError: Bool {
        connectionErrorIdentifiers.contains { element($0).exists }
            || app.staticTexts[
                "The Mac disconnected. Reconnect to the saved paired Mac when it is available."
            ].exists
    }

    private var connectionErrorIdentifiers: [String] {
        [
            "worldwidePreparationError",
            "worldwideMediaError",
            "worldwideSavedPairUnavailable",
            "worldwidePairingStorageError",
        ]
    }

    private var screenObservation: String {
        let video = element("worldwideMacScreenVideo")
        let acknowledgement = element("worldwideScreenAcknowledgementOracle")
        return "appState=\(app.state.rawValue), presentation=\(element("worldwidePresentationState").value as? String ?? "missing"), session=\(element("worldwideSessionState").value as? String ?? "missing"), video=\(video.value as? String ?? "missing"), acknowledgement=\(acknowledgement.value as? String ?? "missing"), error=\(hasConnectionError)"
    }

    private func elapsed(_ startedAt: TimeInterval) -> String {
        String(format: "%.2f", ProcessInfo.processInfo.systemUptime - startedAt)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

}
