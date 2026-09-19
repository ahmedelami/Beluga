import AudioToolbox
import CryptoKit
import Foundation

struct CoreAudioProcessTapCallbackProgress: Equatable, Sendable {
    var callbackCount: UInt64 = 0
    var frameCount: UInt64 = 0
    var firstCallbackHostTime: UInt64 = 0
    var latestCallbackHostTime: UInt64 = 0
}

/// Both mutation and snapshot reads belong to the source's serial PCM queue.
final class CoreAudioProcessTapCallbackCounter: @unchecked Sendable {
    private(set) var progress = CoreAudioProcessTapCallbackProgress()

    func recordValidCallback(frameCount: UInt32, hostTime: UInt64) {
        guard frameCount > 0 else { return }
        if progress.callbackCount == 0 {
            progress.firstCallbackHostTime = hostTime
        }
        progress.callbackCount &+= 1
        progress.frameCount &+= UInt64(frameCount)
        progress.latestCallbackHostTime = hostTime
    }
}

/// API return values never enter this tracker: only actual callback observations do.
struct CoreAudioProcessTapStartupProgressTracker {
    enum Event: String {
        case awaitingFirstCallback = "awaiting-first-callback"
        case firstValidCallback = "first-valid-callback"
        case callbacksAdvancing = "callbacks-advancing"
    }

    private var reportedWaiting = false
    private var firstObservation: CoreAudioProcessTapCallbackProgress?
    private(set) var didObserveAdvancement = false

    mutating func observe(_ progress: CoreAudioProcessTapCallbackProgress) -> Event? {
        guard !didObserveAdvancement else { return nil }
        guard progress.callbackCount > 0, progress.frameCount > 0 else {
            guard !reportedWaiting, firstObservation == nil else { return nil }
            reportedWaiting = true
            return .awaitingFirstCallback
        }
        guard let firstObservation else {
            self.firstObservation = progress
            return .firstValidCallback
        }
        guard progress.callbackCount > firstObservation.callbackCount,
              progress.frameCount > firstObservation.frameCount,
              progress.firstCallbackHostTime == firstObservation.firstCallbackHostTime,
              progress.latestCallbackHostTime > firstObservation.latestCallbackHostTime else {
            return nil
        }
        didObserveAdvancement = true
        return .callbacksAdvancing
    }
}

/// Immutable lifetime identity is shared; sampling state belongs to the control queue.
final class CoreAudioProcessTapStartupDiagnostics: @unchecked Sendable {
    let lifetimeID = UUID()
    let beganAtHostTime = AudioGetCurrentHostTime()
    let tapAutoStartRequested: Bool
    let callbacks = CoreAudioProcessTapCallbackCounter()
    private(set) var progressTracker = CoreAudioProcessTapStartupProgressTracker()
    private(set) var apiStartStatus: OSStatus?
    private(set) var isRetired = false
    var sampleIsPending = false

    init(tapAutoStartRequested: Bool) {
        self.tapAutoStartRequested = tapAutoStartRequested
    }

    static func clockUIDDiagnostic(_ uid: String) -> String {
        if uid == "BuiltInSpeakerDevice" { return uid }
        let digest = SHA256.hash(data: Data(uid.utf8))
        return "sha256:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func recordAPIStartResult(_ status: OSStatus) {
        guard !isRetired else { return }
        apiStartStatus = status
    }

    func observe(
        _ progress: CoreAudioProcessTapCallbackProgress,
        lifetimeID: UUID
    ) -> CoreAudioProcessTapStartupProgressTracker.Event? {
        guard !isRetired, lifetimeID == self.lifetimeID else { return nil }
        return progressTracker.observe(progress)
    }

    func retire() {
        isRetired = true
    }

    func elapsedMilliseconds(at hostTime: UInt64) -> UInt64 {
        guard hostTime >= beganAtHostTime else { return 0 }
        return AudioConvertHostTimeToNanos(hostTime - beganAtHostTime) / 1_000_000
    }
}
