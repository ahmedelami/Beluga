import XCTest
@testable import CaptureServer

/// Exercises the production invalidation seam across real actor suspensions, not a host session.
final class WorldwideScreenNativeApplicationCacheTests: XCTestCase {
    func testForcedReconciliationIsRequiredEvenWhenCacheAlreadyMatches() {
        XCTAssertFalse(
            WorldwideScreenNativeApplicationCache.requiresNativeReconciliation(
                applied: initialRecommendation,
                desired: initialRecommendation,
                force: false
            )
        )
        XCTAssertTrue(
            WorldwideScreenNativeApplicationCache.requiresNativeReconciliation(
                applied: initialRecommendation,
                desired: initialRecommendation,
                force: true
            )
        )
        XCTAssertTrue(
            WorldwideScreenNativeApplicationCache.requiresNativeReconciliation(
                applied: nil,
                desired: initialRecommendation,
                force: false
            )
        )
    }

    func testStaleSamePeerApplyFailurePreservesNewerRecommendation() async {
        await assertSupersededFailure(.applyFailed)
    }

    func testStaleSamePeerRollbackFailurePreservesNewerRecommendation() async {
        await assertSupersededFailure(.rollbackFailed)
    }

    func testCurrentOwnerFailureInvalidatesAndRequiresOneReapplication() async {
        let owner = NativeApplicationCacheOwner()
        let entered = expectation(description: "Native operation suspended")
        let suspension = NativeApplicationCacheSuspension(entered: entered)
        let completion = Task {
            await owner.reconcileFailure {
                await suspension.wait()
                throw NativeApplicationCacheFailure.applyFailed
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await suspension.release()
        let invalidated = await completion.value
        let beforeReconciliation = await owner.snapshot()
        let reapplications = await owner.reconcileIfNeeded(with: initialRecommendation)

        XCTAssertTrue(invalidated)
        XCTAssertNil(beforeReconciliation.recommendation)
        XCTAssertEqual(reapplications, 1)
        let afterReconciliation = await owner.snapshot()
        XCTAssertEqual(afterReconciliation.recommendation, initialRecommendation)
    }

    func testAuthorizationLossWithoutRevisionChangeCannotInvalidateCache() async {
        await assertOtherOwnerChangePreservesCache(replacePeer: false)
    }

    func testPeerReplacementWithoutRevisionChangeCannotInvalidateCache() async {
        await assertOtherOwnerChangePreservesCache(replacePeer: true)
    }

    private func assertSupersededFailure(
        _ failure: NativeApplicationCacheFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let owner = NativeApplicationCacheOwner()
        let original = await owner.snapshot()
        let entered = expectation(description: "Old native completion suspended")
        let suspension = NativeApplicationCacheSuspension(entered: entered)
        let completion = Task {
            await owner.reconcileFailure {
                await suspension.wait()
                throw failure
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await owner.installSuccessor(newerRecommendation)
        let successor = await owner.snapshot()
        await suspension.release()
        let invalidated = await completion.value
        let afterOldCompletion = await owner.snapshot()
        let reapplications = await owner.reconcileIfNeeded(with: newerRecommendation)

        XCTAssertEqual(successor.peerGeneration, original.peerGeneration, file: file, line: line)
        XCTAssertGreaterThan(successor.policyRevision, original.policyRevision, file: file, line: line)
        XCTAssertFalse(invalidated, file: file, line: line)
        XCTAssertEqual(afterOldCompletion.recommendation, newerRecommendation, file: file, line: line)
        XCTAssertEqual(afterOldCompletion.policyRevision, successor.policyRevision, file: file, line: line)
        XCTAssertEqual(reapplications, 0, "A stale failure must not cause an unnecessary native reapply", file: file, line: line)
    }

    private func assertOtherOwnerChangePreservesCache(
        replacePeer: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let owner = NativeApplicationCacheOwner()
        let original = await owner.snapshot()
        let entered = expectation(description: "Native operation suspended before ownership loss")
        let suspension = NativeApplicationCacheSuspension(entered: entered)
        let completion = Task {
            await owner.reconcileFailure {
                await suspension.wait()
                throw NativeApplicationCacheFailure.applyFailed
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await owner.changeOtherOwner(replacePeer: replacePeer)
        await suspension.release()
        let invalidated = await completion.value
        let result = await owner.snapshot()

        XCTAssertEqual(result.policyRevision, original.policyRevision, file: file, line: line)
        XCTAssertFalse(invalidated, file: file, line: line)
        XCTAssertEqual(result.recommendation, initialRecommendation, file: file, line: line)
    }
}

private enum NativeApplicationCacheFailure: Error, Sendable {
    case applyFailed
    case rollbackFailed
}

private struct NativeApplicationCacheSnapshot: Sendable {
    let peerGeneration: UInt64
    let policyRevision: UInt64
    let recommendation: WorldwideScreenVideoEncodingRecommendation?
}

private actor NativeApplicationCacheOwner {
    private var peerGeneration: UInt64 = 7
    private var policyRevision: UInt64 = 11
    private var authorizationIsValid = true
    private var recommendation: WorldwideScreenVideoEncodingRecommendation? = initialRecommendation
    private var reapplications = 0

    func reconcileFailure(_ operation: @Sendable () async throws -> Void) async -> Bool {
        let expectedPeerGeneration = peerGeneration
        let expectedPolicyRevision = policyRevision
        do {
            try await operation()
            return false
        } catch {
            return WorldwideScreenNativeApplicationCache.invalidateIfCurrent(
                &recommendation,
                expectedPolicyRevision: expectedPolicyRevision,
                currentPolicyRevision: policyRevision,
                otherOwnersAreCurrent: peerGeneration == expectedPeerGeneration && authorizationIsValid
            )
        }
    }

    func installSuccessor(_ next: WorldwideScreenVideoEncodingRecommendation) {
        policyRevision += 1
        recommendation = next
    }

    func changeOtherOwner(replacePeer: Bool) {
        if replacePeer {
            peerGeneration += 1
        } else {
            authorizationIsValid = false
        }
    }

    func snapshot() -> NativeApplicationCacheSnapshot {
        .init(peerGeneration: peerGeneration, policyRevision: policyRevision, recommendation: recommendation)
    }

    func reconcileIfNeeded(with expected: WorldwideScreenVideoEncodingRecommendation) -> Int {
        if recommendation != expected {
            reapplications += 1
            recommendation = expected
        }
        return reapplications
    }
}

private actor NativeApplicationCacheSuspension {
    private let entered: XCTestExpectation
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(entered: XCTestExpectation) {
        self.entered = entered
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
            entered.fulfill()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private let initialRecommendation = WorldwideScreenVideoEncodingRecommendation(
    tier: .constrained, maximumBitrateBps: 2_000_000,
    maximumTotalRTPBitrateBps: 2_256_000, maximumFramesPerSecond: 5,
    scaleResolutionDownBy: 2
)

private let newerRecommendation = WorldwideScreenVideoEncodingRecommendation(
    tier: .balanced, maximumBitrateBps: 4_000_000,
    maximumTotalRTPBitrateBps: 4_256_000, maximumFramesPerSecond: 13,
    scaleResolutionDownBy: 1
)
