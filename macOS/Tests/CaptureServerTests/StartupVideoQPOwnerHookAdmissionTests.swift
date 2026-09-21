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
