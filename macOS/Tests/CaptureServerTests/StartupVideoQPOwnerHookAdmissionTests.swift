#if os(macOS)
import XCTest
@testable import WebRTCTransport

final class StartupVideoQPOwnerHookAdmissionTests: XCTestCase {
    private var optedIn: [String: String] {
        ["OPENSTEAMER_VT_QP_MODE": "unset", "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT": "1",
         "OPENSTEAMER_RUN_PACER_EXPERIMENT": "1"]
    }
    private func rejects(_ message: String, eligible: Bool = true, environment: [String: String],
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try StartupVideoQPOwnerHook.requested(eligible: eligible, environment: environment),
                             file: file, line: line) { error in
            guard case .nativeFailure(let actual) = error as? WebRTCTransportError else {
                XCTFail("Wrong admission failure: \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(actual, message, file: file, line: line)
        }
    }

    func testDefaultPathDoesNotLoadOrCreateHook() throws {
        XCTAssertNil(try StartupVideoQPOwnerHook.requested(eligible: false, environment: [:]))
        XCTAssertNil(try StartupVideoQPOwnerHook.requested(eligible: true, environment: [:]))
    }
    func testOtherFixturesCannotRequestHook() {
        rejects("QP hook requires the exact video-only encoder-boundary diagnostic", eligible: false, environment: optedIn)
    }
    func testMissingStartupOptInIsRejectedBeforeLoading() {
        var environment = optedIn
        environment.removeValue(forKey: "OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT")
        rejects("QP hook requires the exact video-only encoder-boundary diagnostic", environment: environment)
    }
    func testMissingPacerOptInIsRejectedBeforeLoading() {
        var environment = optedIn
        environment.removeValue(forKey: "OPENSTEAMER_RUN_PACER_EXPERIMENT")
        rejects("QP hook requires the exact video-only encoder-boundary diagnostic", environment: environment)
    }
    func testUnknownArmIsRejectedBeforeLoading() {
        var environment = optedIn
        environment["OPENSTEAMER_VT_QP_MODE"] = "anything"
        rejects("Unknown QP diagnostic arm", environment: environment)
    }
    func testBounded1500ArmsAreExactAndRejectLookalikes() throws {
        let control = try StartupVideoQPHookAdmission.parse("control1500")
        XCTAssertEqual(control.requestedArm, "control1500")
        XCTAssertEqual(control.nativeMode, 0)
        XCTAssertEqual(control.expectedStartupWindowNanoseconds, 1_500_000_000)

        let startup = try StartupVideoQPHookAdmission.parse("startup1500")
        XCTAssertEqual(startup.requestedArm, "startup1500")
        XCTAssertEqual(startup.nativeMode, 2)
        XCTAssertEqual(startup.expectedStartupWindowNanoseconds, 1_500_000_000)

        for value in ["control1000", "startup1000", "control1499", "startup1501",
                      "control1500 ", "startup1500 ", "CONTROL1500", "STARTUP1500"] {
            XCTAssertThrowsError(try StartupVideoQPHookAdmission.parse(value), value)
        }
    }
    func testBounded1500ArmsRequireSameEligibilityAndPreloadedSeal() {
        for arm in ["control1500", "startup1500"] {
            var environment = optedIn
            environment["OPENSTEAMER_VT_QP_MODE"] = arm
            rejects("QP hook requires the exact video-only encoder-boundary diagnostic",
                    eligible: false, environment: environment)
            rejects("QP hook requires one explicit fresh-process artifact", environment: environment)
        }
    }
    func testStartupArmRequiresSameEligibilityAndPreloadedSeal() {
        var environment = optedIn
        environment["OPENSTEAMER_VT_QP_MODE"] = "startup"
        rejects("QP hook requires the exact video-only encoder-boundary diagnostic", eligible: false,
                environment: environment)
        rejects("QP hook requires one explicit fresh-process artifact", environment: environment)
    }
    func testMissingSealedPreloadedArtifactIsRejected() {
        rejects("QP hook requires one explicit fresh-process artifact", environment: optedIn)
        var environment = optedIn
        environment["OPENSTEAMER_VT_QP_HOOK_PATH"] = "/nonexistent/diagnostic.dylib"
        environment["OPENSTEAMER_VT_QP_HOOK_SHA256"] = String(repeating: "0", count: 64)
        environment["DYLD_INSERT_LIBRARIES"] = "/different/image.dylib"
        rejects("QP hook requires one explicit fresh-process artifact", environment: environment)
    }
}
#endif
