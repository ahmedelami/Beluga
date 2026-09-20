import CoreAudio
import XCTest
@testable import CaptureCore

final class CoreAudioProcessTapAggregateConfigurationTests: XCTestCase {
    func testEveryFreshAggregateStartsWithoutWaitingForTappedPlayback() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("Requires process taps") }
        for lifetime in 1...3 {
            let description = CoreAudioProcessTapAggregateConfiguration.description(
                aggregateUID: "aggregate-\(lifetime)",
                tapUID: "tap-\(lifetime)",
                clockDeviceUID: "real-output-\(lifetime)"
            ) as NSDictionary

            XCTAssertEqual(description[kAudioAggregateDeviceTapAutoStartKey] as? NSNumber, 0,
                           "A silent Mac must not gate fresh microphone reader startup.")
            XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, "aggregate-\(lifetime)")
            XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String,
                           "real-output-\(lifetime)")
            XCTAssertEqual(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: String]],
                           [[kAudioSubDeviceUIDKey: "real-output-\(lifetime)"]])
            let taps = try XCTUnwrap(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
            XCTAssertEqual(taps.count, 1)
            XCTAssertEqual(taps.first?[kAudioSubTapUIDKey] as? String, "tap-\(lifetime)")
            XCTAssertEqual(taps.first?[kAudioSubTapDriftCompensationKey] as? Bool, true)
            XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
            XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, false)
        }
    }
}
