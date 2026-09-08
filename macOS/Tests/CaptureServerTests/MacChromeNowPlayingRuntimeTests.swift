import AppKit
import CoreServices
import WebRTCTransport
import XCTest
@testable import CaptureServer

private final class ChromeTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}

private let chromeOwner = MacChromePlayerIdentity(processID: 42, launchDate: Date(timeIntervalSince1970: 100))
private let chromeURL = "https://www.youtube.com/watch?v=abcdefghijk"
private let chromeNextURL = "https://www.youtube.com/watch?v=lmnopqrstuv"

private func chromeMedia(video: String = "abcdefghijk", paused: Bool = false,
                         item: String = "00000000-0000-4000-8000-000000000001", generation: Int64 = 1,
                         title: String = "Video", pageTime: Double = 50_000) -> MacChromeScriptSnapshot {
    .init(documentID: "00000000-0000-4000-8000-000000000002", itemID: item, itemGeneration: generation,
          videoID: video, title: title, artist: "Channel", duration: 120, elapsedTime: 15,
          playbackRate: 1, paused: paused, observedAtUnixMilliseconds: 1_000_000,
          observedAtPageMilliseconds: pageTime, canPlay: paused, canPause: !paused,
          canNext: true, canPrevious: true)
}

private func chromePlayer(tab: String = "2", media: MacChromeScriptSnapshot = chromeMedia()) -> MacChromePlayerSnapshot {
    .init(tab: .init(owner: chromeOwner, windowID: "1", tabID: tab), media: media, receivedAtUptime: 10)
}

private final class ChromeTestBackend: MacChromeNowPlayingBackend, @unchecked Sendable {
    var snapshots = [chromePlayer()]
    var error: MacChromeBackendError?
    var commandError: MacChromeBackendError?
    var commands: [MacChromeCommand] = []
    var reads = 0
    var permissions = 0
    var onPermission: (() -> Void)?
    func readSnapshots(deadline: TimeInterval) throws -> [MacChromePlayerSnapshot] {
        reads += 1
        if let error { throw error }
        return snapshots
    }
    func requestAutomationPermission() throws { permissions += 1; onPermission?() }
    func send(_ command: MacChromeCommand, expected: MacChromePlayerSnapshot, deadline: TimeInterval,
              isAuthorized: @escaping @Sendable () -> Bool) throws -> WebRTCRemoteMediaCommandResult {
        guard isAuthorized() else { return .staleContext }
        commands.append(command)
        if let commandError { throw commandError }
        return .applied
    }
}

/// Executes actual production Apple Event descriptor queries against a changing fake target.
private final class ChromeTestClient: MacChromeAppleEventsClient, @unchecked Sendable {
    struct Window {
        var id: String
        var mode: String = "normal"
        var tabs: [(id: String, url: String)]
    }
    var owner: MacChromePlayerIdentity? = chromeOwner
    var windows = [Window(id: "1", tabs: [("2", chromeURL)])]
    var media = chromeMedia()
    var permissionStatus: OSStatus = noErr
    var permissionRequests: [Bool] = []
    var options: [NSAppleEventDescriptor.SendOptions] = []
    var timeouts: [TimeInterval] = []
    var targets: [Int32] = []
    var requests: [[String: Any]] = []
    var commandDispatches = 0
    var resultPolls = 0
    var pendingPlay = false
    var ignoreCommands = false
    var commandError: OSStatus?
    var scriptError: (OSStatus, String)?
    var oversizedResult = false
    var urlReads = 0
    var onURLRead: ((Int) -> Void)?
    var onProperty: ((OSType) -> Void)?

    func runningOwner() -> MacChromePlayerIdentity? { owner }
    func automationPermission(owner: MacChromePlayerIdentity, askUser: Bool) -> OSStatus {
        XCTAssertEqual(owner, self.owner)
        permissionRequests.append(askUser)
        return permissionStatus
    }

    func sendEvent(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
                   timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        self.options.append(options); timeouts.append(timeout)
        let target = try XCTUnwrap(event.attributeDescriptor(forKeyword: keyAddressAttr))
        XCTAssertEqual(target.descriptorType, typeKernelProcessID)
        targets.append(target.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        let result: NSAppleEventDescriptor
        if event.eventClass == 0x43725375 {
            XCTAssertEqual(event.eventID, 0x45784A61)
            let targetTab = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            XCTAssertEqual(targetTab.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formUniqueID))
            XCTAssertEqual(targetTab.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, "2")
            let script = try XCTUnwrap(event.paramDescriptor(forKeyword: 0x4A765363)?.stringValue)
            let marker = try XCTUnwrap(script.range(of: "\n)(", options: .backwards))
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(script[marker.upperBound...].dropLast().utf8)) as? [String: Any])
            requests.append(request)
            if let scriptError { return answer(.null(), error: scriptError.0, message: scriptError.1) }
            if oversizedResult { return answer(.init(string: String(repeating: "x", count: 262_145))) }
            let operation = request["operation"] as? String
            var status = "ok"
            if operation == "command" {
                commandDispatches += 1
                if !ignoreCommands {
                    switch request["command"] as? String {
                    case "pause": media = chromeMedia(paused: true)
                    case "play":
                        if pendingPlay { status = "pending" } else { media = chromeMedia(paused: false) }
                    case "next", "previous":
                        media = chromeMedia(video: "lmnopqrstuv", item: "00000000-0000-4000-8000-000000000003", generation: 2)
                        windows[0].tabs[0].url = chromeNextURL
                    default: XCTFail("Unexpected command")
                    }
                }
                if let commandError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(commandError)) }
            } else if operation == "result" {
                resultPolls += 1
                if resultPolls < 2 { status = "pending" }
                else { media = chromeMedia(paused: false) }
            } else { XCTAssertEqual(operation, "read") }
            let object: [String: Any] = ["schemaVersion": 1, "status": status,
                                        "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(media))]
            result = .init(string: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        } else {
            XCTAssertEqual(event.eventClass, kAECoreSuite)
            XCTAssertEqual(event.eventID, kAEGetData)
            let reference = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            let property = try XCTUnwrap(reference.forKeyword(AEKeyword(keyAEKeyData))).typeCodeValue
            let container = try XCTUnwrap(reference.forKeyword(AEKeyword(keyAEContainer)))
            let kind = container.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue
            let selector = container.forKeyword(AEKeyword(keyAEKeyData))
            let isAll = container.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formAbsolutePosition)
            onProperty?(property)
            if property == 0x49442020, kind == 0x6377696E, isAll { result = Self.list(windows.map(\.id)) }
            else if property == 0x6D6F6465 {
                result = .init(string: try XCTUnwrap(windows.first { $0.id == selector?.stringValue }).mode)
            } else {
                XCTAssertEqual(kind, 0x43725462)
                let windowID = container.forKeyword(AEKeyword(keyAEContainer))?
                    .forKeyword(AEKeyword(keyAEKeyData))?.stringValue
                let window = try XCTUnwrap(windows.first { $0.id == windowID })
                if property == 0x49442020, isAll { result = Self.list(window.tabs.map(\.id)) }
                else if property == 0x55524C20, isAll { result = Self.list(window.tabs.map(\.url)) }
                else if property == 0x55524C20 {
                    urlReads += 1
                    onURLRead?(urlReads)
                    result = .init(string: try XCTUnwrap(windows.first { $0.id == windowID }?.tabs
                        .first { $0.id == selector?.stringValue }).url)
                } else { XCTFail("Unexpected property"); result = .null() }
            }
        }
        return answer(result)
    }

    private func answer(_ result: NSAppleEventDescriptor, error: OSStatus? = nil, message: String? = nil)
        -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEAnswer, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reply.setParam(result, forKeyword: keyDirectObject)
        if let error { reply.setParam(.init(int32: error), forKeyword: keyErrorNumber) }
        if let message { reply.setParam(.init(string: message), forKeyword: keyErrorString) }
        return reply
    }

    private static func list(_ strings: [String]) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        for (index, string) in strings.enumerated() { result.insert(.init(string: string), at: index + 1) }
        return result
    }
}

final class MacChromeNowPlayingRuntimeTests: XCTestCase {
    func testNoRunningChromeSendsNothingAndCannotRequestLaunchOrPermission() throws {
        let client = ChromeTestClient(); client.owner = nil
        let backend = makeBackend(client)
        XCTAssertTrue(try backend.readSnapshots(deadline: 11).isEmpty)
        XCTAssertThrowsError(try backend.requestAutomationPermission())
        XCTAssertTrue(client.options.isEmpty)
        XCTAssertTrue(client.permissionRequests.isEmpty)
    }

    func testPublicNativeDescriptorsUseStablePIDIDsNormalWindowsAndNoPromptOptions() throws {
        let client = ChromeTestClient()
        client.windows[0].tabs.append(("3", "https://example.com/private"))
        client.windows.append(.init(id: "4", mode: "incognito", tabs: [("5", chromeURL)]))
        let snapshots = try makeBackend(client).readSnapshots(deadline: 11)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.tab, chromePlayer().tab)
        XCTAssertEqual(snapshots.first?.media.title, "Video")
        XCTAssertEqual(snapshots.first?.media.duration, 120)
        XCTAssertEqual(snapshots.first?.media.elapsedTime, 15)
        XCTAssertEqual(snapshots.first?.media.enabledCommands, [1, 4, 5])
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.permissionRequests, [false])
        XCTAssertTrue(client.targets.allSatisfy { $0 == 42 })
        XCTAssertTrue(client.timeouts.allSatisfy { $0 > 0 && $0 <= 0.35 })
        XCTAssertTrue(client.options.allSatisfy {
            $0.rawValue & UInt(kAENeverInteract | kAEDoNotPromptForUserConsent | kAEDontRecord)
                == UInt(kAENeverInteract | kAEDoNotPromptForUserConsent | kAEDontRecord)
        })
    }

    func testPermissionDeniedNeverPromptsAndExplicitOnboardingIsSeparate() throws {
        let client = ChromeTestClient(); client.permissionStatus = -1744
        let backend = makeBackend(client)
        XCTAssertThrowsError(try backend.readSnapshots(deadline: 11)) {
            XCTAssertEqual($0 as? MacChromeBackendError, .permissionRequired)
        }
        XCTAssertEqual(client.permissionRequests, [false])
        XCTAssertTrue(client.options.isEmpty)
        client.permissionStatus = -1743
        XCTAssertThrowsError(try backend.requestAutomationPermission()) {
            XCTAssertEqual($0 as? MacChromeBackendError, .permissionDenied)
        }
        XCTAssertEqual(client.permissionRequests, [false, true])
    }

    func testJavaScriptPermissionErrorIsContentFreeAndDistinct() throws {
        let client = ChromeTestClient()
        client.scriptError = (-10000, "Executing JavaScript through AppleScript is turned off.")
        XCTAssertThrowsError(try makeBackend(client).readSnapshots(deadline: 11)) {
            XCTAssertEqual($0 as? MacChromeBackendError, .javascriptPermissionRequired)
        }
        XCTAssertEqual(client.permissionRequests, [false])
    }

    func testOnlyOrdinaryExactYouTubeWatchURLsAreEligible() {
        XCTAssertEqual(MacChromeAppleEventsBackend.videoID(from: chromeURL + "&list=abc&index=2"), "abcdefghijk")
        for url in ["http://www.youtube.com/watch?v=abcdefghijk", "https://youtube.com/watch?v=abcdefghijk",
                    "https://www.youtube.com.evil.test/watch?v=abcdefghijk", "https://user@www.youtube.com/watch?v=abcdefghijk",
                    "https://www.youtube.com:443/watch?v=abcdefghijk", chromeURL + "&v=lmnopqrstuv", chromeURL + "#x",
                    "https://www.youtube.com/shorts/abcdefghijk", "chrome://extensions", "javascript:alert(1)"] {
            XCTAssertNil(MacChromeAppleEventsBackend.videoID(from: url), url)
        }
    }

    func testOwnerRestartAndSameURLItemABACannotReuseSnapshot() throws {
        let client = ChromeTestClient(); let backend = makeBackend(client)
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        client.owner = .init(processID: 42, launchDate: Date(timeIntervalSince1970: 101))
        XCTAssertThrowsError(try backend.send(.pause, expected: expected, deadline: 11, isAuthorized: { true }))
        client.owner = chromeOwner
        client.media = chromeMedia(item: "00000000-0000-4000-8000-000000000003", generation: 3)
        XCTAssertEqual(try backend.send(.pause, expected: expected, deadline: 11, isAuthorized: { true }), .staleContext)
        XCTAssertEqual(client.commandDispatches, 0)
    }

    func testURLChangeAtReadBoundaryRejectsMixedSnapshotAndOversizedReplyFailsClosed() throws {
        let client = ChromeTestClient()
        client.onURLRead = { count in if count == 2 { client.windows[0].tabs[0].url = chromeNextURL } }
        XCTAssertThrowsError(try makeBackend(client).readSnapshots(deadline: 11))
        client.onURLRead = nil; client.windows[0].tabs[0].url = chromeURL; client.oversizedResult = true
        XCTAssertThrowsError(try makeBackend(client).readSnapshots(deadline: 11)) {
            XCTAssertEqual($0 as? MacChromeBackendError, .invalidData)
        }
    }

    func testFinalNativeAuthorizationGuardPreventsActualPlayerMutation() throws {
        let client = ChromeTestClient(); let backend = makeBackend(client)
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        client.urlReads = 0
        let armed = ChromeTestBox(false); let checks = ChromeTestBox(0)
        client.onURLRead = { count in if count == 4 { armed.set(true) } }
        XCTAssertThrowsError(try backend.send(.pause, expected: expected, deadline: 11, isAuthorized: {
            guard armed.get() else { return true }
            let count = checks.get() + 1; checks.set(count)
            return count == 1 // post-URL proof passes; final native dispatch is revoked.
        }))
        XCTAssertTrue(armed.get())
        XCTAssertEqual(client.commandDispatches, 0)
        XCTAssertFalse(client.media.paused)
    }

    func testFinalNativeDeadlineGuardPreventsActualPlayerMutation() throws {
        let client = ChromeTestClient(); let armed = ChromeTestBox(false); let checks = ChromeTestBox(0)
        let backend = makeBackend(client, now: {
            guard armed.get() else { return 10 }
            let count = checks.get() + 1; checks.set(count)
            return count == 1 ? 10 : 20
        })
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        client.urlReads = 0
        client.onURLRead = { count in if count == 4 { armed.set(true) } }
        XCTAssertThrowsError(try backend.send(.pause, expected: expected, deadline: 11, isAuthorized: { true }))
        XCTAssertTrue(armed.get())
        XCTAssertEqual(client.commandDispatches, 0)
        XCTAssertFalse(client.media.paused)
    }

    func testCommandExpiryUsesEarlierSnapshotClockAndPlayRequiresAsyncReadback() throws {
        let client = ChromeTestClient(); client.media = chromeMedia(paused: true); client.pendingPlay = true
        let backend = makeBackend(client)
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        XCTAssertEqual(try backend.send(.play, expected: expected, deadline: 11, isAuthorized: { true }), .applied)
        XCTAssertEqual(client.commandDispatches, 1)
        XCTAssertEqual(client.resultPolls, 2)
        let request = try XCTUnwrap(client.requests.first { $0["operation"] as? String == "command" })
        XCTAssertEqual(request["expiresAtPageMilliseconds"] as? Double, 51_000)
        XCTAssertEqual(request["expiresAtUnixMilliseconds"] as? Double, 1_001_000)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(request["commandID"] as? String)))
        let expectedObject = try XCTUnwrap(request["expected"] as? [String: Any])
        XCTAssertEqual(expectedObject["itemID"] as? String, expected.media.itemID)
        XCTAssertFalse(client.media.paused)
    }

    func testSuccessfulEnvelopeWithoutActualPauseAndRelativeTransitionIsNotApplied() throws {
        let client = ChromeTestClient(); client.ignoreCommands = true
        let backend = makeBackend(client)
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        XCTAssertEqual(try backend.send(.pause, expected: expected, deadline: 11, isAuthorized: { true }), .failed)
        XCTAssertEqual(try backend.send(.next, expected: expected, deadline: 11, isAuthorized: { true }), .failed)
        XCTAssertEqual(client.commandDispatches, 2)
    }

    func testRelativeTimeoutDoesNotResendNativeMutation() throws {
        let client = ChromeTestClient(); let backend = makeBackend(client)
        let expected = try XCTUnwrap(backend.readSnapshots(deadline: 11).first)
        client.commandError = OSStatus(errAETimeout)
        XCTAssertThrowsError(try backend.send(.next, expected: expected, deadline: 11, isAuthorized: { true }))
        XCTAssertEqual(client.commandDispatches, 1)
        XCTAssertEqual(client.resultPolls, 0)
        XCTAssertEqual(client.media.videoID, "lmnopqrstuv")
    }

    func testUniquePlayingWinsStickyPauseAndAmbiguityRevokesInsteadOfPickingFirst() async throws {
        let backend = ChromeTestBackend()
        let runtime = makeRuntime(backend)
        let first = try await snapshot(runtime)
        backend.snapshots = [chromePlayer(media: chromeMedia(paused: true)),
                             chromePlayer(tab: "3", media: chromeMedia(paused: true))]
        let sticky = try await snapshot(runtime)
        XCTAssertTrue(first.client === sticky.client)
        backend.snapshots = [chromePlayer(media: chromeMedia(paused: true)), chromePlayer(tab: "3")]
        let other = try await snapshot(runtime)
        XCTAssertFalse(first.client === other.client)
        backend.snapshots = [chromePlayer(), chromePlayer(tab: "3")]
        guard case .retry = await fetch(runtime) else { return XCTFail("Ambiguous players selected") }
        XCTAssertEqual(runtime.lastDiscoveryStatus, .ambiguousPlayers)
        await assertSend(runtime, command: 1, snapshot: other, equals: .staleContext)
        backend.snapshots = [chromePlayer()]
        let returned = try await snapshot(runtime)
        XCTAssertFalse(first.client === returned.client)
        await assertSend(runtime, command: 1, snapshot: first, equals: .staleContext)
    }

    func testIndeterminateReadAndStopRotateIdentityEvenForSameItem() async throws {
        let backend = ChromeTestBackend(); let runtime = makeRuntime(backend)
        let first = try await snapshot(runtime)
        backend.error = .timedOut
        guard case .retry = await fetch(runtime) else { return XCTFail("Timeout published") }
        XCTAssertEqual(runtime.lastDiscoveryStatus, .timedOut)
        await assertSend(runtime, command: 1, snapshot: first, equals: .staleContext)
        backend.error = nil
        let second = try await snapshot(runtime)
        XCTAssertFalse(first.client === second.client)
        runtime.stop()
        let third = try await snapshot(runtime)
        XCTAssertFalse(second.client === third.client)
    }

    func testStoppedAndExpiredQueuedReadsNeverCallBackendOrPublish() async {
        let backend = ChromeTestBackend(); let clock = ChromeTestBox<TimeInterval>(10)
        let queue = DispatchQueue(label: "chrome-read-test")
        let runtime = MacChromeNowPlayingRuntime(backend: backend, queue: queue, now: { clock.get() })
        queue.suspend()
        let done = expectation(description: "stopped read")
        runtime.fetchSnapshot { value in
            guard case .retry = value else { return XCTFail("Stopped read published") }
            done.fulfill()
        }
        runtime.stop(); queue.resume()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(backend.reads, 0)
        queue.suspend()
        let expired = expectation(description: "expired read")
        runtime.fetchSnapshot { value in
            guard case .retry = value else { return XCTFail("Expired read published") }
            expired.fulfill()
        }
        clock.set(12); queue.resume()
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertEqual(backend.reads, 0)
        XCTAssertEqual(runtime.lastDiscoveryStatus, .timedOut)
    }

    func testRevokedAndExpiredQueuedCommandsCannotCallBackend() async throws {
        for expiry in [false, true] {
            let backend = ChromeTestBackend(); let clock = ChromeTestBox<TimeInterval>(10)
            let queue = DispatchQueue(label: "chrome-command-test")
            let runtime = MacChromeNowPlayingRuntime(backend: backend, queue: queue, now: { clock.get() })
            let current = try await snapshot(runtime)
            let authorization = WebRTCControlAuthorization()
            queue.suspend()
            let done = expectation(description: "command canceled")
            runtime.send(rawCommand: 1, snapshot: current, isAuthorized: { authorization.isValid }) {
                XCTAssertEqual($0, .staleContext); done.fulfill()
            }
            if expiry { clock.set(12) } else { authorization.revoke() }
            queue.resume()
            await fulfillment(of: [done], timeout: 2)
            XCTAssertTrue(backend.commands.isEmpty)
        }
    }

    func testRelativeTimeoutConsumesOldTokenAcrossRefreshAndDoesNotDisableFreshControl() async throws {
        let backend = ChromeTestBackend(); backend.commandError = .timedOut
        let runtime = makeRuntime(backend)
        let first = try await snapshot(runtime)
        await assertSend(runtime, command: 4, snapshot: first, equals: .failed)
        await assertSend(runtime, command: 4, snapshot: first, equals: .staleContext)
        let fresh = try await snapshot(runtime)
        XCTAssertFalse(first.client === fresh.client)
        await assertSend(runtime, command: 4, snapshot: first, equals: .staleContext)
        await assertSend(runtime, command: 4, snapshot: fresh, equals: .failed)
        XCTAssertEqual(backend.commands, [.next, .next])
    }

    func testRoutineFetchAheadOfQueuedRelativeCommandDoesNotCancelItsOwnAuthority() async throws {
        let backend = ChromeTestBackend()
        let queue = DispatchQueue(label: "chrome-overlap-test")
        let runtime = MacChromeNowPlayingRuntime(backend: backend, queue: queue, now: { 10 })
        let first = try await snapshot(runtime)
        queue.suspend()
        let fetched = expectation(description: "overlapping unchanged read")
        runtime.fetchSnapshot { value in
            guard case .snapshot(let value) = value else { return XCTFail("Routine read became indeterminate") }
            XCTAssertTrue(value.client === first.client)
            fetched.fulfill()
        }
        let commanded = expectation(description: "relative command executes once")
        runtime.send(rawCommand: 4, snapshot: first, isAuthorized: { true }) {
            XCTAssertEqual($0, .applied); commanded.fulfill()
        }
        queue.resume()
        await fulfillment(of: [fetched, commanded], timeout: 2)
        XCTAssertEqual(backend.commands, [.next])
        await assertSend(runtime, command: 4, snapshot: first, equals: .staleContext)
        let refreshed = try await snapshot(runtime)
        XCTAssertFalse(refreshed.client === first.client)
    }

    func testPermissionCompletionAfterStopCannotReviveLifecycle() async {
        let backend = ChromeTestBackend(); let runtime = makeRuntime(backend)
        let started = expectation(description: "permission began")
        let gate = DispatchSemaphore(value: 0)
        backend.onPermission = { started.fulfill(); _ = gate.wait(timeout: .now() + 2) }
        let done = expectation(description: "permission completion")
        runtime.requestAutomationPermission { accepted in XCTAssertFalse(accepted); done.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        runtime.stop(); gate.signal()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(backend.permissions, 1)
        XCTAssertEqual(runtime.lastDiscoveryStatus, .idle)
    }

    private func makeBackend(_ client: ChromeTestClient, now: @escaping @Sendable () -> TimeInterval = { 10 })
        -> MacChromeAppleEventsBackend {
        .init(client: client, now: now, wallNow: { 1000 })
    }
    private func makeRuntime(_ backend: ChromeTestBackend) -> MacChromeNowPlayingRuntime {
        .init(backend: backend, now: { 10 })
    }
    private func fetch(_ runtime: MacChromeNowPlayingRuntime) async -> MacNowPlayingRuntimeSnapshotResult {
        await withCheckedContinuation { continuation in runtime.fetchSnapshot { continuation.resume(returning: $0) } }
    }
    private func snapshot(_ runtime: MacChromeNowPlayingRuntime) async throws -> MacNowPlayingRuntimeSnapshot {
        guard case .snapshot(let snapshot) = await fetch(runtime) else { throw MacChromeBackendError.unavailable }
        return snapshot
    }
    private func assertSend(_ runtime: MacChromeNowPlayingRuntime, command: Int, snapshot: MacNowPlayingRuntimeSnapshot,
                            equals expected: WebRTCRemoteMediaCommandResult,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let result = await withCheckedContinuation { continuation in
            runtime.send(rawCommand: command, snapshot: snapshot, isAuthorized: { true }) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(result, expected, file: file, line: line)
    }
}
