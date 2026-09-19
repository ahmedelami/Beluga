import Foundation

/// Unforgeable binding for one exact offer/answer generation. This remains transport-internal:
/// application code supplies semantic state and commands while `WebRTCPeer` stamps and validates
/// the authorization at the wire boundary.
struct WebRTCRemoteMediaAuthorization: Codable, Equatable, Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Absolute commands for the Mac's current system Now Playing session.
public enum WebRTCRemoteMediaCommand: String, Codable, CaseIterable, Sendable {
    case play
    case pause
    case nextTrack
    case previousTrack
}

public enum WebRTCRemoteMediaPlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

/// Explicit command support keeps iOS from presenting controls the active Mac player cannot use.
public struct WebRTCRemoteMediaCapabilities: Codable, Equatable, Sendable {
    public let canPlay: Bool
    public let canPause: Bool
    public let canSkipForward: Bool
    public let canSkipBackward: Bool

    public init(
        canPlay: Bool,
        canPause: Bool,
        canSkipForward: Bool,
        canSkipBackward: Bool
    ) {
        self.canPlay = canPlay
        self.canPause = canPause
        self.canSkipForward = canSkipForward
        self.canSkipBackward = canSkipBackward
    }

    public func permits(_ command: WebRTCRemoteMediaCommand) -> Bool {
        switch command {
        case .play: canPlay
        case .pause: canPause
        case .nextTrack: canSkipForward
        case .previousTrack: canSkipBackward
        }
    }
}

/// A bounded provider identifier, never a peer-supplied URL or image payload.
public struct WebRTCRemoteMediaArtworkReference: Codable, Equatable, Hashable, Sendable {
    public enum Provider: String, Codable, Hashable, Sendable {
        case youtube
    }

    public let provider: Provider
    public let videoID: String

    public init?(provider: Provider = .youtube, videoID: String) {
        guard videoID.utf8.count == 11,
              videoID.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }
        self.provider = provider
        self.videoID = videoID
    }

    public var url: URL {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")!
    }

    private enum CodingKeys: String, CodingKey {
        case provider, videoID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try values.decode(Provider.self, forKey: .provider)
        let videoID = try values.decode(String.self, forKey: .videoID)
        guard let reference = Self(provider: provider, videoID: videoID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .videoID, in: values, debugDescription: "Invalid artwork identifier"
            )
        }
        self = reference
    }
}

/// Bounded metadata for one Mac system Now Playing owner. Only a small artwork reference may
/// accompany it; image bytes never enter the 4 KiB ordered control channel.
public struct WebRTCRemoteMediaItem: Codable, Equatable, Sendable {
    public static let maximumContextIDBytes = 128
    public static let maximumSourceNameBytes = 128
    public static let maximumTitleBytes = 512
    public static let maximumArtistBytes = 256
    public static let maximumAlbumBytes = 256

    public let contextID: String
    public let sourceName: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let playbackState: WebRTCRemoteMediaPlaybackState
    public let elapsedTime: TimeInterval?
    public let duration: TimeInterval?
    public let playbackRate: Double
    public let capabilities: WebRTCRemoteMediaCapabilities
    public let artwork: WebRTCRemoteMediaArtworkReference?

    public init(
        contextID: String,
        sourceName: String,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        playbackState: WebRTCRemoteMediaPlaybackState,
        elapsedTime: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        playbackRate: Double,
        capabilities: WebRTCRemoteMediaCapabilities,
        artwork: WebRTCRemoteMediaArtworkReference? = nil
    ) {
        self.contextID = contextID
        self.sourceName = sourceName
        self.title = title
        self.artist = artist
        self.album = album
        self.playbackState = playbackState
        self.elapsedTime = elapsedTime
        self.duration = duration
        self.playbackRate = playbackRate
        self.capabilities = capabilities
        self.artwork = artwork
    }

    private enum CodingKeys: String, CodingKey {
        case contextID, sourceName, title, artist, album, playbackState
        case elapsedTime, duration, playbackRate, capabilities, artwork
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        contextID = try values.decode(String.self, forKey: .contextID)
        sourceName = try values.decode(String.self, forKey: .sourceName)
        title = try values.decode(String.self, forKey: .title)
        artist = try values.decodeIfPresent(String.self, forKey: .artist)
        album = try values.decodeIfPresent(String.self, forKey: .album)
        playbackState = try values.decode(WebRTCRemoteMediaPlaybackState.self, forKey: .playbackState)
        elapsedTime = try values.decodeIfPresent(TimeInterval.self, forKey: .elapsedTime)
        duration = try values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        playbackRate = try values.decode(Double.self, forKey: .playbackRate)
        capabilities = try values.decode(WebRTCRemoteMediaCapabilities.self, forKey: .capabilities)
        // Optional decoration must not revoke otherwise valid playback controls.
        artwork = try? values.decodeIfPresent(WebRTCRemoteMediaArtworkReference.self, forKey: .artwork)
    }

    public var isValid: Bool {
        Self.validRequired(contextID, maximumBytes: Self.maximumContextIDBytes)
            && Self.validRequired(sourceName, maximumBytes: Self.maximumSourceNameBytes)
            && Self.validRequired(title, maximumBytes: Self.maximumTitleBytes)
            && Self.validOptional(artist, maximumBytes: Self.maximumArtistBytes)
            && Self.validOptional(album, maximumBytes: Self.maximumAlbumBytes)
            && Self.validTime(elapsedTime)
            && Self.validTime(duration)
            && playbackRate.isFinite
            && playbackRate >= 0
            && playbackRate <= 16
    }

    private static func validRequired(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validOptional(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return validRequired(value, maximumBytes: maximumBytes)
    }

    private static func validTime(_ value: TimeInterval?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 31_536_000
    }
}

/// A nil item explicitly clears a prior Now Playing owner. Revisions are monotonic within one
/// negotiated WebRTC peer generation.
public struct WebRTCRemoteMediaStateUpdate: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let item: WebRTCRemoteMediaItem?

    public init(revision: UInt64, item: WebRTCRemoteMediaItem?) {
        self.revision = revision
        self.item = item
    }

    public var isValid: Bool {
        revision > 0 && (item?.isValid ?? true)
    }
}

/// An immutable state received under one exact transport negotiation. Application code may retain
/// it for native controls, but cannot manufacture or replace its transport authority.
public struct WebRTCReceivedRemoteMediaState: Equatable, Sendable {
    public let update: WebRTCRemoteMediaStateUpdate
    public let refreshID: UUID?
    let authorization: WebRTCRemoteMediaAuthorization

    init(envelope: WebRTCRemoteMediaStateEnvelope) {
        update = envelope.update
        refreshID = envelope.refreshID
        authorization = envelope.authorization
    }

    public func isSameNegotiation(as other: Self) -> Bool {
        authorization == other.authorization
    }
}

/// A viewer-ready snapshot request stamped by the receiving transport, never by application code.
public struct WebRTCReceivedRemoteMediaStateRefreshRequest: Equatable, Sendable {
    public let id: UUID
    let authorization: WebRTCRemoteMediaAuthorization

    init(envelope: WebRTCRemoteMediaStateRefreshEnvelope) {
        id = envelope.id
        authorization = envelope.authorization
    }
}

public struct WebRTCRemoteMediaCommandRequest: Codable, Equatable, Sendable {
    public let id: UInt64
    public let contextID: String
    public let observedRevision: UInt64
    public let command: WebRTCRemoteMediaCommand

    public init(
        id: UInt64,
        contextID: String,
        observedRevision: UInt64,
        command: WebRTCRemoteMediaCommand
    ) {
        self.id = id
        self.contextID = contextID
        self.observedRevision = observedRevision
        self.command = command
    }

    public var isValid: Bool {
        id > 0
            && observedRevision > 0
            && !contextID.isEmpty
            && contextID.utf8.count <= WebRTCRemoteMediaItem.maximumContextIDBytes
            && !contextID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// The application must return this exact received command when completing asynchronous work.
/// A numeric request ID alone is not unique after a same-peer renegotiation.
public struct WebRTCReceivedRemoteMediaCommand: Equatable, Sendable {
    public let request: WebRTCRemoteMediaCommandRequest
    let authorization: WebRTCRemoteMediaAuthorization
    let executionAuthorization: WebRTCControlAuthorization

    public var isValid: Bool { executionAuthorization.isValid }

    init(
        envelope: WebRTCRemoteMediaCommandEnvelope,
        executionAuthorization: WebRTCControlAuthorization
    ) {
        request = envelope.request
        authorization = envelope.authorization
        self.executionAuthorization = executionAuthorization
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.request == rhs.request && lhs.authorization == rhs.authorization
            && lhs.executionAuthorization === rhs.executionAuthorization
    }
}

public enum WebRTCRemoteMediaCommandResult: String, Codable, Sendable {
    case applied
    case unsupported
    case staleContext
    case noActiveMedia
    case failed
}

public struct WebRTCRemoteMediaCommandAcknowledgement: Codable, Equatable, Sendable {
    public let id: UInt64
    public let result: WebRTCRemoteMediaCommandResult

    public init(id: UInt64, result: WebRTCRemoteMediaCommandResult) {
        self.id = id
        self.result = result
    }

    public var isValid: Bool { id > 0 }
}

/// Wire-only envelopes make the negotiation authorization mandatory without asking the host media
/// controller or iOS UI to obtain, retain, or manufacture transport authority.
struct WebRTCRemoteMediaStateEnvelope: Codable, Equatable, Sendable {
    let authorization: WebRTCRemoteMediaAuthorization
    let update: WebRTCRemoteMediaStateUpdate
    let refreshID: UUID?

    init(
        authorization: WebRTCRemoteMediaAuthorization,
        update: WebRTCRemoteMediaStateUpdate,
        refreshID: UUID? = nil
    ) {
        self.authorization = authorization
        self.update = update
        self.refreshID = refreshID
    }

    var isValid: Bool { update.isValid }
}

struct WebRTCRemoteMediaStateRefreshEnvelope: Codable, Equatable, Sendable {
    let authorization: WebRTCRemoteMediaAuthorization
    let id: UUID
}

struct WebRTCRemoteMediaCommandEnvelope: Codable, Equatable, Sendable {
    let authorization: WebRTCRemoteMediaAuthorization
    let request: WebRTCRemoteMediaCommandRequest

    var isValid: Bool { request.isValid }
}

struct WebRTCRemoteMediaCommandAcknowledgementEnvelope:
    Codable,
    Equatable,
    Sendable
{
    let authorization: WebRTCRemoteMediaAuthorization
    let acknowledgement: WebRTCRemoteMediaCommandAcknowledgement

    var isValid: Bool { acknowledgement.isValid }
}

/// Pure admission rule for relative media commands. A normal elapsed-time refresh may advance the
/// state revision while retaining the same media context, so an older observed revision is safe;
/// a future revision, changed context, or changed capability is not.
public enum WebRTCRemoteMediaCommandAdmission {
    public static func rejection(
        for request: WebRTCRemoteMediaCommandRequest,
        latestSuccessfullySent update: WebRTCRemoteMediaStateUpdate?
    ) -> WebRTCRemoteMediaCommandResult? {
        guard request.isValid else { return .failed }
        guard let update, update.isValid else { return .noActiveMedia }
        guard request.observedRevision <= update.revision else {
            return .staleContext
        }
        guard let item = update.item else { return .noActiveMedia }
        guard request.contextID == item.contextID else {
            return .staleContext
        }
        guard item.capabilities.permits(request.command) else {
            return .unsupported
        }
        return nil
    }
}
