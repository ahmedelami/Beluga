#if os(macOS)
import Foundation
import XCTest

final class StartupVideoNativeEncoderLogObserverTests: XCTestCase {
    private func message(_ body: String) -> String { "(RTCVideoEncoderH264.mm:900): " + body }

    func testParsesExactDropFailureAndPropertyFormats() {
        let cases: [(String, StartupVideoNativeEncoderLogPayload)] = [
            ("H264 encode dropped frame.", .encodeDropped),
            ("Failed to encode frame with code: -12903", .encodeFailed(stage: .submission, status: -12903)),
            ("H264 encode failed with code: -12909", .encodeFailed(stage: .completion, status: -12909)),
            ("Did update encoder frame rate: 5", .frameRateUpdate(framesPerSecond: 5, result: .success)),
            ("Failed to set frame rate: 60 error: -50", .frameRateUpdate(framesPerSecond: 60, result: .failure(status: -50))),
            ("Did update encoder bitrate: 99360", .bitrateUpdate(bitrateBps: 99360, result: .success)),
            ("Failed to update encoder bitrate: 99360error: -50", .bitrateUpdate(bitrateBps: 99360, result: .failure(status: -50))),
            ("Did update encoder data rate limits", .dataRateLimitsUpdate(succeeded: true)),
            ("Failed to update encoder data rate limits", .dataRateLimitsUpdate(succeeded: false))
        ]
        for (body, payload) in cases {
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message(body)), payload)
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse("[123:456][789] " + message(body) + "\n"), payload)
        }
        XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Failed to update encoder bitrate: 99360 error: -50")))
        XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Failed to update encoder data rate limits error: -50")))
    }

    func testHardwareAndLowLatencyMessagesRetainOnlyAllowedEnums() {
        for enabled in [false, true] {
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message(
                "Compression session created with hw accl " + (enabled ? "enabled" : "disabled"))),
                .hardwareAccelerationReported(enabled: enabled))
        }
        let profiles: [StartupVideoNativeEncoderLogPayload.H264Profile] = [
            .constrainedBaseline, .baseline, .main, .constrainedHigh, .high, .predictiveHigh444, .unparsed, .unknown
        ]
        for profile in profiles {
            let enabled = profile.isHighFamily
            let body = "H264: \(enabled ? "enabling" : "skipping") EnableLowLatencyRateControl (profile=\(profile.rawValue), \(enabled ? "in" : "not in") High family)."
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message(body)),
                           .lowLatencyRateControl(enabled: enabled, profile: profile))
            let crossed = body.replacingOccurrences(of: enabled ? "enabling" : "skipping",
                                                     with: enabled ? "skipping" : "enabling")
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message(crossed)))
        }
        XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message(
            "H264: skipping EnableLowLatencyRateControl (profile=Other, not in High family).")))
        XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message(
            "H264: enabling EnableLowLatencyRateControl (profile=High, not in High family).")))
    }

    func testRejectsWrongSourceMalformedTrailingAndOversizedMessages() {
        let valid = message("H264 encode dropped frame.")
        let rejected = [
            "H264 encode dropped frame.", "private " + valid, "/path/" + valid,
            valid.replacingOccurrences(of: "RTCVideoEncoderH264.mm", with: "other.mm"),
            valid.replacingOccurrences(of: "RTCVideoEncoderH264.mm", with: "/tmp/RTCVideoEncoderH264.mm"),
            valid.replacingOccurrences(of: ":900", with: ":0"),
            valid.replacingOccurrences(of: ":900", with: ":-1"),
            valid.replacingOccurrences(of: ":900", with: ":1000000"),
            valid.replacingOccurrences(of: ":900", with: ":"),
            valid + " extra", valid + "\n" + valid, valid + "\n\n", valid + "\r\n", valid + "é",
            String(repeating: "0", count: 65) + valid,
            String(repeating: "0", count: StartupVideoNativeEncoderLogParser.maximumMessageBytes + 1),
            message("Did update encoder frame rate: 5 frameRate: 6"),
            message("Did update encoder bitrate: 99360 bitrate: 99360"),
            message("Failed to set frame rate: 60 error: -50 trailing"),
            message("setBitrateKBit: 99 targetBps: 99000 frameRate: 5")
        ]
        for value in rejected { XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(value), "Must reject unallowlisted format") }
    }

    func testNumericNativeWidthsAndZeroAutomaticValuesAreExact() {
        for value in [UInt32(0), UInt32.max] {
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message("Did update encoder bitrate: \(value)")),
                           .bitrateUpdate(bitrateBps: value, result: .success))
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message("Did update encoder frame rate: \(value)")),
                           .frameRateUpdate(framesPerSecond: value, result: .success))
        }
        for value in [Int32.min, -1, 1, Int32.max] {
            XCTAssertEqual(StartupVideoNativeEncoderLogParser.parse(message("H264 encode failed with code: \(value)")),
                           .encodeFailed(stage: .completion, status: value))
        }
        for token in ["-1", "+1", "1.5", "NaN", "inf", "4294967296", "18446744073709551616"] {
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Did update encoder bitrate: " + token)))
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Did update encoder frame rate: " + token)))
        }
        for token in ["0", "-0", "+1", "1.5", "NaN", "2147483648", "-2147483649"] {
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("H264 encode failed with code: " + token)))
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Failed to set frame rate: 5 error: " + token)))
            XCTAssertNil(StartupVideoNativeEncoderLogParser.parse(message("Failed to update encoder bitrate: 99error: " + token)))
        }
    }

    func testFixedWindowKeepsPreArmConfigurationWithoutPreArmFrameEvidence() throws {
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        collector.record(message("H264 encode dropped frame."), observedAtUptimeNanoseconds: 101, observedThreadID: 41)
        collector.record(message("Compression session created with hw accl enabled"),
                         observedAtUptimeNanoseconds: 999, observedThreadID: 42)
        // Configuration between the capture timestamp and arm stays explicitly pre-arm.
        collector.record(message("Did update encoder bitrate: 99360"),
                         observedAtUptimeNanoseconds: 1_001, observedThreadID: 42)
        try collector.arm(captureStartedAtUptimeNanoseconds: 1_000, observedAtUptimeNanoseconds: 1_002)
        collector.record(message("H264 encode dropped frame."), observedAtUptimeNanoseconds: 1_002, observedThreadID: 43)
        let end = 1_000 + StartupVideoNativeEncoderLogCollector.windowNanoseconds
        collector.record(message("H264 encode failed with code: -50"), observedAtUptimeNanoseconds: end - 1, observedThreadID: 43)
        collector.record(message("H264 encode dropped frame."), observedAtUptimeNanoseconds: end, observedThreadID: 43)
        collector.record(message("Did update encoder frame rate: 5"), observedAtUptimeNanoseconds: end + 1, observedThreadID: 42)
        let batch = collector.finish()
        XCTAssertTrue(batch.isVerified)
        XCTAssertEqual(batch.counts.omittedBeforeArmFrameCount, 1)
        XCTAssertEqual(batch.counts.outOfWindowEventCount, 2)
        XCTAssertEqual(batch.events.map(\.phase), [.preArmConfiguration, .preArmConfiguration, .captureWindow, .captureWindow])
        XCTAssertEqual(batch.events.map(\.callbackUptimeNanoseconds), [999, 1_001, 1_002, end - 1])
        XCTAssertEqual(batch.events.map(\.threadID), [42, 42, 43, 43])
        XCTAssertEqual(batch.events.map(\.sequence), [1, 2, 3, 4])
    }

    func testArmIsSingleUseAndRejectsInvalidOrOverflowingWindows() throws {
        let invalid: [(UInt64, UInt64, UInt64)] = [
            (0, 1, 1), (100, 0, 100), (100, 99, 100), (100, 200, 199),
            (100, UInt64.max - 1, UInt64.max - 1),
            (100, 100, 100 + StartupVideoNativeEncoderLogCollector.windowNanoseconds)
        ]
        for (started, capture, observed) in invalid {
            let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: started)
            XCTAssertThrowsError(try collector.arm(captureStartedAtUptimeNanoseconds: capture,
                                                   observedAtUptimeNanoseconds: observed))
            let batch = collector.finish()
            XCTAssertFalse(batch.isVerified)
            XCTAssertTrue(batch.failures.contains(.arm))
            XCTAssertEqual(batch.counts.rejectedArmCount, 1)
        }
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        try collector.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 100)
        XCTAssertThrowsError(try collector.arm(captureStartedAtUptimeNanoseconds: 200, observedAtUptimeNanoseconds: 200))
        XCTAssertEqual(collector.finish().captureStartedAtUptimeNanoseconds, 100)
        XCTAssertFalse(collector.snapshot().isVerified)
        XCTAssertFalse(StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100).finish().isVerified)
    }

    func testCapacityRetainsFirst512EventsAndCumulativeOverflow() throws {
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        try collector.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 100)
        for offset in 0..<515 {
            collector.record(message("H264 encode dropped frame."),
                             observedAtUptimeNanoseconds: 100 + UInt64(offset), observedThreadID: 41)
        }
        let batch = collector.finish()
        XCTAssertEqual(batch.capacity, 512)
        XCTAssertEqual(batch.events.count, 512)
        XCTAssertEqual(batch.events.first?.sequence, 1)
        XCTAssertEqual(batch.events.last?.sequence, 512)
        XCTAssertEqual(batch.counts.matchingMessageCount, 515)
        XCTAssertEqual(batch.counts.droppedEventCount, 3)
        XCTAssertEqual(batch.failures, [.overflow])
        XCTAssertFalse(batch.isVerified)
        XCTAssertEqual(collector.snapshot(), batch)
    }

    func testInvalidRegressingClocksAndMissingThreadRejectEvidenceButTiesRemainValid() throws {
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        try collector.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 100)
        let body = message("Did update encoder frame rate: 5")
        collector.record(body, observedAtUptimeNanoseconds: 0, observedThreadID: 41)
        collector.record(body, observedAtUptimeNanoseconds: 99, observedThreadID: 41)
        collector.record(body, observedAtUptimeNanoseconds: 101, observedThreadID: 0)
        collector.record(body, observedAtUptimeNanoseconds: 102, observedThreadID: 41)
        collector.record(body, observedAtUptimeNanoseconds: 101, observedThreadID: 41)
        collector.record(body, observedAtUptimeNanoseconds: 102, observedThreadID: 42)
        let batch = collector.finish()
        XCTAssertEqual(batch.counts.invalidObservationTimeCount, 2)
        XCTAssertEqual(batch.counts.regressingObservationTimeCount, 1)
        XCTAssertEqual(batch.counts.invalidThreadIDCount, 1)
        XCTAssertEqual(batch.events.map(\.callbackUptimeNanoseconds), [102, 102])
        XCTAssertEqual(batch.failures, [.clock, .thread])
        XCTAssertFalse(batch.isVerified)
        let preArm = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        preArm.record(body, observedAtUptimeNanoseconds: 200, observedThreadID: 41)
        XCTAssertThrowsError(try preArm.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 199))
    }

    func testProcessScopedSnapshotRoundTripsWithoutRawTextAndNativeErrorsRemainObservations() throws {
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        try collector.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 100)
        collector.record(message("H264 encode failed with code: -50"), observedAtUptimeNanoseconds: 101, observedThreadID: 41)
        collector.record(message("Failed to update encoder data rate limits"), observedAtUptimeNanoseconds: 102, observedThreadID: 42)
        collector.record(message("H264 encode dropped frame."), observedAtUptimeNanoseconds: 103, observedThreadID: 41)
        collector.record("private unrelated raw SDK data", observedAtUptimeNanoseconds: 104, observedThreadID: 41)
        collector.record(String(repeating: "x", count: 1_025), observedAtUptimeNanoseconds: 105, observedThreadID: 41)
        let batch = collector.finish()
        XCTAssertTrue(batch.isVerified)
        XCTAssertTrue(batch.failures.isEmpty)
        XCTAssertEqual(batch.schemaVersion, 1)
        XCTAssertEqual(batch.scope, .process)
        XCTAssertEqual(batch.windowNanoseconds, 6_000_000_000)
        XCTAssertEqual(batch.counts.rejectedMessageCount, 2)
        XCTAssertEqual(batch.counts.oversizedMessageCount, 1)
        XCTAssertEqual(batch.events.map(\.payload), [.encodeFailed(stage: .completion, status: -50),
            .dataRateLimitsUpdate(succeeded: false), .encodeDropped])
        let data = try JSONEncoder().encode(batch)
        XCTAssertEqual(try JSONDecoder().decode(StartupVideoNativeEncoderLogBatch.self, from: data), batch)
        let json = String(decoding: data, as: UTF8.self)
        for forbidden in ["private", "unrelated", "RTCVideoEncoderH264.mm", "H264 encode", "peerID", "rtpTimestamp", "encoderID"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }

    func testFinishRetiresAdmissionWithoutMintingPositiveEventPresence() throws {
        let collector = StartupVideoNativeEncoderLogCollector(startedAtUptimeNanoseconds: 100)
        try collector.arm(captureStartedAtUptimeNanoseconds: 100, observedAtUptimeNanoseconds: 100)
        XCTAssertFalse(collector.snapshot().isVerified)
        let empty = collector.finish()
        XCTAssertTrue(empty.isVerified, "This flag describes structure, not positive native event presence")
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertEqual(collector.finish(), empty)
        collector.record(message("H264 encode dropped frame."), observedAtUptimeNanoseconds: 101, observedThreadID: 41)
        collector.record("private late message", observedAtUptimeNanoseconds: 102, observedThreadID: 41)
        let late = collector.snapshot()
        XCTAssertEqual(late.events, empty.events)
        XCTAssertEqual(late.counts.retiredMessageCount, 2)
        XCTAssertTrue(late.isVerified)
        XCTAssertThrowsError(try collector.arm(captureStartedAtUptimeNanoseconds: 102, observedAtUptimeNanoseconds: 102))
        XCTAssertFalse(collector.snapshot().isVerified)
    }
}
#endif
