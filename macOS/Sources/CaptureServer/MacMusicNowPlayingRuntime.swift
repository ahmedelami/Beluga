@preconcurrency import AppKit
import CoreServices
import WebRTCTransport

struct MacMusicPlayerIdentity: Equatable, Sendable {
    let processID: Int32
    let launchDate: Date
}

enum MacMusicPlaybackState: Equatable, Sendable {
    case playing, paused, stopped
}

struct MacMusicNavigation: Equatable, Sendable {
    let playlistID: String
    let index: Int32
    let count: Int32
    let nextTrackID: String?
    let previousTrackID: String?
}

struct MacMusicPlayerSnapshot: Sendable {
    let owner: MacMusicPlayerIdentity
    let trackID: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let position: Double?
    let state: MacMusicPlaybackState
    let observedAt: Date
    var navigation: MacMusicNavigation? = nil

    var enabledCommands: Set<Int> {
        var commands: Set<Int> = state == .playing ? [1] : [0]
        if navigation?.nextTrackID != nil { commands.insert(4) }
        if navigation?.previousTrackID != nil { commands.insert(5) }
        return commands
    }

    func hasSameItem(as other: Self) -> Bool {
        owner == other.owner && trackID == other.trackID
    }
}

enum MacMusicBackendError: Error, Equatable {
    case permissionRequired, permissionDenied, timedOut, staleItem, invalidData, unavailable
}

enum MacMusicDiscoveryStatus: String, Sendable {
    case idle, available, noPlayer, permissionRequired, permissionDenied, timedOut, staleItem, invalidData, unavailable

    init(error: Error) {
        guard let error = error as? MacMusicBackendError else { self = .unavailable; return }
        switch error {
        case .permissionRequired: self = .permissionRequired
        case .permissionDenied: self = .permissionDenied
        case .timedOut: self = .timedOut
        case .staleItem: self = .staleItem
        case .invalidData: self = .invalidData
        case .unavailable: self = .unavailable
        }
    }
}

enum MacMusicCommand: Int, Sendable {
    case play = 0, pause = 1, next = 4, previous = 5

    var isRelative: Bool { self == .next || self == .previous }

    var eventID: AEEventID {
        switch self {
        case .play: return 0x506C6179 // Play
        case .pause: return 0x50617573 // Paus
        case .next: return 0x4E657874 // Next
        case .previous: return 0x50726576 // Prev
        }
    }
}

protocol MacMusicNowPlayingBackend: Sendable {
    /// Deadlines are monotonic system uptime; ordinary operations must never request consent.
    func readSnapshot(deadline: TimeInterval) throws -> MacMusicPlayerSnapshot?
    func requestAutomationPermission() throws
    func send(
        _ command: MacMusicCommand,
        expected: MacMusicPlayerSnapshot,
        deadline: TimeInterval,
        isAuthorized: @escaping @Sendable () -> Bool
    ) throws -> WebRTCRemoteMediaCommandResult
}

protocol MacMusicAppleEventsClient: Sendable {
    func runningOwner() -> MacMusicPlayerIdentity?
    func requestPermission(owner: MacMusicPlayerIdentity) -> OSStatus
    func sendEvent(
        _ event: NSAppleEventDescriptor,
        options: NSAppleEventDescriptor.SendOptions,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor
}

private struct MacMusicSystemAppleEventsClient: MacMusicAppleEventsClient {
    func runningOwner() -> MacMusicPlayerIdentity? {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            .filter { !$0.isTerminated && $0.bundleURL?.path == "/System/Applications/Music.app" }
        guard matches.count == 1, let app = matches.first, let launchDate = app.launchDate,
              app.processIdentifier > 0 else { return nil }
        return MacMusicPlayerIdentity(processID: app.processIdentifier, launchDate: launchDate)
    }

    func requestPermission(owner: MacMusicPlayerIdentity) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: owner.processID)
        guard let address = target.aeDesc else { return OSStatus(errAEWrongDataType) }
        return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, true)
    }

    func sendEvent(
        _ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
        timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        try event.sendEvent(options: options, timeout: timeout)
    }
}

/// Public, PID-addressed Apple Events only. It never launches Music or invokes a system script host.
final class MacMusicAppleEventsBackend: MacMusicNowPlayingBackend, @unchecked Sendable {
    static let bundleIdentifier = "com.apple.Music"
    static let sendOptions = NSAppleEventDescriptor.SendOptions(rawValue:
        UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent)
    )

    private static let currentTrack: AEKeyword = 0x7054726B // pTrk
    private static let persistentID: AEKeyword = 0x70504953 // pPIS
    private let client: any MacMusicAppleEventsClient

    init(client: any MacMusicAppleEventsClient = MacMusicSystemAppleEventsClient()) {
        self.client = client
    }

    /// Call only from explicit user-initiated onboarding, never from a poll or retry.
    func requestAutomationPermission() throws {
        guard let owner = client.runningOwner() else { throw MacMusicBackendError.unavailable }
        try Self.checkStatus(client.requestPermission(owner: owner))
        guard client.runningOwner() == owner else { throw MacMusicBackendError.staleItem }
    }

    func readSnapshot(deadline: TimeInterval) throws -> MacMusicPlayerSnapshot? {
        guard let owner = client.runningOwner() else { return nil }
        let stateCode = try get(0x70506C53, owner: owner, deadline: deadline).enumCodeValue // pPlS
        let state: MacMusicPlaybackState
        switch stateCode {
        case 0x6B505350: state = .playing // kPSP
        case 0x6B505370: state = .paused // kPSp
        case 0x6B505353: state = .stopped // kPSS
        default: throw MacMusicBackendError.invalidData
        }
        let track = try get(Self.currentTrack, owner: owner, deadline: deadline)
        if track.descriptorType == typeNull { return nil }
        guard track.descriptorType == typeObjectSpecifier else {
            throw MacMusicBackendError.invalidData
        }
        let trackID = try text(get(Self.persistentID, of: track, owner: owner, deadline: deadline))
        let title = try text(get(0x706E616D, of: track, owner: owner, deadline: deadline)) // pnam
        let artist = try text(get(0x70417274, of: track, owner: owner, deadline: deadline)) // pArt
        let album = try text(get(0x70416C62, of: track, owner: owner, deadline: deadline)) // pAlb
        let duration = try number(get(0x70447572, of: track, owner: owner, deadline: deadline)) // pDur
        let position = try number(get(0x70506F73, owner: owner, deadline: deadline)) // pPos
        let observedAt = Date()
        // Optional playlist discovery must not consume the final identity-read
        // budget and make otherwise usable Play/Pause metadata disappear.
        let navigationDeadline = min(deadline - 0.25, ProcessInfo.processInfo.systemUptime + 0.35)
        let navigation = try? readNavigation(owner: owner, trackID: trackID, deadline: navigationDeadline)
        guard client.runningOwner() == owner,
              try currentTrackID(owner: owner, deadline: deadline) == trackID else {
            throw MacMusicBackendError.staleItem
        }
        return MacMusicPlayerSnapshot(
            owner: owner, trackID: trackID, title: title, artist: artist, album: album,
            duration: duration, position: position, state: state, observedAt: observedAt,
            navigation: navigation
        )
    }

    func send(
        _ command: MacMusicCommand,
        expected: MacMusicPlayerSnapshot,
        deadline: TimeInterval,
        isAuthorized: @escaping @Sendable () -> Bool
    ) throws -> WebRTCRemoteMediaCommandResult {
        guard isAuthorized() else { return .staleContext }
        guard let current = try readSnapshot(deadline: deadline) else { return .noActiveMedia }
        guard current.hasSameItem(as: expected), isAuthorized() else { return .staleContext }
        if command == .play && current.state == .playing { return .applied }
        if command == .pause && current.state == .paused { return .applied }
        guard current.enabledCommands.contains(command.rawValue) else { return .unsupported }
        if command.isRelative && current.navigation != expected.navigation { return .staleContext }
        let event = Self.commandEvent(command, owner: current.owner)
        // Music has no atomic expected-track command. This final read narrows, but cannot
        // eliminate, the cross-process item-change race before Apple Events dispatch.
        guard try currentTrackID(owner: current.owner, deadline: deadline) == expected.trackID else {
            return .staleContext
        }
        if command.isRelative {
            guard try readNavigation(owner: current.owner, trackID: expected.trackID, deadline: deadline)
                    == expected.navigation,
                  try currentTrackID(owner: current.owner, deadline: deadline) == expected.trackID else {
                return .staleContext
            }
        }
        _ = try sendEvent(event, owner: current.owner, deadline: deadline, isAuthorized: isAuthorized)
        guard isAuthorized() else { return .staleContext }
        guard let after = try readSnapshot(deadline: deadline) else { return .failed }
        guard after.owner == expected.owner, isAuthorized() else { return .staleContext }
        if command.isRelative {
            let targetID = command == .next
                ? current.navigation?.nextTrackID : current.navigation?.previousTrackID
            return after.trackID == targetID
                && after.navigation?.playlistID == current.navigation?.playlistID ? .applied : .failed
        }
        guard after.trackID == expected.trackID else { return .staleContext }
        return (command == .play && after.state == .playing)
            || (command == .pause && after.state == .paused) ? .applied : .failed
    }

    static func commandEvent(
        _ command: MacMusicCommand, owner: MacMusicPlayerIdentity
    ) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: 0x686F6F6B, eventID: command.eventID, // hook
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: owner.processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func readNavigation(
        owner: MacMusicPlayerIdentity, trackID: String, deadline: TimeInterval
    ) throws -> MacMusicNavigation? {
        let playlist = try get(0x70506C61, owner: owner, deadline: deadline) // pPla
        guard playlist.descriptorType == typeObjectSpecifier else { return nil }
        let playlistID = try text(get(Self.persistentID, of: playlist, owner: owner, deadline: deadline))
        guard MacMusicNowPlayingRuntime.isValidPersistentID(playlistID) else { return nil }
        let shuffle = try get(0x70536845, owner: owner, deadline: deadline) // pShE
        guard shuffle.descriptorType == typeBoolean else { throw MacMusicBackendError.invalidData }
        // Music does not publish shuffle order or playback history through its dictionary.
        guard !shuffle.booleanValue else { return nil }
        let repeatCode = try get(0x70527074, owner: owner, deadline: deadline).enumCodeValue // pRpt
        guard [0x6B52704F, 0x6B527031, 0x6B416C6C].contains(repeatCode) else { return nil }
        let track = try get(Self.currentTrack, owner: owner, deadline: deadline)
        let indexValue = try number(get(0x70696478, of: track, owner: owner, deadline: deadline)) // pidx
        let countEvent = NSAppleEventDescriptor(
            eventClass: kAECoreSuite, eventID: kAECountElements,
            targetDescriptor: .init(processIdentifier: owner.processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        countEvent.setParam(playlist, forKeyword: keyDirectObject)
        countEvent.setParam(.init(typeCode: 0x6354726B), forKeyword: keyAEObjectClass) // cTrk
        let countReply = try sendEvent(countEvent, owner: owner, deadline: deadline)
        guard let countDescriptor = countReply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw MacMusicBackendError.invalidData
        }
        let countValue = try number(countDescriptor)
        guard countValue >= 1, countValue <= 1_000_000, countValue.rounded() == countValue else { return nil }
        let count = Int32(countValue)
        let index: Int32
        if indexValue >= 1, indexValue <= countValue, indexValue.rounded() == indexValue,
           try playlistTrackID(index: Int32(indexValue), playlist: playlist, owner: owner, deadline: deadline) == trackID {
            index = Int32(indexValue)
        } else {
            // A current track can report its library index. Resolve small playlists by exact ID.
            guard count <= 256,
                  let resolved = try playlistIndex(trackID: trackID, playlist: playlist, count: count,
                                                   owner: owner, deadline: deadline) else { return nil }
            index = resolved
        }
        let wraps = repeatCode == 0x6B416C6C && count > 1 // kAll
        let nextIndex: Int32? = index < count ? index + 1 : (wraps ? 1 : nil)
        let previousIndex: Int32? = index > 1 ? index - 1 : (wraps ? count : nil)
        let next = try nextIndex.flatMap {
            try eligiblePlaylistTrackID(index: $0, playlist: playlist, owner: owner, deadline: deadline)
        }
        let previous = try previousIndex.flatMap {
            try eligiblePlaylistTrackID(index: $0, playlist: playlist, owner: owner, deadline: deadline)
        }
        guard try text(get(Self.persistentID, of: get(0x70506C61, owner: owner, deadline: deadline),
                           owner: owner, deadline: deadline)) == playlistID else {
            throw MacMusicBackendError.staleItem
        }
        return MacMusicNavigation(playlistID: playlistID, index: index, count: count,
                                  nextTrackID: next, previousTrackID: previous)
    }

    private func playlistIndex(
        trackID: String, playlist: NSAppleEventDescriptor, count: Int32,
        owner: MacMusicPlayerIdentity, deadline: TimeInterval
    ) throws -> Int32? {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(.init(typeCode: 0x6354726B), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(playlist, forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(.init(enumCode: OSType(kAEAll)), forKeyword: AEKeyword(keyAEKeyData))
        guard let tracks = specifier.coerce(toDescriptorType: typeObjectSpecifier) else { return nil }
        let identifiers = try get(Self.persistentID, of: tracks, owner: owner, deadline: deadline)
        guard identifiers.descriptorType == typeAEList, identifiers.numberOfItems == Int(count) else { return nil }
        var match: Int32?
        for index in 1...Int(count) {
            guard let descriptor = identifiers.atIndex(index) else { return nil }
            if try text(descriptor) == trackID {
                guard match == nil else { return nil }
                match = Int32(index)
            }
        }
        return match
    }

    private func playlistTrack(
        index: Int32, playlist: NSAppleEventDescriptor, owner: MacMusicPlayerIdentity,
        deadline: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(.init(typeCode: 0x6354726B), forKeyword: AEKeyword(keyAEDesiredClass)) // cTrk
        specifier.setDescriptor(playlist, forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(.init(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(.init(int32: index), forKeyword: AEKeyword(keyAEKeyData))
        guard let track = specifier.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MacMusicBackendError.invalidData
        }
        return track
    }

    private func playlistTrackID(
        index: Int32, playlist: NSAppleEventDescriptor, owner: MacMusicPlayerIdentity,
        deadline: TimeInterval
    ) throws -> String {
        let track = try playlistTrack(index: index, playlist: playlist, owner: owner, deadline: deadline)
        return try text(get(Self.persistentID, of: track, owner: owner, deadline: deadline))
    }

    private func eligiblePlaylistTrackID(
        index: Int32, playlist: NSAppleEventDescriptor, owner: MacMusicPlayerIdentity,
        deadline: TimeInterval
    ) throws -> String? {
        let track = try playlistTrack(index: index, playlist: playlist, owner: owner, deadline: deadline)
        let enabled = try get(0x656E626C, of: track, owner: owner, deadline: deadline) // enbl
        guard enabled.descriptorType == typeBoolean, enabled.booleanValue else { return nil }
        let identifier = try text(get(Self.persistentID, of: track, owner: owner, deadline: deadline))
        return MacMusicNowPlayingRuntime.isValidPersistentID(identifier) ? identifier : nil
    }

    private func currentTrackID(owner: MacMusicPlayerIdentity, deadline: TimeInterval) throws -> String {
        let track = try get(Self.currentTrack, owner: owner, deadline: deadline)
        guard track.descriptorType == typeObjectSpecifier else { throw MacMusicBackendError.staleItem }
        return try text(get(Self.persistentID, of: track, owner: owner, deadline: deadline))
    }

    private func get(
        _ property: AEKeyword, of container: NSAppleEventDescriptor = .null(),
        owner: MacMusicPlayerIdentity, deadline: TimeInterval
    ) throws -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(.init(typeCode: typeProperty), forKeyword: AEKeyword(keyAEDesiredClass))
        specifier.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        specifier.setDescriptor(.init(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        specifier.setDescriptor(.init(typeCode: property), forKeyword: AEKeyword(keyAEKeyData))
        guard let object = specifier.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MacMusicBackendError.invalidData
        }
        let event = NSAppleEventDescriptor(
            eventClass: kAECoreSuite, eventID: kAEGetData,
            targetDescriptor: .init(processIdentifier: owner.processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(object, forKeyword: keyDirectObject)
        let reply = try sendEvent(event, owner: owner, deadline: deadline)
        guard let result = reply.paramDescriptor(forKeyword: keyDirectObject),
              result.data.count <= 16_384 else { throw MacMusicBackendError.invalidData }
        return result
    }

    private func sendEvent(
        _ event: NSAppleEventDescriptor, owner: MacMusicPlayerIdentity,
        deadline: TimeInterval, isAuthorized: () -> Bool = { true }
    ) throws -> NSAppleEventDescriptor {
        guard client.runningOwner() == owner else { throw MacMusicBackendError.staleItem }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw MacMusicBackendError.timedOut }
        guard isAuthorized() else { throw MacMusicBackendError.staleItem }
        do {
            let reply = try client.sendEvent(event, options: Self.sendOptions, timeout: min(remaining, 0.25))
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber) {
                try Self.checkStatus(error.int32Value)
            }
            return reply
        } catch let error as MacMusicBackendError { throw error }
        catch { try Self.checkStatus(OSStatus((error as NSError).code)); throw MacMusicBackendError.unavailable }
    }

    private func text(_ descriptor: NSAppleEventDescriptor) throws -> String {
        guard let value = descriptor.stringValue, value.utf8.count <= 16_384 else {
            throw MacMusicBackendError.invalidData
        }
        return value
    }

    private func number(_ descriptor: NSAppleEventDescriptor) throws -> Double {
        guard let value = descriptor.coerce(toDescriptorType: typeIEEE64BitFloatingPoint)?.doubleValue,
              value.isFinite else { throw MacMusicBackendError.invalidData }
        return value
    }

    private static func checkStatus(_ status: OSStatus) throws {
        switch status {
        case noErr: return
        case -1744: throw MacMusicBackendError.permissionRequired
        case -1743: throw MacMusicBackendError.permissionDenied
        case OSStatus(errAETimeout): throw MacMusicBackendError.timedOut
        default: throw MacMusicBackendError.unavailable
        }
    }
}

final class MacMusicNowPlayingRuntime: MacSystemNowPlayingRuntime, @unchecked Sendable {
    private let backend: any MacMusicNowPlayingBackend
    private let queue: DispatchQueue
    private let now: @Sendable () -> TimeInterval
    private let admission = NSLock()
    private var commandPending = false
    private var fetchPending = false
    private var permissionPending = false
    private var discoveryStatus: MacMusicDiscoveryStatus = .idle
    private let permissionQueue = DispatchQueue(label: "com.elamin.opensteamer.music-permission", qos: .userInitiated)
    private var current: (snapshot: MacMusicPlayerSnapshot, token: MacNowPlayingClientToken)?
    private var relativeConsumed = false
    var isAvailable: Bool { true }
    var lastDiscoveryStatus: MacMusicDiscoveryStatus { admission.withLock { discoveryStatus } }

    init(
        backend: any MacMusicNowPlayingBackend = MacMusicAppleEventsBackend(),
        queue: DispatchQueue = DispatchQueue(label: "com.elamin.opensteamer.music-events", qos: .utility),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend
        self.queue = queue
        self.now = now
    }

    func fetchSnapshot(completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void) {
        guard admission.withLock({
            guard !fetchPending else { return false }
            fetchPending = true
            return true
        }) else { completion(.retry); return }
        let deadline = now() + 1.5
        queue.async { [self] in
            let result: MacNowPlayingRuntimeSnapshotResult
            let status: MacMusicDiscoveryStatus
            do {
                guard now() < deadline else { throw MacMusicBackendError.timedOut }
                if let snapshot = try backend.readSnapshot(deadline: deadline) {
                    guard let metadata = Self.metadata(snapshot) else { throw MacMusicBackendError.invalidData }
                    guard now() < deadline else { throw MacMusicBackendError.timedOut }
                    let token: MacNowPlayingClientToken
                    if let previous = current, previous.snapshot.hasSameItem(as: snapshot), !relativeConsumed {
                        token = previous.token
                    } else {
                        token = MacNowPlayingClientToken(
                            object: NSObject(),
                            clientIdentity: "music:\(snapshot.owner.processID):\(snapshot.owner.launchDate.timeIntervalSince1970)"
                        )
                    }
                    current = (snapshot, token)
                    relativeConsumed = false
                    result = .snapshot(MacNowPlayingRuntimeSnapshot(
                        client: token, sourceName: "Music", metadata: metadata,
                        enabledCommands: snapshot.enabledCommands
                    ))
                    status = .available
                } else {
                    current = nil
                    result = .noActiveMedia
                    status = .noPlayer
                }
            } catch {
                current = nil
                result = error as? MacMusicBackendError == .staleItem ? .retry : .noActiveMedia
                status = MacMusicDiscoveryStatus(error: error)
            }
            admission.withLock { fetchPending = false; discoveryStatus = status }
            completion(result)
        }
    }

    /// Explicit host onboarding only. The system owns the consent dialog's lifetime.
    func requestAutomationPermission(completion: @escaping @Sendable (Bool) -> Void) {
        guard admission.withLock({
            guard !permissionPending else { return false }
            permissionPending = true
            return true
        }) else { completion(false); return }
        permissionQueue.async { [self] in
            let granted: Bool
            do { try backend.requestAutomationPermission(); granted = true }
            catch { granted = false }
            admission.withLock { permissionPending = false }
            completion(granted)
        }
    }

    func send(
        rawCommand: Int, snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    ) {
        guard let command = MacMusicCommand(rawValue: rawCommand) else { completion(.unsupported); return }
        guard isAuthorized() else { completion(.staleContext); return }
        guard snapshot.enabledCommands.contains(rawCommand) else { completion(.unsupported); return }
        guard admission.withLock({
            guard !commandPending else { return false }
            commandPending = true
            return true
        }) else { completion(.failed); return }
        let deadline = now() + 1.5
        queue.async { [self] in
            let result: WebRTCRemoteMediaCommandResult
            if now() >= deadline || !isAuthorized() {
                result = .staleContext
            } else if let current, current.token === snapshot.client,
                      snapshot.metadata.contentIdentifier == current.snapshot.trackID,
                      !relativeConsumed {
                // A relative operation is consumed before dispatch, including ambiguous timeout.
                // A new snapshot is required before a distinct subsequent relative operation.
                if command.isRelative { relativeConsumed = true }
                do {
                    result = try backend.send(
                        command, expected: current.snapshot, deadline: deadline, isAuthorized: isAuthorized
                    )
                } catch {
                    result = error as? MacMusicBackendError == .staleItem ? .staleContext : .failed
                }
            } else { result = .staleContext }
            admission.withLock { commandPending = false }
            completion(result)
        }
    }

    static func metadata(_ snapshot: MacMusicPlayerSnapshot) -> MacNowPlayingMetadata? {
        guard snapshot.owner.processID > 0, snapshot.owner.launchDate.timeIntervalSince1970.isFinite,
              isValidPersistentID(snapshot.trackID),
              let title = boundedText(snapshot.title, bytes: WebRTCRemoteMediaItem.maximumTitleBytes),
              snapshot.observedAt.timeIntervalSince1970.isFinite else { return nil }
        let duration = validTime(snapshot.duration).flatMap { $0 > 0 ? $0 : nil }
        let position = validTime(snapshot.position).map { min($0, duration ?? $0) }
        return MacNowPlayingMetadata(
            title: title,
            artist: boundedText(snapshot.artist, bytes: WebRTCRemoteMediaItem.maximumArtistBytes),
            album: boundedText(snapshot.album, bytes: WebRTCRemoteMediaItem.maximumAlbumBytes),
            duration: duration, elapsedTime: position, playbackRate: snapshot.state == .playing ? 1 : 0,
            timestamp: snapshot.observedAt, contentIdentifier: snapshot.trackID, uniqueIdentifier: nil
        )
    }

    static func isValidPersistentID(_ identifier: String) -> Bool {
        identifier.utf8.count == 16
            && identifier.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }

    private static func boundedText(_ value: String?, bytes: Int) -> String? {
        guard let value, value.utf8.count <= 16_384 else { return nil }
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var result = ""
        for character in String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines) {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    private static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 31_536_000 else { return nil }
        return value
    }
}
