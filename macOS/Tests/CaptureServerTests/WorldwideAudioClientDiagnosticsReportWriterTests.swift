import Darwin
import Foundation
@testable import CaptureServer
import WebRTCTransport
import XCTest

final class WorldwideAudioClientDiagnosticsReportWriterTests: XCTestCase {
    func testReportHasFiniteExpiryAndPreservesContentFreeFailureAndEvents() throws {
        let value = report()
        XCTAssertEqual(value.receivedAtUnixMilliseconds, 998_000)
        XCTAssertEqual(value.freshUntilUnixMilliseconds, 1_003_000)
        XCTAssertEqual(value.generatedAtUnixMilliseconds, 1_000_000)
        XCTAssertEqual(value.acousticAudibility, "unverified")
        let bytes = try JSONEncoder().encode(value)
        XCTAssertLessThan(bytes.count, WorldwideAudioClientReportStorage.maximumBytes)
        let decoded = try JSONDecoder().decode(WorldwideAudioClientDiagnosticsReport.self, from: bytes)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.heartbeat?.failureSnapshot?.native?.failureContext?.reason, .activationRejected)
        XCTAssertEqual(decoded.heartbeat?.events.count, 8)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for forbidden in ["routeName", "NSError", "SSRC", "SDP", "trackID", "title", "artist"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testOnePendingReportCoalescesAndWritesAtMostOncePerFiveSeconds() {
        var schedule = WorldwideAudioClientReportSchedule()
        schedule.offer(report(peerGeneration: 1), terminal: false)
        XCTAssertEqual(schedule.take(now: 0)?.peerGeneration, 1)
        for generation in 2...1_000 {
            schedule.offer(report(peerGeneration: UInt64(generation)), terminal: false)
            XCTAssertNil(schedule.take(now: 4))
        }
        XCTAssertEqual(schedule.pending?.peerGeneration, 1_000)
        XCTAssertEqual(schedule.delay(now: 4), 1)
        XCTAssertEqual(schedule.take(now: 5)?.peerGeneration, 1_000)
        XCTAssertNil(schedule.pending)
    }

    func testOnlyChangedTerminalStatusBypassesOrdinaryRateLimit() {
        var schedule = WorldwideAudioClientReportSchedule()
        schedule.offer(report(), terminal: false)
        XCTAssertNotNil(schedule.take(now: 0))
        schedule.offer(report(status: .unavailable(.stopped)), terminal: true)
        XCTAssertNotNil(schedule.take(now: 1))
        schedule.offer(report(status: .unavailable(.stopped)), terminal: true)
        XCTAssertNil(schedule.take(now: 2))
        XCTAssertNotNil(schedule.take(now: 6))
    }

    func testSerializedWriterKeepsOnlyLatestPendingDuringBlockedStorage() {
        let entered = expectation(description: "first storage operation")
        let finished = expectation(description: "latest coalesced operation")
        let release = DispatchSemaphore(value: 0)
        let spy = WriteSpy()
        let writer = WorldwideAudioClientDiagnosticsReportWriter { value in
            let count = spy.record(value.peerGeneration)
            if count == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
            } else {
                finished.fulfill()
            }
        }
        writer.submit(report(peerGeneration: 1))
        wait(for: [entered], timeout: 1)
        for generation in 2...1_000 {
            writer.submit(report(peerGeneration: UInt64(generation)))
        }
        writer.submit(report(peerGeneration: 1_001, status: .unavailable(.stopped)), terminal: true)
        release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(spy.values, [1, 1_001])
    }

    func testTerminalUpdateWakesAlreadyScheduledFiveSecondDelay() {
        let first = expectation(description: "initial write")
        let terminal = expectation(description: "terminal write without five-second wait")
        let spy = WriteSpy()
        let writer = WorldwideAudioClientDiagnosticsReportWriter { value in
            let count = spy.record(value.peerGeneration)
            if count == 1 { first.fulfill() } else { terminal.fulfill() }
        }
        writer.submit(report(peerGeneration: 1))
        wait(for: [first], timeout: 1)
        writer.submit(report(peerGeneration: 2))
        let stopped = report(peerGeneration: 3, status: .unavailable(.stopped))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            writer.submit(stopped, terminal: true)
        }
        wait(for: [terminal], timeout: 1)
        XCTAssertEqual(spy.values, [1, 3])
    }

    func testFreshPrivateReportIsAtomicAndReplacesOnlyValidPriorReport() throws {
        try withFixture { root in
            let storage = WorldwideAudioClientReportStorage(applicationSupportURL: root)
            try storage.write(report(peerGeneration: 7))
            let directory = root.appendingPathComponent("opensteamer/diagnostics")
            let file = directory.appendingPathComponent(WorldwideAudioClientReportStorage.fileName)
            let original = try metadata(file)
            XCTAssertEqual(original.st_mode & 0o777, 0o600)
            XCTAssertEqual(original.st_uid, geteuid())
            XCTAssertEqual(try metadata(directory).st_mode & 0o777, 0o700)
            try storage.write(report(peerGeneration: 8, status: .unavailable(.stopped)))
            let next = try metadata(file)
            XCTAssertNotEqual(original.st_ino, next.st_ino)
            let decoded = try JSONDecoder().decode(WorldwideAudioClientDiagnosticsReport.self, from: Data(contentsOf: file))
            XCTAssertEqual(decoded.peerGeneration, 8)
            XCTAssertEqual(decoded.status, "unavailable.stopped")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["audio-client-v1.json"])
        }
    }

    func testSymlinkedProductDirectoryIsRejectedWithoutWritingOutsideTarget() throws {
        try withFixture { root in
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("opensteamer"), withDestinationURL: outside)
            XCTAssertThrowsError(try WorldwideAudioClientReportStorage(applicationSupportURL: root).write(report()))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        }
    }

    func testSymlinkedApplicationSupportAncestorIsRejected() throws {
        try withFixture { root in
            let actual = root.appendingPathComponent("actual")
            let link = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
            XCTAssertThrowsError(try WorldwideAudioClientReportStorage(applicationSupportURL: link).write(report()))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: actual.path), [])
        }
    }

    func testSymlinkedReportDoesNotOverwriteItsTarget() throws {
        try withFixture { root in
            let storage = WorldwideAudioClientReportStorage(applicationSupportURL: root)
            try storage.write(report())
            let file = root.appendingPathComponent("opensteamer/diagnostics/audio-client-v1.json")
            let sentinel = root.appendingPathComponent("sentinel")
            let content = Data("fixture-sentinel".utf8)
            try content.write(to: sentinel)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
            XCTAssertThrowsError(try storage.write(report(peerGeneration: 99)))
            XCTAssertEqual(try Data(contentsOf: sentinel), content)
            XCTAssertEqual(try metadata(file).st_mode & S_IFMT, S_IFLNK)
        }
    }

    func testPermissiveExistingDirectoryIsRejectedRatherThanRepaired() throws {
        try withFixture { root in
            let product = root.appendingPathComponent("opensteamer")
            try FileManager.default.createDirectory(at: product, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o755])
            XCTAssertThrowsError(try WorldwideAudioClientReportStorage(applicationSupportURL: root).write(report()))
            XCTAssertEqual(try metadata(product).st_mode & 0o777, 0o755)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: product.path), [])
        }
    }

    func testNonownedOrNondirectoryMetadataFailsPrivacyAdmission() {
        XCTAssertTrue(WorldwideAudioClientReportStorage.isPrivateDirectory(mode: S_IFDIR | 0o700, owner: 501, expectedOwner: 501))
        XCTAssertFalse(WorldwideAudioClientReportStorage.isPrivateDirectory(mode: S_IFDIR | 0o700, owner: 502, expectedOwner: 501))
        XCTAssertFalse(WorldwideAudioClientReportStorage.isPrivateDirectory(mode: S_IFDIR | 0o755, owner: 501, expectedOwner: 501))
        XCTAssertFalse(WorldwideAudioClientReportStorage.isPrivateDirectory(mode: S_IFREG | 0o700, owner: 501, expectedOwner: 501))
    }

    func testACLGrantIsRejectedEvenWhenPOSIXModeRemainsPrivate() throws {
        for targetDirectory in [true, false] {
            try withFixture { root in
                let storage = WorldwideAudioClientReportStorage(applicationSupportURL: root)
                try storage.write(report())
                let directory = root.appendingPathComponent("opensteamer/diagnostics")
                let file = directory.appendingPathComponent("audio-client-v1.json")
                let target = targetDirectory ? directory : file
                let before = try Data(contentsOf: file)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/chmod")
                process.arguments = ["+a", targetDirectory
                    ? "everyone allow read,write,file_inherit,directory_inherit" : "everyone allow read,write", target.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertEqual(try metadata(target).st_mode & 0o777, targetDirectory ? 0o700 : 0o600)
                XCTAssertThrowsError(try storage.write(report(peerGeneration: 99)))
                XCTAssertEqual(try Data(contentsOf: file), before)
            }
        }
    }

    func testAbsentAndDenyOnlyExtendedACLPermitPrivateReportStorage() throws {
        try withFixture { root in
            let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }
            XCTAssertNoThrow(try WorldwideAudioClientReportStorage.rejectAllowACL(descriptor))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = ["+a", "everyone deny chown", root.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try metadata(root).st_mode & 0o777, 0o700)
            XCTAssertNoThrow(try WorldwideAudioClientReportStorage.rejectAllowACL(descriptor))
            try WorldwideAudioClientReportStorage(applicationSupportURL: root).write(report())
        }
    }

    func testInvalidDescriptorIsNotTreatedAsAnAbsentACL() {
        XCTAssertThrowsError(try WorldwideAudioClientReportStorage.rejectAllowACL(-1))
    }

    func testUnexpectedOversizedOrHardlinkedExistingFileIsNeverOverwritten() throws {
        for mode in 0...2 {
            try withFixture { root in
                let storage = WorldwideAudioClientReportStorage(applicationSupportURL: root)
                try storage.write(report())
                let file = root.appendingPathComponent("opensteamer/diagnostics/audio-client-v1.json")
                if mode == 0 {
                    try Data("unrelated fixture content".utf8).write(to: file)
                } else if mode == 1 {
                    try Data(repeating: 65, count: WorldwideAudioClientReportStorage.maximumBytes + 1).write(to: file)
                } else {
                    XCTAssertEqual(Darwin.link(file.path, root.appendingPathComponent("second-link").path), 0)
                }
                let before = try Data(contentsOf: file)
                XCTAssertThrowsError(try storage.write(report(peerGeneration: 999)))
                XCTAssertEqual(try Data(contentsOf: file), before)
            }
        }
    }

    private func report(peerGeneration: UInt64 = 7,
                        status: WorldwideAudioClientDiagnosticsSink.Status = .fresh(.renderingNonzero)) -> WorldwideAudioClientDiagnosticsReport {
        var native = WebRTCAudioClientNativeSnapshot()
        var cause = WebRTCAudioClientFailureContext()
        cause.eventSequence = 1
        cause.reason = .activationRejected
        cause.stage = .sessionActivation
        native.failureContext = cause
        var snapshot = WebRTCAudioClientSnapshot()
        snapshot.native = native
        snapshot.nativeObservationAgeMilliseconds = 0
        let heartbeat = WebRTCAudioClientDiagnosticsHeartbeat(
            sequence: 1, sessionID: UUID(), build: .init(buildNumber: 66), snapshot: snapshot,
            failureSnapshot: snapshot, events: (1...8).map {
                .init(sequence: UInt64($0), elapsedMilliseconds: UInt64($0), kind: .nativeReceipt)
            }
        )
        let latest = WorldwideAudioClientDiagnosticsSink.Latest(hostPID: 123, peerGeneration: peerGeneration,
            negotiationEpoch: 1, status: status, heartbeat: heartbeat, receiptUptime: 10)
        return .init(latest: latest, uptime: 12, date: Date(timeIntervalSince1970: 1_000))
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        // Build TMPDIR may live below a group-writable external-volume ancestor.
        // Keep these tiny fixtures under the admitted root-owned sticky directory;
        // production path admission remains identical and is never relaxed for tests.
        var template = Array("/private/tmp/opensteamer-audio-report-test.XXXXXX".utf8CString)
        let path = template.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        let directory = URL(fileURLWithPath: try XCTUnwrap(path), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return value
    }

    private final class WriteSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UInt64] = []
        var values: [UInt64] { lock.lock(); defer { lock.unlock() }; return recorded }
        func record(_ value: UInt64) -> Int {
            lock.lock(); defer { lock.unlock() }
            recorded.append(value)
            return recorded.count
        }
    }
}
