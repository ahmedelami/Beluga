import Foundation
import WebRTCTransport

final class MacChromeNowPlayingRuntime: MacSystemNowPlayingRuntime, @unchecked Sendable {
    private let backend: any MacChromeNowPlayingBackend
    private let queue: DispatchQueue
    private let permissionQueue = DispatchQueue(label: "com.elamin.opensteamer.chrome-permission", qos: .userInitiated)
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var fetchPending = false
    private var commandPending = false
    private var permissionPending = false
    private var relativeConsumed = false
    private var current: (player: MacChromePlayerSnapshot, token: MacNowPlayingClientToken)?
    // Selection only: an uncertain read always retires current command authority.
    private var selectionHint: MacChromePlayerSnapshot?
    private var discoveryStatus: MacChromeDiscoveryStatus = .idle
    var isAvailable: Bool { true }
    var lastDiscoveryStatus: MacChromeDiscoveryStatus { lock.withLock { discoveryStatus } }

    init(backend: any MacChromeNowPlayingBackend = MacChromeAppleEventsBackend(),
         queue: DispatchQueue = DispatchQueue(label: "com.elamin.opensteamer.chrome-events", qos: .utility),
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend; self.queue = queue; self.now = now
    }

    func fetchSnapshot(completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void) {
        let admitted = lock.withLock { () -> UInt64? in
            guard !fetchPending else { return nil }
            fetchPending = true
            return epoch
        }
        guard let admitted else { completion(.retry); return }
        let deadline = now() + 1.5
        queue.async { [self] in
            let preferred = lock.withLock { selectionHint }
            var selected: MacChromePlayerSnapshot?
            var failure: Error?
            do {
                guard lock.withLock({ epoch == admitted }), now() < deadline else {
                    throw MacChromeBackendError.timedOut
                }
                selected = try MacChromeAppleEventsBackend.select(backend.readSnapshots(deadline: deadline),
                                                                  preferred: preferred)
                guard now() < deadline else { throw MacChromeBackendError.timedOut }
            } catch { failure = error }
            let result: MacNowPlayingRuntimeSnapshotResult = lock.withLock {
                fetchPending = false
                guard epoch == admitted else { return .retry }
                if let failure {
                    epoch &+= 1; current = nil; relativeConsumed = false
                    if failure as? MacChromeBackendError != .timedOut { selectionHint = nil }
                    discoveryStatus = MacChromeDiscoveryStatus(error: failure)
                    // Unknown browser state must revoke its commands without choosing another tab.
                    return .retry
                }
                guard let selected, let metadata = Self.metadata(selected) else {
                    epoch &+= 1; current = nil; selectionHint = nil; relativeConsumed = false
                    discoveryStatus = selected == nil ? .noPlayer : .invalidData
                    return .noActiveMedia
                }
                let token: MacNowPlayingClientToken
                if let current, current.player.hasSameItem(as: selected), !relativeConsumed || commandPending {
                    token = current.token
                } else {
                    epoch &+= 1
                    token = MacNowPlayingClientToken(object: NSObject(), clientIdentity: "chrome:" + UUID().uuidString)
                }
                if !commandPending || current?.player.hasSameItem(as: selected) != true { relativeConsumed = false }
                current = (selected, token); selectionHint = selected; discoveryStatus = .available
                return .snapshot(.init(client: token, sourceName: "YouTube", metadata: metadata,
                                       enabledCommands: selected.media.enabledCommands))
            }
            completion(result)
        }
    }

    /// Explicit host onboarding only; ordinary polling never requests consent.
    func requestAutomationPermission(completion: @escaping @Sendable (Bool) -> Void) {
        let admitted = lock.withLock { () -> UInt64? in
            guard !permissionPending else { return nil }
            permissionPending = true
            return lifecycle
        }
        guard let admitted else { completion(false); return }
        permissionQueue.async { [self] in
            var success = false
            if lock.withLock({ lifecycle == admitted }) {
                do { try backend.requestAutomationPermission(); success = true } catch {}
            }
            let accepted = lock.withLock {
                permissionPending = false
                return success && lifecycle == admitted
            }
            completion(accepted)
        }
    }

    func send(rawCommand: Int, snapshot: MacNowPlayingRuntimeSnapshot,
              isAuthorized: @escaping @Sendable () -> Bool,
              completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void) {
        guard let command = MacChromeCommand(rawValue: rawCommand),
              snapshot.enabledCommands.contains(rawCommand) else { completion(.unsupported); return }
        guard isAuthorized() else { completion(.staleContext); return }
        let admission = lock.withLock { () -> (MacChromePlayerSnapshot, UInt64)? in
            guard !commandPending, !relativeConsumed, let current, current.token === snapshot.client,
                  Self.metadata(current.player)?.identityComponent == snapshot.metadata.identityComponent else { return nil }
            commandPending = true
            if command.isRelative { relativeConsumed = true }
            return (current.player, epoch)
        }
        guard let (expected, admitted) = admission else { completion(.staleContext); return }
        let deadline = min(now() + 1.5, expected.receivedAtUptime + MacChromeAppleEventsBackend.maximumSnapshotAge)
        let authorized: @Sendable () -> Bool = { [weak self] in
            guard let self, isAuthorized() else { return false }
            return self.lock.withLock {
                self.epoch == admitted && self.current?.token === snapshot.client
                    && self.current?.player.hasSameItem(as: expected) == true
            }
        }
        queue.async { [self] in
            let result: WebRTCRemoteMediaCommandResult
            if !authorized() || now() >= deadline { result = .staleContext }
            else {
                do { result = try backend.send(command, expected: expected, deadline: deadline, isAuthorized: authorized) }
                catch { result = error as? MacChromeBackendError == .staleItem ? .staleContext : .failed }
            }
            lock.withLock { commandPending = false }
            completion(result)
        }
    }

    func stop() {
        lock.withLock {
            epoch &+= 1; lifecycle &+= 1; current = nil; selectionHint = nil; relativeConsumed = false; discoveryStatus = .idle
        }
    }

    static func metadata(_ snapshot: MacChromePlayerSnapshot) -> MacNowPlayingMetadata? {
        let media = snapshot.media
        guard snapshot.tab.owner.processID > 0, snapshot.tab.owner.launchDate.timeIntervalSince1970.isFinite,
              UUID(uuidString: media.documentID) != nil, UUID(uuidString: media.itemID) != nil,
              media.itemGeneration > 0, media.itemGeneration <= 9_007_199_254_740_991,
              media.playbackRate.isFinite, (0...16).contains(media.playbackRate),
              MacChromeAppleEventsBackend.videoID(from: "https://www.youtube.com/watch?v=" + media.videoID) == media.videoID,
              media.observedAtUnixMilliseconds.isFinite,
              let title = boundedText(media.title, maximum: WebRTCRemoteMediaItem.maximumTitleBytes) else { return nil }
        let duration = validTime(media.duration).flatMap { $0 > 0 ? $0 : nil }
        let elapsed = validTime(media.elapsedTime).map { min($0, duration ?? $0) }
        return .init(title: title, artist: boundedText(media.artist, maximum: WebRTCRemoteMediaItem.maximumArtistBytes),
                     album: nil, duration: duration, elapsedTime: elapsed,
                     playbackRate: media.paused ? 0 : media.playbackRate,
                     timestamp: Date(timeIntervalSince1970: media.observedAtUnixMilliseconds / 1000),
                     contentIdentifier: media.itemID + ":" + String(media.itemGeneration),
                     uniqueIdentifier: nil)
    }

    private static func boundedText(_ value: String?, maximum: Int) -> String? {
        guard let value, value.utf8.count <= 8_192 else { return nil }
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var result = ""
        for character in String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines) {
            guard result.utf8.count + character.utf8.count <= maximum else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    private static func validTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 31_536_000 else { return nil }
        return value
    }
}
