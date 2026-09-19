import Foundation
import XCTest
@testable import MediaBridgeCore

final class MediaAutomationOnboardingTests: XCTestCase {
    func testOnlyExactExplicitFlagsCanRequestConsent() throws {
        XCTAssertEqual(MediaAutomationOnboarding.requestType(argument: "--authorize-chrome"), "authorizeChrome")
        XCTAssertEqual(MediaAutomationOnboarding.requestType(argument: "--authorize-music"), "authorizeMusic")
        for argument in ["--authorize", "--authorize-chrome extra", "chrome://extensions", "", "--play"] {
            XCTAssertNil(MediaAutomationOnboarding.requestType(argument: argument))
        }
        let id = UUID().uuidString
        let data = try MediaAutomationOnboarding.request(type: "authorizeChrome", id: id)
        guard case .authorizeChrome(let request) = try MediaBridgeProtocol.decode(data) else { return XCTFail() }
        XCTAssertEqual(request.id, id)
        XCTAssertThrowsError(try MediaAutomationOnboarding.request(type: "command", id: id))
        XCTAssertThrowsError(try MediaAutomationOnboarding.request(type: "authorizeChrome", id: "bad"))
    }

    func testPermissionResponseMustMatchExactRequestAndShape() throws {
        let id = UUID().uuidString
        let value: [String: Any] = ["v": 1, "type": "permissionResult", "id": id, "result": "authorized"]
        XCTAssertEqual(try MediaAutomationOnboarding.result(JSONSerialization.data(withJSONObject: value), expectedID: id), "authorized")
        for mutation: [String: Any] in [["v": true], ["v": 1.5], ["id": UUID().uuidString],
                                      ["result": "success"], ["command": "play"], ["type": "result"]] {
            var invalid = value
            invalid.merge(mutation) { _, new in new }
            XCTAssertThrowsError(try MediaAutomationOnboarding.result(JSONSerialization.data(withJSONObject: invalid), expectedID: id))
        }
        XCTAssertThrowsError(try MediaAutomationOnboarding.result(Data(repeating: 32, count: 4097), expectedID: id))
    }
}
