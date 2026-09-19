import Foundation

/// One process-wide slot remains occupied until the actual read returns, even after timeout.
/// A stuck system getter cannot accumulate a task/queue per heartbeat or replacement peer.
final class WebRTCAudioDiagnosticsReadCoordinator: @unchecked Sendable {
    static let process = WebRTCAudioDiagnosticsReadCoordinator()
    let queue = DispatchQueue(label: "opensteamer.audio-diagnostics.read", qos: .utility)
    let deadlines = DispatchQueue(label: "opensteamer.audio-diagnostics.deadline", qos: .utility)
    private let lock = NSLock()
    private var active: UUID?
    private var lastStarted: TimeInterval?
    private let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 1) { self.minimumInterval = minimumInterval }

    func begin() -> UUID? {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard active == nil, lastStarted.map({ now - $0 >= minimumInterval }) ?? true else { return nil }
            let id = UUID()
            active = id
            lastStarted = now
            return id
        }
    }

    func finish(_ id: UUID) {
        lock.withLock { if active == id { active = nil } }
    }
}

private final class AudioDiagnosticsReadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebRTCAudioClientNativeSnapshot?, Never>?
    private var timer: (any DispatchSourceTimer)?

    init(_ continuation: CheckedContinuation<WebRTCAudioClientNativeSnapshot?, Never>) {
        self.continuation = continuation
    }

    func arm(on queue: DispatchQueue, timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [self] in complete(nil) }
        timer.schedule(deadline: .now() + timeout)
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func complete(_ result: WebRTCAudioClientNativeSnapshot?) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<WebRTCAudioClientNativeSnapshot?, Never>?, (any DispatchSourceTimer)?
        ) in
            let pending = (continuation, timer)
            continuation = nil
            timer = nil
            return pending
        }
        pending.1?.cancel()
        pending.0?.resume(returning: result)
    }
}

/// Immutable read operation plus lock-protected retirement. No native read holds the owner lock.
/// The only unchecked boundary is the native device's explicitly concurrent-safe POD getter.
final class WebRTCAudioDiagnosticsSampler: @unchecked Sendable {
    private let coordinator: WebRTCAudioDiagnosticsReadCoordinator
    private let timeout: TimeInterval
    private let readOperation: @Sendable () -> WebRTCAudioClientNativeSnapshot?
    private let lock = NSLock()
    private var retired = false

    init(coordinator: WebRTCAudioDiagnosticsReadCoordinator = .process,
         timeout: TimeInterval = 0.25,
         read: @escaping @Sendable () -> WebRTCAudioClientNativeSnapshot?) {
        self.coordinator = coordinator
        self.timeout = timeout
        readOperation = read
    }

    func invalidate() { lock.withLock { retired = true } }

    func sample() async -> WebRTCAudioClientNativeSnapshot? {
        guard !Task.isCancelled, lock.withLock({ !retired }),
              let request = coordinator.begin() else { return nil }
        return await withCheckedContinuation { continuation in
            let completion = AudioDiagnosticsReadCompletion(continuation)
            completion.arm(on: coordinator.deadlines, timeout: timeout)
            coordinator.queue.async { [self] in
                defer { coordinator.finish(request) }
                let value = lock.withLock({ !retired }) ? autoreleasepool(invoking: readOperation) : nil
                lock.withLock { completion.complete(retired ? nil : value) }
            }
        }
    }
}

#if os(iOS)
import IOSWebRTCAudioDeviceShim

/// Strong retention prevents deallocation during a read, not publication after peer retirement.
/// copyDiagnosticsIfAvailable reads atomics/lock-copied POD only for device-owned mutable state;
/// AVAudioSession queries run on the dedicated utility queue and have an independent deadline.
private final class IOSAudioDiagnosticsDeviceReader: @unchecked Sendable {
    let device: ASIOSStereoPlayoutAudioDevice
    init(_ device: ASIOSStereoPlayoutAudioDevice) { self.device = device }

    func read() -> WebRTCAudioClientNativeSnapshot? {
        var native = ASIOSStereoPlayoutDiagnostics()
        guard device.copyDiagnosticsIfAvailable(&native) else { return nil }
        return WebRTCAudioClientNativeSnapshot(native: native)
    }
}

extension WebRTCAudioDiagnosticsSampler {
    convenience init(device: ASIOSStereoPlayoutAudioDevice) {
        let reader = IOSAudioDiagnosticsDeviceReader(device)
        self.init(read: { reader.read() })
    }
}
#endif
