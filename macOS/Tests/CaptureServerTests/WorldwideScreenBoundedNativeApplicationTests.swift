import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideScreenBoundedNativeApplicationTests: XCTestCase {
    func testOrdinaryApplicationWithoutDeadlineDoesNotAcquireTrialExpiry() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)
        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: nil, now: { state.now },
            apply: {
                state.recordApply()
                state.advance(to: origin.advanced(by: .seconds(10)))
                return 31
            },
            rollback: { _ in state.recordRollback(); return true })
        guard case let .applied(token) = outcome else { return XCTFail("Ordinary update expired") }
        XCTAssertEqual(token, 31)
        XCTAssertEqual(state.applyCount, 1)
        XCTAssertEqual(state.rollbackCount, 0)
    }

    func testExpiredBeforeApplyDoesNotInvokeNativeClosures() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: origin,
            now: { state.now },
            apply: {
                state.recordApply()
                return 7
            },
            rollback: { _ in
                state.recordRollback()
                return true
            }
        )

        assertExpired(outcome, rollbackWasProven: true)
        XCTAssertEqual(state.applyCount, 0)
        XCTAssertEqual(state.rollbackCount, 0)
    }

    func testValidApplyReturnsTokenWithoutRollback() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: origin.advanced(by: .seconds(3)),
            now: { state.now },
            apply: {
                state.recordApply()
                return 19
            },
            rollback: { _ in
                state.recordRollback()
                return true
            }
        )

        guard case let .applied(token) = outcome else {
            return XCTFail("Expected a valid native application")
        }
        XCTAssertEqual(token, 19)
        XCTAssertEqual(state.applyCount, 1)
        XCTAssertEqual(state.rollbackCount, 0)
    }

    func testApplyCrossingDeadlineRollsBackBeforeReturningExpired() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: origin.advanced(by: .seconds(3)),
            now: { state.now },
            apply: {
                state.recordApply()
                state.advance(to: origin.advanced(by: .seconds(4)))
                return 23
            },
            rollback: { token in
                state.recordRollback(token: token)
                return true
            }
        )

        assertExpired(outcome, rollbackWasProven: true)
        XCTAssertEqual(state.applyCount, 1)
        XCTAssertEqual(state.rollbackTokens, [23])
    }

    func testApplyErrorPropagatesWithoutRollback() async {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        do {
            let _: WorldwideScreenBoundedNativeApplicationOutcome<Int> =
                try await WorldwideScreenBoundedNativeApplication.apply(
                    deadline: origin.advanced(by: .seconds(3)),
                    now: { state.now },
                    apply: {
                        state.recordApply()
                        throw BoundedNativeApplicationTestError.applyFailed
                    },
                    rollback: { _ in
                        state.recordRollback()
                        return true
                    }
                )
            XCTFail("Expected the native apply error")
        } catch {
            XCTAssertEqual(error as? BoundedNativeApplicationTestError, .applyFailed)
        }
        XCTAssertEqual(state.applyCount, 1)
        XCTAssertEqual(state.rollbackCount, 0)
    }

    func testRollbackFalseReportsUnknownNativeState() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: origin.advanced(by: .seconds(3)),
            now: { state.now },
            apply: {
                state.recordApply()
                state.advance(to: origin.advanced(by: .seconds(4)))
                return 29
            },
            rollback: { token in
                state.recordRollback(token: token)
                return false
            }
        )

        assertExpired(outcome, rollbackWasProven: false)
        XCTAssertEqual(state.rollbackTokens, [29])
    }

    func testRollbackErrorReportsUnknownNativeState() async throws {
        let origin = ContinuousClock.now
        let state = BoundedNativeApplicationTestState(now: origin)

        let outcome = try await WorldwideScreenBoundedNativeApplication.apply(
            deadline: origin.advanced(by: .seconds(3)),
            now: { state.now },
            apply: {
                state.recordApply()
                state.advance(to: origin.advanced(by: .seconds(4)))
                return 31
            },
            rollback: { token in
                state.recordRollback(token: token)
                throw BoundedNativeApplicationTestError.rollbackFailed
            }
        )

        assertExpired(outcome, rollbackWasProven: false)
        XCTAssertEqual(state.rollbackTokens, [31])
    }

    private func assertExpired<Token: Sendable>(
        _ outcome: WorldwideScreenBoundedNativeApplicationOutcome<Token>,
        rollbackWasProven: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .expired(actual) = outcome else {
            return XCTFail("Expected an expired native application", file: file, line: line)
        }
        XCTAssertEqual(actual, rollbackWasProven, file: file, line: line)
    }
}

private enum BoundedNativeApplicationTestError: Error, Equatable {
    case applyFailed
    case rollbackFailed
}

private final class BoundedNativeApplicationTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: ContinuousClock.Instant
    private var storedApplyCount = 0
    private var storedRollbackTokens: [Int] = []

    init(now: ContinuousClock.Instant) {
        storedNow = now
    }

    var now: ContinuousClock.Instant {
        lock.withLock { storedNow }
    }

    var applyCount: Int {
        lock.withLock { storedApplyCount }
    }

    var rollbackCount: Int {
        lock.withLock { storedRollbackTokens.count }
    }

    var rollbackTokens: [Int] {
        lock.withLock { storedRollbackTokens }
    }

    func advance(to now: ContinuousClock.Instant) {
        lock.withLock { storedNow = max(storedNow, now) }
    }

    func recordApply() {
        lock.withLock { storedApplyCount += 1 }
    }

    func recordRollback(token: Int = 0) {
        lock.withLock { storedRollbackTokens.append(token) }
    }
}
