#if DEBUG && os(macOS)
import Foundation
@testable import WebRTCTransport
import XCTest

final class StartupVideoPacerBridgeTests: XCTestCase {
    func testProbeDurationRequiresExactDurationAndAllFlagsBeforeLoading() {
        for milliseconds in [-1, 0, 14, 15, 16, 39, 40, 41, Int.max] {
            for observe in [false, true] {
                for hold in [false, true] {
                    for skip in [false, true] {
                        let valid = [15, 40].contains(milliseconds) && observe && hold && skip
                        XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
                            "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1"
                        ], observeEstimator: observe, holdDelayGrowthInALR: hold,
                            skipProbesBelowCurrentEstimate: skip,
                            probeDurationMilliseconds: milliseconds)) { error in
                            XCTAssertEqual(error as? WebRTCTransportError, .nativeFailure(valid
                                ? "Missing pinned pacing experiment artifact"
                                : "Probe duration requires a 15/40 ms held probe-cap observer"))
                        }
                    }
                }
            }
        }
    }

    func testProbeDurationCannotBypassArtifactDigestValidation() {
        for milliseconds in [15, 40] {
            XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
                "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1",
                "OPENSTEAMER_PACER_BRIDGE_PATH": #filePath,
                "OPENSTEAMER_PACER_BRIDGE_SHA256": String(repeating: "0", count: 64)
            ], observeEstimator: true, holdDelayGrowthInALR: true,
                skipProbesBelowCurrentEstimate: true, probeDurationMilliseconds: milliseconds)) { error in
                XCTAssertEqual(error as? WebRTCTransportError,
                               .nativeFailure("Pacing experiment artifact identity mismatch"))
            }
        }
    }

    func testALRProbeCapWithoutHeldObserverFailsBeforeLoading() {
        for observeEstimator in [false, true] {
            XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
                "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1"
            ], observeEstimator: observeEstimator, skipProbesBelowCurrentEstimate: true)) { error in
                XCTAssertEqual(error as? WebRTCTransportError,
                               .nativeFailure("ALR probe cap requires held estimator observation"))
            }
        }
    }

    func testALRGrowthHoldWithoutObserverFailsBeforeLoading() {
        XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
            "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1"
        ], holdDelayGrowthInALR: true)) { error in
            XCTAssertEqual(error as? WebRTCTransportError,
                           .nativeFailure("ALR growth hold requires an estimator observer"))
        }
    }

    func testMissingArtifactPinsFailBeforeLoading() {
        XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
            "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1"
        ])) { error in
            XCTAssertEqual(error as? WebRTCTransportError,
                           .nativeFailure("Missing pinned pacing experiment artifact"))
        }
    }

    func testWrongArtifactDigestFailsBeforeLoading() {
        // This source file is intentionally not a loadable library. A loader-first
        // regression produces a different error and cannot satisfy this assertion.
        XCTAssertThrowsError(try StartupVideoPacerBridge(environment: [
            "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1",
            "OPENSTEAMER_PACER_BRIDGE_PATH": #filePath,
            "OPENSTEAMER_PACER_BRIDGE_SHA256": String(repeating: "0", count: 64)
        ])) { error in
            XCTAssertEqual(error as? WebRTCTransportError,
                           .nativeFailure("Pacing experiment artifact identity mismatch"))
        }
    }
}
#endif
