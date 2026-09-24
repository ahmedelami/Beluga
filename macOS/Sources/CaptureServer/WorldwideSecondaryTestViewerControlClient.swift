import Darwin
import Foundation
import MediaBridgeCore
import RemoteSessionCore

enum WorldwideSecondaryTestViewerControlClientError: LocalizedError, Equatable {
    case invalidArguments
    case unsafeEndpoint
    case invalidResponse
    case probeRejected(WorldwideSecondaryTestViewerControlStatus)
    case renewalRejected(WorldwideSecondaryTestViewerControlStatus)
    case stopRejected(WorldwideSecondaryTestViewerControlStatus)
    case cleanupUnconfirmed
    case unsafeOutput

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "The secondary viewer request arguments are invalid."
        case .unsafeEndpoint:
            "The secondary viewer control endpoint failed owner or identity validation."
        case .invalidResponse:
            "The secondary viewer control response was invalid."
        case .probeRejected(let status):
            "The secondary viewer status probe was rejected with status \(status.rawValue)."
        case .renewalRejected(let status):
            "The secondary viewer renewal request was rejected with status \(status.rawValue)."
        case .stopRejected(let status):
            "The exact secondary viewer generation did not confirm stop: \(status.rawValue)."
        case .cleanupUnconfirmed:
            "The secondary viewer invitation failed after minting and exact cleanup was not confirmed."
        case .unsafeOutput:
            "The secondary viewer invitation output path is unsafe or already exists."
        }
    }
}

/// Client-only process mode parsed before host options, locking, display, capture, or audio setup.
struct WorldwideSecondaryTestViewerControlClientMode: Equatable {
    static let probeFlag = "--probe-secondary-test-viewer-status"
    static let requestFlag = "--request-secondary-test-viewer-invitation"
    static let stopFlag = "--stop-secondary-test-viewer-generation"

    enum Action: Equatable {
        case probe(outputURL: URL)
        case request(invitationURL: URL, receiptURL: URL)
        case stop(receiptURL: URL)
    }

    let socketPath: String
    let action: Action

    var outputURL: URL {
        switch action {
        case .probe(let outputURL): outputURL
        case .request(let invitationURL, _): invitationURL
        case .stop(let receiptURL): receiptURL
        }
    }

    var receiptURL: URL {
        switch action {
        case .probe(let outputURL): outputURL
        case .request(_, let receiptURL), .stop(let receiptURL): receiptURL
        }
    }

    static func parseIfRequested(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self? {
        let requestsProbe = arguments.dropFirst().contains(probeFlag)
        let requestsInvitation = arguments.dropFirst().contains(requestFlag)
        let requestsStop = arguments.dropFirst().contains(stopFlag)
        guard requestsProbe || requestsInvitation || requestsStop else { return nil }
        let actionCount = [requestsProbe, requestsInvitation, requestsStop]
            .filter { $0 }
            .count
        guard actionCount == 1 else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
        }
        var requestedPath: String?
        var socketPath = environment[
            "OPENSTEAMER_SECONDARY_VIEWER_CONTROL_SOCKET"
        ]
        var socketArgumentWasProvided = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case probeFlag, requestFlag, stopFlag:
                guard requestedPath == nil,
                      index + 1 < arguments.count else {
                    throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
                }
                index += 1
                requestedPath = arguments[index]
            case "--secondary-test-viewer-control-socket":
                guard !socketArgumentWasProvided,
                      index + 1 < arguments.count else {
                    throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
                }
                index += 1
                socketPath = arguments[index]
                socketArgumentWasProvided = true
            default:
                throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
            }
            index += 1
        }
        guard let requestedPath,
              WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(requestedPath) else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
        }
        let resolvedSocketPath = try socketPath ??
            WorldwideSecondaryTestViewerControlServer.defaultSocketPath()
        guard WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(resolvedSocketPath) else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
        }
        let requestedURL = URL(fileURLWithPath: requestedPath)
        let action: Action
        if requestsProbe {
            action = .probe(outputURL: requestedURL)
        } else if requestsInvitation {
            let receiptPath = requestedPath + ".receipt"
            guard WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(receiptPath),
                  receiptPath != requestedPath else {
                throw WorldwideSecondaryTestViewerControlClientError.invalidArguments
            }
            action = .request(
                invitationURL: requestedURL,
                receiptURL: URL(fileURLWithPath: receiptPath)
            )
        } else {
            action = .stop(receiptURL: requestedURL)
        }
        return Self(socketPath: resolvedSocketPath, action: action)
    }

    func run() throws {
        let client = WorldwideSecondaryTestViewerControlClient()
        let hostLockURL = try WorldwideSecondaryTestViewerHostIdentity
            .defaultLockRecordURL()
        switch action {
        case .probe(let outputURL):
            try client.probeAndWriteStatus(
                socketPath: socketPath,
                hostLockURL: hostLockURL,
                outputURL: outputURL
            )
        case .request(let invitationURL, let receiptURL):
            try client.requestAndWriteInvitation(
                socketPath: socketPath,
                hostLockURL: hostLockURL,
                outputURL: invitationURL,
                receiptURL: receiptURL
            )
        case .stop(let receiptURL):
            try client.stopGeneration(
                socketPath: socketPath,
                hostLockURL: hostLockURL,
                receiptURL: receiptURL
            )
        }
    }

}

/// Nonsecret, nonce-bound status record emitted by the client-only probe mode.
struct WorldwideSecondaryTestViewerStatusProbeResult: Codable, Equatable, Sendable {
    static let version = 1
    static let messageType = "secondaryTestViewerStatusProbeResult"
    static let maximumBytes = 1_024

    let v: Int
    let type: String
    let hostProcessIdentifier: Int32
    let hostGeneration: String
    let managerGeneration: UInt64
    let managerPhase: String
    let managerIsIdle: Bool
    let requestNonce: String

    init(
        hostProcessIdentifier: Int32,
        hostGeneration: String,
        managerGeneration: UInt64,
        managerPhase: String,
        managerIsIdle: Bool,
        requestNonce: String
    ) {
        v = Self.version
        type = Self.messageType
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostGeneration = hostGeneration
        self.managerGeneration = managerGeneration
        self.managerPhase = managerPhase
        self.managerIsIdle = managerIsIdle
        self.requestNonce = requestNonce
    }

    func encode() throws -> Data {
        guard isValid else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == Set([
                "v",
                "type",
                "hostProcessIdentifier",
                "hostGeneration",
                "managerGeneration",
                "managerPhase",
                "managerIsIdle",
                "requestNonce",
              ]),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.isValid else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        return result
    }

    private var isValid: Bool {
        guard v == Self.version,
              type == Self.messageType,
              hostProcessIdentifier > 0,
              Self.isLowercaseHex(hostGeneration, count: 64),
              Self.isLowercaseHex(requestNonce, count: 32),
              let phase = WorldwideSecondaryTestViewerManagerSnapshot.Phase(
                rawValue: managerPhase
              ) else {
            return false
        }
        return managerIsIdle == (phase == .idle)
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Bounded client for one-response secondary-viewer control operations.
///
/// It binds every response to the owner-only host-lock identity and a fresh 128-bit nonce. A stale
/// manager generation is retried exactly once with the returned generation and a different nonce.
struct WorldwideSecondaryTestViewerControlClient: Sendable {
    typealias Exchange = @Sendable (
        _ socketPath: String,
        _ request: WorldwideSecondaryTestViewerControlRequest
    ) throws -> WorldwideSecondaryTestViewerControlResponse
    typealias FrameReader = (
        _ descriptor: Int32,
        _ idleTimeout: TimeInterval
    ) throws -> Data?

    // A probe is a local snapshot and should fail quickly. Renewal must outlive the rendezvous
    // transport's 30-second WebSocket upgrade budget, while exact stop must outlive the
    // 45-second whole-media teardown watchdog. Small margins preserve bounded client behavior
    // without converting healthy slow startup or native teardown into an uncertain delivery.
    static let probeResponseTimeout: TimeInterval = 2
    static let renewalResponseTimeout: TimeInterval = 35
    static let stopResponseTimeout: TimeInterval = 50
    static let trailingFrameTimeout: TimeInterval = 1

    private let exchange: Exchange

    struct MintedGeneration: Equatable, Sendable {
        let invitationCode: String
        let receipt: WorldwideSecondaryTestViewerGenerationReceipt
    }

    init(exchange: @escaping Exchange = Self.liveExchange) {
        self.exchange = exchange
    }

    func probeAndWriteStatus(
        socketPath: String,
        hostLockURL: URL,
        outputURL: URL
    ) throws {
        let reservation = try WorldwideSecondaryTestViewerStatusFile.reserve(
            at: outputURL
        )
        let result = try probeStatus(
            socketPath: socketPath,
            hostLockURL: hostLockURL
        )
        try reservation.commit(result)
    }

    func probeStatus(
        socketPath: String,
        hostLockURL: URL
    ) throws -> WorldwideSecondaryTestViewerStatusProbeResult {
        try probeStatus(
            socketPath: socketPath,
            hostIdentity: WorldwideSecondaryTestViewerHostIdentity.load(
                from: hostLockURL
            )
        )
    }

    func probeStatus(
        socketPath: String,
        hostIdentity: WorldwideSecondaryTestViewerHostIdentity
    ) throws -> WorldwideSecondaryTestViewerStatusProbeResult {
        let nonce = Self.makeNonce()
        let request = WorldwideSecondaryTestViewerControlRequest(
            probing: hostIdentity,
            requestNonce: nonce
        )
        let response = try exchange(socketPath, request)
        guard response.status == .observed,
              response.hostProcessIdentifier == hostIdentity.processIdentifier,
              response.hostGeneration == hostIdentity.generation,
              response.requestNonce == nonce,
              response.invitationCode == nil,
              response.generationReceipt == nil,
              let managerPhase = response.managerPhase,
              let managerIsIdle = response.managerIsIdle else {
            if response.hostProcessIdentifier == hostIdentity.processIdentifier,
               response.hostGeneration == hostIdentity.generation,
               response.requestNonce == nonce,
               response.status != .observed {
                throw WorldwideSecondaryTestViewerControlClientError
                    .probeRejected(response.status)
            }
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        let result = WorldwideSecondaryTestViewerStatusProbeResult(
            hostProcessIdentifier: response.hostProcessIdentifier,
            hostGeneration: response.hostGeneration,
            managerGeneration: response.managerGeneration,
            managerPhase: managerPhase,
            managerIsIdle: managerIsIdle,
            requestNonce: nonce
        )
        // Encoding is the single strict validation path used by both in-memory and file results.
        _ = try result.encode()
        return result
    }

    func requestAndWriteInvitation(
        socketPath: String,
        hostLockURL: URL,
        outputURL: URL,
        receiptURL: URL? = nil,
        afterReceiptCommitForTesting: (() throws -> Void)? = nil
    ) throws {
        let resolvedReceiptURL = receiptURL ?? URL(
            fileURLWithPath: outputURL.path + ".receipt"
        )
        guard resolvedReceiptURL.isFileURL,
              WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(resolvedReceiptURL.path),
              resolvedReceiptURL.path != outputURL.path else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let invitationReservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
            at: outputURL
        )
        let receiptReservation: WorldwideSecondaryTestViewerInvitationFile.Reservation
        do {
            receiptReservation = try WorldwideSecondaryTestViewerInvitationFile.reserve(
                at: resolvedReceiptURL
            )
        } catch {
            invitationReservation.cancel()
            throw error
        }
        var minted: MintedGeneration?
        var cleanupCandidate: WorldwideSecondaryTestViewerGenerationReceipt?
        do {
            let hostIdentity = try WorldwideSecondaryTestViewerHostIdentity.load(
                from: hostLockURL
            )
            let generation = try requestGeneration(
                socketPath: socketPath,
                hostIdentity: hostIdentity,
                beforeExchange: { receipt in
                    cleanupCandidate = receipt
                    try receiptReservation.stageReceipt(
                        WorldwideSecondaryTestViewerPersistedGenerationReceipt(
                            invitationOutputPath: outputURL.path,
                            receipt: receipt
                        )
                    )
                }
            )
            minted = generation
            let record = WorldwideSecondaryTestViewerPersistedGenerationReceipt(
                invitationOutputPath: outputURL.path,
                receipt: generation.receipt
            )
            // Finalize the same candidate that was durably staged before the exchange. If the
            // process dies after the server mints but before reading its response, the parent
            // runner already has a complete exact-generation cleanup record.
            try receiptReservation.commitReceipt(record)
            try afterReceiptCommitForTesting?()
            try invitationReservation.commit(generation.invitationCode)
        } catch {
            invitationReservation.cancel()
            if let minted {
                do {
                    let hostIdentity = WorldwideSecondaryTestViewerHostIdentity(
                        processIdentifier: minted.receipt.hostProcessIdentifier,
                        generation: minted.receipt.hostGeneration
                    )
                    try stopGeneration(
                        socketPath: socketPath,
                        hostIdentity: hostIdentity,
                        receipt: minted.receipt
                    )
                    invitationReservation.removePublishedFile()
                    receiptReservation.removePublishedFile()
                } catch {
                    // Preserve any successfully written nonsecret receipt for an explicit retry.
                    // Never reinterpret an unconfirmed teardown as a harmless output failure.
                    receiptReservation.preserveStagedReceipt()
                    throw WorldwideSecondaryTestViewerControlClientError.cleanupUnconfirmed
                }
            } else if let cleanupCandidate {
                do {
                    let hostIdentity = WorldwideSecondaryTestViewerHostIdentity(
                        processIdentifier: cleanupCandidate.hostProcessIdentifier,
                        generation: cleanupCandidate.hostGeneration
                    )
                    try proveCandidateInactive(
                        socketPath: socketPath,
                        hostIdentity: hostIdentity,
                        receipt: cleanupCandidate
                    )
                    invitationReservation.removePublishedFile()
                    receiptReservation.removePublishedFile()
                } catch {
                    // Keep the staged receipt for the parent runner when delivery outcome is
                    // uncertain. It contains no invitation material.
                    receiptReservation.preserveStagedReceipt()
                    throw WorldwideSecondaryTestViewerControlClientError.cleanupUnconfirmed
                }
            } else {
                receiptReservation.cancel()
            }
            throw error
        }
    }

    func requestInvitation(
        socketPath: String,
        hostIdentity: WorldwideSecondaryTestViewerHostIdentity
    ) throws -> String {
        try requestGeneration(
            socketPath: socketPath,
            hostIdentity: hostIdentity
        ).invitationCode
    }

    func requestGeneration(
        socketPath: String,
        hostIdentity: WorldwideSecondaryTestViewerHostIdentity,
        beforeExchange: (
            (WorldwideSecondaryTestViewerGenerationReceipt) throws -> Void
        )? = nil
    ) throws -> MintedGeneration {
        var expectedManagerGeneration: UInt64 = 0
        for attempt in 0...1 {
            let nonce = Self.makeNonce()
            let next = expectedManagerGeneration.addingReportingOverflow(1)
            guard !next.overflow, next.partialValue != 0 else {
                throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
            }
            let candidateReceipt = WorldwideSecondaryTestViewerGenerationReceipt(
                hostProcessIdentifier: hostIdentity.processIdentifier,
                hostGeneration: hostIdentity.generation,
                managerGeneration: next.partialValue,
                renewalRequestNonce: nonce
            )
            try beforeExchange?(candidateReceipt)
            let request = WorldwideSecondaryTestViewerControlRequest(
                expectedHostProcessIdentifier: hostIdentity.processIdentifier,
                expectedHostGeneration: hostIdentity.generation,
                expectedManagerGeneration: expectedManagerGeneration,
                requestNonce: nonce
            )
            let response = try exchange(socketPath, request)
            guard response.hostProcessIdentifier == hostIdentity.processIdentifier,
                  response.hostGeneration == hostIdentity.generation,
                  response.requestNonce == nonce else {
                throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
            }
            switch response.status {
            case .started:
                guard response.managerGeneration == next.partialValue,
                      let invitation = response.invitationCode,
                      (try? RemoteInvitationCode(invitation)) != nil,
                      let receipt = response.generationReceipt,
                      receipt.isValid,
                      receipt.hostProcessIdentifier == hostIdentity.processIdentifier,
                      receipt.hostGeneration == hostIdentity.generation,
                      receipt.managerGeneration == response.managerGeneration,
                      receipt.renewalRequestNonce == nonce,
                      receipt == candidateReceipt else {
                    throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
                }
                return MintedGeneration(
                    invitationCode: invitation,
                    receipt: receipt
                )
            case .staleGeneration where attempt == 0:
                expectedManagerGeneration = response.managerGeneration
            default:
                throw WorldwideSecondaryTestViewerControlClientError
                    .renewalRejected(response.status)
            }
        }
        throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
    }

    /// Stops and proves native teardown for the exact generation in an owner-only receipt file.
    func stopGeneration(
        socketPath: String,
        hostLockURL: URL,
        receiptURL: URL
    ) throws {
        let loaded = try WorldwideSecondaryTestViewerGenerationReceiptFile.load(
            from: receiptURL
        )
        let hostIdentity = try WorldwideSecondaryTestViewerHostIdentity.load(
            from: hostLockURL
        )
        guard loaded.record.receipt.hostProcessIdentifier == hostIdentity.processIdentifier,
              loaded.record.receipt.hostGeneration == hostIdentity.generation else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeEndpoint
        }
        try stopGeneration(
            socketPath: socketPath,
            hostIdentity: hostIdentity,
            receipt: loaded.record.receipt
        )
        try loaded.consume()
    }

    func stopGeneration(
        socketPath: String,
        hostIdentity: WorldwideSecondaryTestViewerHostIdentity,
        receipt: WorldwideSecondaryTestViewerGenerationReceipt
    ) throws {
        guard receipt.isValid,
              receipt.hostProcessIdentifier == hostIdentity.processIdentifier,
              receipt.hostGeneration == hostIdentity.generation else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        try proveCandidateInactive(
            socketPath: socketPath,
            hostIdentity: hostIdentity,
            receipt: receipt
        )
    }

    /// Proves that a durably staged request candidate is no longer active. The candidate may have
    /// been staged immediately before a transport failure and therefore never reached the server.
    private func proveCandidateInactive(
        socketPath: String,
        hostIdentity: WorldwideSecondaryTestViewerHostIdentity,
        receipt: WorldwideSecondaryTestViewerGenerationReceipt
    ) throws {
        let nonce = Self.makeNonce()
        let request = WorldwideSecondaryTestViewerControlRequest(
            stopping: receipt,
            requestNonce: nonce
        )
        let response = try exchange(socketPath, request)
        guard response.hostProcessIdentifier == hostIdentity.processIdentifier,
              response.hostGeneration == hostIdentity.generation,
              response.requestNonce == nonce else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        switch response.status {
        case .stopped:
            guard response.managerGeneration == receipt.managerGeneration else {
                throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
            }
        case .invalidReceipt:
            // The server never associated this candidate with a minted service, or a newer
            // non-overlapping generation has already fenced it. Equality is never proof of
            // inactivity: it can mean the server lost the cleanup receipt for its current,
            // potentially quarantined native capture.
            guard response.managerGeneration != receipt.managerGeneration else {
                throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
            }
        case .staleGeneration:
            // Non-overlap means an older generation had to confirm teardown before a newer one;
            // a future candidate was never created.
            break
        default:
            throw WorldwideSecondaryTestViewerControlClientError
                .stopRejected(response.status)
        }
    }

    private static func liveExchange(
        socketPath: String,
        request: WorldwideSecondaryTestViewerControlRequest
    ) throws -> WorldwideSecondaryTestViewerControlResponse {
        var before = stat()
        guard WorldwideSecondaryTestViewerControlPath.hasCanonicalParent(socketPath),
              lstat(socketPath, &before) == 0,
              before.st_mode & S_IFMT == S_IFSOCK,
              before.st_uid == geteuid(),
              before.st_mode & 0o777 == 0o600 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeEndpoint
        }
        let descriptor: Int32
        do {
            descriptor = try MediaBridgeSocket.connect(path: socketPath)
        } catch {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeEndpoint
        }
        defer { Darwin.close(descriptor) }
        var peerProcessIdentifier: pid_t = 0
        var peerProcessIdentifierSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerProcessIdentifier,
            &peerProcessIdentifierSize
        ) == 0,
        peerProcessIdentifier == request.expectedHostProcessIdentifier
        else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeEndpoint
        }
        var after = stat()
        guard WorldwideSecondaryTestViewerControlPath.hasCanonicalParent(socketPath),
              lstat(socketPath, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_mode & S_IFMT == S_IFSOCK,
              after.st_uid == geteuid(),
              after.st_mode & 0o777 == 0o600 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeEndpoint
        }
        do {
            try MediaBridgeFraming.writeFrame(descriptor, data: request.encode())
            return try readSingleResponse(
                descriptor: descriptor,
                request: request
            ) { descriptor, idleTimeout in
                try MediaBridgeFraming.readFrame(
                    descriptor,
                    idleTimeout: idleTimeout
                )
            }
        } catch let error as WorldwideSecondaryTestViewerControlClientError {
            throw error
        } catch {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
    }

    static func responseTimeout(
        for request: WorldwideSecondaryTestViewerControlRequest
    ) -> TimeInterval {
        if request.isProbe { return probeResponseTimeout }
        if request.isStop { return stopResponseTimeout }
        return renewalResponseTimeout
    }

    /// Reads exactly one response and then requires transport EOF, rejecting response smuggling.
    /// The injected reader keeps timeout-policy coverage deterministic without sleeping through
    /// production network or native-teardown budgets.
    static func readSingleResponse(
        descriptor: Int32,
        request: WorldwideSecondaryTestViewerControlRequest,
        readFrame: FrameReader
    ) throws -> WorldwideSecondaryTestViewerControlResponse {
        guard let data = try readFrame(
            descriptor,
            responseTimeout(for: request)
        ),
        data.count <= WorldwideSecondaryTestViewerControlRequest.maximumBytes
        else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        let response = try WorldwideSecondaryTestViewerControlResponse.decode(data)
        guard try readFrame(descriptor, trailingFrameTimeout) == nil else {
            throw WorldwideSecondaryTestViewerControlClientError.invalidResponse
        }
        return response
    }

    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            arc4random_buf(baseAddress, buffer.count)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Strict nonsecret record stored beside the invitation output.
struct WorldwideSecondaryTestViewerPersistedGenerationReceipt: Codable, Equatable, Sendable {
    static let version = 1
    static let messageType = "secondaryTestViewerPersistedGenerationReceipt"
    static let maximumBytes = 4_096

    let v: Int
    let type: String
    let invitationOutputPath: String
    let receipt: WorldwideSecondaryTestViewerGenerationReceipt

    init(
        invitationOutputPath: String,
        receipt: WorldwideSecondaryTestViewerGenerationReceipt
    ) {
        v = Self.version
        type = Self.messageType
        self.invitationOutputPath = invitationOutputPath
        self.receipt = receipt
    }

    func encode() throws -> Data {
        guard isValid else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == Set([
                "v",
                "type",
                "invitationOutputPath",
                "receipt",
              ]),
              let receiptObject = object["receipt"] as? [String: Any],
              WorldwideSecondaryTestViewerGenerationReceipt.hasExactKeys(receiptObject),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.isValid else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return decoded
    }

    private var isValid: Bool {
        v == Self.version &&
            type == Self.messageType &&
            WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(invitationOutputPath) &&
            receipt.isValid
    }
}

/// Atomically publishes one status record in a new owner-only file.
enum WorldwideSecondaryTestViewerStatusFile {
    fileprivate struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    final class Reservation {
        private let directory: Int32
        private let temporary: Int32
        private let directoryURL: URL
        private let temporaryName: String
        private let outputName: String
        private let directoryIdentity: Identity
        private let temporaryIdentity: Identity
        private var isCommitted = false

        fileprivate init(
            directory: Int32,
            temporary: Int32,
            directoryURL: URL,
            temporaryName: String,
            outputName: String,
            directoryIdentity: Identity,
            temporaryIdentity: Identity
        ) {
            self.directory = directory
            self.temporary = temporary
            self.directoryURL = directoryURL
            self.temporaryName = temporaryName
            self.outputName = outputName
            self.directoryIdentity = directoryIdentity
            self.temporaryIdentity = temporaryIdentity
        }

        deinit {
            if !isCommitted {
                Self.removeTemporaryFile(
                    directory: directory,
                    temporaryName: temporaryName,
                    identity: temporaryIdentity
                )
            }
            Darwin.close(temporary)
            Darwin.close(directory)
        }

        func commit(_ result: WorldwideSecondaryTestViewerStatusProbeResult) throws {
            guard !isCommitted else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            let bytes = try result.encode() + Data([0x0a])
            guard bytes.count <= WorldwideSecondaryTestViewerStatusProbeResult.maximumBytes else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            do {
                try bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.write(
                            temporary,
                            buffer.baseAddress!.advanced(by: offset),
                            buffer.count - offset
                        )
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                        }
                        offset += count
                    }
                }
                var temporaryMetadata = stat()
                guard fchmod(temporary, 0o600) == 0,
                      fstat(temporary, &temporaryMetadata) == 0,
                      Identity(
                        device: temporaryMetadata.st_dev,
                        inode: temporaryMetadata.st_ino
                      ) == temporaryIdentity,
                      temporaryMetadata.st_mode & S_IFMT == S_IFREG,
                      temporaryMetadata.st_uid == geteuid(),
                      temporaryMetadata.st_mode & 0o777 == 0o600,
                      temporaryMetadata.st_nlink == 1,
                      fsync(temporary) == 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }

                let reopened = open(
                    directoryURL.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard reopened >= 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                defer { Darwin.close(reopened) }
                var staged = stat()
                var existing = stat()
                let targetIsAbsent = fstatat(
                    directory,
                    outputName,
                    &existing,
                    AT_SYMLINK_NOFOLLOW
                ) != 0 && errno == ENOENT
                guard try Self.privateDirectoryIdentity(reopened) == directoryIdentity,
                      fstatat(
                        directory,
                        temporaryName,
                        &staged,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      Identity(device: staged.st_dev, inode: staged.st_ino) ==
                        temporaryIdentity,
                      staged.st_mode & S_IFMT == S_IFREG,
                      staged.st_uid == geteuid(),
                      staged.st_mode & 0o777 == 0o600,
                      staged.st_nlink == 1,
                      targetIsAbsent else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                guard renameatx_np(
                    directory,
                    temporaryName,
                    directory,
                    outputName,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                do {
                    var published = stat()
                    guard fstatat(
                        directory,
                        outputName,
                        &published,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0,
                    Identity(device: published.st_dev, inode: published.st_ino) ==
                        temporaryIdentity,
                    published.st_mode & S_IFMT == S_IFREG,
                    published.st_uid == geteuid(),
                    published.st_mode & 0o777 == 0o600,
                    published.st_nlink == 1,
                    fsync(directory) == 0 else {
                        throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                    }
                    isCommitted = true
                } catch {
                    Self.removePublishedFile(
                        directory: directory,
                        outputName: outputName,
                        identity: temporaryIdentity
                    )
                    throw error
                }
            } catch let error as WorldwideSecondaryTestViewerControlClientError {
                throw error
            } catch {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
        }

        private static func privateDirectoryIdentity(
            _ descriptor: Int32
        ) throws -> Identity {
            try WorldwideSecondaryTestViewerStatusFile.privateDirectoryIdentity(
                descriptor
            )
        }

        private static func removePublishedFile(
            directory: Int32,
            outputName: String,
            identity: Identity
        ) {
            var current = stat()
            if fstatat(
                directory,
                outputName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: current.st_dev, inode: current.st_ino) == identity,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_uid == geteuid() {
                _ = unlinkat(directory, outputName, 0)
                _ = fsync(directory)
            }
        }

        private static func removeTemporaryFile(
            directory: Int32,
            temporaryName: String,
            identity: Identity
        ) {
            var current = stat()
            if fstatat(
                directory,
                temporaryName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: current.st_dev, inode: current.st_ino) == identity,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_uid == geteuid() {
                _ = unlinkat(directory, temporaryName, 0)
            }
        }
    }

    static func reserve(at outputURL: URL) throws -> Reservation {
        guard outputURL.isFileURL,
              WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(outputURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directoryURL = outputURL.deletingLastPathComponent()
        let outputName = outputURL.lastPathComponent
        guard !outputName.isEmpty,
              outputName != ".",
              outputName != "..",
              WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directoryURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directory = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        do {
            let directoryIdentity = try privateDirectoryIdentity(directory)
            var existing = stat()
            guard fstatat(
                directory,
                outputName,
                &existing,
                AT_SYMLINK_NOFOLLOW
            ) != 0,
            errno == ENOENT else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            let temporaryName = ".\(outputName).\(UUID().uuidString).tmp"
            let temporary = openat(
                directory,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
            guard temporary >= 0 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            var openedMetadata = stat()
            guard fstat(temporary, &openedMetadata) == 0 else {
                Darwin.close(temporary)
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            let temporaryIdentity = Identity(
                device: openedMetadata.st_dev,
                inode: openedMetadata.st_ino
            )
            var restrictedMetadata = stat()
            guard openedMetadata.st_mode & S_IFMT == S_IFREG,
                  openedMetadata.st_uid == geteuid(),
                  openedMetadata.st_nlink == 1,
                  fchmod(temporary, 0o600) == 0,
                  fstat(temporary, &restrictedMetadata) == 0,
                  Identity(
                    device: restrictedMetadata.st_dev,
                    inode: restrictedMetadata.st_ino
                  ) == temporaryIdentity,
                  restrictedMetadata.st_mode & S_IFMT == S_IFREG,
                  restrictedMetadata.st_uid == geteuid(),
                  restrictedMetadata.st_mode & 0o777 == 0o600,
                  restrictedMetadata.st_nlink == 1 else {
                Darwin.close(temporary)
                var current = stat()
                if fstatat(
                    directory,
                    temporaryName,
                    &current,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                Identity(device: current.st_dev, inode: current.st_ino) ==
                    temporaryIdentity,
                current.st_mode & S_IFMT == S_IFREG,
                current.st_uid == geteuid() {
                    _ = unlinkat(directory, temporaryName, 0)
                }
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            return Reservation(
                directory: directory,
                temporary: temporary,
                directoryURL: directoryURL,
                temporaryName: temporaryName,
                outputName: outputName,
                directoryIdentity: directoryIdentity,
                temporaryIdentity: temporaryIdentity
            )
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private static func privateDirectoryIdentity(
        _ descriptor: Int32
    ) throws -> Identity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return Identity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}

/// Writes the invitation only to a new regular file in an existing owner-only directory.
enum WorldwideSecondaryTestViewerInvitationFile {
    fileprivate struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    final class Reservation {
        private let directory: Int32
        private let output: Int32
        private let directoryURL: URL
        private let fileName: String
        private let directoryIdentity: Identity
        private let outputIdentity: Identity
        private var isCommitted = false
        private var stagedReceipt: WorldwideSecondaryTestViewerPersistedGenerationReceipt?

        fileprivate init(
            directory: Int32,
            output: Int32,
            directoryURL: URL,
            fileName: String,
            directoryIdentity: Identity,
            outputIdentity: Identity
        ) {
            self.directory = directory
            self.output = output
            self.directoryURL = directoryURL
            self.fileName = fileName
            self.directoryIdentity = directoryIdentity
            self.outputIdentity = outputIdentity
        }

        deinit {
            cancel()
            Darwin.close(output)
            Darwin.close(directory)
        }

        func commit(_ invitation: String) throws {
            guard !isCommitted,
                  (try? RemoteInvitationCode(invitation)) != nil else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            try commitBytes(Data((invitation + "\n").utf8))
        }

        func commitReceipt(
            _ record: WorldwideSecondaryTestViewerPersistedGenerationReceipt
        ) throws {
            guard !isCommitted else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            if stagedReceipt == record {
                try finalizeStagedReceipt()
                return
            }
            try writeReceipt(record, finalize: true)
        }

        func stageReceipt(
            _ record: WorldwideSecondaryTestViewerPersistedGenerationReceipt
        ) throws {
            guard !isCommitted else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            try writeReceipt(record, finalize: false)
            stagedReceipt = record
        }

        private func writeReceipt(
            _ record: WorldwideSecondaryTestViewerPersistedGenerationReceipt,
            finalize: Bool
        ) throws {
            let encoded = try record.encode() + Data([0x0a])
            guard ftruncate(output, 0) == 0,
                  lseek(output, 0, SEEK_SET) == 0 else {
                cancel()
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            try commitBytes(encoded, finalize: finalize)
            if finalize {
                stagedReceipt = nil
            }
        }

        private func finalizeStagedReceipt() throws {
            let reopened = open(
                directoryURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard reopened >= 0 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            defer { Darwin.close(reopened) }
            var published = stat()
            guard try privateDirectoryIdentity(reopened) == directoryIdentity,
                  fstatat(
                    directory,
                    fileName,
                    &published,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  Identity(
                    device: published.st_dev,
                    inode: published.st_ino
                  ) == outputIdentity,
                  published.st_mode & S_IFMT == S_IFREG,
                  published.st_uid == geteuid(),
                  published.st_mode & 0o777 == 0o600,
                  published.st_nlink == 1,
                  fsync(output) == 0,
                  fsync(directory) == 0 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            stagedReceipt = nil
            isCommitted = true
        }

        private func commitBytes(_ bytes: Data, finalize: Bool = true) throws {
            do {
                try bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.write(
                            output,
                            buffer.baseAddress!.advanced(by: offset),
                            buffer.count - offset
                        )
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else {
                            throw WorldwideSecondaryTestViewerControlClientError
                                .unsafeOutput
                        }
                        offset += count
                    }
                }
                guard fsync(output) == 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                let reopened = open(
                    directoryURL.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard reopened >= 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                defer { Darwin.close(reopened) }
                var published = stat()
                guard try privateDirectoryIdentity(reopened) == directoryIdentity,
                      fstatat(
                        directory,
                        fileName,
                        &published,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      Identity(
                        device: published.st_dev,
                        inode: published.st_ino
                      ) == outputIdentity,
                      published.st_mode & S_IFMT == S_IFREG,
                      published.st_uid == geteuid(),
                      published.st_mode & 0o777 == 0o600,
                      published.st_nlink == 1,
                      fsync(directory) == 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                if finalize {
                    isCommitted = true
                }
            } catch {
                cancel()
                throw error
            }
        }

        func cancel() {
            guard !isCommitted else { return }
            var current = stat()
            if fstatat(
                directory,
                fileName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: current.st_dev, inode: current.st_ino) == outputIdentity,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_uid == geteuid() {
                _ = unlinkat(directory, fileName, 0)
            }
            stagedReceipt = nil
            isCommitted = true
        }

        /// Leaves a previously fsynced nonsecret receipt in place for a later authenticated stop.
        /// This is used only when exact teardown could not be confirmed. The staged bytes were
        /// made durable before the renewal request was sent, so detaching here never publishes a
        /// partially constructed post-mint record.
        func preserveStagedReceipt() {
            guard !isCommitted, stagedReceipt != nil else { return }
            stagedReceipt = nil
            isCommitted = true
        }

        /// Inode-fenced rollback used only after an exact generation stop has been confirmed.
        func removePublishedFile() {
            var current = stat()
            if fstatat(
                directory,
                fileName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: current.st_dev, inode: current.st_ino) == outputIdentity,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_uid == geteuid() {
                _ = unlinkat(directory, fileName, 0)
                _ = fsync(directory)
            }
            stagedReceipt = nil
            isCommitted = true
        }
    }

    static func reserve(
        at outputURL: URL,
        afterOutputOpenForTesting: (() throws -> Void)? = nil
    ) throws -> Reservation {
        guard outputURL.isFileURL,
              WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(outputURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directoryURL = outputURL.deletingLastPathComponent()
        let fileName = outputURL.lastPathComponent
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directoryURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directory = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directoryIdentity: Identity
        do {
            directoryIdentity = try privateDirectoryIdentity(directory)
        } catch {
            Darwin.close(directory)
            throw error
        }
        let output = openat(
            directory,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard output >= 0 else {
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        var outputMetadata = stat()
        guard fstat(output, &outputMetadata) == 0 else {
            Darwin.close(output)
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let outputIdentity = Identity(
            device: outputMetadata.st_dev,
            inode: outputMetadata.st_ino
        )
        guard outputMetadata.st_mode & S_IFMT == S_IFREG,
              outputMetadata.st_uid == geteuid(),
              outputMetadata.st_nlink == 1 else {
            removeIfOwned(
                directory: directory,
                fileName: fileName,
                identity: outputIdentity
            )
            Darwin.close(output)
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        do {
            try afterOutputOpenForTesting?()
        } catch {
            removeIfOwned(
                directory: directory,
                fileName: fileName,
                identity: outputIdentity
            )
            Darwin.close(output)
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        var restrictedMetadata = stat()
        guard fchmod(output, 0o600) == 0,
              fstat(output, &restrictedMetadata) == 0,
              Identity(
                device: restrictedMetadata.st_dev,
                inode: restrictedMetadata.st_ino
              ) == outputIdentity,
              restrictedMetadata.st_mode & S_IFMT == S_IFREG,
              restrictedMetadata.st_uid == geteuid(),
              restrictedMetadata.st_mode & 0o777 == 0o600,
              restrictedMetadata.st_nlink == 1,
              fsync(output) == 0,
              fsync(directory) == 0 else {
            removeIfOwned(
                directory: directory,
                fileName: fileName,
                identity: outputIdentity
            )
            Darwin.close(output)
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return Reservation(
            directory: directory,
            output: output,
            directoryURL: directoryURL,
            fileName: fileName,
            directoryIdentity: directoryIdentity,
            outputIdentity: outputIdentity
        )
    }

    static func write(_ invitation: String, to outputURL: URL) throws {
        let reservation = try reserve(at: outputURL)
        try reservation.commit(invitation)
    }

    private static func privateDirectoryIdentity(_ descriptor: Int32) throws -> Identity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return Identity(device: metadata.st_dev, inode: metadata.st_ino)
    }

    private static func removeIfOwned(
        directory: Int32,
        fileName: String,
        identity: Identity
    ) {
        var current = stat()
        if fstatat(
            directory,
            fileName,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        Identity(device: current.st_dev, inode: current.st_ino) == identity,
        current.st_mode & S_IFMT == S_IFREG,
        current.st_uid == geteuid() {
            _ = unlinkat(directory, fileName, 0)
        }
    }
}

/// Secure loader/consumer for the nonsecret exact-generation cleanup record.
enum WorldwideSecondaryTestViewerGenerationReceiptFile {
    fileprivate struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    final class Loaded {
        let record: WorldwideSecondaryTestViewerPersistedGenerationReceipt

        private let directory: Int32
        private let descriptor: Int32
        private let fileName: String
        private let directoryIdentity: Identity
        private let fileIdentity: Identity
        private var wasConsumed = false

        fileprivate init(
            record: WorldwideSecondaryTestViewerPersistedGenerationReceipt,
            directory: Int32,
            descriptor: Int32,
            fileName: String,
            directoryIdentity: Identity,
            fileIdentity: Identity
        ) {
            self.record = record
            self.directory = directory
            self.descriptor = descriptor
            self.fileName = fileName
            self.directoryIdentity = directoryIdentity
            self.fileIdentity = fileIdentity
        }

        deinit {
            Darwin.close(descriptor)
            Darwin.close(directory)
        }

        func consume() throws {
            guard !wasConsumed,
                  try Self.privateDirectoryIdentity(directory) == directoryIdentity else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            var current = stat()
            guard fstatat(
                directory,
                fileName,
                &current,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: current.st_dev, inode: current.st_ino) == fileIdentity,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_uid == geteuid(),
            current.st_mode & 0o777 == 0o600,
            current.st_nlink == 1,
            unlinkat(directory, fileName, 0) == 0,
            fsync(directory) == 0 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            wasConsumed = true
        }

        private static func privateDirectoryIdentity(
            _ descriptor: Int32
        ) throws -> Identity {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o777 == 0o700 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            return Identity(device: metadata.st_dev, inode: metadata.st_ino)
        }
    }

    static func load(from receiptURL: URL) throws -> Loaded {
        guard receiptURL.isFileURL,
              WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(receiptURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directoryURL = receiptURL.deletingLastPathComponent()
        let fileName = receiptURL.lastPathComponent
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directoryURL.path) else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directory = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directory >= 0 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        let directoryIdentity: Identity
        do {
            directoryIdentity = try privateDirectoryIdentity(directory)
        } catch {
            Darwin.close(directory)
            throw error
        }
        let descriptor = openat(
            directory,
            fileName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            Darwin.close(directory)
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        do {
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_mode & S_IFMT == S_IFREG,
                  opened.st_uid == geteuid(),
                  opened.st_mode & 0o777 == 0o600,
                  opened.st_nlink == 1,
                  opened.st_size > 0,
                  opened.st_size <= WorldwideSecondaryTestViewerPersistedGenerationReceipt
                    .maximumBytes else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            let fileIdentity = Identity(
                device: opened.st_dev,
                inode: opened.st_ino
            )
            var bytes = [UInt8](repeating: 0, count: Int(opened.st_size))
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.read(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        buffer.count - offset
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
                }
                offset += count
            }
            var canonical = stat()
            guard fstatat(
                directory,
                fileName,
                &canonical,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            Identity(device: canonical.st_dev, inode: canonical.st_ino) == fileIdentity,
            canonical.st_mode & S_IFMT == S_IFREG,
            canonical.st_uid == geteuid(),
            canonical.st_mode & 0o777 == 0o600,
            canonical.st_nlink == 1 else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            let record = try WorldwideSecondaryTestViewerPersistedGenerationReceipt.decode(
                Data(bytes)
            )
            guard record.invitationOutputPath + ".receipt" == receiptURL.path else {
                throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
            }
            return Loaded(
                record: record,
                directory: directory,
                descriptor: descriptor,
                fileName: fileName,
                directoryIdentity: directoryIdentity,
                fileIdentity: fileIdentity
            )
        } catch {
            Darwin.close(descriptor)
            Darwin.close(directory)
            throw error
        }
    }

    private static func privateDirectoryIdentity(
        _ descriptor: Int32
    ) throws -> Identity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o777 == 0o700 else {
            throw WorldwideSecondaryTestViewerControlClientError.unsafeOutput
        }
        return Identity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}
