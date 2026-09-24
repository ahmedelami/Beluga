import UIKit
import XCTest

/// Development-only physical oracle for the dedicated iPhone 15.
///
/// Unlike the production TestFlight oracle, this test may launch and drive only the side-by-side
/// `.dev` app. A guarded shell runner preflights the exact device, app, host, routes, and fresh
/// secondary invitation before XCTest starts. The test confirms the restricted viewer's published
/// audio/microphone UI state and measures the actual final iPhone pixels against a fresh nonce.
@MainActor
final class IPhone15SecondaryViewerDevelopmentPhysicalUITests: XCTestCase {
  nonisolated private static let developmentBundleIdentifier =
    "org.example.AudioStreamer.dev"
  nonisolated private static let developmentCoreDeviceIdentifier =
    "10B6E5EE-D3B9-5334-99C1-EA12EFA34447"
  nonisolated private static let developmentHardwareUDID =
    "00008120-0000242E3E32201E"
  private static let launchArgument =
    "--opensteamer-iphone15-dev-secondary-viewer"
  private static let cleanupReceiptArgument =
    "--opensteamer-iphone15-dev-cleanup-receipt"

  private let app = XCUIApplication(
    bundleIdentifier: developmentBundleIdentifier
  )
  private let observationDuration: TimeInterval = 13
  private let sampleInterval: TimeInterval = 0.30
  private let maximumConsecutiveUndecodableSamples = 3
  private let maximumSameSymbolHoldDuration: TimeInterval = 4.25

  override func setUp() {
    super.setUp()
    continueAfterFailure = false

    // XCTest's assertion parameters are nonisolated autoclosures. Snapshot the main-actor
    // values first so Swift 6 does not carry actor-isolated references into those autoclosures.
    let expectedBundleIdentifier = Self.developmentBundleIdentifier
    let expectedCoreDeviceIdentifier = Self.developmentCoreDeviceIdentifier
    let expectedHardwareUDID = Self.developmentHardwareUDID
    let nonce = validatedNonce

    XCTAssertEqual(
      ProcessInfo.processInfo.environment[
        "OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER"
      ],
      expectedBundleIdentifier
    )
    XCTAssertEqual(
      ProcessInfo.processInfo.environment[
        "OPENSTEAMER_DEV_COREDEVICE_ID"
      ],
      expectedCoreDeviceIdentifier
    )
    XCTAssertEqual(
      ProcessInfo.processInfo.environment[
        "OPENSTEAMER_DEV_HARDWARE_UDID"
      ],
      expectedHardwareUDID
    )
    XCTAssertEqual(
      ProcessInfo.processInfo.environment[
        "OPENSTEAMER_DEV_SECONDARY_INVITATION_PRESEEDED"
      ],
      "1",
      "The guarded runner must seed a fresh invitation without exposing it to XCTest."
    )
    XCTAssertNotNil(nonce)
  }

  func testTemporaryViewerFinalPixelsTrackFreshMacChallenge() throws {
    let nonce = try XCTUnwrap(validatedNonce)

    app.terminate()
    app.launchArguments = [
      Self.launchArgument,
      Self.cleanupReceiptArgument,
      nonce,
    ]
    app.launch()
    addTeardownBlock { [app] in
      app.terminate()
    }

    XCTAssertTrue(
      element("developmentSecondaryInvitationLoaded")
        .waitForExistence(timeout: 10),
      "The Debug app did not consume the runner-seeded invitation file."
    )
    let connect = app.buttons["connectTemporaryWorldwideViewer"]
    XCTAssertTrue(
      connect.waitForExistence(timeout: 10),
      "The iPhone 15 Debug app exposed no temporary-viewer action."
    )
    XCTAssertTrue(
      waitUntil(timeout: 5) { connect.isEnabled },
      "The temporary-viewer action never became enabled."
    )
    connect.tap()

    XCTAssertTrue(
      waitUntil(timeout: 65) {
        self.element("worldwidePresentationState").value as? String
          == "active"
          && self.element("worldwideSessionState").value as? String
            == "Connected"
      },
      "The temporary viewer did not reach a connected active session. Last state: \(connectionObservation)"
    )
    XCTAssertEqual(
      element("worldwideAudioState").value as? String,
      "Inactive",
      "The video/control-only development viewer did not publish inactive audio state."
    )
    XCTAssertFalse(
      element("toggleWorldwideIPhoneMicrophone").isEnabled,
      "The video/control-only development viewer exposed a microphone affordance."
    )

    let playerTab = app.tabBars.buttons["Player"]
    XCTAssertTrue(playerTab.waitForExistence(timeout: 5))
    playerTab.tap()

    let viewScreen = app.buttons["viewWorldwideMacScreen"]
    XCTAssertTrue(viewScreen.waitForExistence(timeout: 10))
    XCTAssertTrue(
      waitUntil(timeout: 20) { viewScreen.isEnabled },
      "The connected temporary viewer never became eligible to present the Mac screen."
    )
    viewScreen.tap()

    let initial = try XCTUnwrap(
      waitForAcknowledgedScreen(timeout: 25),
      "The iPhone 15 never displayed a live acknowledged Mac screen. Last state: \(screenObservation)"
    )
    let videoContentFrame = try XCTUnwrap(
      PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
        container: initial.videoFrame,
        sourceWidth: initial.video.width,
        sourceHeight: initial.video.height
      )
    )
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
    let startedAt = ProcessInfo.processInfo.systemUptime
    var decodedSamples = 0
    var maximumUndecodableRun = 0
    var consecutiveUndecodableSamples = 0
    var observedIndices: [Int] = []
    var lastVideo = initial.video

    while ProcessInfo.processInfo.systemUptime - startedAt
      < observationDuration
    {
      XCTAssertEqual(app.state, .runningForeground)
      assertNoConnectionError()
      let current = try currentScreenEvidence(
        expectedAcknowledgement: initial.acknowledgement,
        expectedRendererID: initial.video.rendererID,
        expectedVideoFrame: initial.videoFrame,
        expectedVideoWidth: initial.video.width,
        expectedVideoHeight: initial.video.height
      )
      lastVideo = current.video

      if let frame = captureVideoFrame(videoContentFrame),
        let symbol = frame.decode(nonce: nonce)
      {
        let observedAt = ProcessInfo.processInfo.systemUptime
        consecutiveUndecodableSamples = 0
        decodedSamples += 1
        _ = tracker.observe(symbol)
        XCTAssertNotEqual(
          continuityTracker.observe(symbol, at: observedAt),
          .rejected,
          "The iPhone 15 final pixels froze or left the ordered challenge."
        )
        if observedIndices.last != symbol.index {
          observedIndices.append(symbol.index)
        }
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
          "The iPhone 15 final display stayed black, stale, obscured, or unrelated."
        )
      }
      RunLoop.current.run(
        until: Date().addingTimeInterval(sampleInterval)
      )
    }

    // Require the observation to end on an actual nonce-bound final-composite frame. A short
    // retry tolerates one codec transition, while the existing bounded-gap tracker still rejects
    // a black, obscured, stale, or unrelated tail.
    let terminalDeadline = Date().addingTimeInterval(
      sampleInterval * Double(maximumConsecutiveUndecodableSamples + 1)
    )
    var terminalSymbol: PhysicalScreenSequenceSymbol?
    while Date() < terminalDeadline, terminalSymbol == nil {
      XCTAssertEqual(app.state, .runningForeground)
      assertNoConnectionError()
      let current = try currentScreenEvidence(
        expectedAcknowledgement: initial.acknowledgement,
        expectedRendererID: initial.video.rendererID,
        expectedVideoFrame: initial.videoFrame,
        expectedVideoWidth: initial.video.width,
        expectedVideoHeight: initial.video.height
      )
      lastVideo = current.video

      if let frame = captureVideoFrame(videoContentFrame),
        let symbol = frame.decode(nonce: nonce)
      {
        let observedAt = ProcessInfo.processInfo.systemUptime
        terminalSymbol = symbol
        consecutiveUndecodableSamples = 0
        decodedSamples += 1
        _ = tracker.observe(symbol)
        XCTAssertNotEqual(
          continuityTracker.observe(symbol, at: observedAt),
          .rejected,
          "The iPhone 15 final pixels ended frozen or out of sequence."
        )
        if observedIndices.last != symbol.index {
          observedIndices.append(symbol.index)
        }
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
          "The iPhone 15 final display remained black, stale, obscured, or unrelated."
        )
        RunLoop.current.run(
          until: Date().addingTimeInterval(sampleInterval)
        )
      }
    }

    XCTAssertEqual(tracker.state, .satisfied)
    XCTAssertEqual(continuityTracker.state, .satisfied)
    XCTAssertNotNil(
      terminalSymbol,
      "The iPhone 15 observation did not end on a fresh nonce-bound final frame."
    )
    XCTAssertGreaterThanOrEqual(decodedSamples, 12)
    XCTAssertGreaterThanOrEqual(observedIndices.count, 5)
    XCTAssertGreaterThan(lastVideo.frameCount, initial.video.frameCount)
    XCTAssertGreaterThan(
      lastVideo.timestampNanoseconds,
      initial.video.timestampNanoseconds
    )

    let maximumSameSymbolHoldText = String(
      format: "%.2f",
      continuityTracker.maximumObservedSameSymbolHoldDuration
    )
    let marker =
      "OPENSTEAMER_IPHONE15_DEV_SCREEN_VISUAL_ORACLE_V1"
      + " nonce=\(nonce)"
      + " session=\(initial.acknowledgement.sessionGeneration.uuidString.lowercased())"
      + " renderer=\(initial.video.rendererID.uuidString.lowercased())"
      + " decodedSamples=\(decodedSamples)"
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

  nonisolated private var validatedNonce: String? {
    guard
      let nonce = ProcessInfo.processInfo.environment[
        "OPENSTEAMER_SCREEN_ORACLE_NONCE"
      ],
      nonce.range(
        of: #"^[0-9a-f]{32}$"#,
        options: .regularExpression
      ) != nil
    else { return nil }
    return nonce
  }

  private func waitForAcknowledgedScreen(
    timeout: TimeInterval
  ) -> ScreenEvidence? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard app.state == .runningForeground,
        !hasConnectionError
      else { return nil }
      let videoElement = element("worldwideMacScreenVideo")
      let acknowledgementElement = element(
        "worldwideScreenAcknowledgementOracle"
      )
      if videoElement.exists,
        videoElement.frame.width > 1,
        videoElement.frame.height > 1,
        acknowledgementElement.exists,
        acknowledgementElement.label == "Screen live",
        let encodedVideo = videoElement.value as? String,
        let video = PhysicalVideoRenderSnapshot(
          accessibilityValue: encodedVideo
        ),
        video.frameCount > 0,
        video.width > 0,
        video.height > 0,
        let encodedAcknowledgement =
          acknowledgementElement.value as? String,
        let acknowledgement = PhysicalScreenAcknowledgementSnapshot(
          accessibilityValue: encodedAcknowledgement
        ),
        acknowledgement.command == .show,
        acknowledgement.state == .active
      {
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
    let acknowledgementElement = element(
      "worldwideScreenAcknowledgementOracle"
    )
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

  private func captureVideoFrame(
    _ videoFrame: CGRect
  ) -> PhysicalScreenSequenceFrame? {
    PhysicalScreenSequenceScreenshotSampler.sample(
      screenshot: XCUIScreen.main.screenshot().image,
      regionInPoints: videoFrame
    )
  }

  private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
  }

  private func assertNoConnectionError(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for identifier in connectionErrorIdentifiers {
      XCTAssertFalse(element(identifier).exists, file: file, line: line)
    }
  }

  private var hasConnectionError: Bool {
    connectionErrorIdentifiers.contains { element($0).exists }
  }

  private var connectionErrorIdentifiers: [String] {
    [
      "worldwidePreparationError",
      "worldwideMediaError",
      "worldwideSavedPairUnavailable",
      "worldwidePairingStorageError",
    ]
  }

  private var connectionObservation: String {
    "appState=\(app.state.rawValue), presentation=\(element("worldwidePresentationState").value as? String ?? "missing"), session=\(element("worldwideSessionState").value as? String ?? "missing"), error=\(hasConnectionError)"
  }

  private var screenObservation: String {
    let video = element("worldwideMacScreenVideo")
    let acknowledgement = element("worldwideScreenAcknowledgementOracle")
    return
      "appState=\(app.state.rawValue), video=\(video.value as? String ?? "missing"), acknowledgement=\(acknowledgement.value as? String ?? "missing"), error=\(hasConnectionError)"
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
  }
}
