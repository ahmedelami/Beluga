import Foundation

/// Injectable boundary around one legacy consume-once worldwide screen service.
protocol WorldwideSecondaryTestViewerServing: AnyObject, Sendable {
    var completion: AsyncStream<Void> { get }

    func startSecondaryTestViewer() async throws -> String
    func stopSecondaryTestViewer() async
    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool
}

extension WorldwideScreenService: WorldwideSecondaryTestViewerServing {
    func startSecondaryTestViewer() async throws -> String {
        try await start()
    }

    func stopSecondaryTestViewer() async {
        await stop()
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        hasUnconfirmedNativeCaptureStop()
    }
}

/// Creates a new consume-once service for every accepted manager generation.
struct WorldwideSecondaryTestViewerServiceFactory: @unchecked Sendable {
    private let make: @Sendable (UInt64) throws -> any WorldwideSecondaryTestViewerServing

    init(
        _ make: @escaping @Sendable (UInt64) throws ->
            any WorldwideSecondaryTestViewerServing
    ) {
        self.make = make
    }

    func makeService(
        generation: UInt64
    ) throws -> any WorldwideSecondaryTestViewerServing {
        try make(generation)
    }
}

struct WorldwideSecondaryTestViewerInvitation: Equatable, Sendable {
    let managerGeneration: UInt64
    let code: String
}

struct WorldwideSecondaryTestViewerManagerSnapshot: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case idle
        case starting
        case running
        case stopping
        case quarantined
        case shutdown
    }

    let managerGeneration: UInt64
    let phase: Phase
}

enum WorldwideSecondaryTestViewerManagerError: LocalizedError, Equatable {
    case staleGeneration(expected: UInt64, actual: UInt64)
    case busy(generation: UInt64)
    case quarantined(generation: UInt64)
    case shutdown(generation: UInt64)
    case generationExhausted
    case nativeCaptureTeardownUnconfirmed(generation: UInt64)

    var errorDescription: String? {
        switch self {
        case .staleGeneration:
            "The secondary test viewer manager generation is stale."
        case .busy:
            "The secondary test viewer is busy."
        case .quarantined:
            "The secondary test viewer is quarantined after unconfirmed native teardown."
        case .shutdown:
            "The secondary test viewer manager is shut down."
        case .generationExhausted:
            "The secondary test viewer manager generation is exhausted."
        case .nativeCaptureTeardownUnconfirmed:
            "Native capture did not confirm shutdown for the secondary test viewer."
        }
    }
}

/// Owns renewable, non-overlapping secondary consume-once services.
///
/// A generation is admitted only while the manager is idle. Completion first closes the old
/// service and confirms its native capture stopped; only then may a factory create the next
/// service. An uncertain stop permanently quarantines renewal until process shutdown retries the
/// retained service. Every completion callback is fenced by both generation and object identity,
/// so a delayed callback from an old service cannot affect a new generation.
actor WorldwideSecondaryTestViewerCoordinator {
    private let factory: WorldwideSecondaryTestViewerServiceFactory
    private let beforeGenerationAdvanceForTesting:
        (@Sendable (UInt64) async -> Void)?
    private var managerGeneration: UInt64 = 0
    private var phase = WorldwideSecondaryTestViewerManagerSnapshot.Phase.idle
    private var service: (any WorldwideSecondaryTestViewerServing)?
    private var serviceIdentity: ObjectIdentifier?
    private var serviceCompletionTask: Task<Void, Never>?
    private var teardownTask: Task<Bool, Never>?
    private var shutdownRequested = false

    init(
        factory: WorldwideSecondaryTestViewerServiceFactory,
        beforeGenerationAdvanceForTesting:
            (@Sendable (UInt64) async -> Void)? = nil
    ) {
        self.factory = factory
        self.beforeGenerationAdvanceForTesting = beforeGenerationAdvanceForTesting
    }

    /// Compatibility entry point for the initial invitation presented by the host process.
    func start() async throws -> String {
        try await renew(expectedManagerGeneration: managerGeneration).code
    }

    /// Creates and starts the next consume-once service if no generation remains active.
    func renew(
        expectedManagerGeneration: UInt64,
        generationDidAdvance: (@Sendable (UInt64) -> Void)? = nil
    ) async throws -> WorldwideSecondaryTestViewerInvitation {
        guard expectedManagerGeneration == managerGeneration else {
            throw WorldwideSecondaryTestViewerManagerError.staleGeneration(
                expected: expectedManagerGeneration,
                actual: managerGeneration
            )
        }
        guard !shutdownRequested else {
            throw WorldwideSecondaryTestViewerManagerError.shutdown(
                generation: managerGeneration
            )
        }
        switch phase {
        case .idle:
            break
        case .starting, .running, .stopping:
            throw WorldwideSecondaryTestViewerManagerError.busy(
                generation: managerGeneration
            )
        case .quarantined:
            throw WorldwideSecondaryTestViewerManagerError.quarantined(
                generation: managerGeneration
            )
        case .shutdown:
            throw WorldwideSecondaryTestViewerManagerError.shutdown(
                generation: managerGeneration
            )
        }

        if let beforeGenerationAdvanceForTesting {
            await beforeGenerationAdvanceForTesting(expectedManagerGeneration)
            // The test-only suspension is deliberately treated like any other actor reentrancy:
            // revalidate every admission invariant before advancing the fence.
            guard expectedManagerGeneration == managerGeneration else {
                throw WorldwideSecondaryTestViewerManagerError.staleGeneration(
                    expected: expectedManagerGeneration,
                    actual: managerGeneration
                )
            }
            guard !shutdownRequested, phase == .idle else {
                if shutdownRequested || phase == .shutdown {
                    throw WorldwideSecondaryTestViewerManagerError.shutdown(
                        generation: managerGeneration
                    )
                }
                if phase == .quarantined {
                    throw WorldwideSecondaryTestViewerManagerError.quarantined(
                        generation: managerGeneration
                    )
                }
                throw WorldwideSecondaryTestViewerManagerError.busy(
                    generation: managerGeneration
                )
            }
        }

        let increment = managerGeneration.addingReportingOverflow(1)
        guard !increment.overflow, increment.partialValue != 0 else {
            throw WorldwideSecondaryTestViewerManagerError.generationExhausted
        }
        managerGeneration = increment.partialValue
        phase = .starting
        generationDidAdvance?(managerGeneration)

        let newService: any WorldwideSecondaryTestViewerServing
        do {
            newService = try factory.makeService(generation: managerGeneration)
        } catch {
            phase = .idle
            throw error
        }
        let generation = managerGeneration
        let identity = ObjectIdentifier(newService)
        service = newService
        serviceIdentity = identity

        do {
            let invitationCode = try await newService.startSecondaryTestViewer()
            guard generation == managerGeneration,
                  serviceIdentity == identity,
                  phase == .starting,
                  !shutdownRequested else {
                _ = await teardown(
                    generation: generation,
                    identity: identity,
                    service: newService
                )
                throw CancellationError()
            }
            phase = .running
            observeCompletion(
                of: newService,
                generation: generation
            )
            return WorldwideSecondaryTestViewerInvitation(
                managerGeneration: generation,
                code: invitationCode
            )
        } catch {
            if generation == managerGeneration,
               serviceIdentity == identity,
               phase != .quarantined,
               phase != .shutdown {
                let confirmed = await teardown(
                    generation: generation,
                    identity: identity,
                    service: newService
                )
                if !confirmed {
                    throw WorldwideSecondaryTestViewerManagerError
                        .nativeCaptureTeardownUnconfirmed(generation: generation)
                }
            }
            throw error
        }
    }

    /// Stops only the exact renewable generation named by an authenticated control receipt.
    ///
    /// This is deliberately distinct from ``stop()``: runner cleanup must not shut down the
    /// manager or affect the primary worldwide host. A stale receipt can never stop a newer
    /// generation, and success is returned only after the secondary native capture teardown is
    /// confirmed. An already-idle matching generation is also a valid, idempotent stop proof.
    func stopGeneration(
        expectedManagerGeneration: UInt64
    ) async throws -> WorldwideSecondaryTestViewerManagerSnapshot {
        guard expectedManagerGeneration == managerGeneration else {
            throw WorldwideSecondaryTestViewerManagerError.staleGeneration(
                expected: expectedManagerGeneration,
                actual: managerGeneration
            )
        }
        guard !shutdownRequested else {
            throw WorldwideSecondaryTestViewerManagerError.shutdown(
                generation: managerGeneration
            )
        }

        switch phase {
        case .idle:
            return snapshot()
        case .starting, .running, .stopping, .quarantined:
            guard let service, let identity = serviceIdentity else {
                // An active-looking phase without its exact service identity is never safe to
                // reinterpret as stopped.
                phase = .quarantined
                throw WorldwideSecondaryTestViewerManagerError
                    .nativeCaptureTeardownUnconfirmed(generation: managerGeneration)
            }
            let generation = managerGeneration
            let confirmed = await teardown(
                generation: generation,
                identity: identity,
                service: service,
                retryQuarantined: true
            )
            guard confirmed,
                  managerGeneration == expectedManagerGeneration,
                  self.service == nil,
                  serviceIdentity == nil,
                  phase == .idle else {
                throw WorldwideSecondaryTestViewerManagerError
                    .nativeCaptureTeardownUnconfirmed(generation: generation)
            }
            return snapshot()
        case .shutdown:
            throw WorldwideSecondaryTestViewerManagerError.shutdown(
                generation: managerGeneration
            )
        }
    }

    /// Permanently closes renewal admission and joins or retries retained native teardown.
    @discardableResult
    func stop() async -> Bool {
        shutdownRequested = true
        serviceCompletionTask?.cancel()
        serviceCompletionTask = nil

        guard let service, let identity = serviceIdentity else {
            phase = .shutdown
            return true
        }
        let generation = managerGeneration
        let confirmed = await teardown(
            generation: generation,
            identity: identity,
            service: service,
            retryQuarantined: true
        )
        if confirmed {
            phase = .shutdown
        }
        return confirmed
    }

    func snapshot() -> WorldwideSecondaryTestViewerManagerSnapshot {
        WorldwideSecondaryTestViewerManagerSnapshot(
            managerGeneration: managerGeneration,
            phase: phase
        )
    }

    private func observeCompletion(
        of service: any WorldwideSecondaryTestViewerServing,
        generation: UInt64
    ) {
        let completion = service.completion
        serviceCompletionTask = Task { [weak self] in
            for await _ in completion { break }
            guard !Task.isCancelled else { return }
            await self?.serviceDidComplete(
                generation: generation,
                service: service
            )
        }
    }

    /// Generation-fenced callback entry point. Internal visibility keeps the stale-callback
    /// contract directly testable without exposing it outside CaptureServer.
    func serviceDidComplete(
        generation: UInt64,
        service: any WorldwideSecondaryTestViewerServing
    ) async {
        let identity = ObjectIdentifier(service)
        guard generation == managerGeneration,
              serviceIdentity == identity,
              phase == .running else {
            return
        }
        serviceCompletionTask = nil
        _ = await teardown(
            generation: generation,
            identity: identity,
            service: service
        )
    }

    private func teardown(
        generation: UInt64,
        identity: ObjectIdentifier,
        service: any WorldwideSecondaryTestViewerServing,
        retryQuarantined: Bool = false
    ) async -> Bool {
        guard generation == managerGeneration,
              serviceIdentity == identity else {
            return true
        }
        if phase == .quarantined, !retryQuarantined {
            return false
        }
        serviceCompletionTask?.cancel()
        serviceCompletionTask = nil

        let task: Task<Bool, Never>
        if let teardownTask {
            task = teardownTask
        } else {
            phase = .stopping
            let created = Task {
                await service.stopSecondaryTestViewer()
                return !(await service
                    .secondaryTestViewerHasUnconfirmedNativeCaptureStop())
            }
            teardownTask = created
            task = created
        }

        let confirmed = await task.value
        guard generation == managerGeneration,
              serviceIdentity == identity else {
            return confirmed
        }
        teardownTask = nil
        if confirmed {
            self.service = nil
            serviceIdentity = nil
            phase = shutdownRequested ? .shutdown : .idle
        } else {
            // Retain the exact service for a process-shutdown retry. No future factory call is
            // admitted while native ownership remains uncertain.
            phase = .quarantined
        }
        return confirmed
    }
}
