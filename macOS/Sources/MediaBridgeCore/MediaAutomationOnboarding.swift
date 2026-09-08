import Foundation
import CoreFoundation

/// A local helper requests consent from the running signed host; it never sends
/// Apple Events itself or launches another CaptureServer.
public enum MediaAutomationOnboarding {
    public static func requestType(argument: String) -> String? {
        switch argument {
        case "--authorize-chrome": return "authorizeChrome"
        case "--authorize-music": return "authorizeMusic"
        default: return nil
        }
    }

    public static func request(type: String, id: String) throws -> Data {
        guard ["authorizeChrome", "authorizeMusic"].contains(type), MediaBridgeProtocol.isUUID(id) else {
            throw MediaBridgeError.invalidMessage
        }
        let data = try JSONSerialization.data(withJSONObject: ["v": 1, "type": type, "id": id])
        _ = try MediaBridgeProtocol.decode(data)
        return data
    }

    public static func result(_ data: Data, expectedID: String) throws -> String {
        guard data.count <= MediaBridgeProtocol.maximumBytes,
              MediaBridgeProtocol.isUUID(expectedID),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == Set(["v", "type", "id", "result"]),
              let version = value["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              value["type"] as? String == "permissionResult", value["id"] as? String == expectedID,
              let result = value["result"] as? String,
              ["authorized", "denied", "unavailable"].contains(result) else {
            throw MediaBridgeError.invalidMessage
        }
        return result
    }
}
