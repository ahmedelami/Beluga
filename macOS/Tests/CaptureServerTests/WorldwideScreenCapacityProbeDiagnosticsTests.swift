import XCTest
import WebRTCTransport
@testable import CaptureServer

final class WorldwideScreenCapacityProbeDiagnosticsTests: XCTestCase {
    func testQueueUsesPacketDeltaRatherThanCumulativeDelayOrWallClockInterval() {
        var diagnostics = makeDiagnostics()
        diagnostics.recordQueue(
            previousPackets: 1_000, previousDelay: 20,
            packets: 1_004, delay: 20.125
        )

        XCTAssertEqual(diagnostics.deltaPackets, 4)
        XCTAssertEqual(diagnostics.deltaSendDelayMicroseconds, 125_000)
        XCTAssertEqual(diagnostics.averageQueueMicroseconds, 31_250)
    }

    func testLatestFastBaselineAndOrdinaryBaselineExposeDifferentPacketWindows() {
        var fastWindow = makeDiagnostics()
        fastWindow.recordQueue(
            previousPackets: 104, previousDelay: 10.125,
            packets: 106, delay: 10.375
        )
        var ordinaryWindow = makeDiagnostics()
        ordinaryWindow.recordQueue(
            previousPackets: 100, previousDelay: 10,
            packets: 106, delay: 10.375
        )

        XCTAssertEqual(fastWindow.deltaPackets, 2)
        XCTAssertEqual(fastWindow.deltaSendDelayMicroseconds, 250_000)
        XCTAssertEqual(fastWindow.averageQueueMicroseconds, 125_000)
        XCTAssertEqual(ordinaryWindow.deltaPackets, 6)
        XCTAssertEqual(ordinaryWindow.averageQueueMicroseconds, 62_500)
        XCTAssertNotEqual(fastWindow.averageQueueMicroseconds, ordinaryWindow.averageQueueMicroseconds)
    }

    func testNoNewPacketsNeverFabricatesAZeroQueueMeasurement() {
        for delay in [10.0, 10.125] {
            var diagnostics = makeDiagnostics()
            diagnostics.recordQueue(previousPackets: 100, previousDelay: 10, packets: 100, delay: delay)
            XCTAssertEqual(diagnostics.deltaPackets, 0)
            XCTAssertEqual(diagnostics.deltaSendDelayMicroseconds, delay == 10 ? 0 : 125_000)
            XCTAssertNil(diagnostics.averageQueueMicroseconds)
            XCTAssertEqual(fields(diagnostics)["fastQueueMicros"], "unknown")
        }
    }

    func testAdvancingPacketsWithUnchangedDelayAreMeasuredZeroQueue() {
        var diagnostics = makeDiagnostics()
        diagnostics.recordQueue(previousPackets: 100, previousDelay: 10, packets: 104, delay: 10)
        XCTAssertEqual(diagnostics.deltaPackets, 4)
        XCTAssertEqual(diagnostics.deltaSendDelayMicroseconds, 0)
        XCTAssertEqual(diagnostics.averageQueueMicroseconds, 0)
        XCTAssertEqual(fields(diagnostics)["fastQueueMicros"], "0")
    }

    func testMissingCountersOrEitherCounterRegressionHaveNoDerivedEvidence() {
        let cases: [(UInt64?, Double?, UInt64?, Double?)] = [
            (nil, 10, 104, 10.125), (100, nil, 104, 10.125),
            (100, 10, nil, 10.125), (100, 10, 104, nil),
            (100, 10, 99, 10.125), (100, 10, 104, 9.875),
            (.max, 10, 0, 10.125),
        ]
        for (previousPackets, previousDelay, packets, delay) in cases {
            var diagnostics = makeDiagnostics()
            diagnostics.recordQueue(previousPackets: previousPackets, previousDelay: previousDelay, packets: packets, delay: delay)
            assertNoQueueEvidence(diagnostics)
        }
    }

    func testMalformedCumulativeDelayCannotBecomeNumericQueueEvidence() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, -0.25] {
            var invalidPrevious = makeDiagnostics()
            invalidPrevious.recordQueue(previousPackets: 100, previousDelay: invalid, packets: 104, delay: 10)
            assertNoQueueEvidence(invalidPrevious)

            var invalidCurrent = makeDiagnostics()
            invalidCurrent.recordQueue(previousPackets: 100, previousDelay: 0, packets: 104, delay: invalid)
            assertNoQueueEvidence(invalidCurrent)
        }
    }

    func testOverflowIsUnknownWithoutSaturatingOrTrapping() {
        var overflow = makeDiagnostics()
        overflow.recordQueue(previousPackets: 0, previousDelay: 0, packets: 1, delay: .greatestFiniteMagnitude)
        XCTAssertEqual(overflow.deltaPackets, 1)
        XCTAssertNil(overflow.deltaSendDelayMicroseconds)
        XCTAssertNil(overflow.averageQueueMicroseconds)
        XCTAssertEqual(fields(overflow)["fastDeltaSendDelayMicros"], "unknown")
        XCTAssertEqual(fields(overflow)["fastQueueMicros"], "unknown")

        var boundedAverage = makeDiagnostics()
        boundedAverage.recordQueue(previousPackets: 0, previousDelay: 0, packets: 1_000_000, delay: 20_000_000_000_000)
        XCTAssertNil(boundedAverage.deltaSendDelayMicroseconds)
        XCTAssertEqual(boundedAverage.averageQueueMicroseconds, 20_000_000_000_000)
    }

    func testPacketSubtractionNearUInt64MaximumDoesNotOverflow() {
        var diagnostics = makeDiagnostics()
        diagnostics.recordQueue(previousPackets: .max - 4, previousDelay: 20, packets: .max, delay: 20.125)
        XCTAssertEqual(diagnostics.deltaPackets, 4)
        XCTAssertEqual(diagnostics.averageQueueMicroseconds, 31_250)
    }

    func testInvalidNativeTimestampsStayUnknownIncludingNegativeFractions() {
        let invalidValues: [Double?] = [
            nil, .nan, .infinity, -.infinity, -1, -0.25,
            -.leastNonzeroMagnitude, .greatestFiniteMagnitude, Double(UInt64.max),
        ]
        for invalid in invalidValues {
            let diagnostics = makeDiagnostics(previousTimestamp: invalid, timestamp: invalid)
            XCTAssertNil(diagnostics.previousNativeReportMicroseconds)
            XCTAssertNil(diagnostics.nativeReportMicroseconds)
            XCTAssertEqual(fields(diagnostics)["previousNativeReportMicros"], "unknown")
            XCTAssertEqual(fields(diagnostics)["nativeReportMicros"], "unknown")
        }
    }

    func testRepresentableNativeTimestampsRoundWithoutElapsedTimeInference() {
        XCTAssertEqual(WorldwideScreenCapacityProbeDiagnostics.boundedInteger(0), 0)
        XCTAssertEqual(WorldwideScreenCapacityProbeDiagnostics.boundedInteger(1.25), 1)
        XCTAssertEqual(WorldwideScreenCapacityProbeDiagnostics.boundedInteger(1.5), 2)
        XCTAssertEqual(WorldwideScreenCapacityProbeDiagnostics.boundedInteger(Double(UInt64.max).nextDown), UInt64.max - 2_047)

        let regressing = makeDiagnostics(previousTimestamp: 3_000_000, timestamp: 2_000_000)
        XCTAssertEqual(regressing.previousNativeReportMicroseconds, 3_000_000)
        XCTAssertEqual(regressing.nativeReportMicroseconds, 2_000_000)
        XCTAssertEqual(regressing.reason, .rejectedReport)
    }

    func testLogFormatHasOnlyFixedEnumsAndWhitelistedNumericFields() {
        let reasons: [WorldwideScreenCapacityProbeDiagnostics.Reason] = [
            .inactive, .expired, .rejectedReport, .roundTripTime, .routeChanged,
            .missingPrimaryEvidence, .immediateQueue, .missingBandwidth, .bandwidthCollapse,
            .queueWithheld, .growthVetoed, .bandwidthNotAdvanced, .atCeiling, .increased,
        ]
        let origins: [WorldwideScreenVideoAdaptationTier?] = [nil] + WorldwideScreenVideoAdaptationTier.allCases.map { Optional($0) }
        let numericKeys: Set<String> = [
            "collectionSeq", "previousNativeReportMicros", "nativeReportMicros",
            "beforeTotalCapBps", "proposedTotalCapBps", "collapseThresholdBps",
            "fastDeltaPackets", "fastDeltaSendDelayMicros", "fastQueueMicros",
        ]
        for origin in origins {
            for reason in reasons {
                var diagnostics = WorldwideScreenCapacityProbeDiagnostics(
                    origin: origin, collectionSequence: .max,
                    previousNativeReportTimestamp: 1_000_000, nativeReportTimestamp: 2_000_000,
                    beforeTotalCapBps: 486_000
                )
                diagnostics.reason = reason
                diagnostics.proposedTotalCapBps = Int.max
                diagnostics.collapseThresholdBps = .max
                diagnostics.recordQueue(previousPackets: 100, previousDelay: 10, packets: 104, delay: 10.125)
                let log = fields(diagnostics)
                XCTAssertEqual(Set(log.keys), numericKeys.union(["probeReason", "probeOriginBefore"]))
                XCTAssertEqual(log["probeReason"], reason.rawValue)
                XCTAssertEqual(log["probeOriginBefore"], origin.map { String(describing: $0) } ?? "none")
                for key in numericKeys {
                    XCTAssertNotNil(log[key].flatMap(UInt64.init), "Non-numeric payload in \(key)")
                }
                XCTAssertFalse(diagnostics.logFields.contains("\n"))
            }
        }
    }

    func testDefaultFieldsDoNotClaimMissingSequenceOrQueueWasZero() {
        let diagnostics = WorldwideScreenCapacityProbeDiagnostics(
            origin: nil, collectionSequence: nil,
            previousNativeReportTimestamp: nil, nativeReportTimestamp: nil,
            beforeTotalCapBps: 486_000
        )
        XCTAssertEqual(diagnostics.logFields,
            "probeReason=rejectedReport probeOriginBefore=none collectionSeq=unknown"
                + " previousNativeReportMicros=unknown nativeReportMicros=unknown"
                + " beforeTotalCapBps=486000 proposedTotalCapBps=486000 collapseThresholdBps=unknown"
                + " fastDeltaPackets=unknown fastDeltaSendDelayMicros=unknown fastQueueMicros=unknown")
    }

    func testPolicyReportsImmediateQueueFromPreviousFastReportNotOrdinaryWindow() throws {
        var (policy, start) = makeStartedPolicy()
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        let first = try evaluate(&policy, bandwidth: 950_000, sequence: 4,
                                 packets: 304, delay: 0.304, at: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(first.diagnostics.reason, .increased)
        let capBeforeAbort = policy.currentRecommendation.maximumTotalRTPBitrateBps
        let second = try evaluate(&policy, bandwidth: 1_800_000, sequence: 5,
                                  packets: 306, delay: 0.804, at: start.advanced(by: .milliseconds(400)))

        XCTAssertEqual(second.diagnostics.reason, .immediateQueue)
        XCTAssertEqual(second.diagnostics.origin, .audioPriority)
        XCTAssertEqual(second.diagnostics.deltaPackets, 2)
        XCTAssertEqual(second.diagnostics.deltaSendDelayMicroseconds, 500_000)
        XCTAssertEqual(second.diagnostics.averageQueueMicroseconds, 250_000)
        XCTAssertEqual(second.diagnostics.previousNativeReportMicroseconds, 4_000_000)
        XCTAssertEqual(second.diagnostics.nativeReportMicroseconds, 5_000_000)
        XCTAssertEqual(second.diagnostics.beforeTotalCapBps, capBeforeAbort)
        XCTAssertEqual(second.diagnostics.proposedTotalCapBps, second.recommendation?.maximumTotalRTPBitrateBps)
        XCTAssertNil(second.diagnostics.collapseThresholdBps)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.lastConsumedCollectionSequence, 3)
        XCTAssertEqual(try XCTUnwrap(policy.lastAveragePacketSendDelaySeconds), 0.001, accuracy: 0.000_000_1)
        XCTAssertFalse(second.diagnostics.logFields.contains(Self.syntheticPairFingerprint))
    }

    func testPolicyReportsBandwidthCollapseWithActualFastPacketEvidence() throws {
        var (policy, start) = makeStartedPolicy()
        XCTAssertEqual(policy.applicationLimitedProbeOriginTier, .audioPriority)
        let before = policy.currentRecommendation.maximumTotalRTPBitrateBps
        let result = try evaluate(&policy, bandwidth: 100_000, sequence: 4,
                                 packets: 304, delay: 0.304, at: start.advanced(by: .milliseconds(200)))

        XCTAssertEqual(result.diagnostics.reason, .bandwidthCollapse)
        XCTAssertEqual(result.diagnostics.deltaPackets, 4)
        XCTAssertEqual(result.diagnostics.deltaSendDelayMicroseconds, 4_000)
        XCTAssertEqual(result.diagnostics.averageQueueMicroseconds, 1_000)
        XCTAssertGreaterThan(try XCTUnwrap(result.diagnostics.collapseThresholdBps), 100_000)
        XCTAssertEqual(result.diagnostics.beforeTotalCapBps, before)
        XCTAssertEqual(result.diagnostics.proposedTotalCapBps, result.recommendation?.maximumTotalRTPBitrateBps)
        XCTAssertLessThan(result.diagnostics.proposedTotalCapBps, before)
        XCTAssertNil(policy.applicationLimitedProbeOriginTier)
        XCTAssertEqual(policy.lastConsumedCollectionSequence, 3)
        XCTAssertFalse(result.diagnostics.logFields.contains(Self.syntheticPairFingerprint))
    }

    func testDiagnosticsCallbackDoesNotChangePolicyOrRecommendation() throws {
        let (initial, start) = makeStartedPolicy()
        let when = start.advanced(by: .milliseconds(200))
        let cases: [(name: String, bandwidth: Double, sequence: UInt64, timestamp: Double,
                     delay: Double, reason: WorldwideScreenCapacityProbeDiagnostics.Reason)] = [
            ("growth", 950_000, 4, 4_000_000, 0.304, .increased),
            ("immediate queue cancellation", 950_000, 4, 4_000_000, 1.3, .immediateQueue),
            ("bandwidth collapse cancellation", 100_000, 4, 4_000_000, 0.304, .bandwidthCollapse),
            ("cached native report", 950_000, 4, 3_000_000, 0.304, .rejectedReport),
            ("older native report", 950_000, 4, 2_000_000, 0.304, .rejectedReport),
            ("older collection sequence", 950_000, 2, 4_000_000, 0.304, .rejectedReport),
        ]
        for sample in cases {
            var observed = initial
            var silent = initial
            let result = try evaluate(&observed, bandwidth: sample.bandwidth, sequence: sample.sequence,
                                      packets: 304, delay: sample.delay,
                                      timestampOverride: sample.timestamp, at: when)
            let silentRecommendation = silent.updateCapacityProbe(
                peerGeneration: 1, isCaptureActive: true, availableOutgoingBitrateBps: sample.bandwidth,
                currentRoundTripTimeSeconds: 0.005, roundTripTimeObservation: Self.rtt,
                collectionSequence: sample.sequence, nativeReportTimestampMicroseconds: sample.timestamp,
                selectedRoute: .init(kind: .direct), outboundVideoPacketsSent: 304,
                outboundVideoTotalPacketSendDelaySeconds: sample.delay, observedAt: when
            )
            XCTAssertEqual(result.diagnostics.reason, sample.reason, sample.name)
            XCTAssertEqual(result.recommendation, silentRecommendation, sample.name)
            XCTAssertEqual(observed, silent, sample.name)
            if sample.reason == .rejectedReport {
                var agedWithoutReport = initial
                XCTAssertNil(agedWithoutReport.expireApplicationLimitedProbeWithoutReport(
                    peerGeneration: 1, isCaptureActive: true, observedAt: when
                ))
                XCTAssertEqual(observed, agedWithoutReport, sample.name)
                XCTAssertEqual(observed.roundTripTimeObservationAge, .milliseconds(1_200))
                XCTAssertNil(result.recommendation, sample.name)
                XCTAssertEqual(result.diagnostics.beforeTotalCapBps, result.diagnostics.proposedTotalCapBps, sample.name)
            } else if sample.reason == .immediateQueue || sample.reason == .bandwidthCollapse {
                XCTAssertNil(observed.applicationLimitedProbeOriginTier, sample.name)
                XCTAssertNotNil(result.recommendation, sample.name)
                XCTAssertLessThan(result.diagnostics.proposedTotalCapBps, result.diagnostics.beforeTotalCapBps, sample.name)
            }
        }
    }

    private static let syntheticPairFingerprint = String(repeating: "e", count: 64)
    private static var rtt: WebRTCRoundTripTimeObservation {
        .measurement(.init(selectedCandidatePairFingerprint: syntheticPairFingerprint,
                           totalRoundTripTimeSeconds: 1, responsesReceived: 10))
    }

    private func makeStartedPolicy() -> (WorldwideScreenVideoAdaptationPolicy, ContinuousClock.Instant) {
        var policy = WorldwideScreenVideoAdaptationPolicy(configuredTotalRTPBitrateBps: 50_000_000, baseFramesPerSecond: 60)
        let start = ContinuousClock.now
        for (index, bandwidth) in [100_000.0, 100_000, 486_001].enumerated() {
            let sequence = UInt64(index + 1)
            _ = policy.update(
                peerGeneration: 1, isCaptureActive: true, availableOutgoingBitrateBps: bandwidth,
                currentRoundTripTimeSeconds: 0.005, roundTripTimeObservation: Self.rtt,
                collectionSequence: sequence, requireRoundTripTimeObservation: true,
                selectedRoute: .init(kind: .direct), outboundVideoPacketsSent: sequence * 100,
                outboundVideoTotalPacketSendDelaySeconds: Double(sequence) / 10,
                nativeReportTimestampMicroseconds: Double(sequence) * 1_000_000,
                observedAt: start.advanced(by: .milliseconds(index * 500))
            )
        }
        return (policy, start.advanced(by: .seconds(1)))
    }

    private func evaluate(_ policy: inout WorldwideScreenVideoAdaptationPolicy,
                          bandwidth: Double, sequence: UInt64, packets: UInt64, delay: Double,
                          timestampOverride: Double? = nil,
                          at time: ContinuousClock.Instant) throws
        -> (recommendation: WorldwideScreenVideoEncodingRecommendation?, diagnostics: WorldwideScreenCapacityProbeDiagnostics) {
        var reports: [WorldwideScreenCapacityProbeDiagnostics] = []
        let recommendation = policy.updateCapacityProbe(
            peerGeneration: 1, isCaptureActive: true, availableOutgoingBitrateBps: bandwidth,
            currentRoundTripTimeSeconds: 0.005, roundTripTimeObservation: Self.rtt,
            collectionSequence: sequence, nativeReportTimestampMicroseconds: timestampOverride ?? Double(sequence) * 1_000_000,
            selectedRoute: .init(kind: .direct), outboundVideoPacketsSent: packets,
            outboundVideoTotalPacketSendDelaySeconds: delay, observedAt: time,
            diagnostics: { reports.append($0) }
        )
        XCTAssertEqual(reports.count, 1)
        return (recommendation, try XCTUnwrap(reports.first))
    }

    private func makeDiagnostics(previousTimestamp: Double? = 1_000_000, timestamp: Double? = 2_000_000)
        -> WorldwideScreenCapacityProbeDiagnostics {
        WorldwideScreenCapacityProbeDiagnostics(
            origin: .audioPriority, collectionSequence: 10,
            previousNativeReportTimestamp: previousTimestamp, nativeReportTimestamp: timestamp,
            beforeTotalCapBps: 486_000
        )
    }

    private func assertNoQueueEvidence(_ diagnostics: WorldwideScreenCapacityProbeDiagnostics,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(diagnostics.deltaPackets, file: file, line: line)
        XCTAssertNil(diagnostics.deltaSendDelayMicroseconds, file: file, line: line)
        XCTAssertNil(diagnostics.averageQueueMicroseconds, file: file, line: line)
        let log = fields(diagnostics)
        XCTAssertEqual(log["fastDeltaPackets"], "unknown", file: file, line: line)
        XCTAssertEqual(log["fastDeltaSendDelayMicros"], "unknown", file: file, line: line)
        XCTAssertEqual(log["fastQueueMicros"], "unknown", file: file, line: line)
    }

    private func fields(_ diagnostics: WorldwideScreenCapacityProbeDiagnostics) -> [String: String] {
        var result: [String: String] = [:]
        for token in diagnostics.logFields.split(separator: " ") {
            let pair = token.split(separator: "=", omittingEmptySubsequences: false)
            XCTAssertEqual(pair.count, 2)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            XCTAssertNil(result.updateValue(String(pair[1]), forKey: key), "Duplicate log field")
        }
        return result
    }
}
