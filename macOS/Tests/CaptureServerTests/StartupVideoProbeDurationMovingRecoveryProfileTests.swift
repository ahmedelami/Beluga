#if os(macOS)
import XCTest
@testable import WebRTCTransport

final class StartupVideoProbeDurationMovingRecoveryProfileTests: XCTestCase {
    func testBothDurationArmsAcceptOnlyTheFixedMovingRecoveryProfile() {
        for duration in [15, 40] {
            var input = Input()
            input.durationMilliseconds = duration
            XCTAssertNoThrow(try input.validate())
        }
    }

    func testEveryBooleanProfileDriftIsRejectedIndependently() {
        let fields: [(String, WritableKeyPath<Input, Bool>)] = [
            ("followsPolicyFPS", \.followsPolicyFPS),
            ("movingContent", \.movingContent),
            ("shapeInitialCapture", \.shapeInitialCapture),
            ("capacityDropAndRecovery", \.capacityDropAndRecovery),
            ("spatialRecoveryEnabled", \.spatialRecoveryEnabled),
            ("requiresSpatialRecovery", \.requiresSpatialRecovery),
            ("secondCapacityDrop", \.secondCapacityDrop),
            ("collectTrafficTiming", \.collectTrafficTiming),
            ("collectReceiverTiming", \.collectReceiverTiming),
            ("observeEstimator", \.observeEstimator),
            ("holdDelayGrowthInALR", \.holdDelayGrowthInALR),
            ("skipProbesBelowCurrentEstimate", \.skipProbesBelowCurrentEstimate),
            ("hasOtherObserver", \.hasOtherObserver)
        ]
        for duration in [15, 40] {
            for (name, field) in fields {
                var input = Input()
                input.durationMilliseconds = duration
                input[keyPath: field].toggle()
                assertRejected(input, "duration=\(duration) field=\(name)")
            }
        }
    }

    func testNumericAndOptionalProfileDriftIsRejectedIndependently() {
        for duration in [Int.min, -1, 0, 14, 16, 25, 39, 41, 100, Int.max] {
            var input = Input()
            input.durationMilliseconds = duration
            assertRejected(input, "duration=\(duration)")
        }
        for duration in [15, 40] {
            var valid = Input()
            valid.durationMilliseconds = duration
            for bitrate in [UInt64(0), 1, 800_000, 7_999_999, 8_000_001, UInt64.max] {
                var input = valid
                input.bitsPerSecond = bitrate
                assertRejected(input, "bitrate=\(bitrate)")
            }
            let delays: [Int?] = [nil, Int.min, -1, 0, 1, 3, 20, 50, Int.max]
            for delay in delays {
                var input = valid
                input.oneWayDelayMilliseconds = delay
                assertRejected(input, "delay=\(String(describing: delay))")
            }
            for warmup in [Int.min, -1, 1, 1_000, Int.max] {
                var input = valid
                input.warmupMilliseconds = warmup
                assertRejected(input, "warmup=\(warmup)")
            }
            let modes: [StartupVideoPacerMode?] = [nil, .zeroBurst, .twentyMillisecondBurst]
            for mode in modes {
                var input = valid
                input.pacerMode = mode
                assertRejected(input, "pacerMode=\(String(describing: mode))")
            }
            let factors: [Double?] = [nil, -Double.infinity, -1, -0.0, 0.999_999,
                                      1.000_001, 1.15, Double.infinity, Double.nan]
            for factor in factors {
                var input = valid
                input.pacingFactor = factor
                assertRejected(input, "pacingFactor=\(String(describing: factor))")
            }
            XCTAssertNoThrow(try valid.validate(), "Rejected copies must not alter the valid profile")
        }
    }

    private func assertRejected(_ input: Input, _ context: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try input.validate(), context, file: file, line: line) { error in
            XCTAssertTrue(error is WebRTCTransportError, context, file: file, line: line)
        }
    }

    private struct Input {
        var durationMilliseconds = 15
        var bitsPerSecond: UInt64 = 8_000_000
        var oneWayDelayMilliseconds: Int? = 2
        var followsPolicyFPS = true
        var movingContent = true
        var warmupMilliseconds = 0
        var shapeInitialCapture = false
        var capacityDropAndRecovery = true
        var spatialRecoveryEnabled = true
        var requiresSpatialRecovery = true
        var secondCapacityDrop = false
        var collectTrafficTiming = true
        var collectReceiverTiming = true
        var pacerMode: StartupVideoPacerMode? = .sdkDefault
        var pacingFactor: Double? = 1
        var observeEstimator = true
        var holdDelayGrowthInALR = true
        var skipProbesBelowCurrentEstimate = true
        var hasOtherObserver = false

        func validate() throws {
            try StartupVideoProbeDurationMovingRecoveryProfile.validate(
                durationMilliseconds: durationMilliseconds,
                bitsPerSecond: bitsPerSecond,
                oneWayDelayMilliseconds: oneWayDelayMilliseconds,
                followsPolicyFPS: followsPolicyFPS,
                movingContent: movingContent,
                warmupMilliseconds: warmupMilliseconds,
                shapeInitialCapture: shapeInitialCapture,
                capacityDropAndRecovery: capacityDropAndRecovery,
                spatialRecoveryEnabled: spatialRecoveryEnabled,
                requiresSpatialRecovery: requiresSpatialRecovery,
                secondCapacityDrop: secondCapacityDrop,
                collectTrafficTiming: collectTrafficTiming,
                collectReceiverTiming: collectReceiverTiming,
                pacerMode: pacerMode,
                pacingFactor: pacingFactor,
                observeEstimator: observeEstimator,
                holdDelayGrowthInALR: holdDelayGrowthInALR,
                skipProbesBelowCurrentEstimate: skipProbesBelowCurrentEstimate,
                hasOtherObserver: hasOtherObserver)
        }
    }
}
#endif
