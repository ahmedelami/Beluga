@preconcurrency import MediaPlayer
import UIKit
import WebRTCTransport

/// Minimal interface for borrowing iOS background time while a lifecycle transition settles.
/// Implementations must balance every successful begin with an end and must not treat the lease
/// as permission for indefinite background execution.
@MainActor
protocol TransitionBackgroundTaskCoordinating: AnyObject {
    func beginTransitionTask()
    func endTransitionTask()
}

/// A bounded iOS background-task lease for short state transitions that must finish atomically.
/// It does not grant continuous background execution and must never be used as a media lifetime.
@MainActor
final class AppTransitionBackgroundTaskCoordinator: TransitionBackgroundTaskCoordinating {
    private let name: String
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        self.name = name
    }

    func beginTransitionTask() {
        guard backgroundTask == .invalid else { return }

        let task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.endTransitionTask()
            }
        }
        guard task != .invalid else { return }
        backgroundTask = task
    }

    func endTransitionTask() {
        guard backgroundTask != .invalid else { return }

        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}

/// Thread-safe admission bridge used by MediaPlayer callbacks, which are not guaranteed to arrive
/// on the main actor. Authority is captured here, not reacquired after an actor hop.
struct RemoteMediaCommandDispatch: Sendable {
    let command: WebRTCRemoteMediaCommand
    let state: WebRTCReceivedRemoteMediaState
    let authorization: WebRTCControlAuthorization
}

typealias RemoteMediaCommandSender = @Sendable (RemoteMediaCommandDispatch) -> Void

/// Process-local authority for the one worldwide session allowed to mutate the process-global
/// MediaPlayer command center. A superseded view model can still drain delayed callbacks, but its
/// token can no longer replace metadata, reopen commands, or release a newer owner.
struct RemoteMediaCommandOwnerToken: Hashable, Sendable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

final class RemoteMediaCommandDispatchGate: @unchecked Sendable {

    private let lock = NSLock()
    private var owner: RemoteMediaCommandOwnerToken?
    private var state: WebRTCReceivedRemoteMediaState?
    private var authorization: WebRTCControlAuthorization?
    private var transportIsReady = false
    private var sender: RemoteMediaCommandSender?

    func claim(
        owner: RemoteMediaCommandOwnerToken,
        sender: @escaping RemoteMediaCommandSender
    ) {
        lock.withLock {
            authorization?.revoke()
            authorization = nil
            self.owner = owner
            self.state = nil
            self.transportIsReady = false
            self.sender = sender
        }
    }

    @discardableResult
    func release(owner: RemoteMediaCommandOwnerToken) -> Bool {
        lock.withLock {
            guard self.owner == owner else { return false }
            authorization?.revoke()
            authorization = nil
            self.owner = nil
            self.state = nil
            self.transportIsReady = false
            self.sender = nil
            return true
        }
    }

    @discardableResult
    func update(
        owner: RemoteMediaCommandOwnerToken,
        state: WebRTCReceivedRemoteMediaState?,
        transportIsReady: Bool
    ) -> Bool {
        lock.withLock {
            guard self.owner == owner else { return false }
            let samePresentation = self.state.map { previous in
                state.map {
                    previous.isSameNegotiation(as: $0)
                        && previous.update.item?.contextID == $0.update.item?.contextID
                        && previous.update.item?.capabilities == $0.update.item?.capabilities
                } ?? false
            } ?? false
            if !transportIsReady || !samePresentation || state?.update.item == nil {
                authorization?.revoke()
                authorization = nil
            }
            if transportIsReady, state?.update.item != nil, authorization == nil {
                authorization = WebRTCControlAuthorization()
            }
            self.state = state
            self.transportIsReady = transportIsReady
            return true
        }
    }

    func dispatch(_ command: WebRTCRemoteMediaCommand) -> Bool {
        let admitted: (RemoteMediaCommandSender, RemoteMediaCommandDispatch)? = lock.withLock {
            guard transportIsReady,
                  let state,
                  let item = state.update.item,
                  item.capabilities.permits(command),
                  state.update.revision > 0,
                  let authorization,
                  authorization.isValid,
                  let sender else { return nil }
            return (sender, RemoteMediaCommandDispatch(
                command: command,
                state: state,
                authorization: authorization
            ))
        }
        guard let admitted else { return false }
        admitted.0(admitted.1)
        return true
    }
}

/// Publishes lock-screen playback state, installs native media commands exactly once, and owns
/// transition-only background leases. Continuous background eligibility still comes from genuine
/// audio playout rather than this object.
@MainActor
final class BackgroundPlaybackCoordinator {
    static let shared = BackgroundPlaybackCoordinator()

    private let transitionTask = AppTransitionBackgroundTaskCoordinator(
        name: "opensteamerBackgroundPlayback"
    )
    private let commandGate = RemoteMediaCommandDispatchGate()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var remoteMediaCommandOwner: RemoteMediaCommandOwnerToken?
    private var remoteMediaState: WebRTCReceivedRemoteMediaState?
    private var remoteMediaUpdate: WebRTCRemoteMediaStateUpdate? { remoteMediaState?.update }
    private var remoteMediaTransportIsReady = false
    private var remoteMediaCommandSender: RemoteMediaCommandSender?
    private var genericPlayback: (serverName: String?, isPlaying: Bool)?

    private init() {
        installCommandTargetsIfNeeded()
        updateNativeCommandAvailability()
    }

    func beginTransitionTask() {
        // This is only transition grace; continuous background eligibility comes from active audio playback.
        transitionTask.beginTransitionTask()
    }

    func endTransitionTask() {
        transitionTask.endTransitionTask()
    }

    func publishLiveStream(serverName: String?, isPlaying: Bool) {
        genericPlayback = (serverName, isPlaying)
        guard remoteMediaUpdate?.item == nil else { return }
        publishGenericLiveStream(serverName: serverName, isPlaying: isPlaying)
    }

    func claimRemoteMediaCommandSender(
        _ sender: @escaping RemoteMediaCommandSender
    ) -> RemoteMediaCommandOwnerToken {
        let owner = RemoteMediaCommandOwnerToken()
        remoteMediaCommandOwner = owner
        remoteMediaState = nil
        remoteMediaTransportIsReady = false
        remoteMediaCommandSender = sender
        commandGate.claim(owner: owner, sender: sender)
        updateNativeCommandAvailability()
        if let genericPlayback {
            publishGenericLiveStream(
                serverName: genericPlayback.serverName,
                isPlaying: genericPlayback.isPlaying
            )
        } else {
            clearNowPlayingInfo()
        }
        return owner
    }

    func releaseRemoteMediaCommandSender(
        owner: RemoteMediaCommandOwnerToken
    ) {
        guard remoteMediaCommandOwner == owner else { return }
        remoteMediaCommandOwner = nil
        remoteMediaState = nil
        remoteMediaTransportIsReady = false
        remoteMediaCommandSender = nil
        _ = commandGate.release(owner: owner)
        updateNativeCommandAvailability()
        if let genericPlayback {
            publishGenericLiveStream(
                serverName: genericPlayback.serverName,
                isPlaying: genericPlayback.isPlaying
            )
        } else {
            clearNowPlayingInfo()
        }
    }

    func setRemoteMediaTransportReady(
        _ isReady: Bool,
        owner: RemoteMediaCommandOwnerToken
    ) {
        guard remoteMediaCommandOwner == owner else { return }
        remoteMediaTransportIsReady = isReady
        updateCommandGate()
        updateNativeCommandAvailability()
    }

    func publishRemoteMedia(
        _ state: WebRTCReceivedRemoteMediaState,
        owner: RemoteMediaCommandOwnerToken
    ) {
        let update = state.update
        guard remoteMediaCommandOwner == owner,
              update.isValid,
              update.revision > (remoteMediaUpdate?.revision ?? 0) else {
            return
        }
        remoteMediaState = state
        updateCommandGate()
        updateNativeCommandAvailability()

        guard let item = update.item else {
            if let genericPlayback {
                publishGenericLiveStream(
                    serverName: genericPlayback.serverName,
                    isPlaying: genericPlayback.isPlaying
                )
            } else {
                clearNowPlayingInfo()
            }
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist ?? item.sourceName,
            MPNowPlayingInfoPropertyExternalContentIdentifier: item.contextID,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyPlaybackRate: item.playbackRate
        ]
        if let album = item.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let elapsedTime = item.elapsedTime {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        }
        if let duration = item.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = switch item.playbackState {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        }
    }

    func clearRemoteMedia(owner: RemoteMediaCommandOwnerToken) {
        guard remoteMediaCommandOwner == owner else { return }
        remoteMediaState = nil
        remoteMediaTransportIsReady = false
        updateCommandGate()
        updateNativeCommandAvailability()
        if let genericPlayback {
            publishGenericLiveStream(
                serverName: genericPlayback.serverName,
                isPlaying: genericPlayback.isPlaying
            )
        } else {
            clearNowPlayingInfo()
        }
    }

    private func publishGenericLiveStream(serverName: String?, isPlaying: Bool) {
        // Lock-screen metadata is visible outside the unlocked app. Keep it deliberately generic
        // rather than exposing the paired Mac's user-assigned name.
        _ = serverName
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "opensteamer",
            MPMediaItemPropertyArtist: "Connected Mac",
            MPMediaItemPropertyAlbumTitle: "Mac audio stream",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        genericPlayback = nil
        if remoteMediaUpdate?.item == nil { clearNowPlayingInfo() }
        endTransitionTask()
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func installCommandTargetsIfNeeded() {
        guard commandTargets.isEmpty else { return }
        let mappings: [(MPRemoteCommand, WebRTCRemoteMediaCommand)] = [
            (commandCenter.playCommand, .play),
            (commandCenter.pauseCommand, .pause),
            (commandCenter.nextTrackCommand, .nextTrack),
            (commandCenter.previousTrackCommand, .previousTrack)
        ]
        for (nativeCommand, command) in mappings {
            let gate = commandGate
            let target = nativeCommand.addTarget { _ in
                gate.dispatch(command) ? .success : .commandFailed
            }
            commandTargets.append((nativeCommand, target))
        }
        // These controls have no negotiated Mac-side semantic and must never appear as no-op UI.
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenter.changeRepeatModeCommand.isEnabled = false
        commandCenter.changeShuffleModeCommand.isEnabled = false
        commandCenter.enableLanguageOptionCommand.isEnabled = false
        commandCenter.disableLanguageOptionCommand.isEnabled = false
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false
        commandCenter.bookmarkCommand.isEnabled = false
    }

    private func updateCommandGate() {
        guard let remoteMediaCommandOwner else { return }
        commandGate.update(
            owner: remoteMediaCommandOwner,
            state: remoteMediaState,
            transportIsReady: remoteMediaTransportIsReady
        )
    }

    private func updateNativeCommandAvailability() {
        let capabilities = remoteMediaUpdate?.item?.capabilities
        let ready = remoteMediaTransportIsReady && remoteMediaCommandSender != nil
        commandCenter.playCommand.isEnabled = ready && (capabilities?.canPlay ?? false)
        commandCenter.pauseCommand.isEnabled = ready && (capabilities?.canPause ?? false)
        commandCenter.nextTrackCommand.isEnabled =
            ready && (capabilities?.canSkipForward ?? false)
        commandCenter.previousTrackCommand.isEnabled =
            ready && (capabilities?.canSkipBackward ?? false)
    }
}

extension BackgroundPlaybackCoordinator: TransitionBackgroundTaskCoordinating {}
