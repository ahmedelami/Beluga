import Foundation
import CoreFoundation

public enum MediaBridgeProtocol {
    public static let maximumBytes = 4096
    public static let origin = "chrome-extension://dhmdpbpcldmnkjfibepklolofapiceab/"
    public static let maximumRevision: UInt64 = 9_007_199_254_740_991

    public static func isUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }

    public static func boundedText(_ value: String, bytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= bytes
            && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= maximumBytes else { throw MediaBridgeError.invalidMessage }
        return data
    }

    public static func decode(_ data: Data) throws -> MediaBridgeInbound {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.intValue == 1,
              version.doubleValue == 1,
              let type = object["type"] as? String else { throw MediaBridgeError.invalidMessage }
        let decoder = JSONDecoder()
        switch type {
        case "state":
            guard Set(object.keys) == Set(["v", "type", "revision", "item"]) else {
                throw MediaBridgeError.invalidMessage
            }
            if let item = object["item"] as? [String: Any] {
                let required: Set<String> = ["contextID", "sourceName", "title", "playbackRate",
                    "playbackState", "canPlay", "canPause", "canSkipForward", "canSkipBackward"]
                guard required.isSubset(of: Set(item.keys)),
                      Set(item.keys).isSubset(of: required.union(["artist", "duration", "elapsedTime"])) else {
                    throw MediaBridgeError.invalidMessage
                }
            } else if !(object["item"] is NSNull) { throw MediaBridgeError.invalidMessage }
            let value = try decoder.decode(BrowserMediaState.self, from: data)
            guard value.revision > 0, value.revision <= maximumRevision,
                  value.item?.isValid != false else { throw MediaBridgeError.invalidMessage }
            return .state(value)
        case "result":
            guard Set(object.keys) == Set(["v", "type", "id", "contextID", "result"]) else {
                throw MediaBridgeError.invalidMessage
            }
            let value = try decoder.decode(BrowserMediaResult.self, from: data)
            guard isUUID(value.id), isUUID(value.contextID) else { throw MediaBridgeError.invalidMessage }
            return .result(value)
        case "authorizeMusic", "authorizeChrome":
            guard Set(object.keys) == Set(["v", "type", "id"]) else { throw MediaBridgeError.invalidMessage }
            let value = try decoder.decode(MediaAuthorizationRequest.self, from: data)
            guard isUUID(value.id) else { throw MediaBridgeError.invalidMessage }
            return type == "authorizeChrome" ? .authorizeChrome(value) : .authorizeMusic(value)
        default: throw MediaBridgeError.invalidMessage
        }
    }
}

public enum MediaBridgeError: Error { case invalidMessage, invalidPath, unavailable, timedOut, closed }

public struct BrowserMediaItem: Codable, Sendable, Equatable {
    public let contextID: String
    public let sourceName: String
    public let title: String
    public let artist: String?
    public let duration: Double?
    public let elapsedTime: Double?
    public let playbackRate: Double
    public let playbackState: String
    public let canPlay: Bool
    public let canPause: Bool
    public let canSkipForward: Bool
    public let canSkipBackward: Bool

    public var isValid: Bool {
        MediaBridgeProtocol.isUUID(contextID) && sourceName == "YouTube"
            && MediaBridgeProtocol.boundedText(title, bytes: 512)
            && artist.map { MediaBridgeProtocol.boundedText($0, bytes: 256) } != false
            && duration.map { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 } != false
            && elapsedTime.map { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 } != false
            && playbackRate.isFinite && (0...16).contains(playbackRate)
            && ["playing", "paused"].contains(playbackState)
            && (playbackState != "playing" || playbackRate > 0)
    }
}

public struct BrowserMediaState: Codable, Sendable {
    public let v: Int
    public let type: String
    public let revision: UInt64
    public let item: BrowserMediaItem?
}

public enum BrowserMediaCommandResult: String, Codable, Sendable {
    case applied, staleContext, unsupported, noActiveMedia, failed
}

public struct BrowserMediaResult: Codable, Sendable {
    public let v: Int
    public let type: String
    public let id: String
    public let contextID: String
    public let result: BrowserMediaCommandResult
}

public struct BrowserMediaCommand: Encodable, Sendable {
    public let v = 1
    public let type = "command"
    public let id: String
    public let contextID: String
    public let command: String
    public let issuedAtMilliseconds: Int64

    public init(id: String, contextID: String, command: String, now: Date = Date()) {
        self.id = id
        self.contextID = contextID
        self.command = command
        issuedAtMilliseconds = Int64(now.timeIntervalSince1970 * 1000)
    }
}

public struct MediaAuthorizationRequest: Decodable, Sendable {
    public let v: Int
    public let type: String
    public let id: String
}

public struct MediaAuthorizationResult: Encodable, Sendable {
    public let v = 1
    public let type = "permissionResult"
    public let id: String
    public let result: String
    public init(id: String, result: String) { self.id = id; self.result = result }
}

public enum MediaBridgeInbound: Sendable {
    case state(BrowserMediaState)
    case result(BrowserMediaResult)
    case authorizeMusic(MediaAuthorizationRequest)
    case authorizeChrome(MediaAuthorizationRequest)
}
