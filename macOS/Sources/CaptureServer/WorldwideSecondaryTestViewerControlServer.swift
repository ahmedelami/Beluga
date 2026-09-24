import Darwin
import Foundation
import MediaBridgeCore
import RemoteSessionCore

enum WorldwideSecondaryTestViewerControlStatus: String, Codable, Sendable {
    case observed
    case started
    case stopped
    case busy
    case staleGeneration
    case quarantined
    case shutdown
    case unavailable
    case replayed
    case wrongHost
    case invalidReceipt
    case invalidRequest
}

/// Nonsecret receipt naming the exact secondary generation minted by one renewal request.
///
/// The receipt is an identity/fencing record, not a bearer secret. Stop authorization still
/// requires the owner-only socket, same-user peer admission, the current host-lock PID and
/// generation, and a fresh replay-protected request nonce. Binding the mint nonce prevents an
/// unrelated or accidentally substituted generation record from being accepted.
struct WorldwideSecondaryTestViewerGenerationReceipt:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    static let version = 1
    static let messageType = "secondaryTestViewerGenerationReceipt"

    let v: Int
    let type: String
    let hostProcessIdentifier: Int32
    let hostGeneration: String
    let managerGeneration: UInt64
    let renewalRequestNonce: String

    init(
        hostProcessIdentifier: Int32,
        hostGeneration: String,
        managerGeneration: UInt64,
        renewalRequestNonce: String
    ) {
        v = Self.version
        type = Self.messageType
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostGeneration = hostGeneration
        self.managerGeneration = managerGeneration
        self.renewalRequestNonce = renewalRequestNonce
    }

    var isValid: Bool {
        v == Self.version &&
            type == Self.messageType &&
            hostProcessIdentifier > 0 &&
            managerGeneration > 0 &&
            Self.isLowercaseHex(hostGeneration, count: 64) &&
            Self.isLowercaseHex(renewalRequestNonce, count: 32)
    }

    static func hasExactKeys(_ object: [String: Any]) -> Bool {
        Set(object.keys) == Set([
            "v",
            "type",
            "hostProcessIdentifier",
            "hostGeneration",
            "managerGeneration",
            "renewalRequestNonce",
        ])
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

struct WorldwideSecondaryTestViewerControlRequest: Codable, Equatable, Sendable {
    static let version = 1
    static let probeMessageType = "probeSecondaryTestViewerStatus"
    static let renewalMessageType = "renewSecondaryTestViewer"
    static let stopMessageType = "stopSecondaryTestViewerGeneration"
    static let maximumBytes = 4_096

    let v: Int
    let type: String
    let expectedHostProcessIdentifier: Int32
    let expectedHostGeneration: String
    let expectedManagerGeneration: UInt64
    let requestNonce: String
    let generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt?

    init(
        expectedHostProcessIdentifier: Int32,
        expectedHostGeneration: String,
        expectedManagerGeneration: UInt64,
        requestNonce: String
    ) {
        v = Self.version
        type = Self.renewalMessageType
        self.expectedHostProcessIdentifier = expectedHostProcessIdentifier
        self.expectedHostGeneration = expectedHostGeneration
        self.expectedManagerGeneration = expectedManagerGeneration
        self.requestNonce = requestNonce
        generationReceipt = nil
    }

    init(
        probing hostIdentity: WorldwideSecondaryTestViewerHostIdentity,
        requestNonce: String
    ) {
        v = Self.version
        type = Self.probeMessageType
        expectedHostProcessIdentifier = hostIdentity.processIdentifier
        expectedHostGeneration = hostIdentity.generation
        expectedManagerGeneration = 0
        self.requestNonce = requestNonce
        generationReceipt = nil
    }

    init(
        stopping generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt,
        requestNonce: String
    ) {
        v = Self.version
        type = Self.stopMessageType
        expectedHostProcessIdentifier = generationReceipt.hostProcessIdentifier
        expectedHostGeneration = generationReceipt.hostGeneration
        expectedManagerGeneration = generationReceipt.managerGeneration
        self.requestNonce = requestNonce
        self.generationReceipt = generationReceipt
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let request = try? JSONDecoder().decode(Self.self, from: data) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        var expectedKeys: Set<String> = [
                "v",
                "type",
                "expectedHostProcessIdentifier",
                "expectedHostGeneration",
                "expectedManagerGeneration",
                "requestNonce",
        ]
        if request.generationReceipt != nil {
            expectedKeys.insert("generationReceipt")
        }
        guard Set(object.keys) == expectedKeys,
              request.isValid,
              request.hasStrictReceiptObject(object) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        return request
    }

    func encode() throws -> Data {
        guard isValid else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        let data = try JSONEncoder().encode(self)
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        return data
    }

    var isProbe: Bool { type == Self.probeMessageType }
    var isRenewal: Bool { type == Self.renewalMessageType }
    var isStop: Bool { type == Self.stopMessageType }

    private var isValid: Bool {
        guard v == Self.version,
              expectedHostProcessIdentifier > 0,
              Self.isLowercaseHex(expectedHostGeneration, count: 64),
              Self.isLowercaseHex(requestNonce, count: 32) else {
            return false
        }
        if isProbe {
            return expectedManagerGeneration == 0 && generationReceipt == nil
        }
        if isRenewal {
            return generationReceipt == nil
        }
        if isStop, let generationReceipt {
            return generationReceipt.isValid &&
                expectedManagerGeneration > 0 &&
                generationReceipt.hostProcessIdentifier == expectedHostProcessIdentifier &&
                generationReceipt.hostGeneration == expectedHostGeneration &&
                generationReceipt.managerGeneration == expectedManagerGeneration
        }
        return false
    }

    private func hasStrictReceiptObject(_ object: [String: Any]) -> Bool {
        guard let generationReceipt else {
            return object["generationReceipt"] == nil
        }
        guard generationReceipt.isValid,
              let receiptObject = object["generationReceipt"] as? [String: Any] else {
            return false
        }
        return WorldwideSecondaryTestViewerGenerationReceipt.hasExactKeys(receiptObject)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

struct WorldwideSecondaryTestViewerControlResponse: Codable, Equatable, Sendable {
    static let renewalMessageType = "secondaryTestViewerRenewalResult"
    static let probeMessageType = "secondaryTestViewerStatusResult"

    let v: Int
    let type: String
    let status: WorldwideSecondaryTestViewerControlStatus
    let hostProcessIdentifier: Int32
    let hostGeneration: String
    let managerGeneration: UInt64
    let requestNonce: String?
    let invitationCode: String?
    let generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt?
    let managerPhase: String?
    let managerIsIdle: Bool?

    init(
        status: WorldwideSecondaryTestViewerControlStatus,
        hostProcessIdentifier: Int32,
        hostGeneration: String,
        managerGeneration: UInt64,
        requestNonce: String?,
        invitationCode: String? = nil,
        generationReceipt: WorldwideSecondaryTestViewerGenerationReceipt? = nil,
        managerPhase: String? = nil,
        managerIsIdle: Bool? = nil
    ) {
        v = WorldwideSecondaryTestViewerControlRequest.version
        type = status == .observed
            ? Self.probeMessageType
            : Self.renewalMessageType
        self.status = status
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostGeneration = hostGeneration
        self.managerGeneration = managerGeneration
        self.requestNonce = requestNonce
        self.invitationCode = invitationCode
        self.generationReceipt = generationReceipt
        self.managerPhase = managerPhase
        self.managerIsIdle = managerIsIdle
    }

    func encode() throws -> Data {
        guard isValid else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidResponse
        }
        let data = try JSONEncoder().encode(self)
        guard !data.isEmpty,
              data.count <= WorldwideSecondaryTestViewerControlRequest.maximumBytes else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidResponse
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty,
              data.count <= WorldwideSecondaryTestViewerControlRequest.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidResponse
        }
        let response = try JSONDecoder().decode(Self.self, from: data)
        let baseKeys: Set<String> = [
            "v",
            "type",
            "status",
            "hostProcessIdentifier",
            "hostGeneration",
            "managerGeneration",
        ]
        let expectedKeys = baseKeys
            .union(response.requestNonce == nil ? [] : ["requestNonce"])
            .union(response.invitationCode == nil ? [] : ["invitationCode"])
            .union(response.generationReceipt == nil ? [] : ["generationReceipt"])
            .union(response.managerPhase == nil ? [] : ["managerPhase"])
            .union(response.managerIsIdle == nil ? [] : ["managerIsIdle"])
        let receiptObjectIsStrict: Bool
        if response.generationReceipt == nil {
            receiptObjectIsStrict = object["generationReceipt"] == nil
        } else if let receiptObject = object["generationReceipt"] as? [String: Any] {
            receiptObjectIsStrict = WorldwideSecondaryTestViewerGenerationReceipt
                .hasExactKeys(receiptObject)
        } else {
            receiptObjectIsStrict = false
        }
        guard Set(object.keys) == expectedKeys,
              receiptObjectIsStrict,
              response.isValid else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidResponse
        }
        return response
    }

    private var isValid: Bool {
        guard v == WorldwideSecondaryTestViewerControlRequest.version,
              (type == Self.renewalMessageType || type == Self.probeMessageType),
              hostProcessIdentifier > 0,
              Self.isLowercaseHex(hostGeneration, count: 64) else {
            return false
        }
        if status == .invalidRequest {
            return type == Self.renewalMessageType &&
                requestNonce == nil &&
                invitationCode == nil &&
                generationReceipt == nil &&
                managerPhase == nil &&
                managerIsIdle == nil
        }
        guard let requestNonce,
              Self.isLowercaseHex(requestNonce, count: 32) else {
            return false
        }
        if status == .observed {
            guard type == Self.probeMessageType,
                  invitationCode == nil,
                  generationReceipt == nil,
                  let managerPhase,
                  let phase = WorldwideSecondaryTestViewerManagerSnapshot.Phase(
                    rawValue: managerPhase
                  ),
                  let managerIsIdle,
                  managerIsIdle == (phase == .idle) else {
                return false
            }
        } else if status == .started {
            guard type == Self.renewalMessageType,
                  managerPhase == nil,
                  managerIsIdle == nil else {
                return false
            }
            guard let invitationCode,
                  (try? RemoteInvitationCode(invitationCode)) != nil,
                  let generationReceipt,
                  generationReceipt.isValid,
                  generationReceipt.hostProcessIdentifier == hostProcessIdentifier,
                  generationReceipt.hostGeneration == hostGeneration,
                  generationReceipt.managerGeneration == managerGeneration,
                  generationReceipt.renewalRequestNonce == requestNonce else {
                return false
            }
        } else if type != Self.renewalMessageType ||
                    invitationCode != nil ||
                    generationReceipt != nil ||
                    managerPhase != nil ||
                    managerIsIdle != nil {
            return false
        }
        return true
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

enum WorldwideSecondaryTestViewerControlProtocolError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case unsafeSocketPath
    case endpointUnavailable
}

/// Identity a client reads from the already-published owner-only worldwide host lock record.
struct WorldwideSecondaryTestViewerHostIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let generation: String

    static func defaultLockRecordURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
        }
        return applicationSupport
            .appendingPathComponent(
                WorldwideHostProcessLock.legacyRuntimeDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent("worldwide-host.lock")
    }

    static func parse(_ record: String) throws -> Self {
        let lines = record.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count == 4,
              lines[0] == "OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1",
              lines[1].hasPrefix("pid="),
              lines[2].hasPrefix("nonce="),
              lines[3].isEmpty,
              let processIdentifier = Int32(lines[1].dropFirst(4)),
              processIdentifier > 0 else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        let generation = String(lines[2].dropFirst(6))
        guard generation.utf8.count == 64,
              generation.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        return Self(
            processIdentifier: processIdentifier,
            generation: generation
        )
    }

    /// Opens the record without following a symlink and binds the bytes to the inspected inode.
    static func load(from url: URL) throws -> Self {
        let path = url.path
        guard url.isFileURL, WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(path) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        let directory = url.deletingLastPathComponent()
        guard WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directory.path) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        do {
            try MediaBridgeSocket.validateDirectory(directory)
        } catch {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_mode & 0o777 == 0o600,
              opened.st_nlink == 1,
              opened.st_size > 0,
              opened.st_size <= 256 else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        var bytes = [UInt8](repeating: 0, count: Int(opened.st_size))
        let byteCount = bytes.count
        var offset = 0
        while offset < byteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    byteCount - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
            }
            offset += count
        }
        var canonical = stat()
        guard lstat(path, &canonical) == 0,
              canonical.st_mode & S_IFMT == S_IFREG,
              canonical.st_uid == geteuid(),
              canonical.st_mode & 0o777 == 0o600,
              canonical.st_nlink == 1,
              canonical.st_dev == opened.st_dev,
              canonical.st_ino == opened.st_ino,
              let record = String(bytes: bytes, encoding: .utf8) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.invalidRequest
        }
        return try parse(record)
    }
}

/// Synchronous admission latch shared by the transport and request handler.
///
/// Closing the latch prevents every not-yet-admitted request from reaching the coordinator. A
/// request which already holds admission remains counted until its response path finishes. Host
/// teardown closes new admission, stops the generation-fenced manager concurrently so a blocked
/// request can unwind, and does not confirm shutdown until every admitted response path drains.
private final class WorldwideSecondaryTestViewerControlAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true
    private var inFlightRequestCount = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    func beginRequest() -> Bool {
        lock.withLock {
            guard isOpen else { return false }
            inFlightRequestCount += 1
            return true
        }
    }

    func endRequest() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(inFlightRequestCount > 0)
            inFlightRequestCount -= 1
            guard inFlightRequestCount == 0 else { return [] }
            defer { drainWaiters.removeAll(keepingCapacity: false) }
            return drainWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func close() {
        lock.withLock { isOpen = false }
    }

    var allowsRenewal: Bool {
        lock.withLock { isOpen }
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard inFlightRequestCount > 0 else { return true }
                drainWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

/// One-shot synchronization between a renewal's coordinator admission and an overtaking stop.
///
/// The handler actor is intentionally reentrant while native startup is suspended. A matching
/// stop must not ask the coordinator to stop generation N until the renewal has either advanced
/// the coordinator to N or definitively failed before doing so.
private final class WorldwideSecondaryTestViewerGenerationAdvanceLatch:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    @discardableResult
    func resolve(_ didAdvance: Bool) -> Bool {
        let resolution = lock.withLock {
            () -> (Bool, [CheckedContinuation<Bool, Never>]) in
            if let result { return (result, []) }
            result = didAdvance
            defer { waiters.removeAll(keepingCapacity: false) }
            return (didAdvance, waiters)
        }
        resolution.1.forEach { $0.resume(returning: resolution.0) }
        return resolution.0
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }
}

/// Serial request admission and replay protection, independent of the socket transport.
actor WorldwideSecondaryTestViewerControlHandler {
    static let maximumConsumedNonces = 256
    static let maximumConsumedProbeNonces = 256

    private let hostProcessIdentifier: Int32
    private let hostGeneration: String
    private let coordinator: WorldwideSecondaryTestViewerCoordinator
    private nonisolated let admission =
        WorldwideSecondaryTestViewerControlAdmission()
    private var consumedNonces: Set<String> = []
    private var consumedProbeNonces: Set<String> = []
    private var activeGenerationReceipt: WorldwideSecondaryTestViewerGenerationReceipt?
    private var preparingGenerationReceipt: WorldwideSecondaryTestViewerGenerationReceipt?
    private var pendingGenerationReceipt: WorldwideSecondaryTestViewerGenerationReceipt?
    private var pendingGenerationAdvanceLatch:
        WorldwideSecondaryTestViewerGenerationAdvanceLatch?
    private var cancelledGenerationReceipts:
        Set<WorldwideSecondaryTestViewerGenerationReceipt> = []

    init(
        hostProcessIdentifier: Int32,
        hostGeneration: String,
        coordinator: WorldwideSecondaryTestViewerCoordinator
    ) {
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostGeneration = hostGeneration
        self.coordinator = coordinator
    }

    func handle(
        _ request: WorldwideSecondaryTestViewerControlRequest
    ) async -> WorldwideSecondaryTestViewerControlResponse {
        guard beginRequestAdmission() else {
            return response(
                status: .shutdown,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        defer { endRequestAdmission() }
        return await handleAdmitted(request)
    }

    nonisolated func closeAdmission() {
        admission.close()
    }

    nonisolated func waitUntilDrained() async {
        await admission.waitUntilDrained()
    }

    nonisolated func beginRequestAdmission() -> Bool {
        admission.beginRequest()
    }

    nonisolated func endRequestAdmission() {
        admission.endRequest()
    }

    func handleAdmitted(
        _ request: WorldwideSecondaryTestViewerControlRequest
    ) async -> WorldwideSecondaryTestViewerControlResponse {
        guard request.expectedHostProcessIdentifier == hostProcessIdentifier,
              request.expectedHostGeneration == hostGeneration else {
            return response(
                status: .wrongHost,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        if request.isProbe {
            guard consumedProbeNonces.insert(request.requestNonce).inserted else {
                return response(
                    status: .replayed,
                    snapshot: await coordinator.snapshot(),
                    requestNonce: request.requestNonce
                )
            }
            guard consumedProbeNonces.count <= Self.maximumConsumedProbeNonces else {
                // Probe replay state is bounded separately so observation cannot consume the
                // mutation nonce budget. It never evicts within this host generation.
                consumedProbeNonces.remove(request.requestNonce)
                return response(
                    status: .unavailable,
                    snapshot: await coordinator.snapshot(),
                    requestNonce: request.requestNonce
                )
            }
        } else {
            guard consumedNonces.insert(request.requestNonce).inserted else {
                return response(
                    status: .replayed,
                    snapshot: await coordinator.snapshot(),
                    requestNonce: request.requestNonce
                )
            }
            guard consumedNonces.count <= Self.maximumConsumedNonces else {
                // The bounded replay table never evicts. Once exhausted, all new work fails closed
                // for the rest of this host generation rather than accepting an old nonce again.
                consumedNonces.remove(request.requestNonce)
                return response(
                    status: .unavailable,
                    snapshot: await coordinator.snapshot(),
                    requestNonce: request.requestNonce
                )
            }
        }

        // This synchronous latch is deliberately the last check before actor hand-off. If host
        // teardown closes admission immediately after this check, its drain waits for this request
        // to finish before it can stop the coordinator.
        guard admission.allowsRenewal else {
            return response(
                status: .shutdown,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }

        if request.isProbe {
            let snapshot = await coordinator.snapshot()
            return WorldwideSecondaryTestViewerControlResponse(
                status: .observed,
                hostProcessIdentifier: hostProcessIdentifier,
                hostGeneration: hostGeneration,
                managerGeneration: snapshot.managerGeneration,
                requestNonce: request.requestNonce,
                managerPhase: snapshot.phase.rawValue,
                managerIsIdle: snapshot.phase == .idle
            )
        }

        if request.isStop {
            return await stopExactGeneration(request)
        }

        let increment = request.expectedManagerGeneration.addingReportingOverflow(1)
        guard !increment.overflow, increment.partialValue != 0 else {
            return response(
                status: .unavailable,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        let candidate = WorldwideSecondaryTestViewerGenerationReceipt(
            hostProcessIdentifier: hostProcessIdentifier,
            hostGeneration: hostGeneration,
            managerGeneration: increment.partialValue,
            renewalRequestNonce: request.requestNonce
        )
        guard !cancelledGenerationReceipts.contains(candidate) else {
            return response(
                status: .invalidReceipt,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        guard preparingGenerationReceipt == nil,
              pendingGenerationReceipt == nil else {
            return response(
                status: .busy,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }

        // Register a preparation fence before reading coordinator state. A cleanup request which
        // overtakes this renewal records an exact tombstone; after the await below, this request
        // observes that tombstone and can never mint the cancelled candidate.
        preparingGenerationReceipt = candidate
        let snapshot = await coordinator.snapshot()
        if cancelledGenerationReceipts.contains(candidate) {
            if preparingGenerationReceipt == candidate {
                preparingGenerationReceipt = nil
            }
            return response(
                status: .invalidReceipt,
                snapshot: snapshot,
                requestNonce: request.requestNonce
            )
        }
        guard snapshot.managerGeneration == request.expectedManagerGeneration else {
            if preparingGenerationReceipt == candidate {
                preparingGenerationReceipt = nil
            }
            return response(
                status: .staleGeneration,
                snapshot: snapshot,
                requestNonce: request.requestNonce
            )
        }
        let unavailableStatus: WorldwideSecondaryTestViewerControlStatus?
        switch snapshot.phase {
        case .idle:
            unavailableStatus = nil
        case .starting, .running, .stopping:
            unavailableStatus = .busy
        case .quarantined:
            unavailableStatus = .quarantined
        case .shutdown:
            unavailableStatus = .shutdown
        }
        if let unavailableStatus {
            if preparingGenerationReceipt == candidate {
                preparingGenerationReceipt = nil
            }
            return response(
                status: unavailableStatus,
                snapshot: snapshot,
                requestNonce: request.requestNonce
            )
        }
        preparingGenerationReceipt = nil
        pendingGenerationReceipt = candidate
        let generationAdvanceLatch =
            WorldwideSecondaryTestViewerGenerationAdvanceLatch()
        pendingGenerationAdvanceLatch = generationAdvanceLatch

        do {
            let invitation = try await coordinator.renew(
                expectedManagerGeneration: request.expectedManagerGeneration,
                generationDidAdvance: { generation in
                    generationAdvanceLatch.resolve(
                        generation == candidate.managerGeneration
                    )
                }
            )
            generationAdvanceLatch.resolve(
                invitation.managerGeneration == candidate.managerGeneration
            )
            if pendingGenerationReceipt == candidate {
                pendingGenerationReceipt = nil
                pendingGenerationAdvanceLatch = nil
            }
            activeGenerationReceipt = candidate
            guard invitation.managerGeneration == candidate.managerGeneration else {
                return response(
                    status: .unavailable,
                    snapshot: await coordinator.snapshot(),
                    requestNonce: request.requestNonce
                )
            }
            if cancelledGenerationReceipts.contains(candidate) {
                // Cleanup overtook a renewal after coordinator admission but before this response.
                // Never deliver the invitation; join exact teardown and return only its proof.
                return await stopExactGeneration(
                    WorldwideSecondaryTestViewerControlRequest(
                        stopping: candidate,
                        requestNonce: request.requestNonce
                    )
                )
            }
            return WorldwideSecondaryTestViewerControlResponse(
                status: .started,
                hostProcessIdentifier: hostProcessIdentifier,
                hostGeneration: hostGeneration,
                managerGeneration: invitation.managerGeneration,
                requestNonce: request.requestNonce,
                invitationCode: invitation.code,
                generationReceipt: candidate
            )
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            let generationDidAdvance = generationAdvanceLatch.resolve(false)
            if pendingGenerationReceipt == candidate {
                pendingGenerationReceipt = nil
                pendingGenerationAdvanceLatch = nil
            }
            if generationDidAdvance {
                // The coordinator owns this exact generation even when construction or startup
                // failed. Retain its receipt so staged-client cleanup can prove idle teardown or
                // retry a quarantined native capture instead of misclassifying it as never minted.
                activeGenerationReceipt = candidate
            }
            let current = await coordinator.snapshot()
            let status: WorldwideSecondaryTestViewerControlStatus
            switch error {
            case .staleGeneration:
                status = .staleGeneration
            case .busy:
                status = .busy
            case .quarantined, .nativeCaptureTeardownUnconfirmed:
                status = .quarantined
            case .shutdown:
                status = .shutdown
            case .generationExhausted:
                status = .unavailable
            }
            return response(
                status: status,
                snapshot: current,
                requestNonce: request.requestNonce
            )
        } catch {
            let generationDidAdvance = generationAdvanceLatch.resolve(false)
            if pendingGenerationReceipt == candidate {
                pendingGenerationReceipt = nil
                pendingGenerationAdvanceLatch = nil
            }
            if generationDidAdvance {
                activeGenerationReceipt = candidate
            }
            return response(
                status: .unavailable,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
    }

    private func stopExactGeneration(
        _ request: WorldwideSecondaryTestViewerControlRequest
    ) async -> WorldwideSecondaryTestViewerControlResponse {
        guard let receipt = request.generationReceipt else {
            return response(
                status: .invalidReceipt,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        cancelledGenerationReceipts.insert(receipt)
        if receipt == preparingGenerationReceipt {
            // The matching renewal has not crossed its mint boundary. Its preparation fence will
            // observe this tombstone before it can invoke the coordinator.
            return response(
                status: .invalidReceipt,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        let matchesPending = receipt == pendingGenerationReceipt
        let generationAdvanceLatch = matchesPending
            ? pendingGenerationAdvanceLatch
            : nil
        guard matchesPending || receipt == activeGenerationReceipt else {
            // A stop may overtake an accepted renewal task. The retained tombstone makes this a
            // terminal proof for that exact candidate: if the delayed renewal arrives later, it
            // is rejected before any service can be constructed.
            return response(
                status: .invalidReceipt,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        if let generationAdvanceLatch,
           !(await generationAdvanceLatch.wait()) {
            // The matching renewal definitively failed before advancing the coordinator. The
            // tombstone above also prevents a delayed copy of that request from minting later.
            return response(
                status: .invalidReceipt,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
        do {
            let stopped = try await coordinator.stopGeneration(
                expectedManagerGeneration: receipt.managerGeneration
            )
            guard stopped.managerGeneration == receipt.managerGeneration,
                  stopped.phase == .idle else {
                return response(
                    status: .quarantined,
                    snapshot: stopped,
                    requestNonce: request.requestNonce
                )
            }
            if pendingGenerationReceipt == receipt {
                pendingGenerationReceipt = nil
                pendingGenerationAdvanceLatch = nil
            }
            activeGenerationReceipt = receipt
            // Retain the stopped receipt until a later generation is successfully minted. If the
            // first stop response is lost, a fresh-nonce retry can prove the same idle generation;
            // the coordinator's generation fence still prevents it from touching any newer one.
            return response(
                status: .stopped,
                snapshot: stopped,
                requestNonce: request.requestNonce
            )
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            let current = await coordinator.snapshot()
            let status: WorldwideSecondaryTestViewerControlStatus
            switch error {
            case .staleGeneration:
                status = .staleGeneration
            case .busy:
                status = .busy
            case .quarantined, .nativeCaptureTeardownUnconfirmed:
                status = .quarantined
            case .shutdown:
                status = .shutdown
            case .generationExhausted:
                status = .unavailable
            }
            return response(
                status: status,
                snapshot: current,
                requestNonce: request.requestNonce
            )
        } catch {
            return response(
                status: .unavailable,
                snapshot: await coordinator.snapshot(),
                requestNonce: request.requestNonce
            )
        }
    }

    func pendingGenerationStopWaiterCountForTesting() -> Int {
        pendingGenerationAdvanceLatch?.waiterCount ?? 0
    }

    func invalidRequestResponse() async -> WorldwideSecondaryTestViewerControlResponse {
        response(
            status: .invalidRequest,
            snapshot: await coordinator.snapshot(),
            requestNonce: nil
        )
    }

    private func response(
        status: WorldwideSecondaryTestViewerControlStatus,
        snapshot: WorldwideSecondaryTestViewerManagerSnapshot,
        requestNonce: String?
    ) -> WorldwideSecondaryTestViewerControlResponse {
        WorldwideSecondaryTestViewerControlResponse(
            status: status,
            hostProcessIdentifier: hostProcessIdentifier,
            hostGeneration: hostGeneration,
            managerGeneration: snapshot.managerGeneration,
            requestNonce: requestNonce
        )
    }
}

/// Owner-only, one-request/one-response AF_UNIX transport for renewable invitations.
///
/// Invitation material exists only in the accepted connection's response buffer. This type never
/// logs it, writes it to a file, or retries delivery after the connection closes.
final class WorldwideSecondaryTestViewerControlServer: @unchecked Sendable {
    typealias PeerAdmission = @Sendable (Int32) -> Bool
    static let maximumActiveClients = 8

    static func defaultSocketPath() throws -> String {
        let path = "/private/tmp/opensteamer-wv-\(geteuid())/control.sock"
        _ = try MediaBridgeSocket.address(path)
        return path
    }

    private let lock = NSLock()
    private let socketPath: String
    private let handler: WorldwideSecondaryTestViewerControlHandler
    private let peerIsAdmitted: PeerAdmission
    private let acceptQueue: DispatchQueue
    private let afterBindForTesting: (@Sendable () throws -> Void)?
    private var listener: Int32 = -1
    private var mayStart = true
    private var clients: Set<Int32> = []
    private var socketIdentity: (device: dev_t, inode: ino_t)?

    init(
        socketPath: String,
        handler: WorldwideSecondaryTestViewerControlHandler,
        peerIsAdmitted: @escaping PeerAdmission = MediaBridgeSocket.sameUser,
        acceptQueue: DispatchQueue = DispatchQueue(
            label: "org.example.opensteamer.secondary-viewer-control",
            qos: .utility
        ),
        afterBindForTesting: (@Sendable () throws -> Void)? = nil
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.peerIsAdmitted = peerIsAdmitted
        self.acceptQueue = acceptQueue
        self.afterBindForTesting = afterBindForTesting
    }

    deinit {
        stop()
    }

    func start() throws {
        let descriptor = try lock.withLock { () throws -> Int32 in
            guard mayStart, listener < 0 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
            // This server is intentionally one-shot. Serializing path creation while holding the
            // state lock prevents concurrent starts/stops from racing pathname ownership.
            mayStart = false
            let created = try Self.makeListener(
                path: socketPath,
                afterBindForTesting: afterBindForTesting
            )
            listener = created.descriptor
            socketIdentity = created.identity
            return created.descriptor
        }

        acceptQueue.async { [weak self] in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            self.acceptConnections(listener: descriptor)
        }
    }

    func stop() {
        // Revoke handler admission before closing any descriptor. A request which was accepted but
        // has not entered the handler can no longer renew; an admitted request remains drainable.
        handler.closeAdmission()
        let closed = lock.withLock { () -> ((dev_t, ino_t)?) in
            mayStart = false
            let descriptor = listener
            listener = -1
            // Keep every descriptor open and owned by its worker while issuing shutdown under the
            // same lock used by `retire`. This prevents an fd integer from being closed/reused
            // between the ownership check and shutdown.
            if descriptor >= 0 {
                _ = shutdown(descriptor, SHUT_RDWR)
            }
            clients.forEach { _ = shutdown($0, SHUT_RDWR) }
            let identity = socketIdentity.map { ($0.device, $0.inode) }
            socketIdentity = nil
            return identity
        }
        if let expected = closed {
            var current = stat()
            if lstat(socketPath, &current) == 0,
               current.st_mode & S_IFMT == S_IFSOCK,
               current.st_uid == geteuid(),
               current.st_dev == expected.0,
               current.st_ino == expected.1 {
                _ = unlink(socketPath)
            }
        }
    }

    func waitUntilRequestsDrain() async {
        await handler.waitUntilDrained()
    }

    var activeClientCountForTesting: Int {
        lock.withLock { clients.count }
    }

    private func acceptConnections(listener: Int32) {
        while lock.withLock({ self.listener == listener }) {
            var descriptor = pollfd(
                fd: listener,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = poll(&descriptor, 1, 250)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { continue }
            guard descriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0
            else { break }

            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            guard MediaBridgeSocket.configure(client), peerIsAdmitted(client) else {
                Darwin.close(client)
                continue
            }
            let retained = lock.withLock { () -> Bool in
                guard self.listener == listener,
                      clients.count < Self.maximumActiveClients else {
                    return false
                }
                clients.insert(client)
                return true
            }
            guard retained else {
                Darwin.close(client)
                continue
            }
            Task { [self] in
                await serveOneRequest(client)
            }
        }
        Darwin.close(listener)
    }

    private func serveOneRequest(_ client: Int32) async {
        defer { retire(client) }
        guard handler.beginRequestAdmission() else { return }
        defer { handler.endRequestAdmission() }
        let response: WorldwideSecondaryTestViewerControlResponse
        do {
            guard let data = try MediaBridgeFraming.readFrame(
                client,
                idleTimeout: 1
            ) else {
                return
            }
            let request = try WorldwideSecondaryTestViewerControlRequest.decode(data)
            response = await handler.handleAdmitted(request)
        } catch {
            response = await handler.invalidRequestResponse()
        }
        guard let data = try? response.encode() else { return }
        try? MediaBridgeFraming.writeFrame(client, data: data)
    }

    private func retire(_ client: Int32) {
        let shouldClose = lock.withLock { clients.remove(client) != nil }
        guard shouldClose else { return }
        _ = shutdown(client, SHUT_RDWR)
        Darwin.close(client)
    }

    private static func makeListener(
        path: String,
        afterBindForTesting: (@Sendable () throws -> Void)?
    ) throws -> (
        descriptor: Int32,
        identity: (device: dev_t, inode: ino_t)
    ) {
        guard WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(path) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
        }
        let socketURL = URL(fileURLWithPath: path)
        let directory = socketURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directory.path) else {
            throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
        }
        _ = try MediaBridgeSocket.address(path)
        do {
            try MediaBridgeSocket.validateDirectory(directory)
        } catch {
            throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
        }

        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK,
                  existing.st_uid == geteuid(),
                  existing.st_mode & 0o777 == 0o600 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
            }
            if let active = try? MediaBridgeSocket.connect(path: path) {
                Darwin.close(active)
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
            var revalidated = stat()
            guard lstat(path, &revalidated) == 0,
                  revalidated.st_mode & S_IFMT == S_IFSOCK,
                  revalidated.st_uid == existing.st_uid,
                  revalidated.st_mode & 0o777 == existing.st_mode & 0o777,
                  revalidated.st_dev == existing.st_dev,
                  revalidated.st_ino == existing.st_ino,
                  unlink(path) == 0 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
        } else if errno != ENOENT {
            throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
        }
        var boundIdentity: (device: dev_t, inode: ino_t)?
        do {
            guard MediaBridgeSocket.configure(descriptor) else {
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
            var address = try MediaBridgeSocket.address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bound == 0 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
            var boundMetadata = stat()
            guard lstat(path, &boundMetadata) == 0,
                  boundMetadata.st_mode & S_IFMT == S_IFSOCK,
                  boundMetadata.st_uid == geteuid() else {
                throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
            }
            boundIdentity = (boundMetadata.st_dev, boundMetadata.st_ino)
            try afterBindForTesting?()
            guard chmod(path, 0o600) == 0,
                  Darwin.listen(descriptor, 4) == 0 else {
                throw WorldwideSecondaryTestViewerControlProtocolError.endpointUnavailable
            }
            var created = stat()
            guard lstat(path, &created) == 0,
                  created.st_mode & S_IFMT == S_IFSOCK,
                  created.st_uid == geteuid(),
                  created.st_mode & 0o777 == 0o600,
                  created.st_dev == boundMetadata.st_dev,
                  created.st_ino == boundMetadata.st_ino else {
                throw WorldwideSecondaryTestViewerControlProtocolError.unsafeSocketPath
            }
            return (
                descriptor,
                (device: created.st_dev, inode: created.st_ino)
            )
        } catch {
            Darwin.close(descriptor)
            if let boundIdentity {
                var created = stat()
                if lstat(path, &created) == 0,
                   created.st_mode & S_IFMT == S_IFSOCK,
                   created.st_uid == geteuid(),
                   created.st_dev == boundIdentity.device,
                   created.st_ino == boundIdentity.inode {
                    _ = unlink(path)
                }
            }
            throw error
        }
    }
}
