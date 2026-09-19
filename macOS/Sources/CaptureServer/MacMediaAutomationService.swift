import Foundation

/// Consent IPC lives for the host process, independently of a media peer or browser extension.
final class MacMediaAutomationService: @unchecked Sendable {
    private let bridge: any MacSystemNowPlayingRuntime
    private let lock = NSLock()
    private let retryInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.elamin.opensteamer.media-onboarding", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var generation: UUID?

    convenience init() {
        let chrome = MacChromeNowPlayingRuntime()
        let music = MacMusicNowPlayingRuntime()
        let bridge = MacBrowserNowPlayingRuntime(acceptsMediaStates: false,
            chromePermissionRequest: { completion in chrome.requestAutomationPermission(completion: completion) },
            permissionRequest: { completion in music.requestAutomationPermission(completion: completion) })
        self.init(bridge: bridge)
    }

    init(bridge: any MacSystemNowPlayingRuntime, retryInterval: TimeInterval = 10) {
        self.bridge = bridge
        self.retryInterval = retryInterval.isFinite && retryInterval > 0 ? retryInterval : 10
    }
    func start() {
        lock.withLock {
            guard timer == nil else { return }
            let id = UUID()
            generation = id
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    guard self.generation == id else { return }
                    self.bridge.fetchSnapshot { _ in }
                }
            }
            self.timer = timer
            timer.resume()
            bridge.fetchSnapshot { _ in }
        }
    }
    func stop() {
        lock.withLock {
            generation = nil
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            bridge.stop()
        }
    }
    deinit { stop() }
}
