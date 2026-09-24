import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideSecondaryTestViewerCoordinatorTests: XCTestCase {
    @MainActor
    func testSecondaryConstructionFailureIsContainedAfterPrimaryIsReady() {
        let primaryIsReady = true

        let outcome: SecondaryTestViewerConstructionOutcome<String> =
            CaptureServerMain.constructOptionalSecondaryTestViewer {
                throw SecondaryStartupTestError.rendezvousUnavailable
            }

        guard case .unavailable = outcome else {
            return XCTFail("Expected optional construction failure")
        }
        XCTAssertTrue(primaryIsReady)
    }

    func testPrimaryResultIsPresentedBeforeOptionalConstructionInMainFlow() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/CaptureServerMain.swift"
            ),
            encoding: .utf8
        )
        let flowStart = try XCTUnwrap(
            source.range(of: "let startResult = try await runUntilProcessTermination")
        )
        let flowEnd = try XCTUnwrap(
            source.range(
                of: "            } else {\n                worldwideHostCoordinator = nil",
                range: flowStart.upperBound..<source.endIndex
            )
        )
        let flow = source[flowStart.lowerBound..<flowEnd.lowerBound]
        let primaryPresentation = try XCTUnwrap(flow.range(of: "switch startResult"))
        let secondaryConstruction = try XCTUnwrap(
            flow.range(of: "constructOptionalSecondaryTestViewer {")
        )

        XCTAssertLessThan(
            primaryPresentation.lowerBound,
            secondaryConstruction.lowerBound
        )
    }

    func testLegacyRecoverableSecondaryStartupFailurePreservesPrimaryPath()
        async throws {
        let stopProbe = SecondaryStartupStopProbe(confirmation: true)

        let outcome = try await CaptureServerMain.startOptionalSecondaryTestViewer(
            start: {
                throw SecondaryStartupTestError.rendezvousUnavailable
            },
            stop: {
                stopProbe.stop()
            }
        )

        guard case .unavailable = outcome else {
            return XCTFail("Expected a contained optional-sidecar failure")
        }
        XCTAssertEqual(stopProbe.stopCount, 1)
    }

    func testLegacyUnconfirmedSecondaryStartupTeardownRemainsFatal() async {
        let stopProbe = SecondaryStartupStopProbe(confirmation: false)

        do {
            _ = try await CaptureServerMain.startOptionalSecondaryTestViewer(
                start: {
                    throw SecondaryStartupTestError.rendezvousUnavailable
                },
                stop: {
                    stopProbe.stop()
                }
            )
            XCTFail("Expected unconfirmed native teardown to remain fatal")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Native capture did not confirm shutdown"
                )
            )
        }
        XCTAssertEqual(stopProbe.stopCount, 1)
    }

    func testInitialGenerationExposesInvitationAndShutdownStopsExactlyOnce()
        async throws {
        let service = SecondaryTestViewerServiceStub(invitationCode: "TEST-CODE")
        let factory = SecondaryTestViewerFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )

        let code = try await coordinator.start()
        let running = await coordinator.snapshot()
        let firstStop = await coordinator.stop()
        let secondStop = await coordinator.stop()
        let stopped = await coordinator.snapshot()

        XCTAssertEqual(code, "TEST-CODE")
        XCTAssertEqual(
            running,
            WorldwideSecondaryTestViewerManagerSnapshot(
                managerGeneration: 1,
                phase: .running
            )
        )
        XCTAssertTrue(firstStop)
        XCTAssertTrue(secondStop)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(stopped.phase, .shutdown)
    }

    func testConfirmedCompletionAllowsFreshRenewalWithoutOverlap() async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(services: [first, second])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )

        let firstCode = try await coordinator.start()
        XCTAssertEqual(firstCode, "FIRST")
        first.signalCompletion()
        try await waitForPhase(.idle, on: coordinator)

        let invitation = try await coordinator.renew(
            expectedManagerGeneration: 1
        )
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(invitation.code, "SECOND")
        XCTAssertEqual(invitation.managerGeneration, 2)
        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(factory.requestedGenerations, [1, 2])
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(second.startCallCount, 1)
        _ = await coordinator.stop()
    }

    func testRenewalIsBusyWhileGenerationIsActive() async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let factory = SecondaryTestViewerFactoryStub(services: [first])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.start()

        do {
            _ = try await coordinator.renew(expectedManagerGeneration: 1)
            XCTFail("Expected active generation to remain exclusive")
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            XCTAssertEqual(error, .busy(generation: 1))
        }
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testExactGenerationStopConfirmsTeardownWithoutShuttingDownManager()
        async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(services: [first, second])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.renew(expectedManagerGeneration: 0)

        let stopped = try await coordinator.stopGeneration(
            expectedManagerGeneration: 1
        )
        let next = try await coordinator.renew(expectedManagerGeneration: 1)

        XCTAssertEqual(stopped.managerGeneration, 1)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(next.managerGeneration, 2)
        XCTAssertEqual(next.code, "SECOND")
        XCTAssertEqual(second.stopCallCount, 0)
        _ = await coordinator.stop()
    }

    func testStaleGenerationStopCannotAffectNewerService() async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(services: [first, second])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.renew(expectedManagerGeneration: 0)
        _ = try await coordinator.stopGeneration(expectedManagerGeneration: 1)
        _ = try await coordinator.renew(expectedManagerGeneration: 1)

        do {
            _ = try await coordinator.stopGeneration(expectedManagerGeneration: 1)
            XCTFail("Expected stale cleanup generation to be fenced")
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            XCTAssertEqual(error, .staleGeneration(expected: 1, actual: 2))
        }
        let current = await coordinator.snapshot()
        XCTAssertEqual(current.managerGeneration, 2)
        XCTAssertEqual(current.phase, .running)
        XCTAssertEqual(second.stopCallCount, 0)
        _ = await coordinator.stop()
    }

    func testExactGenerationStopRetriesQuarantineAndRequiresConfirmation()
        async throws {
        let service = SecondaryTestViewerServiceStub(
            invitationCode: "FIRST",
            nativeStopIsUnconfirmed: true
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: SecondaryTestViewerFactoryStub(services: [service]).factory
        )
        _ = try await coordinator.renew(expectedManagerGeneration: 0)

        do {
            _ = try await coordinator.stopGeneration(expectedManagerGeneration: 1)
            XCTFail("Expected unconfirmed native stop")
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            XCTAssertEqual(
                error,
                .nativeCaptureTeardownUnconfirmed(generation: 1)
            )
        }
        let quarantined = await coordinator.snapshot()
        XCTAssertEqual(quarantined.phase, .quarantined)
        service.nativeStopIsUnconfirmed = false

        let stopped = try await coordinator.stopGeneration(
            expectedManagerGeneration: 1
        )
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertEqual(service.stopCallCount, 2)
        _ = await coordinator.stop()
    }

    func testStaleManagerGenerationCannotCreateService() async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let factory = SecondaryTestViewerFactoryStub(services: [first])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.start()

        do {
            _ = try await coordinator.renew(expectedManagerGeneration: 0)
            XCTFail("Expected stale manager generation rejection")
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            XCTAssertEqual(
                error,
                .staleGeneration(expected: 0, actual: 1)
            )
        }
        XCTAssertEqual(factory.requestedGenerations, [1])
        _ = await coordinator.stop()
    }

    func testStaleCompletionCannotStopNewGeneration() async throws {
        let first = SecondaryTestViewerServiceStub(invitationCode: "FIRST")
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(services: [first, second])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.start()
        first.signalCompletion()
        try await waitForPhase(.idle, on: coordinator)
        _ = try await coordinator.renew(expectedManagerGeneration: 1)

        await coordinator.serviceDidComplete(generation: 1, service: first)
        let snapshot = await coordinator.snapshot()

        XCTAssertEqual(snapshot.managerGeneration, 2)
        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(second.stopCallCount, 0)
        _ = await coordinator.stop()
    }

    func testUnconfirmedNativeStopQuarantinesAndBlocksFactory() async throws {
        let first = SecondaryTestViewerServiceStub(
            invitationCode: "FIRST",
            nativeStopIsUnconfirmed: true
        )
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(services: [first, second])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        _ = try await coordinator.start()

        first.signalCompletion()
        try await waitForPhase(.quarantined, on: coordinator)
        do {
            _ = try await coordinator.renew(expectedManagerGeneration: 1)
            XCTFail("Expected quarantine to block renewal")
        } catch let error as WorldwideSecondaryTestViewerManagerError {
            XCTAssertEqual(error, .quarantined(generation: 1))
        }
        XCTAssertEqual(factory.requestedGenerations, [1])

        first.nativeStopIsUnconfirmed = false
        let shutdownConfirmed = await coordinator.stop()
        XCTAssertTrue(shutdownConfirmed)
        XCTAssertEqual(first.stopCallCount, 2)
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.phase, .shutdown)
    }

    func testConstructionFailureAdvancesFenceButLeavesManagerRenewable()
        async throws {
        let second = SecondaryTestViewerServiceStub(invitationCode: "SECOND")
        let factory = SecondaryTestViewerFactoryStub(
            services: [second],
            failuresBeforeServices: 1
        )
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )

        do {
            _ = try await coordinator.renew(expectedManagerGeneration: 0)
            XCTFail("Expected construction failure")
        } catch SecondaryStartupTestError.rendezvousUnavailable {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let afterFailure = await coordinator.snapshot()
        XCTAssertEqual(afterFailure.managerGeneration, 1)
        XCTAssertEqual(afterFailure.phase, .idle)

        let invitation = try await coordinator.renew(
            expectedManagerGeneration: 1
        )
        XCTAssertEqual(invitation.managerGeneration, 2)
        XCTAssertEqual(invitation.code, "SECOND")
        _ = await coordinator.stop()
    }

    func testCaptureLifetimeClosesControlAdmissionBeforeSecondaryTeardown()
        async throws {
        let service = SecondaryTestViewerServiceStub(invitationCode: "CODE")
        let factory = SecondaryTestViewerFactoryStub(services: [service])
        let coordinator = WorldwideSecondaryTestViewerCoordinator(
            factory: factory.factory
        )
        let lifetime = CaptureServiceLifetime()
        try lifetime.install(secondaryTestViewerCoordinator: coordinator)
        _ = try await coordinator.start()

        let confirmation = await lifetime.shutdown()
        let snapshot = await coordinator.snapshot()

        XCTAssertTrue(confirmation.worldwideNativeCaptureIsConfirmed)
        XCTAssertEqual(service.stopCallCount, 1)
        XCTAssertEqual(snapshot.phase, .shutdown)
    }

    func testProductionFactoryUsesSecondaryMediaProfileAndIsolatedViewOnlyInput()
        throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "macOS/Sources/CaptureServer/CaptureServerMain.swift"
            ),
            encoding: .utf8
        )
        let factoryStart = try XCTUnwrap(
            source.range(of: "let factory = WorldwideSecondaryTestViewerServiceFactory")
        )
        let handlerStart = try XCTUnwrap(
            source.range(
                of: "let handler = WorldwideSecondaryTestViewerControlHandler",
                range: factoryStart.upperBound..<source.endIndex
            )
        )
        let factorySource = source[
            factoryStart.lowerBound..<handlerStart.lowerBound
        ]

        XCTAssertTrue(factorySource.contains("featureProfile: .secondaryTest"))
        XCTAssertTrue(
            factorySource.contains(
                "MacRemoteInputController(\n                                    allowRemoteControl: false"
            )
        )
        XCTAssertFalse(
            factorySource.contains("remoteInputController: remoteInputController")
        )
        XCTAssertFalse(source.contains("Secondary one-time test viewer code"))
        XCTAssertFalse(source.contains("secondary.coordinator.start()"))
        XCTAssertTrue(source.contains("serviceLifetime.installAndStart("))
        XCTAssertFalse(source.contains("try controlServer.start()"))
    }

    private func waitForPhase(
        _ expected: WorldwideSecondaryTestViewerManagerSnapshot.Phase,
        on coordinator: WorldwideSecondaryTestViewerCoordinator
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await coordinator.snapshot().phase == expected {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await coordinator.snapshot().phase
        XCTFail("Timed out waiting for \(expected); observed \(actual)")
    }
}

private enum SecondaryStartupTestError: Error {
    case rendezvousUnavailable
}

private final class SecondaryStartupStopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let confirmation: Bool
    private var storedStopCount = 0

    init(confirmation: Bool) {
        self.confirmation = confirmation
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func stop() -> Bool {
        lock.withLock { storedStopCount += 1 }
        return confirmation
    }
}

private final class SecondaryTestViewerFactoryStub: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [SecondaryTestViewerServiceStub]
    private var remainingFailures: Int
    private var generations: [UInt64] = []

    init(
        services: [SecondaryTestViewerServiceStub],
        failuresBeforeServices: Int = 0
    ) {
        self.services = services
        remainingFailures = failuresBeforeServices
    }

    var factory: WorldwideSecondaryTestViewerServiceFactory {
        WorldwideSecondaryTestViewerServiceFactory { [self] generation in
            try lock.withLock {
                generations.append(generation)
                if remainingFailures > 0 {
                    remainingFailures -= 1
                    throw SecondaryStartupTestError.rendezvousUnavailable
                }
                guard !services.isEmpty else {
                    throw SecondaryStartupTestError.rendezvousUnavailable
                }
                return services.removeFirst()
            }
        }
    }

    var requestedGenerations: [UInt64] {
        lock.withLock { generations }
    }
}

private final class SecondaryTestViewerServiceStub:
    WorldwideSecondaryTestViewerServing,
    @unchecked Sendable
{
    let completion: AsyncStream<Void>

    private let lock = NSLock()
    private let completionContinuation: AsyncStream<Void>.Continuation
    private let invitationCode: String
    private var storedStartCallCount = 0
    private var storedStopCallCount = 0
    private var storedNativeStopIsUnconfirmed: Bool

    init(
        invitationCode: String,
        nativeStopIsUnconfirmed: Bool = false
    ) {
        let pair = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        completion = pair.stream
        completionContinuation = pair.continuation
        self.invitationCode = invitationCode
        storedNativeStopIsUnconfirmed = nativeStopIsUnconfirmed
    }

    var startCallCount: Int {
        lock.withLock { storedStartCallCount }
    }

    var stopCallCount: Int {
        lock.withLock { storedStopCallCount }
    }

    var nativeStopIsUnconfirmed: Bool {
        get { lock.withLock { storedNativeStopIsUnconfirmed } }
        set { lock.withLock { storedNativeStopIsUnconfirmed = newValue } }
    }

    func startSecondaryTestViewer() async throws -> String {
        lock.withLock { storedStartCallCount += 1 }
        return invitationCode
    }

    func stopSecondaryTestViewer() async {
        lock.withLock { storedStopCallCount += 1 }
    }

    func secondaryTestViewerHasUnconfirmedNativeCaptureStop() async -> Bool {
        nativeStopIsUnconfirmed
    }

    func signalCompletion() {
        completionContinuation.yield(())
    }
}
