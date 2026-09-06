@preconcurrency import Foundation
import Darwin
import WebRTCTransport

protocol MacRemoteMediaControlling: Sendable {
    var isAvailable: Bool { get }

    func start(
        onStateChanged: @escaping @Sendable (WebRTCRemoteMediaStateUpdate) -> Void
    )
    func stop()
    /// Revokes commands admitted before a peer/recovery boundary without stopping polling.
    func invalidateCommands()
    /// Captures authority synchronously in the caller's checked admission section.
    func prepareCommand(
        _ command: WebRTCRemoteMediaCommand,
        contextID: String,
        isAuthorized: @escaping @Sendable () -> Bool
    ) -> MacPreparedRemoteMediaCommand?
    func perform(
        _ prepared: MacPreparedRemoteMediaCommand
    ) async -> WebRTCRemoteMediaCommandResult
    func refresh()
}

/// Only the originating controller can create or execute this immutable admission.
struct MacPreparedRemoteMediaCommand: Sendable {
    fileprivate let owner: MacRemoteMediaCommandGate
    fileprivate let authorization: MacRemoteMediaCommandGate.Authorization
    fileprivate let command: WebRTCRemoteMediaCommand
    fileprivate let contextID: String
    fileprivate let isAuthorized: @Sendable () -> Bool
}

/// Strongly owns the private-framework client for the complete snapshot/command transaction.
final class MacNowPlayingClientToken: @unchecked Sendable {
    fileprivate let object: AnyObject
    let clientIdentity: String

    init(object: AnyObject, clientIdentity: String) {
        self.object = object
        self.clientIdentity = clientIdentity
    }
}

struct MacNowPlayingMetadata: Sendable, Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let playbackRate: Double
    let timestamp: Date?
    let contentIdentifier: String?
    let uniqueIdentifier: String?

    var identityComponent: String {
        if let contentIdentifier, !contentIdentifier.isEmpty {
            return "content:" + contentIdentifier
        }
        if let uniqueIdentifier, !uniqueIdentifier.isEmpty {
            return "unique:" + uniqueIdentifier
        }
        return [
            title ?? "",
            artist ?? "",
            album ?? "",
            duration.map { String(format: "%.3f", $0) } ?? ""
        ].joined(separator: "\u{1f}")
    }
}

struct MacNowPlayingRuntimeSnapshot: @unchecked Sendable {
    let client: MacNowPlayingClientToken
    let sourceName: String?
    let metadata: MacNowPlayingMetadata
    /// Raw MediaRemote command values that the exact client reports as enabled.
    let enabledCommands: Set<Int>

    var identityKey: String {
        client.clientIdentity + "\u{1e}" + metadata.identityComponent
    }
}

enum MacNowPlayingRuntimeSnapshotResult: @unchecked Sendable {
    case snapshot(MacNowPlayingRuntimeSnapshot)
    case noActiveMedia
    /// The active client changed during the transaction; retry without publishing mixed state.
    case retry
}

protocol MacSystemNowPlayingRuntime: Sendable {
    var isAvailable: Bool { get }
    func stop()

    func fetchSnapshot(
        completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void
    )

    func send(
        rawCommand: Int,
        snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    )
}

extension MacSystemNowPlayingRuntime {
    func stop() {}
}

enum MacMediaRemoteABIGate {
    /// The dynamic signatures below were verified against macOS 26.5.1. Symbol presence alone is
    /// not enough because a same-named private function may change its calling convention.
    static func supports(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion == 26
            && version.minorVersion == 5
    }
}

private final class MacSingleCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Value) -> Void)?

    init(_ completion: @escaping @Sendable (Value) -> Void) {
        self.completion = completion
    }

    func resolve(_ value: Value) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(value)
    }
}

private final class MacMediaRemoteClientReference: @unchecked Sendable {
    let object: AnyObject

    init(_ object: AnyObject) {
        self.object = object
    }
}

private final class MacRemoteMediaCommandAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func invalidate() {
        lock.withLock { active = false }
    }

    var isActive: Bool { lock.withLock { active } }
}

fileprivate final class MacRemoteMediaCommandGate: @unchecked Sendable {
    struct Lifecycle: Sendable, Equatable {
        fileprivate let value: UInt64
    }

    struct Authorization: Sendable, Equatable {
        fileprivate let lifecycle: UInt64
        fileprivate let commandEpoch: UInt64
        fileprivate let contextID: String
    }

    private let lock = NSLock()
    private var lifecycle: UInt64 = 0
    private var commandEpoch: UInt64 = 0
    private var isOpen = false
    private var contextID: String?

    func open() -> Lifecycle {
        lock.withLock {
            lifecycle &+= 1
            commandEpoch &+= 1
            isOpen = true
            contextID = nil
            return Lifecycle(value: lifecycle)
        }
    }

    func close() {
        lock.withLock {
            lifecycle &+= 1
            commandEpoch &+= 1
            isOpen = false
            contextID = nil
        }
    }

    func invalidateCommands() {
        lock.withLock { commandEpoch &+= 1 }
    }

    func setContext(_ newContextID: String?) {
        lock.withLock {
            guard contextID != newContextID else { return }
            contextID = newContextID
            commandEpoch &+= 1
        }
    }

    func lifecycleIsCurrent(_ candidate: Lifecycle) -> Bool {
        lock.withLock { isOpen && lifecycle == candidate.value }
    }

    func capture(contextID candidate: String) -> Authorization? {
        lock.withLock {
            guard isOpen, contextID == candidate else { return nil }
            return Authorization(
                lifecycle: lifecycle,
                commandEpoch: commandEpoch,
                contextID: candidate
            )
        }
    }

    func admits(_ authorization: Authorization) -> Bool {
        lock.withLock {
            isOpen
                && lifecycle == authorization.lifecycle
                && commandEpoch == authorization.commandEpoch
                && contextID == authorization.contextID
        }
    }
}

/// Dynamically binds the private MediaRemote ABI. Keeping it behind this narrow runtime makes an
/// absent or changed ABI fail closed, though use of MediaRemote remains an App Store review risk.
private final class DynamicMediaRemoteRuntime: MacSystemNowPlayingRuntime,
    @unchecked Sendable
{
    private typealias ClientCallback =
        @convention(block) (UnsafeRawPointer?) -> Void
    private typealias GetClientFunction =
        @convention(c) (DispatchQueue, @escaping ClientCallback) -> Void
    private typealias InfoCallback =
        @convention(block) (CFDictionary?, UnsafeRawPointer?) -> Void
    private typealias GetInfoForClientFunction =
        @convention(c) (
            UnsafeRawPointer?, UnsafeRawPointer?, Bool, DispatchQueue,
            @escaping InfoCallback
        ) -> Void
    private typealias SupportedCommandsCallback =
        @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
    private typealias GetSupportedCommandsForClientFunction =
        @convention(c) (
            UnsafeRawPointer?, UnsafeRawPointer?, DispatchQueue,
            @escaping SupportedCommandsCallback
        ) -> Void
    private typealias CommandReply =
        @convention(block) (UInt32, UnsafeRawPointer?) -> Void
    private typealias SendCommandToClientFunction =
        @convention(c) (
            Int, CFDictionary?, UnsafeRawPointer?, UnsafeRawPointer?,
            UnsafeRawPointer?, DispatchQueue, @escaping CommandReply
        ) -> Bool
    private typealias GetLocalOriginFunction =
        @convention(c) () -> UnsafeRawPointer?
    private typealias ClientStringFunction =
        @convention(c) (UnsafeRawPointer?) -> Unmanaged<CFString>?
    private typealias ClientProcessIdentifierFunction =
        @convention(c) (UnsafeRawPointer?) -> Int32
    private typealias ClientsEqualFunction =
        @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Bool
    private typealias CommandInfoValueFunction =
        @convention(c) (UnsafeRawPointer?) -> Int
    private typealias CommandInfoEnabledFunction =
        @convention(c) (UnsafeRawPointer?) -> Bool

    private struct Functions: @unchecked Sendable {
        let getClient: GetClientFunction
        let getInfo: GetInfoForClientFunction
        let getSupportedCommands: GetSupportedCommandsForClientFunction
        let sendCommand: SendCommandToClientFunction
        let localOrigin: UnsafeRawPointer?
        let displayName: ClientStringFunction?
        let bundleIdentifier: ClientStringFunction?
        let processIdentifier: ClientProcessIdentifierFunction?
        let clientsEqual: ClientsEqualFunction
        let commandValue: CommandInfoValueFunction
        let commandEnabled: CommandInfoEnabledFunction

        init?() {
            guard MacMediaRemoteABIGate.supports(
                ProcessInfo.processInfo.operatingSystemVersion
            ) else { return nil }
            let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL),
                  let getClient = Self.load(
                      "MRMediaRemoteGetNowPlayingClient", from: handle,
                      as: GetClientFunction.self
                  ),
                  let getInfo = Self.load(
                      "MRMediaRemoteGetNowPlayingInfoForClient", from: handle,
                      as: GetInfoForClientFunction.self
                  ),
                  let getSupported = Self.load(
                      "MRMediaRemoteGetSupportedCommandsForClient", from: handle,
                      as: GetSupportedCommandsForClientFunction.self
                  ),
                  let sendCommand = Self.load(
                      "MRMediaRemoteSendCommandToClient", from: handle,
                      as: SendCommandToClientFunction.self
                  ),
                  let getOrigin = Self.load(
                      "MRMediaRemoteGetLocalOrigin", from: handle,
                      as: GetLocalOriginFunction.self
                  ),
                  let clientsEqual = Self.load(
                      "MRNowPlayingClientEqualToClient", from: handle,
                      as: ClientsEqualFunction.self
                  ),
                  let commandValue = Self.load(
                      "MRMediaRemoteCommandInfoGetCommand", from: handle,
                      as: CommandInfoValueFunction.self
                  ),
                  let commandEnabled = Self.load(
                      "MRMediaRemoteCommandInfoGetEnabled", from: handle,
                      as: CommandInfoEnabledFunction.self
                  ) else {
                return nil
            }
            self.getClient = getClient
            self.getInfo = getInfo
            getSupportedCommands = getSupported
            self.sendCommand = sendCommand
            localOrigin = getOrigin()
            self.clientsEqual = clientsEqual
            self.commandValue = commandValue
            self.commandEnabled = commandEnabled
            displayName = Self.load(
                "MRNowPlayingClientGetDisplayName", from: handle,
                as: ClientStringFunction.self
            )
            bundleIdentifier = Self.load(
                "MRNowPlayingClientGetBundleIdentifier", from: handle,
                as: ClientStringFunction.self
            )
            processIdentifier = Self.load(
                "MRNowPlayingClientGetProcessIdentifier", from: handle,
                as: ClientProcessIdentifierFunction.self
            )
            // Asynchronous callbacks may retain these function pointers for process lifetime.
            _ = handle
        }

        private static func load<T>(
            _ name: String,
            from handle: UnsafeMutableRawPointer,
            as type: T.Type
        ) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
    }

    private enum Key {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let duration = "kMRMediaRemoteNowPlayingInfoDuration"
        static let elapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
        static let timestamp = "kMRMediaRemoteNowPlayingInfoTimestamp"
        static let uniqueIdentifier = "kMRMediaRemoteNowPlayingInfoUniqueIdentifier"
        static let contentItemIdentifier =
            "kMRMediaRemoteNowPlayingInfoContentItemIdentifier"
    }

    private let functions: Functions
    private let invocationQueue = DispatchQueue(
        label: "com.elamin.opensteamer.media-remote.invoke",
        qos: .utility
    )
    private let callbackQueue = DispatchQueue(
        label: "com.elamin.opensteamer.media-remote.callback",
        qos: .utility
    )

    var isAvailable: Bool { true }

    init?() {
        guard let functions = Functions() else { return nil }
        self.functions = functions
    }

    func fetchSnapshot(
        completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void
    ) {
        let completion = MacSingleCompletion(completion)
        currentClient { [weak self] client in
            guard let self else {
                completion.resolve(.noActiveMedia)
                return
            }
            guard let client else {
                completion.resolve(.noActiveMedia)
                return
            }
            self.fetchMetadata(for: client) { metadata in
                guard let metadata else {
                    completion.resolve(.noActiveMedia)
                    return
                }
                let token = self.makeToken(client: client)
                self.fetchSupportedCommands(for: client) { commands in
                    self.currentClient { currentClient in
                        guard let currentClient else {
                            completion.resolve(.noActiveMedia)
                            return
                        }
                        guard self.clientsAreEqual(client, currentClient) else {
                            completion.resolve(.retry)
                            return
                        }
                        completion.resolve(.snapshot(MacNowPlayingRuntimeSnapshot(
                            client: token,
                            sourceName: self.clientDisplayName(client),
                            metadata: metadata,
                            enabledCommands: commands
                        )))
                    }
                }
            }
        }
    }

    func send(
        rawCommand: Int,
        snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    ) {
        let completion = MacSingleCompletion(completion)
        guard isAuthorized() else {
            completion.resolve(.staleContext)
            return
        }
        currentClient { [weak self] currentClient in
            guard let self else {
                completion.resolve(.failed)
                return
            }
            guard let currentClient else {
                completion.resolve(.noActiveMedia)
                return
            }
            let snapshotClient = MacMediaRemoteClientReference(snapshot.client.object)
            guard self.clientsAreEqual(snapshotClient, currentClient) else {
                completion.resolve(.staleContext)
                return
            }
            self.fetchMetadata(for: currentClient) { metadata in
                guard let metadata else {
                    completion.resolve(.noActiveMedia)
                    return
                }
                guard metadata.identityComponent == snapshot.metadata.identityComponent else {
                    completion.resolve(.staleContext)
                    return
                }
                self.fetchSupportedCommands(for: currentClient) { commands in
                    guard commands.contains(rawCommand) else {
                        completion.resolve(.unsupported)
                        return
                    }
                    self.currentClient { finalClient in
                        guard let finalClient,
                              self.clientsAreEqual(currentClient, finalClient),
                              isAuthorized() else {
                            completion.resolve(.staleContext)
                            return
                        }
                        self.invokeCommand(
                            rawCommand,
                            client: finalClient,
                            isAuthorized: isAuthorized,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private func currentClient(
        completion: @escaping @Sendable (MacMediaRemoteClientReference?) -> Void
    ) {
        invocationQueue.async { [functions, callbackQueue] in
            functions.getClient(callbackQueue) { pointer in
                guard let pointer else {
                    completion(nil)
                    return
                }
                completion(MacMediaRemoteClientReference(
                    Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                ))
            }
        }
    }

    private func fetchMetadata(
        for client: MacMediaRemoteClientReference,
        completion: @escaping @Sendable (MacNowPlayingMetadata?) -> Void
    ) {
        invocationQueue.async { [functions, callbackQueue] in
            let pointer = Unmanaged.passUnretained(client.object).toOpaque()
            // `false` is deliberate: artwork is neither requested nor retained by the host.
            functions.getInfo(
                pointer,
                functions.localOrigin,
                false,
                callbackQueue
            ) { dictionary, _ in
                completion(dictionary.map(Self.metadata(from:)))
            }
        }
    }

    private func fetchSupportedCommands(
        for client: MacMediaRemoteClientReference,
        completion: @escaping @Sendable (Set<Int>) -> Void
    ) {
        invocationQueue.async { [functions, callbackQueue] in
            let pointer = Unmanaged.passUnretained(client.object).toOpaque()
            functions.getSupportedCommands(
                pointer,
                functions.localOrigin,
                callbackQueue
            ) { arrayPointer, _ in
                guard let arrayPointer else {
                    completion([])
                    return
                }
                let array = Unmanaged<CFArray>
                    .fromOpaque(arrayPointer)
                    .takeUnretainedValue()
                var enabled = Set<Int>()
                for index in 0..<CFArrayGetCount(array) {
                    guard let value = CFArrayGetValueAtIndex(array, index) else {
                        continue
                    }
                    if functions.commandEnabled(value) {
                        enabled.insert(functions.commandValue(value))
                    }
                }
                completion(enabled)
            }
        }
    }

    private func invokeCommand(
        _ rawCommand: Int,
        client: MacMediaRemoteClientReference,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: MacSingleCompletion<WebRTCRemoteMediaCommandResult>
    ) {
        invocationQueue.async { [functions, callbackQueue] in
            guard isAuthorized() else {
                completion.resolve(.staleContext)
                return
            }
            let clientPointer = Unmanaged.passUnretained(client.object).toOpaque()
            let wasDispatched = functions.sendCommand(
                rawCommand,
                nil,
                functions.localOrigin,
                clientPointer,
                nil,
                callbackQueue
            ) { sendError, statusesPointer in
                guard sendError == 0,
                      Self.commandStatusesSucceeded(statusesPointer) else {
                    completion.resolve(.failed)
                    return
                }
                completion.resolve(.applied)
            }
            // The current OS implementation returns true unconditionally, but treating a future
            // false as failure is harmless. Success is still decided only by the async reply.
            if !wasDispatched {
                completion.resolve(.failed)
            }
        }
    }

    private func clientsAreEqual(
        _ lhs: MacMediaRemoteClientReference,
        _ rhs: MacMediaRemoteClientReference
    ) -> Bool {
        functions.clientsEqual(
            Unmanaged.passUnretained(lhs.object).toOpaque(),
            Unmanaged.passUnretained(rhs.object).toOpaque()
        )
    }

    private func makeToken(
        client: MacMediaRemoteClientReference
    ) -> MacNowPlayingClientToken {
        let pointer = Unmanaged.passUnretained(client.object).toOpaque()
        let bundle = functions.bundleIdentifier?(pointer)?.takeUnretainedValue()
            as String? ?? "unknown"
        let process = functions.processIdentifier?(pointer)
        let identity = process.map { bundle + ":" + String($0) } ?? bundle
        return MacNowPlayingClientToken(object: client.object, clientIdentity: identity)
    }

    private func clientDisplayName(_ client: MacMediaRemoteClientReference) -> String? {
        let pointer = Unmanaged.passUnretained(client.object).toOpaque()
        if let name = functions.displayName?(pointer)?.takeUnretainedValue() {
            return name as String
        }
        if let bundle = functions.bundleIdentifier?(pointer)?.takeUnretainedValue() {
            return bundle as String
        }
        return nil
    }

    private static func metadata(from dictionary: CFDictionary) -> MacNowPlayingMetadata {
        let info = dictionary as NSDictionary
        return MacNowPlayingMetadata(
            title: info[Key.title] as? String,
            artist: info[Key.artist] as? String,
            album: info[Key.album] as? String,
            duration: number(info[Key.duration]),
            elapsedTime: number(info[Key.elapsedTime]),
            playbackRate: number(info[Key.playbackRate]) ?? 0,
            timestamp: timestamp(info[Key.timestamp]),
            contentIdentifier: info[Key.contentItemIdentifier]
                .map(String.init(describing:)),
            uniqueIdentifier: info[Key.uniqueIdentifier]
                .map(String.init(describing:))
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let date = value as? NSDate { return date as Date }
        guard let absoluteTime = number(value), absoluteTime.isFinite else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: absoluteTime)
    }

    private static func commandStatusesSucceeded(_ pointer: UnsafeRawPointer?) -> Bool {
        guard let pointer else { return true }
        let statuses = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue()
        for index in 0..<CFArrayGetCount(statuses) {
            guard let rawStatus = CFArrayGetValueAtIndex(statuses, index) else {
                return false
            }
            let status = Unmanaged<AnyObject>
                .fromOpaque(rawStatus)
                .takeUnretainedValue()
            guard let number = status as? NSNumber, number.intValue == 0 else {
                return false
            }
        }
        return true
    }
}

/// Reads and controls the exact system Now Playing client selected by macOS Control Center.
final class MacSystemNowPlayingController: MacRemoteMediaControlling,
    @unchecked Sendable
{
    private enum CommandValue: Int {
        case play = 0
        case pause = 1
        case nextTrack = 4
        case previousTrack = 5

        init(_ command: WebRTCRemoteMediaCommand) {
            switch command {
            case .play: self = .play
            case .pause: self = .pause
            case .nextTrack: self = .nextTrack
            case .previousTrack: self = .previousTrack
            }
        }
    }

    private let runtime: (any MacSystemNowPlayingRuntime)?
    private let queue = DispatchQueue(
        label: "com.elamin.opensteamer.system-now-playing",
        qos: .utility
    )
    private let gate = MacRemoteMediaCommandGate()
    private let pollInterval: TimeInterval?
    private let operationTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let onCommandEnqueued: (@Sendable () -> Void)?
    private var timer: DispatchSourceTimer?
    private var lifecycle: MacRemoteMediaCommandGate.Lifecycle?
    private var onStateChanged:
        (@Sendable (WebRTCRemoteMediaStateUpdate) -> Void)?
    private var revision: UInt64 = 0
    private var currentContextID: String?
    private var currentIdentityKey: String?
    private var currentItem: WebRTCRemoteMediaItem?
    private var currentSnapshot: MacNowPlayingRuntimeSnapshot?
    private var lastPublishedItem: WebRTCRemoteMediaItem?
    private var hasPublishedState = false
    private var nextRefreshID: UInt64 = 0
    private var activeRefreshID: UInt64?
    private var refreshPending = false

    var isAvailable: Bool { runtime?.isAvailable == true }

    init() {
        runtime = MacSupportedNowPlayingRuntime()
        pollInterval = 1
        operationTimeout = 2
        now = Date.init
        onCommandEnqueued = nil
    }

    init(
        runtime: (any MacSystemNowPlayingRuntime)?,
        pollInterval: TimeInterval? = nil,
        operationTimeout: TimeInterval = 2,
        now: @escaping @Sendable () -> Date = Date.init,
        onCommandEnqueued: (@Sendable () -> Void)? = nil
    ) {
        self.runtime = runtime
        self.pollInterval = pollInterval
        self.operationTimeout = operationTimeout
        self.now = now
        self.onCommandEnqueued = onCommandEnqueued
    }

    func start(
        onStateChanged: @escaping @Sendable (WebRTCRemoteMediaStateUpdate) -> Void
    ) {
        let requestedLifecycle = gate.open()
        queue.async { [weak self] in
            guard let self,
                  self.gate.lifecycleIsCurrent(requestedLifecycle) else { return }
            self.lifecycle = requestedLifecycle
            self.onStateChanged = onStateChanged
            self.revision = 0
            self.currentContextID = nil
            self.currentIdentityKey = nil
            self.currentItem = nil
            self.currentSnapshot = nil
            self.lastPublishedItem = nil
            self.hasPublishedState = false
            self.activeRefreshID = nil
            self.refreshPending = false
            self.timer?.cancel()
            self.timer = nil
            if let pollInterval = self.pollInterval, self.isAvailable {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(
                    deadline: .now(),
                    repeating: pollInterval,
                    leeway: .milliseconds(100)
                )
                timer.setEventHandler { [weak self] in self?.requestRefresh() }
                self.timer = timer
                timer.resume()
            } else {
                self.requestRefresh()
            }
        }
    }

    func stop() {
        gate.close()
        queue.async { [weak self] in
            guard let self else { return }
            self.runtime?.stop()
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            self.lifecycle = nil
            self.activeRefreshID = nil
            self.refreshPending = false
            self.onStateChanged = nil
            self.currentContextID = nil
            self.currentIdentityKey = nil
            self.currentItem = nil
            self.currentSnapshot = nil
            self.lastPublishedItem = nil
            self.hasPublishedState = false
        }
    }

    func invalidateCommands() {
        gate.invalidateCommands()
    }

    func refresh() {
        queue.async { [weak self] in self?.requestRefresh() }
    }

    func prepareCommand(
        _ command: WebRTCRemoteMediaCommand,
        contextID: String,
        isAuthorized: @escaping @Sendable () -> Bool
    ) -> MacPreparedRemoteMediaCommand? {
        // Capture before the caller's first suspension, not merely before our
        // dispatch queue. A revoked caller must never adopt a replacement epoch.
        guard isAuthorized(),
              let authorization = gate.capture(contextID: contextID) else {
            return nil
        }
        return MacPreparedRemoteMediaCommand(
            owner: gate,
            authorization: authorization,
            command: command,
            contextID: contextID,
            isAuthorized: isAuthorized
        )
    }

    func perform(
        _ prepared: MacPreparedRemoteMediaCommand
    ) async -> WebRTCRemoteMediaCommandResult {
        guard let runtime, runtime.isAvailable else { return .unsupported }
        let authorization = prepared.authorization
        guard prepared.owner === gate, gate.admits(authorization), prepared.isAuthorized() else {
            return .staleContext
        }
        let command = prepared.command
        let contextID = prepared.contextID
        return await withCheckedContinuation { continuation in
            let resolver = MacSingleCompletion<WebRTCRemoteMediaCommandResult> {
                continuation.resume(returning: $0)
            }
            queue.async { [weak self] in
                guard let self else {
                    resolver.resolve(.failed)
                    return
                }
                guard self.gate.admits(authorization), prepared.isAuthorized() else {
                    resolver.resolve(.staleContext)
                    return
                }
                guard let currentItem = self.currentItem,
                      let snapshot = self.currentSnapshot else {
                    resolver.resolve(.noActiveMedia)
                    return
                }
                guard currentItem.contextID == contextID else {
                    resolver.resolve(.staleContext)
                    return
                }
                guard currentItem.capabilities.permits(command) else {
                    resolver.resolve(.unsupported)
                    return
                }
                let attempt = MacRemoteMediaCommandAttempt()
                let rawCommand = CommandValue(command).rawValue
                runtime.send(
                    rawCommand: rawCommand,
                    snapshot: snapshot,
                    isAuthorized: { [gate = self.gate] in
                        attempt.isActive && gate.admits(authorization) && prepared.isAuthorized()
                    },
                    completion: { [weak self] result in
                        attempt.invalidate()
                        resolver.resolve(result)
                        self?.refresh()
                    }
                )
                self.queue.asyncAfter(deadline: .now() + self.operationTimeout) {
                    attempt.invalidate()
                    resolver.resolve(.failed)
                }
            }
            onCommandEnqueued?()
        }
    }

    private func requestRefresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let runtime, runtime.isAvailable,
              let lifecycle,
              gate.lifecycleIsCurrent(lifecycle) else { return }
        guard activeRefreshID == nil else {
            refreshPending = true
            return
        }
        nextRefreshID &+= 1
        if nextRefreshID == 0 { nextRefreshID = 1 }
        let refreshID = nextRefreshID
        activeRefreshID = refreshID
        runtime.fetchSnapshot { [weak self] result in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.finishRefresh(
                    id: refreshID,
                    lifecycle: lifecycle,
                    result: result
                )
            }
        }
        queue.asyncAfter(deadline: .now() + operationTimeout) { [weak self] in
            self?.finishRefresh(
                id: refreshID,
                lifecycle: lifecycle,
                result: .noActiveMedia
            )
        }
    }

    private func finishRefresh(
        id: UInt64,
        lifecycle candidateLifecycle: MacRemoteMediaCommandGate.Lifecycle,
        result: MacNowPlayingRuntimeSnapshotResult
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard activeRefreshID == id,
              lifecycle == candidateLifecycle,
              gate.lifecycleIsCurrent(candidateLifecycle) else { return }
        activeRefreshID = nil
        switch result {
        case .snapshot(let snapshot):
            finishRefresh(snapshot: snapshot)
        case .noActiveMedia:
            publish(item: nil, snapshot: nil)
        case .retry:
            refreshPending = true
        }
        if refreshPending {
            refreshPending = false
            requestRefresh()
        }
    }

    private func finishRefresh(snapshot: MacNowPlayingRuntimeSnapshot) {
        let sourceName = Self.boundedString(
            snapshot.sourceName,
            maximumBytes: WebRTCRemoteMediaItem.maximumSourceNameBytes
        ) ?? "Mac media"
        guard let title = Self.boundedString(
            snapshot.metadata.title,
            maximumBytes: WebRTCRemoteMediaItem.maximumTitleBytes
        ) ?? (snapshot.sourceName == nil ? nil : sourceName) else {
            publish(item: nil, snapshot: nil)
            return
        }

        if snapshot.identityKey != currentIdentityKey {
            currentIdentityKey = snapshot.identityKey
            currentContextID = UUID().uuidString.lowercased()
        }
        guard let contextID = currentContextID else {
            publish(item: nil, snapshot: nil)
            return
        }

        let rate = min(max(snapshot.metadata.playbackRate, 0), 16)
        let duration = Self.validTime(snapshot.metadata.duration)
        var elapsed = Self.validTime(snapshot.metadata.elapsedTime)
        if rate > 0,
           let anchor = snapshot.metadata.timestamp,
           var anchoredElapsed = elapsed {
            let age = now().timeIntervalSince(anchor)
            if age.isFinite, age >= 0, age <= Self.maximumValidTime {
                anchoredElapsed += age * rate
                elapsed = duration.map { min(anchoredElapsed, $0) }
                    ?? Self.validTime(anchoredElapsed)
            }
        }
        let enabled = snapshot.enabledCommands
        let item = WebRTCRemoteMediaItem(
            contextID: contextID,
            sourceName: sourceName,
            title: title,
            artist: Self.boundedString(
                snapshot.metadata.artist,
                maximumBytes: WebRTCRemoteMediaItem.maximumArtistBytes
            ),
            album: Self.boundedString(
                snapshot.metadata.album,
                maximumBytes: WebRTCRemoteMediaItem.maximumAlbumBytes
            ),
            playbackState: rate > 0 ? .playing : .paused,
            elapsedTime: elapsed,
            duration: duration,
            playbackRate: rate,
            capabilities: WebRTCRemoteMediaCapabilities(
                canPlay: enabled.contains(CommandValue.play.rawValue),
                canPause: enabled.contains(CommandValue.pause.rawValue),
                canSkipForward: enabled.contains(CommandValue.nextTrack.rawValue),
                canSkipBackward: enabled.contains(CommandValue.previousTrack.rawValue)
            )
        )
        publish(item: item.isValid ? item : nil, snapshot: snapshot)
    }

    private func publish(
        item: WebRTCRemoteMediaItem?,
        snapshot: MacNowPlayingRuntimeSnapshot?
    ) {
        currentItem = item
        currentSnapshot = item == nil ? nil : snapshot
        currentContextID = item?.contextID
        if item == nil { currentIdentityKey = nil }
        gate.setContext(item?.contextID)
        guard !hasPublishedState || item != lastPublishedItem else { return }
        hasPublishedState = true
        lastPublishedItem = item
        revision &+= 1
        if revision == 0 { revision = 1 }
        onStateChanged?(
            WebRTCRemoteMediaStateUpdate(revision: revision, item: item)
        )
    }

    private static func validTime(_ value: Double?) -> Double? {
        guard let value,
              value.isFinite,
              value >= 0,
              value <= maximumValidTime else { return nil }
        return value
    }

    private static let maximumValidTime: TimeInterval = 31_536_000

    private static func boundedString(
        _ rawValue: String?,
        maximumBytes: Int
    ) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        var result = normalized
        while result.utf8.count > maximumBytes, !result.isEmpty {
            result.removeLast()
        }
        return result.isEmpty ? nil : result
    }
}
