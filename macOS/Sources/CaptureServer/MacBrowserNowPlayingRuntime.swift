import Darwin
import Foundation
import MediaBridgeCore
import Security
import WebRTCTransport

final class BrowserBridgeConnection: @unchecked Sendable {
    let id = UUID()
    let token: MacNowPlayingClientToken
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
        token = MacNowPlayingClientToken(object: NSObject(), clientIdentity: "browser:" + id.uuidString)
    }

    @discardableResult
    func send(_ data: Data, isAdmitted: @Sendable () -> Bool = { true }) throws -> Bool {
        try lock.withLock {
            guard fd >= 0 else { throw MediaBridgeError.closed }
            guard isAdmitted() else { return false }
            try MediaBridgeFraming.writeFrame(fd, data: data)
            return true
        }
    }

    func close() {
        lock.withLock {
            guard fd >= 0 else { return }
            _ = shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }

    func duplicateForReader() -> Int32 {
        lock.withLock {
            guard fd >= 0 else { return -1 }
            let result = dup(fd)
            guard result >= 0 else { return -1 }
            guard fcntl(result, F_SETFD, FD_CLOEXEC) == 0 else {
                Darwin.close(result)
                return -1
            }
            return result
        }
    }
}

/// Local IPC is separate from media capture: bounded JSON, no listener on the
/// network, and only the same user's independently signed bridge may connect.
final class MacBrowserNowPlayingRuntime: MacSystemNowPlayingRuntime, @unchecked Sendable {
    private struct Source {
        let connection: BrowserBridgeConnection
        var revision: UInt64 = 0
        var item: BrowserMediaItem?
        var observedAt: TimeInterval = 0
        var timestamp = Date()
        var lastPlayedOrder: UInt64 = 0
    }
    private struct Pending {
        let connectionID: UUID
        let contextID: String
        let authorized: @Sendable () -> Bool
        let completion: @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    }
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var directoryLock: Int32 = -1
    private var sources: [UUID: Source] = [:]
    private var pending: [String: Pending] = [:]
    private var started = false
    private var epoch: UInt64 = 0
    private var selectedID: UUID?
    private var permissionPending: (connection: UUID, request: String)?
    private var permissionIDs: [UUID: Set<String>] = [:]
    private var activityOrder: UInt64 = 0
    private var lastStartAttempt: TimeInterval = -.infinity
    private let permissionRequest: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    private let now: @Sendable () -> TimeInterval
    private let peerIsTrusted: @Sendable (Int32) -> Bool
    private let socketPath: String
    private let commandQueue: DispatchQueue

    var isAvailable: Bool { true }

    init(
        socketPath: String = MediaBridgeSocket.path,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        peerIsTrusted: @escaping @Sendable (Int32) -> Bool = MacBrowserNowPlayingRuntime.trustedHelper,
        commandQueue: DispatchQueue = .global(qos: .utility),
        permissionRequest: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) {
        self.socketPath = socketPath
        self.now = now
        self.peerIsTrusted = peerIsTrusted
        self.permissionRequest = permissionRequest
        self.commandQueue = commandQueue
    }

    deinit { stop() }

    func fetchSnapshot(completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void) {
        startIfNeeded()
        let result: MacNowPlayingRuntimeSnapshotResult = lock.withLock {
            let fresh = sources.values.filter { now() - $0.observedAt <= 3.5 && $0.item != nil }
            let playing = fresh.filter { $0.item?.playbackState == "playing" }
            let candidates = playing.isEmpty ? fresh : playing
            let selected = playing.isEmpty
                ? (candidates.first { $0.connection.id == selectedID }
                    ?? candidates.sorted { $0.connection.id.uuidString < $1.connection.id.uuidString }.first)
                : candidates.sorted { $0.lastPlayedOrder > $1.lastPlayedOrder }.first
            selectedID = selected?.connection.id
            guard let source = selected, let item = source.item else { return .noActiveMedia }
            return .snapshot(Self.snapshot(item, source: source))
        }
        completion(result)
    }

    func send(
        rawCommand: Int, snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    ) {
        let names = [0: "play", 1: "pause", 4: "skipForward", 5: "skipBackward"]
        guard let name = names[rawCommand] else { completion(.unsupported); return }
        let id = UUID().uuidString
        let target: BrowserBridgeConnection? = lock.withLock {
            guard pending.count < 4, isAuthorized(),
                  let source = sources.values.first(where: { $0.connection.token === snapshot.client }),
                  source.connection.id == selectedID,
                  now() - source.observedAt <= 3.5, let item = source.item,
                  item.contextID == snapshot.metadata.contentIdentifier,
                  Self.commands(item).contains(rawCommand) else { return nil }
            pending[id] = Pending(connectionID: source.connection.id, contextID: item.contextID,
                authorized: isAuthorized, completion: completion)
            return source.connection
        }
        guard let target, let context = snapshot.metadata.contentIdentifier else {
            completion(.staleContext); return
        }
        let command = BrowserMediaCommand(id: id, contextID: context, command: name)
        let sendDeadline = now() + 1
        // Dedicated utility work avoids blocking the audio or control actor on IPC.
        commandQueue.async { [weak self] in
            guard let self else { return }
            guard self.now() < sendDeadline, isAuthorized(), self.stillAdmits(id) else {
                self.finish(id, result: .staleContext); return
            }
            do {
                let data = try MediaBridgeProtocol.encode(command)
                guard self.now() < sendDeadline, isAuthorized(), self.stillAdmits(id) else {
                    self.finish(id, result: .staleContext); return
                }
                let sent = try target.send(data) { [weak self] in
                    guard let self else { return false }
                    return self.now() < sendDeadline && isAuthorized() && self.stillAdmits(id)
                }
                if !sent { self.finish(id, result: .staleContext) }
            } catch { self.finish(id, result: .failed) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finish(id, result: .failed)
        }
    }

    func stop() {
        let removed = lock.withLock { () -> ([BrowserBridgeConnection], [Pending], Int32, Int32) in
            epoch &+= 1
            let value = (sources.values.map(\.connection), Array(pending.values), listener, directoryLock)
            sources.removeAll(); pending.removeAll(); selectedID = nil
            listener = -1; directoryLock = -1; started = false
            permissionPending = nil; permissionIDs.removeAll()
            return value
        }
        if removed.2 >= 0 { _ = shutdown(removed.2, SHUT_RDWR); Darwin.close(removed.2) }
        removed.0.forEach { $0.close() }
        removed.1.forEach { $0.completion(.staleContext) }
        if removed.3 >= 0 { _ = flock(removed.3, LOCK_UN); Darwin.close(removed.3) }
    }

    private func stillAdmits(_ id: String) -> Bool {
        lock.withLock {
            guard let request = pending[id], request.authorized(),
                  let source = sources[request.connectionID], selectedID == request.connectionID,
                  now() - source.observedAt <= 3.5,
                  source.item?.contextID == request.contextID else { return false }
            return true
        }
    }

    private func finish(_ id: String, result: WebRTCRemoteMediaCommandResult) {
        let value = lock.withLock { pending.removeValue(forKey: id) }
        if let value { value.completion(value.authorized() ? result : .staleContext) }
    }

    private static func commands(_ item: BrowserMediaItem) -> Set<Int> {
        Set([(0, item.canPlay), (1, item.canPause), (4, item.canSkipForward), (5, item.canSkipBackward)]
            .filter(\.1).map(\.0))
    }

    private static func snapshot(_ item: BrowserMediaItem, source: Source) -> MacNowPlayingRuntimeSnapshot {
        MacNowPlayingRuntimeSnapshot(client: source.connection.token, sourceName: item.sourceName,
            metadata: MacNowPlayingMetadata(title: item.title, artist: item.artist, album: nil,
                duration: item.duration, elapsedTime: item.elapsedTime,
                playbackRate: item.playbackState == "playing" ? item.playbackRate : 0,
                timestamp: source.timestamp, contentIdentifier: item.contextID, uniqueIdentifier: nil),
            enabledCommands: commands(item))
    }

    private func startIfNeeded() {
        let generation: UInt64? = lock.withLock {
            guard !started, now() - lastStartAttempt >= 10 else { return nil }
            started = true; lastStartAttempt = now(); epoch &+= 1
            return epoch
        }
        guard let generation else { return }
        do {
            let handles = try Self.listen(path: socketPath)
            let acceptFD = dup(handles.listener)
            guard acceptFD >= 0 else {
                Darwin.close(handles.listener); Darwin.close(handles.lock)
                throw MediaBridgeError.unavailable
            }
            guard fcntl(acceptFD, F_SETFD, FD_CLOEXEC) == 0 else {
                Darwin.close(acceptFD); Darwin.close(handles.listener); Darwin.close(handles.lock)
                throw MediaBridgeError.unavailable
            }
            let admitted = lock.withLock {
                guard started, epoch == generation else { return false }
                listener = handles.listener; directoryLock = handles.lock
                return true
            }
            guard admitted else {
                Darwin.close(acceptFD); Darwin.close(handles.listener); Darwin.close(handles.lock)
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { Darwin.close(acceptFD) }
                while let self, self.lock.withLock({ self.epoch == generation && self.listener == handles.listener }) {
                    var descriptor = pollfd(fd: acceptFD, events: Int16(POLLIN), revents: 0)
                    guard poll(&descriptor, 1, 1000) > 0 else { continue }
                    let client = accept(acceptFD, nil, nil)
                    guard client >= 0 else { continue }
                    guard MediaBridgeSocket.configure(client), self.peerIsTrusted(client) else {
                        Darwin.close(client); continue
                    }
                    let connection = BrowserBridgeConnection(fd: client)
                    let accepted = self.lock.withLock {
                        guard self.epoch == generation, self.sources.count < 4 else { return false }
                        self.sources[connection.id] = Source(connection: connection)
                        return true
                    }
                    guard accepted else { connection.close(); continue }
                    let readFD = connection.duplicateForReader()
                    guard readFD >= 0 else { self.retire(connection); continue }
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        defer { Darwin.close(readFD) }
                        do {
                            while let data = try MediaBridgeFraming.readFrame(readFD, idleTimeout: 3.5) {
                                guard let self else { break }
                                try self.receive(data, from: connection)
                            }
                        } catch { /* Retire, never repair/replay a closed channel. */ }
                        self?.retire(connection)
                    }
                }
            }
        } catch { lock.withLock { if epoch == generation { started = false } } }
    }

    private func receive(_ data: Data, from connection: BrowserBridgeConnection) throws {
        switch try MediaBridgeProtocol.decode(data) {
        case .state(let state):
            try lock.withLock {
                guard var source = sources[connection.id], state.revision > source.revision else {
                    throw MediaBridgeError.invalidMessage
                }
                if state.item?.playbackState == "playing",
                   source.item?.playbackState != "playing" || source.item?.contextID != state.item?.contextID {
                    activityOrder &+= 1; source.lastPlayedOrder = activityOrder
                }
                source.revision = state.revision; source.item = state.item
                source.observedAt = now(); source.timestamp = Date()
                sources[connection.id] = source
            }
        case .result(let result):
            let current = lock.withLock {
                pending[result.id]?.connectionID == connection.id
                    && pending[result.id]?.contextID == result.contextID
            }
            guard current else { return }
            let mapped = WebRTCRemoteMediaCommandResult(rawValue: result.result.rawValue) ?? .failed
            finish(result.id, result: mapped == .applied && !stillAdmits(result.id) ? .staleContext : mapped)
        case .authorizeMusic(let request):
            let admitted = lock.withLock {
                guard sources[connection.id] != nil, permissionPending == nil,
                      (permissionIDs[connection.id]?.count ?? 0) < 16,
                      permissionIDs[connection.id, default: []].insert(request.id).inserted else { return false }
                permissionPending = (connection.id, request.id)
                return true
            }
            guard admitted else {
                try connection.send(MediaBridgeProtocol.encode(MediaAuthorizationResult(id: request.id, result: "unavailable")))
                return
            }
            permissionRequest { [weak self] allowed in
                self?.finishPermission(connection, id: request.id, result: allowed ? "authorized" : "denied")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.finishPermission(connection, id: request.id, result: "unavailable")
            }
        }
    }

    private func finishPermission(_ connection: BrowserBridgeConnection, id: String, result: String) {
        let current = lock.withLock {
            guard permissionPending?.connection == connection.id,
                  permissionPending?.request == id else { return false }
            permissionPending = nil
            return sources[connection.id] != nil
        }
        if current, let response = try? MediaBridgeProtocol.encode(MediaAuthorizationResult(id: id, result: result)) {
            try? connection.send(response)
        }
    }

    private func retire(_ connection: BrowserBridgeConnection) {
        let abandoned = lock.withLock { () -> [Pending] in
            sources.removeValue(forKey: connection.id)
            permissionIDs.removeValue(forKey: connection.id)
            if permissionPending?.connection == connection.id { permissionPending = nil }
            let ids = pending.filter { $0.value.connectionID == connection.id }.map(\.key)
            return ids.compactMap { pending.removeValue(forKey: $0) }
        }
        connection.close()
        abandoned.forEach { $0.completion(.staleContext) }
    }

    private static func listen(path: String) throws -> (listener: Int32, lock: Int32) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        try MediaBridgeSocket.validateDirectory(directory)
        let lockFD = open(directory.appendingPathComponent("owner.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw MediaBridgeError.unavailable }
        var fd: Int32 = -1
        do {
            var lockInfo = stat()
            guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(),
                  lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o777 == 0o600,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw MediaBridgeError.unavailable }
            var prior = stat()
            if lstat(path, &prior) == 0 {
                guard prior.st_uid == getuid(), prior.st_mode & S_IFMT == S_IFSOCK,
                      prior.st_mode & 0o777 == 0o600 else { throw MediaBridgeError.invalidPath }
                if let existing = try? MediaBridgeSocket.connect(path: path) {
                    Darwin.close(existing); throw MediaBridgeError.unavailable
                }
                guard unlink(path) == 0 else { throw MediaBridgeError.unavailable }
            } else if errno != ENOENT { throw MediaBridgeError.invalidPath }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MediaBridgeError.unavailable }
            var address = try MediaBridgeSocket.address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
                throw MediaBridgeError.unavailable
            }
            guard MediaBridgeSocket.configure(fd) else { throw MediaBridgeError.unavailable }
            return (fd, lockFD)
        } catch { if fd >= 0 { Darwin.close(fd) }; Darwin.close(lockFD); throw error }
    }

    private static func trustedHelper(_ fd: Int32) -> Bool {
        guard MediaBridgeSocket.sameUser(fd) else { return false }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return false }
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        let text = "identifier \"org.example.opensteamer.MediaBridge\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
