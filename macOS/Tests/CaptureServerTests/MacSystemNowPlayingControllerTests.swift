import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

private final class NowPlayingLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class FakeMacSystemNowPlayingRuntime: MacSystemNowPlayingRuntime,
    @unchecked Sendable
{
    private struct DeferredCommand {
        let authorization: @Sendable () -> Bool
        let completion: @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    }

    private let lock = NSLock()
    private var queuedResults: [MacNowPlayingRuntimeSnapshotResult] = []
    private var pendingFetches:
        [@Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void] = []
    private var deferredCommands: [DeferredCommand] = []
    private var fetches = 0
    private var sentCommands: [Int] = []
    var isAvailable = true
    var commandResult: WebRTCRemoteMediaCommandResult = .applied
    var deferCommands = false
    var onFetch: (@Sendable () -> Void)?
    var onSend: (@Sendable () -> Void)?

    func enqueue(_ result: MacNowPlayingRuntimeSnapshotResult) {
        lock.withLock { queuedResults.append(result) }
    }

    var fetchCount: Int { lock.withLock { fetches } }
    var commands: [Int] { lock.withLock { sentCommands } }

    func fetchSnapshot(
        completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void
    ) {
        let result: MacNowPlayingRuntimeSnapshotResult? = lock.withLock {
            fetches += 1
            if queuedResults.isEmpty {
                pendingFetches.append(completion)
                return nil
            }
            return queuedResults.removeFirst()
        }
        onFetch?()
        if let result { completion(result) }
    }

    func deliver(_ result: MacNowPlayingRuntimeSnapshotResult) {
        let callback = lock.withLock {
            pendingFetches.isEmpty ? nil : pendingFetches.removeFirst()
        }
        callback?(result)
    }

    func send(
        rawCommand: Int,
        snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    ) {
        let deferred = lock.withLock {
            sentCommands.append(rawCommand)
            if deferCommands {
                deferredCommands.append(DeferredCommand(
                    authorization: isAuthorized,
                    completion: completion
                ))
                return true
            }
            return false
        }
        onSend?()
        if !deferred {
            completion(isAuthorized() ? commandResult : .staleContext)
        }
    }

    @discardableResult
    func resolveDeferredCommands() -> [Bool] {
        let commands = lock.withLock {
            let commands = deferredCommands
            deferredCommands.removeAll()
            return commands
        }
        var authorizations: [Bool] = []
        for command in commands {
            let isAuthorized = command.authorization()
            authorizations.append(isAuthorized)
            command.completion(isAuthorized ? commandResult : .staleContext)
        }
        return authorizations
    }
}

final class MacSystemNowPlayingControllerTests: XCTestCase {
    func testArtworkPublishesAndClearsWithoutRotatingSameItemContext() async throws {
        let reference = try XCTUnwrap(WebRTCRemoteMediaArtworkReference(videoID: "abcdefghijk"))
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot(artwork: reference)))
        let controller = MacSystemNowPlayingController(runtime: runtime)
        let states = NowPlayingLockedBox<[WebRTCRemoteMediaStateUpdate]>([])
        let initial = expectation(description: "artwork published")
        let cleared = expectation(description: "artwork cleared")
        controller.start { state in
            states.update { $0.append(state) }
            if state.item?.artwork != nil { initial.fulfill() }
            else if state.item != nil { cleared.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 1)
        let first = try XCTUnwrap(states.read().last)
        XCTAssertEqual(first.item?.artwork, reference)
        runtime.enqueue(.snapshot(Self.snapshot()))
        controller.refresh()
        await fulfillment(of: [cleared], timeout: 1)
        let after = try XCTUnwrap(states.read().last)
        XCTAssertNil(after.item?.artwork)
        XCTAssertEqual(after.item?.contextID, first.item?.contextID)
        XCTAssertEqual(after.revision, first.revision + 1)
        controller.stop()
    }

    func testSnapshotRebasesElapsedAndUsesOnlyExactEnabledCommands() async {
        let currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot(
            timestamp: currentDate.addingTimeInterval(-5),
            enabledCommands: [0, 1, 4]
        )))
        let controller = MacSystemNowPlayingController(
            runtime: runtime,
            now: { currentDate }
        )
        let update = NowPlayingLockedBox<WebRTCRemoteMediaStateUpdate?>(nil)
        let published = expectation(description: "state published")
        controller.start { state in
            update.update { $0 = state }
            published.fulfill()
        }

        await fulfillment(of: [published], timeout: 1)
        let item = update.read()?.item
        XCTAssertEqual(item?.elapsedTime ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(item?.duration, 120)
        XCTAssertEqual(item?.capabilities.canPlay, true)
        XCTAssertEqual(item?.capabilities.canPause, true)
        XCTAssertEqual(item?.capabilities.canSkipForward, true)
        XCTAssertEqual(item?.capabilities.canSkipBackward, false)
        controller.stop()
    }

    func testAsyncRuntimeReplyDeterminesCommandResult() async {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.commandResult = .failed
        runtime.enqueue(.snapshot(Self.snapshot()))
        let controller = MacSystemNowPlayingController(runtime: runtime)
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)

        let prepared = controller.prepareCommand(.pause, contextID: context.read()!, isAuthorized: { true })!
        let result = await controller.perform(prepared)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(runtime.commands, [1])
        controller.stop()
    }

    func testCommandTimeoutRevokesAttemptBeforeDelayedRuntimeWork() async {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.deferCommands = true
        runtime.enqueue(.snapshot(Self.snapshot()))
        let controller = MacSystemNowPlayingController(
            runtime: runtime,
            operationTimeout: 0.02
        )
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)

        let prepared = controller.prepareCommand(.play, contextID: context.read()!, isAuthorized: { true })!
        let result = await controller.perform(prepared)
        let lateAuthorizations = runtime.resolveDeferredCommands()

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(lateAuthorizations, [false])
        controller.stop()
    }

    func testStopRevokesCommandBeforeRuntimeAppliesIt() async {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.deferCommands = true
        runtime.enqueue(.snapshot(Self.snapshot()))
        let controller = MacSystemNowPlayingController(runtime: runtime)
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        let sendStarted = expectation(description: "runtime send started")
        runtime.onSend = { sendStarted.fulfill() }
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)

        let prepared = controller.prepareCommand(.play, contextID: context.read()!, isAuthorized: { true })!
        let command = Task { await controller.perform(prepared) }
        await fulfillment(of: [sendStarted], timeout: 1)
        controller.stop()
        runtime.resolveDeferredCommands()

        let result = await command.value
        XCTAssertEqual(result, .staleContext)
    }

    func testRetryWithdrawsPausedControlsAndFreshSnapshotCannotReviveOldPlay() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        let pausedSnapshot = Self.snapshot(playbackRate: 0, enabledCommands: [0])
        runtime.enqueue(.snapshot(pausedSnapshot))
        runtime.deferCommands = true
        let fetchTimes = NowPlayingLockedBox<[TimeInterval]>([])
        let thirdRetryFetched = expectation(description: "three bounded retry responses fetched")
        runtime.onFetch = { [weak runtime] in
            fetchTimes.update { $0.append(ProcessInfo.processInfo.systemUptime) }
            if runtime?.fetchCount == 4 { thirdRetryFetched.fulfill() }
        }
        let controller = MacSystemNowPlayingController(runtime: runtime, operationTimeout: 5)
        defer { controller.stop() }
        let updates = NowPlayingLockedBox<[WebRTCRemoteMediaStateUpdate]>([])
        let initiallyPaused = expectation(description: "initial paused item published")
        let withdrawn = expectation(description: "retry withdraws command presentation")
        let recovered = expectation(description: "fresh paused item republished")
        controller.start { update in
            updates.update { $0.append(update) }
            if update.revision == 1 { initiallyPaused.fulfill() }
            else if update.item == nil { withdrawn.fulfill() }
            else { recovered.fulfill() }
        }
        await fulfillment(of: [initiallyPaused], timeout: 1)
        let oldItem = try XCTUnwrap(updates.read().first?.item)
        XCTAssertEqual(oldItem.playbackState, .paused)
        XCTAssertTrue(oldItem.capabilities.canPlay)
        let preparedBeforeRetry = try XCTUnwrap(controller.prepareCommand(
            .play, contextID: oldItem.contextID, isAuthorized: { true }
        ))
        let pendingPrepared = try XCTUnwrap(controller.prepareCommand(
            .play, contextID: oldItem.contextID, isAuthorized: { true }
        ))
        let reachedRuntime = expectation(description: "old Play waits at native boundary")
        runtime.onSend = { reachedRuntime.fulfill() }
        let pendingPlay = Task { await controller.perform(pendingPrepared) }
        await fulfillment(of: [reachedRuntime], timeout: 1)

        runtime.enqueue(.retry)
        runtime.enqueue(.retry)
        runtime.enqueue(.retry)
        controller.refresh()
        await fulfillment(of: [withdrawn], timeout: 1)
        // A missing clear is the original defect. Do not let a later timeout
        // masquerade as the retry transition or leave native work outstanding.
        guard updates.read().last?.item == nil else {
            controller.stop()
            XCTAssertEqual(runtime.resolveDeferredCommands(), [false])
            _ = await pendingPlay.value
            return
        }
        XCTAssertNil(controller.prepareCommand(
            .play, contextID: oldItem.contextID, isAuthorized: { true }
        ))
        let rejectedWhileUncertain = await controller.perform(preparedBeforeRetry)
        XCTAssertEqual(rejectedWhileUncertain, .staleContext)
        XCTAssertEqual(runtime.commands, [0])

        await fulfillment(of: [thirdRetryFetched], timeout: 1)
        let observedFetchTimes = fetchTimes.read()
        XCTAssertEqual(observedFetchTimes.count, 4)
        guard observedFetchTimes.count == 4 else {
            controller.stop()
            _ = runtime.resolveDeferredCommands()
            _ = await pendingPlay.value
            return
        }
        XCTAssertGreaterThanOrEqual(observedFetchTimes[2] - observedFetchTimes[1], 0.20)
        XCTAssertGreaterThanOrEqual(observedFetchTimes[3] - observedFetchTimes[2], 0.20)
        XCTAssertEqual(updates.read().map(\.revision), [1, 2], "repeated retry must not spam clears")

        runtime.enqueue(.snapshot(pausedSnapshot))
        controller.refresh()
        await fulfillment(of: [recovered], timeout: 1)
        let freshItem = try XCTUnwrap(updates.read().last?.item)
        XCTAssertEqual(updates.read().map(\.revision), [1, 2, 3])
        XCTAssertNotEqual(freshItem.contextID, oldItem.contextID)
        XCTAssertEqual(freshItem.title, oldItem.title)
        XCTAssertEqual(freshItem.playbackState, .paused)
        XCTAssertTrue(freshItem.capabilities.canPlay)
        XCTAssertEqual(runtime.resolveDeferredCommands(), [false], "fresh state cannot revive a pending Play")
        let pendingResult = await pendingPlay.value
        XCTAssertEqual(pendingResult, .staleContext)
        let oldResultAfterRecovery = await controller.perform(preparedBeforeRetry)
        XCTAssertEqual(oldResultAfterRecovery, .staleContext)

        runtime.onSend = nil
        runtime.deferCommands = false
        let freshPrepared = try XCTUnwrap(controller.prepareCommand(
            .play, contextID: freshItem.contextID, isAuthorized: { true }
        ))
        let freshResult = await controller.perform(freshPrepared)
        XCTAssertEqual(freshResult, .applied)
        XCTAssertEqual(runtime.commands, [0, 0], "only fresh Play adds a new native dispatch")
    }

    func testFailedPlayAlonePreservesPausedPresentationAndDoesNotReplay() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot(playbackRate: 0, enabledCommands: [0])))
        runtime.commandResult = .failed
        let controller = MacSystemNowPlayingController(runtime: runtime, operationTimeout: 5)
        defer { controller.stop() }
        let updates = NowPlayingLockedBox<[WebRTCRemoteMediaStateUpdate]>([])
        let published = expectation(description: "paused item published")
        controller.start { update in
            updates.update { $0.append(update) }
            if update.revision == 1 { published.fulfill() }
        }
        await fulfillment(of: [published], timeout: 1)
        let item = try XCTUnwrap(updates.read().first?.item)
        let failedPress = try XCTUnwrap(controller.prepareCommand(
            .play, contextID: item.contextID, isAuthorized: { true }
        ))
        let failedResult = await controller.perform(failedPress)
        XCTAssertEqual(failedResult, .failed)
        XCTAssertEqual(runtime.commands, [0])
        XCTAssertEqual(updates.read().count, 1)
        XCTAssertEqual(updates.read().last?.item, item)

        runtime.commandResult = .applied
        let freshPress = try XCTUnwrap(controller.prepareCommand(
            .play, contextID: item.contextID, isAuthorized: { true }
        ))
        let freshResult = await controller.perform(freshPress)
        XCTAssertEqual(freshResult, .applied)
        XCTAssertEqual(runtime.commands, [0, 0], "only a new press may retry the action")
        XCTAssertEqual(updates.read().last?.item, item)
    }

    func testInvalidationRevokesQueuedNextBeforeItCanAdoptReplacementEpoch() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot()))
        let blocked = expectation(description: "controller queue blocked in refresh")
        let enqueued = expectation(description: "next command enqueued behind refresh")
        let releaseRefresh = DispatchSemaphore(value: 0)
        let refreshTimedOut = NowPlayingLockedBox(false)
        runtime.onFetch = { [weak runtime] in
            guard runtime?.fetchCount == 2 else { return }
            blocked.fulfill()
            let result = releaseRefresh.wait(timeout: .now() + 5)
            refreshTimedOut.update { $0 = result == .timedOut }
        }
        let controller = MacSystemNowPlayingController(
            runtime: runtime,
            onCommandEnqueued: { enqueued.fulfill() }
        )
        defer {
            releaseRefresh.signal()
            controller.stop()
        }
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)
        let contextID = try XCTUnwrap(context.read())

        controller.refresh()
        await fulfillment(of: [blocked], timeout: 1)
        let prepared = try XCTUnwrap(controller.prepareCommand(.nextTrack, contextID: contextID, isAuthorized: { true }))
        let command = Task { await controller.perform(prepared) }
        await fulfillment(of: [enqueued], timeout: 1)

        // Keep the same lifecycle and media context. Only the command epoch
        // changes, as it does when transport recovery cancels pending commands.
        controller.invalidateCommands()
        releaseRefresh.signal()
        let result = await command.value

        XCTAssertFalse(refreshTimedOut.read())
        XCTAssertEqual(result, .staleContext)
        XCTAssertEqual(runtime.commands, [], "revoked Next must never reach native dispatch")
    }

    func testInvalidationRevokesPreparedPreviousBeforeAsyncExecutionBegins() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot()))
        let controller = MacSystemNowPlayingController(runtime: runtime)
        defer { controller.stop() }
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)
        let contextID = try XCTUnwrap(context.read())
        let oldPrepared = try XCTUnwrap(controller.prepareCommand(
            .previousTrack,
            contextID: contextID,
            isAuthorized: { true }
        ))

        // This happens before perform even enters its generic executor. The
        // original task need not have been cancelled for its admission to expire.
        controller.invalidateCommands()
        let staleResult = await controller.perform(oldPrepared)

        XCTAssertEqual(staleResult, .staleContext)
        XCTAssertEqual(runtime.commands, [], "old Previous must not adopt the new epoch")
        let freshPrepared = try XCTUnwrap(controller.prepareCommand(
            .previousTrack,
            contextID: contextID,
            isAuthorized: { true }
        ))
        let freshResult = await controller.perform(freshPrepared)
        XCTAssertEqual(freshResult, .applied)
        XCTAssertEqual(runtime.commands, [5], "only newly admitted Previous may dispatch")
    }

    func testOriginalTransportGateIsRequiredAtPreparationAndFinalNativeDispatch() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        runtime.enqueue(.snapshot(Self.snapshot()))
        let controller = MacSystemNowPlayingController(runtime: runtime)
        defer { controller.stop() }
        let context = NowPlayingLockedBox<String?>(nil)
        let published = expectation(description: "state published")
        controller.start { update in
            context.update { $0 = update.item?.contextID }
            published.fulfill()
        }
        await fulfillment(of: [published], timeout: 1)
        let contextID = try XCTUnwrap(context.read())
        let oldTransportGate = WebRTCControlAuthorization()
        let oldPrepared = try XCTUnwrap(controller.prepareCommand(
            .previousTrack, contextID: contextID,
            isAuthorized: { oldTransportGate.isValid }
        ))
        oldTransportGate.revoke()
        XCTAssertNil(controller.prepareCommand(
            .previousTrack, contextID: contextID,
            isAuthorized: { oldTransportGate.isValid }
        ))
        let oldResult = await controller.perform(oldPrepared)
        XCTAssertEqual(oldResult, .staleContext)
        XCTAssertEqual(runtime.commands, [])

        runtime.deferCommands = true
        let sendStarted = expectation(description: "current command reached deferred runtime")
        runtime.onSend = { sendStarted.fulfill() }
        let currentTransportGate = WebRTCControlAuthorization()
        let currentPrepared = try XCTUnwrap(controller.prepareCommand(
            .nextTrack, contextID: contextID,
            isAuthorized: { currentTransportGate.isValid }
        ))
        let pending = Task { await controller.perform(currentPrepared) }
        await fulfillment(of: [sendStarted], timeout: 1)
        currentTransportGate.revoke()
        XCTAssertEqual(runtime.resolveDeferredCommands(), [false])
        let revokedResult = await pending.value
        XCTAssertEqual(revokedResult, .staleContext)

        runtime.onSend = nil
        runtime.deferCommands = false
        let freshTransportGate = WebRTCControlAuthorization()
        let freshPrepared = try XCTUnwrap(controller.prepareCommand(
            .previousTrack, contextID: contextID,
            isAuthorized: { freshTransportGate.isValid }
        ))
        let freshResult = await controller.perform(freshPrepared)
        XCTAssertEqual(freshResult, .applied)
        XCTAssertFalse(oldTransportGate.isValid)
        XCTAssertFalse(currentTransportGate.isValid)
        XCTAssertEqual(runtime.commands, [4, 5])
    }

    func testRefreshCoalescesAndLateCompletionCannotCrossStop() async throws {
        let runtime = FakeMacSystemNowPlayingRuntime()
        let controller = MacSystemNowPlayingController(runtime: runtime)
        let fetches = expectation(description: "two coalesced fetches")
        fetches.expectedFulfillmentCount = 2
        runtime.onFetch = { fetches.fulfill() }
        let publicationCount = NowPlayingLockedBox(0)
        controller.start { _ in publicationCount.update { $0 += 1 } }
        try await Task.sleep(for: .milliseconds(30))

        controller.refresh()
        controller.refresh()
        controller.refresh()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(runtime.fetchCount, 1)

        runtime.deliver(.snapshot(Self.snapshot()))
        await fulfillment(of: [fetches], timeout: 1)
        XCTAssertEqual(runtime.fetchCount, 2)
        controller.stop()
        runtime.deliver(.snapshot(Self.snapshot(title: "Late")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(publicationCount.read(), 1)
    }

    func testElapsedRebaseIgnoresFutureAnchorAndClampsToDuration() async {
        let currentDate = Date(timeIntervalSinceReferenceDate: 1_000)
        let futureRuntime = FakeMacSystemNowPlayingRuntime()
        futureRuntime.enqueue(.snapshot(Self.snapshot(
            timestamp: currentDate.addingTimeInterval(30)
        )))
        let futureController = MacSystemNowPlayingController(
            runtime: futureRuntime,
            now: { currentDate }
        )
        let futureUpdate = NowPlayingLockedBox<WebRTCRemoteMediaStateUpdate?>(nil)
        let futurePublished = expectation(description: "future state")
        futureController.start { update in
            futureUpdate.update { $0 = update }
            futurePublished.fulfill()
        }
        await fulfillment(of: [futurePublished], timeout: 1)
        XCTAssertEqual(futureUpdate.read()?.item?.elapsedTime, 10)
        futureController.stop()

        let oldRuntime = FakeMacSystemNowPlayingRuntime()
        oldRuntime.enqueue(.snapshot(Self.snapshot(
            timestamp: currentDate.addingTimeInterval(-500)
        )))
        let oldController = MacSystemNowPlayingController(
            runtime: oldRuntime,
            now: { currentDate }
        )
        let oldUpdate = NowPlayingLockedBox<WebRTCRemoteMediaStateUpdate?>(nil)
        let oldPublished = expectation(description: "old state")
        oldController.start { update in
            oldUpdate.update { $0 = update }
            oldPublished.fulfill()
        }
        await fulfillment(of: [oldPublished], timeout: 1)
        XCTAssertEqual(oldUpdate.read()?.item?.elapsedTime, 120)
        oldController.stop()
    }

    func testPrivateABIGateIsFailClosedOutsideVerifiedOSRange() {
        XCTAssertTrue(MacMediaRemoteABIGate.supports(OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 5,
            patchVersion: 1
        )))
        XCTAssertFalse(MacMediaRemoteABIGate.supports(OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 6,
            patchVersion: 0
        )))
        XCTAssertFalse(MacMediaRemoteABIGate.supports(OperatingSystemVersion(
            majorVersion: 26,
            minorVersion: 4,
            patchVersion: 0
        )))
        XCTAssertFalse(MacMediaRemoteABIGate.supports(OperatingSystemVersion(
            majorVersion: 27,
            minorVersion: 0,
            patchVersion: 0
        )))
    }

    func testDynamicRuntimeLoadsOnlyWhenVerifiedABIAndSymbolsArePresent() {
        let controller = MacSystemNowPlayingController()
        let isVerifiedOS = MacMediaRemoteABIGate.supports(
            ProcessInfo.processInfo.operatingSystemVersion
        )
        if isVerifiedOS {
            XCTAssertTrue(controller.isAvailable)
        } else {
            XCTAssertFalse(controller.isAvailable)
        }
    }

    func testPublicationMachineCommitsOnlySuccessfulWireState() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        let item = Self.item(contextID: "context-a")
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: item
        ))
        publication.setRemoteMediaAvailable(true)
        let attempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertNil(publication.lastSuccessfullySent)
        XCTAssertEqual(publication.complete(attempt, succeeded: true), .finished)
        XCTAssertEqual(publication.lastSuccessfullySent?.revision, 1)
        XCTAssertEqual(publication.lastSuccessfullySent?.item?.contextID, "context-a")
        let request = WebRTCRemoteMediaCommandRequest(
            id: 1,
            contextID: "context-a",
            observedRevision: 1,
            command: .play
        )
        XCTAssertNil(WebRTCRemoteMediaCommandAdmission.rejection(
            for: request,
            latestSuccessfullySent: publication.lastSuccessfullySent
        ))
    }

    func testSamePeerRecoveryPreservesRevisionFourteenAndRepublishesFifteen() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        let item = Self.item(contextID: "context-a")
        publication.setRemoteMediaAvailable(true)
        for controllerRevision in 1...14 {
            publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
                revision: UInt64(controllerRevision),
                item: item
            ))
            let attempt = publication.beginIfPossible(transportIsReady: true)!
            XCTAssertEqual(publication.complete(attempt, succeeded: true), .finished)
        }
        XCTAssertEqual(publication.lastSuccessfullySent?.revision, 14)

        publication.setRemoteMediaAvailable(false)
        let dirtyVersion = publication.desiredVersion
        publication.setRemoteMediaAvailable(false)
        XCTAssertEqual(publication.desiredVersion, dirtyVersion)
        XCTAssertNil(publication.beginIfPossible(transportIsReady: true))
        XCTAssertEqual(publication.lastSuccessfullySent?.revision, 14)
        publication.setRemoteMediaAvailable(true)
        publication.setRemoteMediaAvailable(true)
        XCTAssertEqual(publication.desiredVersion, dirtyVersion)
        let recoveryAttempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(recoveryAttempt.update.revision, 15)
        XCTAssertEqual(recoveryAttempt.update.item, item)
        XCTAssertEqual(
            publication.complete(recoveryAttempt, succeeded: true),
            .finished
        )

        XCTAssertEqual(publication.lastSuccessfullySent?.revision, 15)
        XCTAssertEqual(publication.lastSuccessfullySent?.item, item)
    }

    func testRefreshRepublishesUnchangedPausedItemWithFreshWireRevision() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        let item = Self.item(contextID: "context-paused", playbackState: .paused)
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 7,
            item: item
        ))
        publication.setRemoteMediaAvailable(true)
        let initial = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(publication.complete(initial, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)

        publication.requestRefresh()

        XCTAssertEqual(publication.desiredControllerRevision, 7)
        XCTAssertTrue(publication.hasPendingPublication)
        let refreshed = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(refreshed.update.item, item)
        XCTAssertEqual(refreshed.update.revision, initial.update.revision + 1)
        XCTAssertEqual(publication.complete(refreshed, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)
    }

    func testFailedRefreshRemainsDirtyWithoutAnotherControllerUpdate() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: Self.item(contextID: "context-paused", playbackState: .paused)
        ))
        publication.setRemoteMediaAvailable(true)
        let initial = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(publication.complete(initial, succeeded: true), .finished)
        publication.requestRefresh()
        let failedRefresh = publication.beginIfPossible(transportIsReady: true)!

        XCTAssertEqual(
            publication.complete(failedRefresh, succeeded: false),
            .retryLatest
        )
        XCTAssertTrue(publication.hasPendingPublication)
        XCTAssertEqual(publication.lastSuccessfullySent, initial.update)
        XCTAssertNil(publication.beginIfPossible(transportIsReady: false))
        let retry = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(retry.update, failedRefresh.update)
        XCTAssertEqual(retry.desiredVersion, failedRefresh.desiredVersion)
        XCTAssertEqual(publication.complete(retry, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)
    }

    func testRefreshDuringInFlightPublicationSurvivesOlderCompletion() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: Self.item(contextID: "context-paused", playbackState: .paused)
        ))
        publication.setRemoteMediaAvailable(true)
        let prior = publication.beginIfPossible(transportIsReady: true)!

        publication.requestRefresh()

        XCTAssertNil(publication.beginIfPossible(transportIsReady: true))
        XCTAssertEqual(publication.complete(prior, succeeded: true), .publishNewest)
        XCTAssertTrue(publication.hasPendingPublication)
        let refreshed = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertNotEqual(refreshed.desiredVersion, prior.desiredVersion)
        XCTAssertEqual(refreshed.update.item, prior.update.item)
        XCTAssertEqual(refreshed.update.revision, prior.update.revision + 1)
        XCTAssertEqual(publication.complete(refreshed, succeeded: true), .finished)
    }

    func testRefreshWithoutInitialControllerStateDoesNotInventAnEmptySnapshot() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        publication.setRemoteMediaAvailable(true)

        publication.requestRefresh()

        XCTAssertNil(publication.desiredControllerRevision)
        XCTAssertFalse(publication.hasPendingPublication)
        XCTAssertNil(publication.beginIfPossible(transportIsReady: true))
    }

    func testPublicationCoalescesInFlightChangesToNewestPayload() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        publication.setRemoteMediaAvailable(true)
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: Self.item(contextID: "context-a")
        ))
        let firstAttempt = publication.beginIfPossible(transportIsReady: true)!

        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 2,
            item: Self.item(contextID: "context-b")
        ))
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 3,
            item: nil
        ))
        XCTAssertNil(publication.beginIfPossible(transportIsReady: true))
        XCTAssertEqual(
            publication.complete(firstAttempt, succeeded: true),
            .publishNewest
        )

        let newestAttempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(newestAttempt.desiredVersion, publication.desiredVersion)
        XCTAssertEqual(newestAttempt.update.revision, 2)
        XCTAssertNil(newestAttempt.update.item)
        XCTAssertEqual(publication.complete(newestAttempt, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)
        XCTAssertNil(publication.lastSuccessfullySent?.item)
    }

    func testAvailabilityLossDuringInitialSendStillRequiresRepublish() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        let item = Self.item(contextID: "context-a")
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: item
        ))
        publication.setRemoteMediaAvailable(true)
        let oldAuthorizationAttempt = publication.beginIfPossible(
            transportIsReady: true
        )!

        publication.setRemoteMediaAvailable(false)
        XCTAssertEqual(
            publication.complete(oldAuthorizationAttempt, succeeded: true),
            .publishNewest
        )
        XCTAssertNil(publication.beginIfPossible(transportIsReady: true))

        publication.setRemoteMediaAvailable(true)
        let reboundAttempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(reboundAttempt.update.revision, 2)
        XCTAssertEqual(reboundAttempt.update.item, item)
    }

    func testFailedPublicationStaysDirtyUntilRecoveryRetry() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        var retryGate = WorldwideRemoteMediaPublicationRetryGate()
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: Self.item(contextID: "context-a")
        ))
        publication.setRemoteMediaAvailable(true)
        let failedAttempt = publication.beginIfPossible(transportIsReady: true)!

        XCTAssertEqual(
            publication.complete(failedAttempt, succeeded: false),
            .retryLatest
        )
        XCTAssertTrue(publication.hasPendingPublication)
        XCTAssertNil(publication.lastSuccessfullySent)
        let retry = retryGate.schedule()!
        XCTAssertNil(retryGate.schedule())

        // The bounded retry fires without any metadata or health event. A static item or clear is
        // therefore not lost merely because the controller correctly deduplicates it.
        XCTAssertTrue(retryGate.consume(retry))
        let retryAttempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertEqual(retryAttempt.desiredVersion, failedAttempt.desiredVersion)
        XCTAssertEqual(retryAttempt.update, failedAttempt.update)
        XCTAssertEqual(publication.complete(retryAttempt, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)
        XCTAssertEqual(publication.lastSuccessfullySent, retryAttempt.update)
    }

    func testPublicationRetryTokenIsRevokedByPeerReset() {
        var retryGate = WorldwideRemoteMediaPublicationRetryGate()
        let oldPeerRetry = retryGate.schedule()!

        retryGate.cancel()

        XCTAssertFalse(retryGate.consume(oldPeerRetry))
        XCTAssertFalse(retryGate.isScheduled)
        XCTAssertNotNil(retryGate.schedule())
    }

    func testPublicationRevisionExhaustionFailsClosedWithoutWrapping() {
        XCTAssertEqual(
            WorldwideRemoteMediaPublicationMachine.nextWireRevision(after: 14),
            15
        )
        XCTAssertNil(WorldwideRemoteMediaPublicationMachine.nextWireRevision(
            after: UInt64.max
        ))
    }

    func testFailureWhileNewerStateArrivesImmediatelyPublishesNewestVersion() {
        var publication = WorldwideRemoteMediaPublicationMachine()
        publication.setRemoteMediaAvailable(true)
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 1,
            item: Self.item(contextID: "context-a")
        ))
        let staleAttempt = publication.beginIfPossible(transportIsReady: true)!
        let newestItem = Self.item(contextID: "context-b")
        publication.applyControllerUpdate(WebRTCRemoteMediaStateUpdate(
            revision: 2,
            item: newestItem
        ))

        XCTAssertEqual(
            publication.complete(staleAttempt, succeeded: false),
            .publishNewest
        )
        let newestAttempt = publication.beginIfPossible(transportIsReady: true)!
        XCTAssertNotEqual(newestAttempt.desiredVersion, staleAttempt.desiredVersion)
        XCTAssertEqual(newestAttempt.update.revision, 1)
        XCTAssertEqual(newestAttempt.update.item, newestItem)
        XCTAssertEqual(publication.complete(newestAttempt, succeeded: true), .finished)
        XCTAssertFalse(publication.hasPendingPublication)
    }

    func testCommandQueueIsBoundedAndOldGenerationCannotWakeAfterReset() {
        var capacity = WorldwideRemoteMediaCommandQueueCapacity()
        let oldGeneration = capacity.reserve()!
        for _ in 1..<WorldwideRemoteMediaCommandQueueCapacity.maximumCount {
            XCTAssertNotNil(capacity.reserve())
        }
        XCTAssertNil(capacity.reserve())

        capacity.reset()

        XCTAssertFalse(capacity.admits(generation: oldGeneration))
        XCTAssertEqual(capacity.count, 0)
        XCTAssertNotNil(capacity.reserve())
    }

    private static func snapshot(
        title: String = "Track",
        timestamp: Date? = nil,
        playbackRate: Double = 1,
        enabledCommands: Set<Int> = [0, 1, 4, 5],
        artwork: WebRTCRemoteMediaArtworkReference? = nil
    ) -> MacNowPlayingRuntimeSnapshot {
        MacNowPlayingRuntimeSnapshot(
            client: MacNowPlayingClientToken(
                object: NSObject(),
                clientIdentity: "com.apple.Music:42"
            ),
            sourceName: "Music",
            metadata: MacNowPlayingMetadata(
                title: title,
                artist: "Artist",
                album: "Album",
                duration: 120,
                elapsedTime: 10,
                playbackRate: playbackRate,
                timestamp: timestamp,
                contentIdentifier: "track-1",
                uniqueIdentifier: nil,
                artwork: artwork
            ),
            enabledCommands: enabledCommands
        )
    }

    private static func item(
        contextID: String,
        playbackState: WebRTCRemoteMediaPlaybackState = .playing
    ) -> WebRTCRemoteMediaItem {
        WebRTCRemoteMediaItem(
            contextID: contextID,
            sourceName: "Music",
            title: "Track",
            playbackState: playbackState,
            elapsedTime: 10,
            duration: 120,
            playbackRate: playbackState == .playing ? 1 : 0,
            capabilities: WebRTCRemoteMediaCapabilities(
                canPlay: true,
                canPause: true,
                canSkipForward: true,
                canSkipBackward: true
            )
        )
    }
}
