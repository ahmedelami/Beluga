@preconcurrency import AppKit
import CoreServices
import WebRTCTransport

struct MacChromePlayerIdentity: Equatable, Hashable, Sendable {
    let processID: Int32
    let launchDate: Date
}

struct MacChromeTabIdentity: Equatable, Hashable, Sendable {
    let owner: MacChromePlayerIdentity
    let windowID: String
    let tabID: String
}

struct MacChromeMediaIdentity: Codable, Equatable, Sendable {
    let documentID: String
    let itemID: String
    let itemGeneration: Int64
}

struct MacChromeScriptSnapshot: Codable, Equatable, Sendable {
    let documentID: String
    let itemID: String
    let itemGeneration: Int64
    let videoID: String
    let title: String
    let artist: String?
    let duration: Double?
    let elapsedTime: Double?
    let playbackRate: Double
    let paused: Bool
    let observedAtUnixMilliseconds: Double
    let observedAtPageMilliseconds: Double
    let canPlay: Bool
    let canPause: Bool
    let canNext: Bool
    let canPrevious: Bool

    var identity: MacChromeMediaIdentity {
        .init(documentID: documentID, itemID: itemID, itemGeneration: itemGeneration)
    }

    var enabledCommands: Set<Int> {
        var commands = Set<Int>()
        if canPlay && paused { commands.insert(0) }
        if canPause && !paused { commands.insert(1) }
        if canNext { commands.insert(4) }
        if canPrevious { commands.insert(5) }
        return commands
    }
}

struct MacChromePlayerSnapshot: Sendable {
    let tab: MacChromeTabIdentity
    let media: MacChromeScriptSnapshot
    let receivedAtUptime: TimeInterval

    func hasSameItem(as other: Self) -> Bool {
        tab == other.tab && media.identity == other.media.identity && media.videoID == other.media.videoID
    }
}

enum MacChromeBackendError: Error, Equatable {
    case permissionRequired, permissionDenied, javascriptPermissionRequired, timedOut
    case staleItem, invalidData, unavailable, ambiguousPlayers
}

enum MacChromeDiscoveryStatus: String, Sendable {
    case idle, available, noPlayer, ambiguousPlayers, permissionRequired, permissionDenied
    case javascriptPermissionRequired, timedOut, staleItem, invalidData, unavailable

    init(error: Error) {
        guard let error = error as? MacChromeBackendError else { self = .unavailable; return }
        switch error {
        case .permissionRequired: self = .permissionRequired
        case .permissionDenied: self = .permissionDenied
        case .javascriptPermissionRequired: self = .javascriptPermissionRequired
        case .timedOut: self = .timedOut
        case .staleItem: self = .staleItem
        case .invalidData: self = .invalidData
        case .unavailable: self = .unavailable
        case .ambiguousPlayers: self = .ambiguousPlayers
        }
    }
}

enum MacChromeCommand: Int, Sendable {
    case play = 0, pause = 1, next = 4, previous = 5
    var isRelative: Bool { self == .next || self == .previous }
    var scriptName: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .next: return "next"
        case .previous: return "previous"
        }
    }
}

protocol MacChromeNowPlayingBackend: Sendable {
    func readSnapshots(deadline: TimeInterval) throws -> [MacChromePlayerSnapshot]
    func requestAutomationPermission() throws
    func send(_ command: MacChromeCommand, expected: MacChromePlayerSnapshot,
              deadline: TimeInterval, isAuthorized: @escaping @Sendable () -> Bool) throws
        -> WebRTCRemoteMediaCommandResult
}

protocol MacChromeAppleEventsClient: Sendable {
    func runningOwner() -> MacChromePlayerIdentity?
    func automationPermission(owner: MacChromePlayerIdentity, askUser: Bool) -> OSStatus
    func sendEvent(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
                   timeout: TimeInterval) throws -> NSAppleEventDescriptor
}

private struct MacChromeSystemAppleEventsClient: MacChromeAppleEventsClient {
    func runningOwner() -> MacChromePlayerIdentity? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
            .filter { !$0.isTerminated && $0.bundleURL?.path == "/Applications/Google Chrome.app" }
        guard apps.count == 1, let app = apps.first, app.processIdentifier > 0,
              let launchDate = app.launchDate else { return nil }
        return .init(processID: app.processIdentifier, launchDate: launchDate)
    }

    func automationPermission(owner: MacChromePlayerIdentity, askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: owner.processID)
        guard let address = target.aeDesc else { return OSStatus(errAEWrongDataType) }
        return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser)
    }

    func sendEvent(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
                   timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        try event.sendEvent(options: options, timeout: timeout)
    }
}

/// Ordinary public Chrome Apple Events only; it neither launches nor activates a browser.
final class MacChromeAppleEventsBackend: MacChromeNowPlayingBackend, @unchecked Sendable {
    static let sendOptions = NSAppleEventDescriptor.SendOptions(rawValue:
        UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
    static let maximumSnapshotAge: TimeInterval = 3
    private let client: any MacChromeAppleEventsClient
    private let now: @Sendable () -> TimeInterval
    private let wallNow: @Sendable () -> TimeInterval

    init(client: any MacChromeAppleEventsClient = MacChromeSystemAppleEventsClient(),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallNow: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.client = client; self.now = now; self.wallNow = wallNow
    }

    func requestAutomationPermission() throws {
        guard let owner = client.runningOwner() else { throw MacChromeBackendError.unavailable }
        try Self.checkStatus(client.automationPermission(owner: owner, askUser: true))
        guard client.runningOwner() == owner else { throw MacChromeBackendError.staleItem }
    }

    func readSnapshots(deadline: TimeInterval) throws -> [MacChromePlayerSnapshot] {
        guard let owner = client.runningOwner() else { return [] }
        try check(owner: owner, deadline: deadline)
        try Self.checkStatus(client.automationPermission(owner: owner, askUser: false))
        let windows = try identifiers(get(property(0x49442020, of: all(0x6377696E)),
                                          owner: owner, deadline: deadline), maximum: 32)
        var tabCount = 0
        var candidates: [(MacChromeTabIdentity, String)] = []
        for windowID in windows {
            let window = try byID(0x6377696E, id: windowID)
            guard try boundedText(get(property(0x6D6F6465, of: window), owner: owner,
                                       deadline: deadline)) == "normal" else { continue }
            let tabs = try all(0x43725462, in: window)
            let tabIDs = try identifiers(get(property(0x49442020, of: tabs), owner: owner,
                                             deadline: deadline), maximum: 512)
            tabCount += tabIDs.count
            guard tabCount <= 512 else { throw MacChromeBackendError.invalidData }
            let urls = try list(get(property(0x55524C20, of: tabs), owner: owner,
                                    deadline: deadline), maximum: 512).map { try boundedText($0) }
            guard urls.count == tabIDs.count else { throw MacChromeBackendError.staleItem }
            for (tabID, url) in zip(tabIDs, urls) where Self.videoID(from: url) != nil {
                candidates.append((.init(owner: owner, windowID: windowID, tabID: tabID), url))
                guard candidates.count <= 16 else { throw MacChromeBackendError.invalidData }
            }
        }
        guard Set(candidates.map(\.0)).count == candidates.count else { throw MacChromeBackendError.invalidData }
        var snapshots: [MacChromePlayerSnapshot] = []
        for (tab, url) in candidates {
            let response = try execute(.init(operation: "read"), tab: tab, expectedURL: url,
                                       deadline: deadline, isAuthorized: { true })
            switch response.status {
            case "ok":
                guard let media = response.snapshot else { throw MacChromeBackendError.invalidData }
                try validate(media, url: url)
                snapshots.append(.init(tab: tab, media: media, receivedAtUptime: now()))
            case "noMedia": break
            case "staleContext": throw MacChromeBackendError.staleItem
            default: throw MacChromeBackendError.invalidData
            }
        }
        try check(owner: owner, deadline: deadline)
        return snapshots
    }

    func send(_ command: MacChromeCommand, expected: MacChromePlayerSnapshot,
              deadline: TimeInterval, isAuthorized: @escaping @Sendable () -> Bool) throws
        -> WebRTCRemoteMediaCommandResult {
        let deadline = min(deadline, expected.receivedAtUptime + Self.maximumSnapshotAge)
        try check(owner: expected.tab.owner, deadline: deadline, isAuthorized: isAuthorized)
        let candidates = try readSnapshots(deadline: deadline)
        guard let selected = try Self.select(candidates, preferred: expected), selected.hasSameItem(as: expected)
        else { return .staleContext }
        guard selected.media.enabledCommands.contains(command.rawValue) else { return .unsupported }
        let remainingFromObservation = (deadline - expected.receivedAtUptime) * 1000
        guard remainingFromObservation > 0 else { throw MacChromeBackendError.timedOut }
        let commandID = UUID().uuidString
        let request = ScriptRequest(
            operation: "command", commandID: commandID, expected: expected.media.identity,
            command: command.scriptName,
            expiresAtUnixMilliseconds: min(wallNow() * 1000 + (deadline - now()) * 1000,
                expected.media.observedAtUnixMilliseconds + remainingFromObservation),
            expiresAtPageMilliseconds: expected.media.observedAtPageMilliseconds + remainingFromObservation)
        let url = try currentURL(expected.tab, deadline: deadline, isAuthorized: isAuthorized)
        guard Self.videoID(from: url) == expected.media.videoID else { return .staleContext }
        var response = try execute(request, tab: expected.tab, expectedURL: url,
                                   deadline: deadline, isAuthorized: isAuthorized,
                                   allowSuccessor: command.isRelative)
        // Only result lookups repeat. A command Apple Event is never resent after timeout.
        var polls = 0
        while response.status == "pending", polls < 24 {
            polls += 1
            try check(owner: expected.tab.owner, deadline: deadline, isAuthorized: isAuthorized)
            Thread.sleep(forTimeInterval: min(0.025, max(0, deadline - now())))
            response = try execute(.init(operation: "result", commandID: commandID,
                                        expected: expected.media.identity),
                                   tab: expected.tab, expectedURL: nil, deadline: deadline,
                                   isAuthorized: isAuthorized, allowSuccessor: command.isRelative)
        }
        try check(owner: expected.tab.owner, deadline: deadline, isAuthorized: isAuthorized)
        switch response.status {
        case "ok":
            guard let media = response.snapshot else { return .failed }
            let finalURL = try currentURL(expected.tab, deadline: deadline, isAuthorized: isAuthorized)
            try validate(media, url: finalURL)
            guard media.documentID == expected.media.documentID else { return .staleContext }
            if command.isRelative {
                return media.videoID != expected.media.videoID && media.identity != expected.media.identity
                    ? .applied : .failed
            }
            guard media.identity == expected.media.identity else { return .staleContext }
            return (command == .play && !media.paused) || (command == .pause && media.paused) ? .applied : .failed
        case "staleContext": return .staleContext
        case "unsupported": return .unsupported
        case "noMedia": return .noActiveMedia
        default: return .failed
        }
    }

    static func select(_ snapshots: [MacChromePlayerSnapshot], preferred: MacChromePlayerSnapshot?) throws
        -> MacChromePlayerSnapshot? {
        let playing = snapshots.filter { !$0.media.paused && $0.media.playbackRate > 0 }
        guard playing.count <= 1 else { throw MacChromeBackendError.ambiguousPlayers }
        if let unique = playing.first { return unique }
        if let preferred, let sticky = snapshots.first(where: { $0.hasSameItem(as: preferred) }) { return sticky }
        guard snapshots.count <= 1 else { throw MacChromeBackendError.ambiguousPlayers }
        return snapshots.first
    }

    static func videoID(from value: String) -> String? {
        guard value.utf8.count <= 8_192, let url = URLComponents(string: value),
              url.scheme == "https", url.host == "www.youtube.com", url.path == "/watch",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        let values = (url.queryItems ?? []).filter { $0.name == "v" }
        guard values.count == 1, let id = values.first?.value, id.utf8.count == 11,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return id
    }

    private struct ScriptRequest: Encodable {
        let schemaVersion = 1
        let operation: String
        var commandID: String? = nil
        var expected: MacChromeMediaIdentity? = nil
        var command: String? = nil
        var expiresAtUnixMilliseconds: Double? = nil
        var expiresAtPageMilliseconds: Double? = nil
    }

    private struct ScriptResponse: Decodable {
        let schemaVersion: Int
        let status: String
        let snapshot: MacChromeScriptSnapshot?
    }

    private func execute(_ request: ScriptRequest, tab: MacChromeTabIdentity, expectedURL: String?,
                         deadline: TimeInterval, isAuthorized: @escaping @Sendable () -> Bool,
                         allowSuccessor: Bool = false) throws -> ScriptResponse {
        let beforeURL = try currentURL(tab, deadline: deadline, isAuthorized: isAuthorized)
        guard Self.videoID(from: beforeURL) != nil, expectedURL == nil || beforeURL == expectedURL else {
            throw MacChromeBackendError.staleItem
        }
        let data = try JSONEncoder().encode(request)
        guard data.count <= 2_048 else { throw MacChromeBackendError.invalidData }
        let script = "(" + MacChromeMediaScript.source + "\n)(" + String(decoding: data, as: UTF8.self) + ")"
        let event = NSAppleEventDescriptor(eventClass: 0x43725375, eventID: 0x45784A61,
            targetDescriptor: .init(processIdentifier: tab.owner.processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(try tabReference(tab), forKeyword: keyDirectObject)
        event.setParam(.init(string: script), forKeyword: 0x4A765363)
        let result = try sendEvent(event, owner: tab.owner, deadline: deadline, isAuthorized: isAuthorized)
        let afterURL = try currentURL(tab, deadline: deadline, isAuthorized: isAuthorized)
        guard Self.videoID(from: afterURL) != nil, allowSuccessor || beforeURL == afterURL else {
            throw MacChromeBackendError.staleItem
        }
        let responseText = try boundedText(result, maximum: 16_384)
        let response = try JSONDecoder().decode(ScriptResponse.self, from: Data(responseText.utf8))
        guard response.schemaVersion == 1 else { throw MacChromeBackendError.invalidData }
        return response
    }

    private func validate(_ media: MacChromeScriptSnapshot, url: String) throws {
        guard UUID(uuidString: media.documentID) != nil, media.documentID.count == 36,
              UUID(uuidString: media.itemID) != nil, media.itemID.count == 36,
              media.itemGeneration > 0, media.itemGeneration <= 9_007_199_254_740_991,
              Self.videoID(from: url) == media.videoID,
              !media.title.isEmpty, media.title.utf8.count <= 8_192,
              (media.artist?.utf8.count ?? 0) <= 8_192,
              media.playbackRate.isFinite, (0...16).contains(media.playbackRate),
              media.observedAtUnixMilliseconds.isFinite,
              abs(wallNow() * 1000 - media.observedAtUnixMilliseconds) <= 5_000,
              media.observedAtPageMilliseconds.isFinite, media.observedAtPageMilliseconds >= 0,
              media.observedAtPageMilliseconds <= 9_007_199_254_740_991,
              [media.duration, media.elapsedTime].allSatisfy({ value in
                  value.map { $0.isFinite && $0 >= 0 && $0 <= 31_536_000 } ?? true
              }) else { throw MacChromeBackendError.invalidData }
    }

    private func currentURL(_ tab: MacChromeTabIdentity, deadline: TimeInterval,
                            isAuthorized: @escaping @Sendable () -> Bool) throws -> String {
        let window = try byID(0x6377696E, id: tab.windowID)
        guard try boundedText(get(property(0x6D6F6465, of: window), owner: tab.owner,
                                  deadline: deadline, isAuthorized: isAuthorized)) == "normal" else {
            throw MacChromeBackendError.staleItem
        }
        return try boundedText(get(property(0x55524C20, of: tabReference(tab)), owner: tab.owner,
                                   deadline: deadline, isAuthorized: isAuthorized))
    }

    private func tabReference(_ tab: MacChromeTabIdentity) throws -> NSAppleEventDescriptor {
        try byID(0x43725462, id: tab.tabID, in: byID(0x6377696E, id: tab.windowID))
    }

    private func get(_ reference: NSAppleEventDescriptor, owner: MacChromePlayerIdentity,
                     deadline: TimeInterval, isAuthorized: @escaping @Sendable () -> Bool = { true }) throws
        -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEGetData,
            targetDescriptor: .init(processIdentifier: owner.processID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(reference, forKeyword: keyDirectObject)
        return try sendEvent(event, owner: owner, deadline: deadline, isAuthorized: isAuthorized)
    }

    private func sendEvent(_ event: NSAppleEventDescriptor, owner: MacChromePlayerIdentity,
                           deadline: TimeInterval, isAuthorized: @escaping @Sendable () -> Bool) throws
        -> NSAppleEventDescriptor {
        let timeout = try dispatchTimeout(owner: owner, deadline: deadline, isAuthorized: isAuthorized)
        do {
            let reply = try client.sendEvent(event, options: Self.sendOptions, timeout: timeout)
            try check(owner: owner, deadline: deadline, isAuthorized: isAuthorized)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
                let message = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? ""
                if error.int32Value == -10000, message.utf8.count <= 8_192,
                   message.lowercased().contains("javascript"), message.lowercased().contains("turned off") {
                    throw MacChromeBackendError.javascriptPermissionRequired
                }
                try Self.checkStatus(error.int32Value)
            }
            guard let result = reply.paramDescriptor(forKeyword: keyDirectObject), result.data.count <= 262_144 else {
                throw MacChromeBackendError.invalidData
            }
            return result
        } catch let error as MacChromeBackendError { throw error }
        catch { try Self.checkStatus(OSStatus((error as NSError).code)); throw MacChromeBackendError.unavailable }
    }

    private func dispatchTimeout(owner: MacChromePlayerIdentity, deadline: TimeInterval,
                                 isAuthorized: () -> Bool) throws -> TimeInterval {
        guard client.runningOwner() == owner else { throw MacChromeBackendError.staleItem }
        let remaining = deadline - now()
        guard deadline.isFinite, remaining > 0 else { throw MacChromeBackendError.timedOut }
        guard isAuthorized() else { throw MacChromeBackendError.staleItem }
        return min(0.35, remaining)
    }

    private func check(owner: MacChromePlayerIdentity, deadline: TimeInterval,
                       isAuthorized: () -> Bool = { true }) throws {
        guard client.runningOwner() == owner, isAuthorized() else { throw MacChromeBackendError.staleItem }
        guard deadline.isFinite, now() < deadline else { throw MacChromeBackendError.timedOut }
    }

    private static func checkStatus(_ status: OSStatus) throws {
        switch status {
        case noErr: return
        case -1744: throw MacChromeBackendError.permissionRequired
        case -1743: throw MacChromeBackendError.permissionDenied
        case OSStatus(errAETimeout): throw MacChromeBackendError.timedOut
        case -1728: throw MacChromeBackendError.staleItem
        default: throw MacChromeBackendError.unavailable
        }
    }

    private func object(_ kind: OSType, container: NSAppleEventDescriptor = .null(),
                        form: OSType, selector: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: kind), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        record.setDescriptor(.init(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw MacChromeBackendError.invalidData
        }
        return result
    }

    private func all(_ kind: OSType, in container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        var ordinal = UInt32(kAEAll)
        guard let selector = withUnsafeBytes(of: &ordinal, {
            NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, data: Data($0))
        }) else { throw MacChromeBackendError.invalidData }
        return try object(kind, container: container, form: OSType(formAbsolutePosition), selector: selector)
    }

    private func byID(_ kind: OSType, id: String, in container: NSAppleEventDescriptor = .null()) throws
        -> NSAppleEventDescriptor {
        guard Self.validIdentifier(id) else { throw MacChromeBackendError.invalidData }
        return try object(kind, container: container, form: OSType(formUniqueID), selector: .init(string: id))
    }

    private func property(_ code: OSType, of container: NSAppleEventDescriptor = .null()) throws
        -> NSAppleEventDescriptor {
        try object(typeProperty, container: container, form: OSType(formPropertyID), selector: .init(typeCode: code))
    }

    private func list(_ descriptor: NSAppleEventDescriptor, maximum: Int) throws -> [NSAppleEventDescriptor] {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems <= maximum else {
            throw MacChromeBackendError.invalidData
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return try (1...descriptor.numberOfItems).map {
            guard let value = descriptor.atIndex($0) else { throw MacChromeBackendError.invalidData }
            return value
        }
    }

    private func identifiers(_ descriptor: NSAppleEventDescriptor, maximum: Int) throws -> [String] {
        let ids = try list(descriptor, maximum: maximum).map { try boundedText($0) }
        guard ids.allSatisfy(Self.validIdentifier), Set(ids).count == ids.count else {
            throw MacChromeBackendError.invalidData
        }
        return ids
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func boundedText(_ descriptor: NSAppleEventDescriptor, maximum: Int = 8_192) throws -> String {
        guard let text = descriptor.stringValue, text.utf8.count <= maximum else { throw MacChromeBackendError.invalidData }
        return text
    }
}
