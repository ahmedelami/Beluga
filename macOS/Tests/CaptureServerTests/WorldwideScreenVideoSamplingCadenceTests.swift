import XCTest
@testable import CaptureServer

final class WorldwideScreenVideoSamplingCadenceTests: XCTestCase {
    func testRegularSamplingNeverRunsBeforeItsWallClockDeadline() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)

        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(500)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(499))))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(500))), .regular)
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(520)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(1_000))))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(1_020))), .regular)
    }

    func testCapacitySlotsFitBetweenRegularObservationsWithoutMovingThemEarlier() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        let expected: [(Int, WorldwideScreenVideoSamplingCadence.Sample)] = [
            (200, .capacityOnly), (400, .capacityOnly), (500, .regular),
            (700, .capacityOnly), (900, .capacityOnly), (1_000, .regular),
        ]

        for (milliseconds, sample) in expected {
            let deadline = start.advanced(by: .milliseconds(milliseconds))
            XCTAssertEqual(cadence.nextDeadline, deadline)
            XCTAssertNil(cadence.takeDueSample(at: deadline.advanced(by: .milliseconds(-1))))
            XCTAssertEqual(cadence.takeDueSample(at: deadline), sample)
            XCTAssertNil(cadence.takeDueSample(at: deadline))
            cadence.didFinishSample(at: deadline)
        }
    }

    func testSlowRegularCallbackCannotCreateCatchUpCounterBursts() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)

        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(500))), .regular)
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(2_000))))
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(2_300)))
        XCTAssertEqual(cadence.nextRegularDeadline, start.advanced(by: .milliseconds(2_800)))
        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(2_500)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(2_300))))

        cadence.setCapacityProbeEnabled(false, at: start.advanced(by: .milliseconds(2_300)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(2_799))))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(2_800))), .regular)
    }

    func testLateWakeRunsOnlyOneRegularSlotAndDiscardsMissedCapacitySlots() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        let late = start.advanced(by: .milliseconds(5_100))

        XCTAssertEqual(cadence.takeDueSample(at: late), .regular)
        XCTAssertNil(cadence.takeDueSample(at: late))
        cadence.didFinishSample(at: late)
        for _ in 0..<10 {
            XCTAssertNil(cadence.takeDueSample(at: late))
        }
        XCTAssertEqual(cadence.nextRegularDeadline, late.advanced(by: .milliseconds(500)))
        XCTAssertEqual(cadence.nextDeadline, late.advanced(by: .milliseconds(200)))
    }

    func testSlowCapacityCallbackDoesNotPostponeAnOverdueRegularObservation() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)

        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(200))), .capacityOnly)
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(1_100)))
        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(500)))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(1_100))), .regular)
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(1_120)))
        XCTAssertEqual(cadence.nextRegularDeadline, start.advanced(by: .milliseconds(1_620)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(1_120))))
    }

    func testDisablingProbesForInactivityLeavesRegularSamplingAndReenableStartsFresh() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        cadence.setCapacityProbeEnabled(false, at: start.advanced(by: .milliseconds(150)))

        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(500)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(200))))
        cadence.setCapacityProbeEnabled(true, at: start.advanced(by: .milliseconds(300)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(499))))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(500))), .regular)
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(500)))
        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(700)))
    }

    func testAutomaticResumeDisableDuringAnOutstandingRequestCannotRearmCapacity() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(200))), .capacityOnly)
        cadence.setCapacityProbeEnabled(false, at: start.advanced(by: .milliseconds(210)))
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(250)))

        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(500)))
        XCTAssertNil(cadence.takeDueSample(at: start.advanced(by: .milliseconds(450))))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(500))), .regular)
    }

    func testRepeatedEligibilityRefreshesDoNotDeferTheCapacityDeadline() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        for milliseconds in [50, 100, 150, 199] {
            cadence.setCapacityProbeEnabled(true, at: start.advanced(by: .milliseconds(milliseconds)))
        }
        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(200))), .capacityOnly)
    }

    func testProbeWindowHasBoundedRequestsAndUnchangedRegularSampleCount() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        cadence.setCapacityProbeEnabled(true, at: start)
        var regularTimes = [Int]()
        var capacityCount = 0

        for milliseconds in 0...3_500 {
            let now = start.advanced(by: .milliseconds(milliseconds))
            guard let sample = cadence.takeDueSample(at: now) else { continue }
            switch sample {
            case .regular: regularTimes.append(milliseconds)
            case .capacityOnly: capacityCount += 1
            }
            cadence.didFinishSample(at: now)
        }

        XCTAssertEqual(regularTimes, [500, 1_000, 1_500, 2_000, 2_500, 3_000, 3_500])
        XCTAssertEqual(capacityCount, 14)
    }

    func testDuplicateCompletionCannotDelayTheNextRegularObservation() {
        let start = ContinuousClock().now
        var cadence = WorldwideScreenVideoSamplingCadence(startedAt: start)
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(500))), .regular)
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(520)))
        cadence.didFinishSample(at: start.advanced(by: .milliseconds(900)))

        XCTAssertEqual(cadence.nextDeadline, start.advanced(by: .milliseconds(1_020)))
        XCTAssertEqual(cadence.takeDueSample(at: start.advanced(by: .milliseconds(1_020))), .regular)
    }
}
