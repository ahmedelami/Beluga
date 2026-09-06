import Foundation
import WebRTCTransport

private final class MacSupportedSnapshotJoin: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Int: MacNowPlayingRuntimeSnapshotResult] = [:]
    private var completed = false
    private let completion: @Sendable ([Int: MacNowPlayingRuntimeSnapshotResult]) -> Void
    init(_ completion: @escaping @Sendable ([Int: MacNowPlayingRuntimeSnapshotResult]) -> Void) {
        self.completion = completion
    }
    func receive(_ value: MacNowPlayingRuntimeSnapshotResult, source: Int) {
        let ready = lock.withLock { () -> [Int: MacNowPlayingRuntimeSnapshotResult]? in
            guard !completed, results[source] == nil else { return nil }
            results[source] = value
            guard results.count == 2 else { return nil }
            completed = true
            return results
        }
        if let ready { completion(ready) }
    }
}

/// Arbitrates only explicitly supported players. This is not macOS's private
/// global owner: a newly playing source wins, with sticky selection while paused.
final class MacSupportedNowPlayingRuntime: MacSystemNowPlayingRuntime, @unchecked Sendable {
    private let browser: any MacSystemNowPlayingRuntime
    private let music: any MacSystemNowPlayingRuntime
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var selected: Int?
    private var identity: String?
    private var wasPlaying: [Int: Bool] = [:]
    private var lastDiagnostics: String?
    private var lastReport = -Double.infinity
    private let diagnostics: @Sendable (String) -> Void
    var isAvailable: Bool { browser.isAvailable || music.isAvailable }

    convenience init() {
        let music = MacMusicNowPlayingRuntime()
        let browser = MacBrowserNowPlayingRuntime { completion in
            music.requestAutomationPermission(completion: completion)
        }
        self.init(browser: browser, music: music) { message in
            print("now-playing-integration " + message)
        }
    }

    init(browser: any MacSystemNowPlayingRuntime, music: any MacSystemNowPlayingRuntime,
         diagnostics: @escaping @Sendable (String) -> Void = { _ in }) {
        self.browser = browser; self.music = music; self.diagnostics = diagnostics
    }

    func fetchSnapshot(completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void) {
        let generation = lock.withLock { epoch &+= 1; return epoch }
        let join = MacSupportedSnapshotJoin { [weak self] results in
            guard let self else { completion(.noActiveMedia); return }
            var report: String?
            let result: MacNowPlayingRuntimeSnapshotResult = self.lock.withLock {
                guard self.epoch == generation else { return .retry }
                // An indeterminate read must not transfer command authority to
                // another player or resurrect a previous selection.
                if results.values.contains(where: { if case .retry = $0 { return true }; return false }) {
                    return .retry
                }
                var available: [Int: MacNowPlayingRuntimeSnapshot] = [:]
                for (key, result) in results {
                    if case .snapshot(let value) = result { available[key] = value }
                }
                let playing = available.keys.filter { available[$0]!.metadata.playbackRate > 0 }.sorted()
                let beganPlaying = playing.filter { self.wasPlaying[$0] != true }
                let chosen: Int?
                if let began = beganPlaying.first { chosen = began }
                else if let selected = self.selected, playing.contains(selected) { chosen = selected }
                else if let first = playing.first { chosen = first }
                else if let selected = self.selected, available[selected] != nil { chosen = selected }
                else { chosen = available.keys.sorted().first }
                self.wasPlaying = [0: playing.contains(0), 1: playing.contains(1)]
                let snapshot = chosen.flatMap { available[$0] }
                if self.selected != chosen || self.identity != snapshot?.identityKey {
                    self.lifecycle &+= 1
                }
                self.selected = chosen
                self.identity = snapshot?.identityKey
                let summary = "source=\(chosen.map { $0 == 0 ? "youtube" : "music" } ?? "none") "
                    + "item=\(snapshot != nil) title=\(snapshot?.metadata.title != nil) "
                    + "duration=\(snapshot?.metadata.duration != nil) elapsed=\(snapshot?.metadata.elapsedTime != nil) "
                    + "playing=\((snapshot?.metadata.playbackRate ?? 0) > 0) "
                    + "commands=\(snapshot?.enabledCommands.sorted().map(String.init).joined(separator: ",") ?? "none") "
                    + "music=\((self.music as? MacMusicNowPlayingRuntime)?.lastDiscoveryStatus.rawValue ?? "adapter")"
                let now = ProcessInfo.processInfo.systemUptime
                if summary != self.lastDiagnostics || now - self.lastReport >= 15 {
                    self.lastDiagnostics = summary; self.lastReport = now; report = summary
                }
                return snapshot.map(MacNowPlayingRuntimeSnapshotResult.snapshot) ?? .noActiveMedia
            }
            if let report { self.diagnostics(report) }
            completion(result)
        }
        browser.fetchSnapshot { join.receive($0, source: 0) }
        music.fetchSnapshot { join.receive($0, source: 1) }
    }

    func send(rawCommand: Int, snapshot: MacNowPlayingRuntimeSnapshot,
              isAuthorized: @escaping @Sendable () -> Bool,
              completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void) {
        let admission = lock.withLock { (identity == snapshot.identityKey ? selected : nil, lifecycle) }
        guard let source = admission.0, isAuthorized() else { completion(.staleContext); return }
        let runtime = source == 0 ? browser : music
        runtime.send(rawCommand: rawCommand, snapshot: snapshot, isAuthorized: { [weak self] in
            guard let self, isAuthorized() else { return false }
            return self.lock.withLock {
                self.lifecycle == admission.1 && self.selected == source && self.identity == snapshot.identityKey
            }
        }, completion: completion)
    }

    func stop() {
        lock.withLock { epoch &+= 1; lifecycle &+= 1; selected = nil; identity = nil; wasPlaying.removeAll() }
        browser.stop(); music.stop()
    }
}
