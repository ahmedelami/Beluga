import Foundation
@testable import WebRTCTransport
import XCTest

private final class AudioSamplerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class AudioDiagnosticsSamplerTests: XCTestCase {
    func testTimeoutDoesNotReleaseNativeSlotOrQueueReplacementReaders() async throws {
        let coordinator = WebRTCAudioDiagnosticsReadCoordinator(minimumInterval: 0)
        let entered = XCTestExpectation(description: "native read entered")
        let completed = XCTestExpectation(description: "native read exited")
        let release = DispatchSemaphore(value: 0)
        let old = WebRTCAudioDiagnosticsSampler(coordinator: coordinator, timeout: 0.02) {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            completed.fulfill()
            return .init()
        }
        let first = Task { await old.sample() }
        await fulfillment(of: [entered], timeout: 1)
        let timedOut = await first.value
        XCTAssertNil(timedOut)
        let counter = AudioSamplerCounter()
        let replacement = WebRTCAudioDiagnosticsSampler(coordinator: coordinator) {
            counter.increment()
            return .init()
        }
        for _ in 0..<100 {
            let unavailable = await replacement.sample()
            XCTAssertNil(unavailable)
        }
        XCTAssertEqual(counter.value, 0, "Timeout must not create a native-read backlog")
        old.invalidate()
        release.signal()
        await fulfillment(of: [completed], timeout: 1)
        var result: WebRTCAudioClientNativeSnapshot?
        for _ in 0..<100 where result == nil {
            result = await replacement.sample()
            if result == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(counter.value, 1)
        replacement.invalidate()
    }

    func testRetirementRejectsInFlightCompletionAndNeverRebindsDevice() async {
        let coordinator = WebRTCAudioDiagnosticsReadCoordinator(minimumInterval: 0)
        let entered = XCTestExpectation(description: "read captured old device")
        let release = DispatchSemaphore(value: 0)
        let counter = AudioSamplerCounter()
        let sampler = WebRTCAudioDiagnosticsSampler(coordinator: coordinator, timeout: 1) {
            counter.increment()
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            var value = WebRTCAudioClientNativeSnapshot()
            value.playoutCallbackCount = 123
            return value
        }
        let task = Task { await sampler.sample() }
        await fulfillment(of: [entered], timeout: 1)
        sampler.invalidate()
        let retiredRead = await sampler.sample()
        XCTAssertNil(retiredRead)
        release.signal()
        let staleResult = await task.value
        XCTAssertNil(staleResult)
        XCTAssertEqual(counter.value, 1)
    }

    func testFastSuccessfulReadCompletesOnceAndDefaultCadenceIsBounded() async {
        let coordinator = WebRTCAudioDiagnosticsReadCoordinator()
        let counter = AudioSamplerCounter()
        let sampler = WebRTCAudioDiagnosticsSampler(coordinator: coordinator) {
            counter.increment()
            var value = WebRTCAudioClientNativeSnapshot()
            value.playoutCallbackCount = 9
            return value
        }
        let first = await sampler.sample()
        XCTAssertEqual(first?.playoutCallbackCount, 9)
        let immediate = await sampler.sample()
        XCTAssertNil(immediate)
        XCTAssertEqual(counter.value, 1)
        sampler.invalidate()
    }
}
