import Darwin
import Foundation
import WebRTCTransport

struct WorldwideAudioClientDiagnosticsReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let hostPID: Int32
    let peerGeneration: UInt64
    let negotiationEpoch: UInt64
    let status: String
    let generatedAtUnixMilliseconds: UInt64
    let receivedAtUnixMilliseconds: UInt64?
    let freshUntilUnixMilliseconds: UInt64?
    let acousticAudibility: String
    let heartbeat: WebRTCAudioClientDiagnosticsHeartbeat?

    init(latest: WorldwideAudioClientDiagnosticsSink.Latest, uptime: TimeInterval, date: Date) {
        schemaVersion = 1
        kind = "opensteamer.audio-client.v1"
        hostPID = latest.hostPID
        peerGeneration = latest.peerGeneration
        negotiationEpoch = latest.negotiationEpoch
        status = latest.status.label
        generatedAtUnixMilliseconds = Self.milliseconds(date.timeIntervalSince1970)
        let age = latest.receiptUptime.map { max(0, uptime - $0) }
        receivedAtUnixMilliseconds = age.map { Self.milliseconds(date.timeIntervalSince1970 - $0) }
        let validity: UInt64
        switch latest.status {
        case .fresh(.renderingNonzero), .fresh(.renderingSilent), .fresh(.renderStalled), .fresh(.inboundStalled):
            let sampleAge = latest.heartbeat?.snapshot.nativeObservationAgeMilliseconds ?? 5_000
            validity = 5_000 - min(5_000, sampleAge)
        default: validity = 10_000
        }
        freshUntilUnixMilliseconds = receivedAtUnixMilliseconds.map { $0 + validity }
        acousticAudibility = "unverified"
        heartbeat = latest.heartbeat
    }

    var isValid: Bool {
        schemaVersion == 1 && kind == "opensteamer.audio-client.v1" && hostPID > 0
            && acousticAudibility == "unverified" && (heartbeat?.isValid ?? true)
            && Self.allowedStatuses.contains(status)
    }

    private static let allowedStatuses: Set<String> = [
        "awaitingEvidence", "intentionallyPaused", "authorizationUnavailable", "transportUncertain",
        "remoteTrackUnavailable", "nativeEvidenceUnavailable", "nativeInitializationFailed",
        "nativeStartFailed", "nativeNotInitialized", "nativeNotStarted", "policyMismatch",
        "routeUnavailable", "nativeRenderFailed", "recoveryFailed", "inboundStalled", "renderStalled",
        "renderingNonzero", "renderingSilent", "stale", "unavailable.awaitingHeartbeat",
        "unavailable.notNegotiated", "unavailable.transportRevoked", "unavailable.laneUnavailable",
        "unavailable.streamEnded", "unavailable.stopped"
    ]

    private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000, Double(UInt64.max / 2)))
    }
}

/// One pending value; failed writes consume the same retry interval as successful writes.
struct WorldwideAudioClientReportSchedule {
    static let writeInterval: TimeInterval = 5
    private(set) var pending: WorldwideAudioClientDiagnosticsReport?
    private var urgent = false
    private var nextWriteUptime: TimeInterval = 0
    private var lastOfferedStatus: String?

    mutating func offer(_ report: WorldwideAudioClientDiagnosticsReport, terminal: Bool) {
        pending = report
        urgent = urgent || (terminal && report.status != lastOfferedStatus)
        lastOfferedStatus = report.status
    }

    func delay(now: TimeInterval) -> TimeInterval? {
        guard pending != nil else { return nil }
        return urgent ? 0 : max(0, nextWriteUptime - now)
    }

    mutating func take(now: TimeInterval) -> WorldwideAudioClientDiagnosticsReport? {
        guard delay(now: now) == 0 else { return nil }
        defer { pending = nil; urgent = false; nextWriteUptime = now + Self.writeInterval }
        return pending
    }
}

final class WorldwideAudioClientDiagnosticsReportWriter: @unchecked Sendable {
    enum StorageStatus: String { case pending, written, unavailable }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "opensteamer.audio-client-report", qos: .utility)
    private var schedule = WorldwideAudioClientReportSchedule()
    private var timer: DispatchSourceTimer?
    private var keepAlive: WorldwideAudioClientDiagnosticsReportWriter?
    private var lastStorageStatus: StorageStatus = .pending
    private let write: @Sendable (WorldwideAudioClientDiagnosticsReport) throws -> Void

    init(write: @escaping @Sendable (WorldwideAudioClientDiagnosticsReport) throws -> Void = {
        try WorldwideAudioClientReportStorage().write($0)
    }) {
        self.write = write
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    deinit { timer?.cancel() }

    var storageStatus: StorageStatus {
        lock.lock()
        defer { lock.unlock() }
        return lastStorageStatus
    }

    func submit(_ report: WorldwideAudioClientDiagnosticsReport, terminal: Bool = false) {
        guard report.isValid else { return }
        lock.lock()
        schedule.offer(report, terminal: terminal)
        keepAlive = self
        scheduleTimerLocked()
        lock.unlock()
    }

    private func drain() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let delay = schedule.delay(now: now) else {
            scheduleTimerLocked()
            lock.unlock()
            return
        }
        if delay > 0 {
            scheduleTimerLocked()
            lock.unlock()
            return
        }
        let report = schedule.take(now: now)
        timer?.schedule(deadline: .distantFuture)
        lock.unlock()
        if let report {
            let outcome: StorageStatus
            do { try write(report); outcome = .written } catch { outcome = .unavailable }
            lock.lock()
            lastStorageStatus = outcome
            lock.unlock()
        }
        lock.lock()
        scheduleTimerLocked()
        lock.unlock()
    }

    private func scheduleTimerLocked() {
        if let delay = schedule.delay(now: ProcessInfo.processInfo.systemUptime) {
            timer?.schedule(deadline: .now() + delay)
        } else {
            timer?.schedule(deadline: .distantFuture)
            keepAlive = nil
        }
    }
}

struct WorldwideAudioClientReportStorage {
    enum Failure: Error { case unsafePath, unsafeReport, oversized, io }
    static let maximumBytes = 32 * 1_024
    static let fileName = "audio-client-v1.json"
    let applicationSupportURL: URL

    init(applicationSupportURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)) {
        self.applicationSupportURL = applicationSupportURL
    }

    func write(_ report: WorldwideAudioClientDiagnosticsReport) throws {
        guard report.isValid else { throw Failure.unsafeReport }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= Self.maximumBytes else { throw Failure.oversized }
        let support = try Self.openDirectoryChain(applicationSupportURL)
        defer { Darwin.close(support) }
        let product = try Self.privateChild("opensteamer", parent: support)
        defer { Darwin.close(product) }
        let directory = try Self.privateChild("diagnostics", parent: product)
        defer { Darwin.close(directory) }
        let existing = try Self.existingReport(directory: directory)
        let temporaryName = ".audio-client-v1.\(UUID().uuidString).tmp"
        let temporary = Darwin.openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else { throw Failure.io }
        defer {
            Darwin.close(temporary)
            Darwin.unlinkat(directory, temporaryName, 0)
        }
        guard Darwin.fchmod(temporary, 0o600) == 0 else { throw Failure.io }
        try Self.rejectAllowACL(temporary)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(temporary, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.io }
                offset += count
            }
        }
        guard Darwin.fsync(temporary) == 0 else { throw Failure.io }
        let reopenedSupport = try Self.openDirectoryChain(applicationSupportURL)
        defer { Darwin.close(reopenedSupport) }
        let supportMatches = try Self.identity(support) == Self.identity(reopenedSupport)
        let productMatches = try Self.childMatches("opensteamer", parent: support, descriptor: product)
        let directoryMatches = try Self.childMatches("diagnostics", parent: product, descriptor: directory)
        let reportMatches = try Self.reportIdentity(directory: directory) == existing
        guard supportMatches, productMatches, directoryMatches, reportMatches else { throw Failure.unsafePath }
        // The owner-only directory excludes other accounts. This is an immediate identity
        // recheck plus atomic publication, not a filesystem compare-and-swap against this user.
        let result = existing == nil
            ? Darwin.renameatx_np(directory, temporaryName, directory, Self.fileName, UInt32(RENAME_EXCL))
            : Darwin.renameat(directory, temporaryName, directory, Self.fileName)
        guard result == 0, Darwin.fsync(directory) == 0 else { throw Failure.io }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private static func identity(_ descriptor: Int32) throws -> Identity {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else { throw Failure.io }
        return Identity(device: value.st_dev, inode: value.st_ino)
    }

    private static func openDirectoryChain(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw Failure.unsafePath }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.io }
        do {
            for component in url.pathComponents.dropFirst() {
                guard component != ".", !component.isEmpty else { throw Failure.unsafePath }
                let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Failure.unsafePath }
                Darwin.close(descriptor)
                descriptor = next
                var value = stat()
                guard Darwin.fstat(descriptor, &value) == 0,
                      value.st_uid == geteuid() || value.st_uid == 0,
                      value.st_mode & 0o022 == 0 || (value.st_uid == 0 && value.st_mode & S_ISVTX != 0) else {
                    throw Failure.unsafePath
                }
                try rejectAllowACL(descriptor)
            }
            var final = stat()
            guard Darwin.fstat(descriptor, &final) == 0, final.st_uid == geteuid(),
                  final.st_mode & 0o777 == 0o700 else { throw Failure.unsafePath }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func privateChild(_ name: String, parent: Int32) throws -> Int32 {
        let created = Darwin.mkdirat(parent, name, 0o700)
        guard created == 0 || errno == EEXIST else { throw Failure.io }
        let descriptor = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
              isPrivateDirectory(mode: value.st_mode, owner: value.st_uid) else {
            Darwin.close(descriptor)
            throw Failure.unsafePath
        }
        do { try rejectAllowACL(descriptor) } catch { Darwin.close(descriptor); throw error }
        return descriptor
    }

    private static func childMatches(_ name: String, parent: Int32, descriptor: Int32) throws -> Bool {
        var entry = stat()
        guard Darwin.fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        let openedIdentity = try identity(descriptor)
        return isPrivateDirectory(mode: entry.st_mode, owner: entry.st_uid)
            && openedIdentity == Identity(device: entry.st_dev, inode: entry.st_ino)
    }

    static func isPrivateDirectory(mode: mode_t, owner: uid_t, expectedOwner: uid_t = geteuid()) -> Bool {
        mode & S_IFMT == S_IFDIR && owner == expectedOwner && mode & 0o777 == 0o700
    }

    private static func reportIdentity(directory: Int32) throws -> Identity? {
        var value = stat()
        if Darwin.fstatat(directory, fileName, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.io }
            return nil
        }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
              value.st_mode & 0o777 == 0o600, value.st_nlink == 1,
              value.st_size > 0, value.st_size <= maximumBytes else { throw Failure.unsafePath }
        return Identity(device: value.st_dev, inode: value.st_ino)
    }

    private static func existingReport(directory: Int32) throws -> Identity? {
        guard let expected = try reportIdentity(directory: directory) else { return nil }
        let descriptor = Darwin.openat(directory, fileName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        defer { Darwin.close(descriptor) }
        guard try identity(descriptor) == expected else { throw Failure.unsafePath }
        try rejectAllowACL(descriptor)
        var bytes = [UInt8](repeating: 0, count: maximumBytes + 1)
        var used = 0
        while used < bytes.count {
            let capacity = bytes.count - used
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: used), capacity)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.io }
            if count == 0 { break }
            used += count
        }
        guard used <= maximumBytes else { throw Failure.oversized }
        let report = try JSONDecoder().decode(WorldwideAudioClientDiagnosticsReport.self, from: Data(bytes.prefix(used)))
        guard report.isValid else { throw Failure.unsafeReport }
        return expected
    }

    static func rejectAllowACL(_ descriptor: Int32) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when an existing descriptor has no extended ACL.
            // Only that result on a still-valid regular file/directory means absent;
            // unsupported ACL reads, permission errors, and invalid descriptors fail closed.
            let aclError = errno
            var value = stat()
            guard aclError == ENOENT, Darwin.fstat(descriptor, &value) == 0,
                  value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else {
                throw Failure.unsafePath
            }
            return
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw Failure.unsafePath }
        for index in 0...Int(ACL_MAX_ENTRIES) {
            var entry: acl_entry_t?
            if acl_get_entry(acl, Int32(index), &entry) != 0 {
                guard errno == EINVAL else { throw Failure.unsafePath }
                return
            }
            guard index < Int(ACL_MAX_ENTRIES), let entry else { throw Failure.unsafePath }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else { throw Failure.unsafePath }
        }
        throw Failure.unsafePath
    }
}
