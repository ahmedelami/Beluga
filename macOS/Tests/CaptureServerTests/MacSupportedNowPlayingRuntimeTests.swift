import Foundation
import WebRTCTransport
import XCTest
@testable import CaptureServer

private final class SupportedRuntimeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private final class SupportedRuntimeFake: MacSystemNowPlayingRuntime, @unchecked Sendable {
    private struct PendingCommand {
        let rawCommand: Int
        let authorized: @Sendable () -> Bool
        let completion: @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    }
    private let lock = NSLock()
    private var fetches: [@Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void] = []
    private var pending: [PendingCommand] = []
    private var executed: [Int] = []
    private var stopped = 0
    var isAvailable = true
    var deferredFetches = false
    var result: MacNowPlayingRuntimeSnapshotResult = .noActiveMedia
    var commands: [Int] { lock.withLock { executed } }
    var pendingCommandCount: Int { lock.withLock { pending.count } }
    var stopCount: Int { lock.withLock { stopped } }

    func fetchSnapshot(completion: @escaping @Sendable (MacNowPlayingRuntimeSnapshotResult) -> Void) {
        if deferredFetches { lock.withLock { fetches.append(completion) } }
        else { completion(result) }
    }

    func deliverFetch(_ index: Int, _ result: MacNowPlayingRuntimeSnapshotResult) {
        let callback = lock.withLock { fetches.indices.contains(index) ? fetches[index] : nil }
        guard let callback else { XCTFail("No pending fetch at requested index"); return }
        callback(result)
    }

    func send(
        rawCommand: Int, snapshot: MacNowPlayingRuntimeSnapshot,
        isAuthorized: @escaping @Sendable () -> Bool,
        completion: @escaping @Sendable (WebRTCRemoteMediaCommandResult) -> Void
    ) {
        lock.withLock { pending.append(PendingCommand(rawCommand: rawCommand, authorized: isAuthorized, completion: completion)) }
    }

    func completeCommand() {
        let command = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        guard let command else { XCTFail("No command reached the selected source"); return }
        let authorized = command.authorized()
        if authorized { lock.withLock { executed.append(command.rawCommand) } }
        command.completion(authorized ? .applied : .staleContext)
    }

    func stop() { lock.withLock { stopped += 1 } }
}

final class MacSupportedNowPlayingRuntimeTests: XCTestCase {
    func testSimultaneouslyDiscoveredPlayersDoNotChooseAnArbitraryCommandTarget() throws {
        let browser = SupportedRuntimeFake(), music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a"))
        music.result = .snapshot(item(source: "Music", identity: "music-a"))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        guard case .noActiveMedia = try fetch(runtime) else { return XCTFail("Ambiguous owner chosen") }
        guard case .noActiveMedia = try fetch(runtime) else { return XCTFail("Ambiguity disappeared without evidence") }
        music.result = .noActiveMedia
        XCTAssertEqual(try snapshot(runtime).sourceName, "YouTube")
    }

    func testSameInnerIdentityWithReplacementTokenRetiresPriorPublication() throws {
        let browser = SupportedRuntimeFake(), music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "same-owner"))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let old = try snapshot(runtime)
        let queued = send(runtime, snapshot: old)
        browser.result = .snapshot(item(source: "YouTube", identity: "same-owner"))
        XCTAssertNotEqual(try snapshot(runtime).identityKey, old.identityKey)
        browser.completeCommand()
        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertEqual(send(runtime, snapshot: old).read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
    }

    func testPlayingYouTubeWinsPausedMusicAndPreservesExactMetadataAndCapabilities() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        let expected = item(source: "YouTube", identity: "browser-a", commands: [1, 4])
        browser.result = .snapshot(expected)
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)

        let actual = try snapshot(runtime)

        XCTAssertFalse(actual.client === expected.client)
        XCTAssertEqual(actual.metadata, expected.metadata)
        XCTAssertEqual(actual.sourceName, "YouTube")
        XCTAssertEqual(actual.enabledCommands, [1, 4])
    }

    func testNewlyPlayingMusicTakesOverAndRemainsSelectedWhenBothPause() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a"))
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        XCTAssertEqual(try snapshot(runtime).sourceName, "YouTube")

        music.result = .snapshot(item(source: "Music", identity: "music-a"))
        XCTAssertEqual(try snapshot(runtime).sourceName, "Music")

        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a", playing: false))
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false, commands: [0]))
        let paused = try snapshot(runtime)
        XCTAssertEqual(paused.sourceName, "Music")
        XCTAssertEqual(paused.metadata.playbackRate, 0)
        XCTAssertEqual(paused.enabledCommands, [0])
    }

    func testSelectedSourceRetryRetiresCommandAuthorityWithoutSwitchingPlayer() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        let original = item(source: "YouTube", identity: "browser-a")
        browser.result = .snapshot(original)
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let before = try snapshot(runtime)
        let queued = send(runtime, snapshot: before)

        browser.result = .retry
        guard case .retry = try fetch(runtime) else { return XCTFail("Indeterminate source switched to paused Music") }
        browser.completeCommand()
        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
        XCTAssertEqual(music.pendingCommandCount, 0)

        browser.result = .snapshot(original)
        let recovered = try snapshot(runtime)
        XCTAssertEqual(recovered.metadata, original.metadata)
        XCTAssertNotEqual(recovered.identityKey, before.identityKey)
        XCTAssertEqual(send(runtime, snapshot: before).read(), .staleContext)
    }

    func testCommandGoesOnlyToSelectedSourceAndExternalRevocationClosesPendingAction() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a"))
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let selected = try snapshot(runtime)
        let authorization = WebRTCControlAuthorization()
        let result = SupportedRuntimeBox<WebRTCRemoteMediaCommandResult?>(nil)
        runtime.send(rawCommand: 1, snapshot: selected, isAuthorized: { authorization.isValid }) { value in
            result.update { $0 = value }
        }
        XCTAssertEqual(browser.pendingCommandCount, 1)
        XCTAssertEqual(music.pendingCommandCount, 0)
        authorization.revoke()
        browser.completeCommand()
        XCTAssertEqual(result.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
        XCTAssertTrue(music.commands.isEmpty)
    }

    func testSourceReplacementRejectsOldSnapshotAndAlreadyQueuedCommand() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a"))
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let old = try snapshot(runtime)
        let queued = send(runtime, snapshot: old)

        music.result = .snapshot(item(source: "Music", identity: "music-a"))
        XCTAssertEqual(try snapshot(runtime).sourceName, "Music")
        let rejected = send(runtime, snapshot: old)
        browser.completeCommand()

        XCTAssertEqual(rejected.read(), .staleContext)
        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
        XCTAssertEqual(music.pendingCommandCount, 0)
    }

    func testQueuedCommandCannotRegainAuthorityAfterSourceReturnsToSameIdentity() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        let original = item(source: "YouTube", identity: "browser-a")
        browser.result = .snapshot(original)
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let queued = send(runtime, snapshot: try snapshot(runtime))

        music.result = .snapshot(item(source: "Music", identity: "music-a"))
        XCTAssertEqual(try snapshot(runtime).sourceName, "Music")
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a", playing: false))
        music.result = .snapshot(item(source: "Music", identity: "music-a", playing: false))
        _ = try snapshot(runtime)
        browser.result = .snapshot(original)
        XCTAssertEqual(try snapshot(runtime).metadata, original.metadata)
        browser.completeCommand()

        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
    }

    func testQueuedCommandCannotRegainAuthorityAfterItemReturnsToSameIdentity() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        let original = item(source: "YouTube", identity: "browser-a", content: "item-a")
        browser.result = .snapshot(original)
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let queued = send(runtime, snapshot: try snapshot(runtime))
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a", content: "item-b"))
        XCTAssertEqual(try snapshot(runtime).metadata.contentIdentifier, "item-b")
        browser.result = .snapshot(original)
        XCTAssertEqual(try snapshot(runtime).metadata, original.metadata)
        browser.completeCommand()

        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
    }

    func testStopRevokesPendingCommandEvenAfterFreshFetchRestoresSameIdentity() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.result = .snapshot(item(source: "YouTube", identity: "browser-a"))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let old = try snapshot(runtime)
        let queued = send(runtime, snapshot: old)

        runtime.stop()
        XCTAssertEqual(browser.stopCount, 1)
        XCTAssertEqual(music.stopCount, 1)
        XCTAssertNotEqual(try snapshot(runtime).identityKey, old.identityKey)
        XCTAssertEqual(send(runtime, snapshot: old).read(), .staleContext)
        browser.completeCommand()

        XCTAssertEqual(queued.read(), .staleContext)
        XCTAssertTrue(browser.commands.isEmpty)
        let fresh = send(runtime, snapshot: try snapshot(runtime))
        browser.completeCommand()
        XCTAssertEqual(fresh.read(), .applied)
        XCTAssertEqual(browser.commands, [1])
    }

    func testOutOfOrderFetchCannotReplaceNewerSelection() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.deferredFetches = true
        music.deferredFetches = true
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let old = SupportedRuntimeBox<[MacNowPlayingRuntimeSnapshotResult]>([])
        let new = SupportedRuntimeBox<[MacNowPlayingRuntimeSnapshotResult]>([])
        runtime.fetchSnapshot { value in old.update { $0.append(value) } }
        runtime.fetchSnapshot { value in new.update { $0.append(value) } }
        let selected = item(source: "Music", identity: "music-new")
        music.deliverFetch(1, .snapshot(selected))
        browser.deliverFetch(1, .noActiveMedia)
        browser.deliverFetch(0, .snapshot(item(source: "YouTube", identity: "browser-old")))
        music.deliverFetch(0, .noActiveMedia)

        XCTAssertEqual(old.read().count, 1)
        guard let oldResult = old.read().first, case .retry = oldResult else { return XCTFail("Old fetch changed selection") }
        XCTAssertEqual(new.read().count, 1)
        guard let publication = new.read().first, case .snapshot(let published) = publication else {
            return XCTFail("New selection was not published")
        }
        let command = send(runtime, snapshot: published)
        music.completeCommand()
        XCTAssertEqual(command.read(), .applied)
        XCTAssertEqual(browser.pendingCommandCount, 0)
    }

    func testDuplicateCallbacksCannotOverwriteFirstSourceResultOrCompleteTwice() {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.deferredFetches = true
        music.deferredFetches = true
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let publications = SupportedRuntimeBox<[MacNowPlayingRuntimeSnapshotResult]>([])
        runtime.fetchSnapshot { value in publications.update { $0.append(value) } }
        let original = item(source: "YouTube", identity: "browser-a", commands: [])
        browser.deliverFetch(0, .snapshot(original))
        browser.deliverFetch(0, .snapshot(item(source: "YouTube", identity: "browser-duplicate")))
        XCTAssertTrue(publications.read().isEmpty)
        music.deliverFetch(0, .noActiveMedia)
        browser.deliverFetch(0, .noActiveMedia)
        music.deliverFetch(0, .snapshot(item(source: "Music", identity: "music-late")))
        XCTAssertEqual(publications.read().count, 1)
        guard let publication = publications.read().first,
              case .snapshot(let actual) = publication else { return XCTFail("Snapshot missing") }
        XCTAssertEqual(actual.metadata, original.metadata)
        XCTAssertTrue(actual.enabledCommands.isEmpty)
    }

    func testFetchCompletionAfterStopCannotReviveSelection() {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        browser.deferredFetches = true
        music.deferredFetches = true
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music)
        let publications = SupportedRuntimeBox<[MacNowPlayingRuntimeSnapshotResult]>([])
        runtime.fetchSnapshot { value in publications.update { $0.append(value) } }
        runtime.stop()
        let stale = item(source: "YouTube", identity: "browser-a")
        music.deliverFetch(0, .noActiveMedia)
        browser.deliverFetch(0, .snapshot(stale))
        guard let publication = publications.read().first,
              case .retry = publication else { return XCTFail("Stopped fetch published media") }
        XCTAssertEqual(send(runtime, snapshot: stale).read(), .staleContext)
        XCTAssertEqual(browser.pendingCommandCount, 0)
    }

    func testMissingPlayersClearSelectionAndDiagnosticsContainNoMediaContent() throws {
        let browser = SupportedRuntimeFake()
        let music = SupportedRuntimeFake()
        let reports = SupportedRuntimeBox<[String]>([])
        browser.result = .snapshot(item(source: "YouTube", identity: "private-owner", content: "private-id"))
        let runtime = MacSupportedNowPlayingRuntime(browser: browser, music: music) { report in
            reports.update { $0.append(report) }
        }
        let old = try snapshot(runtime)
        browser.result = .noActiveMedia
        guard case .noActiveMedia = try fetch(runtime) else { return XCTFail("Missing player retained") }
        XCTAssertEqual(send(runtime, snapshot: old).read(), .staleContext)
        XCTAssertTrue(reports.read().allSatisfy {
            !$0.contains("private-owner") && !$0.contains("private-id") && !$0.contains("Secret title")
                && !$0.contains("Secret artist") && !$0.contains("Secret album")
        })
        browser.isAvailable = false
        music.isAvailable = false
        XCTAssertFalse(runtime.isAvailable)
        music.isAvailable = true
        XCTAssertTrue(runtime.isAvailable)
    }

    private func fetch(_ runtime: MacSupportedNowPlayingRuntime) throws -> MacNowPlayingRuntimeSnapshotResult {
        let result = SupportedRuntimeBox<MacNowPlayingRuntimeSnapshotResult?>(nil)
        runtime.fetchSnapshot { value in result.update { $0 = value } }
        return try XCTUnwrap(result.read())
    }

    private func snapshot(_ runtime: MacSupportedNowPlayingRuntime) throws -> MacNowPlayingRuntimeSnapshot {
        guard case .snapshot(let snapshot) = try fetch(runtime) else { throw MacMusicBackendError.unavailable }
        return snapshot
    }

    private func send(
        _ runtime: MacSupportedNowPlayingRuntime, snapshot: MacNowPlayingRuntimeSnapshot
    ) -> SupportedRuntimeBox<WebRTCRemoteMediaCommandResult?> {
        let result = SupportedRuntimeBox<WebRTCRemoteMediaCommandResult?>(nil)
        runtime.send(rawCommand: 1, snapshot: snapshot, isAuthorized: { true }) { value in
            result.update { $0 = value }
        }
        return result
    }

    private func item(
        source: String, identity: String, content: String = "content-a", playing: Bool = true,
        commands: Set<Int> = [0, 1, 4, 5]
    ) -> MacNowPlayingRuntimeSnapshot {
        MacNowPlayingRuntimeSnapshot(
            client: MacNowPlayingClientToken(object: NSObject(), clientIdentity: identity), sourceName: source,
            metadata: MacNowPlayingMetadata(title: "Secret title", artist: "Secret artist", album: "Secret album",
                                           duration: 90, elapsedTime: 12, playbackRate: playing ? 1 : 0,
                                           timestamp: Date(timeIntervalSince1970: 100), contentIdentifier: content,
                                           uniqueIdentifier: nil), enabledCommands: commands
        )
    }
}
