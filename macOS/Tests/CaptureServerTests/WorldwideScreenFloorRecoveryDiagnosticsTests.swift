import XCTest
@testable import CaptureServer

final class WorldwideScreenFloorRecoveryDiagnosticsTests: XCTestCase {
    func testDefaultFieldsStayUnknownAndProposalOnly() {
        let diagnostics = makeDiagnostics()
        XCTAssertEqual(diagnostics.logFields,
            "floorReason=notEvaluated floorIdentity=notChecked floorShowEpoch=unknown"
                + " floorReserved=false floorActive=false floorConsumed=false floorDisproved=false"
                + " floorCooldownRemaining=0 collectionSeq=unknown previousRegularSeq=unknown"
                + " previousRegularReportMicros=unknown capacityReportMicros=unknown nativeReportMicros=unknown"
                + " currentBweBps=unknown firstBweBps=unknown witnessAgeMicros=unknown"
                + " beforeTotalCapBps=486001 proposedTotalCapBps=486001"
                + " floorQueueKind=notChecked floorQueueMicros=unknown"
                + " rttObservation=unknown rttAllowsUpgrade=unknown bandwidthTrend=unknown")
        XCTAssertFalse(diagnostics.logFields.contains("nativeApply"))
    }

    func testExactBandwidthAndTrendDistinguishValuesWithTheSameRoundedKilobits() throws {
        let first = 306_000.0
        for (current, trend) in [(first.nextDown, Diagnostics.Trend.falling),
                                 (first, .flat), (first.nextUp, .rising)] {
            let diagnostics = makeDiagnostics(current: current, first: first)
            let log = fields(diagnostics)
            XCTAssertEqual(String(format: "%.0f", current / 1_000), "306")
            XCTAssertEqual(diagnostics.trend, trend)
            XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(log["currentBweBps"]))).bitPattern,
                           current.bitPattern)
            XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(log["firstBweBps"]))).bitPattern,
                           first.bitPattern)
            XCTAssertEqual(log["bandwidthTrend"], trend.rawValue)
        }
    }

    func testFinitePositiveBandwidthRoundTripsIncludingExponentNotation() throws {
        for bandwidth in [Double.leastNonzeroMagnitude, 0.125, 306_000, .greatestFiniteMagnitude] {
            let diagnostics = makeDiagnostics(current: bandwidth, first: bandwidth)
            let text = try XCTUnwrap(fields(diagnostics)["currentBweBps"])
            XCTAssertEqual(try XCTUnwrap(Double(text)).bitPattern, bandwidth.bitPattern)
            XCTAssertEqual(diagnostics.trend, .flat)
            XCTAssertFalse(text.contains(" "))
            XCTAssertFalse(text.contains("\n"))
        }
    }

    func testMissingInvalidAndNonpositiveBandwidthDoesNotBecomeZeroOrHealth() {
        for bandwidth in [nil, Double.nan, .infinity, -.infinity, -1, -0.0, 0] as [Double?] {
            let diagnostics = makeDiagnostics(current: bandwidth, first: bandwidth)
            XCTAssertNil(diagnostics.currentBandwidthBps)
            XCTAssertNil(diagnostics.firstBandwidthBps)
            XCTAssertEqual(diagnostics.trend, .unknown)
            XCTAssertEqual(fields(diagnostics)["currentBweBps"], "unknown")
            XCTAssertEqual(fields(diagnostics)["firstBweBps"], "unknown")
        }
    }

    func testNativeTimestampConversionAndQueueConversionAreBounded() {
        for invalid in [nil, Double.nan, .infinity, -.infinity, -0.25,
                        -.leastNonzeroMagnitude, .greatestFiniteMagnitude, Double(UInt64.max)] as [Double?] {
            XCTAssertNil(Diagnostics.boundedInteger(invalid))
        }
        XCTAssertEqual(Diagnostics.boundedInteger(0), 0)
        XCTAssertEqual(Diagnostics.boundedInteger(1.5), 2)
        XCTAssertEqual(Diagnostics.boundedInteger(Double(UInt64.max).nextDown), UInt64.max - 2_047)
        XCTAssertEqual(Diagnostics.boundedMicroseconds(seconds: 0), 0)
        XCTAssertEqual(Diagnostics.boundedMicroseconds(seconds: 0.020), 20_000)
        for invalid in [nil, Double.nan, .infinity, -.infinity, -0.25,
                        -.leastNonzeroMagnitude, .greatestFiniteMagnitude] as [Double?] {
            XCTAssertNil(Diagnostics.boundedMicroseconds(seconds: invalid))
        }
    }

    func testWitnessAgeDistinguishesMissingNegativeZeroAndEligibilityBoundaries() {
        XCTAssertNil(makeDiagnostics(age: nil).witnessAgeMicroseconds)
        XCTAssertNil(makeDiagnostics(age: .nanoseconds(-1)).witnessAgeMicroseconds)
        XCTAssertNil(makeDiagnostics(age: .seconds(Int64.max)).witnessAgeMicroseconds)
        for milliseconds in [0, 499, 500, 1_500, 1_501] {
            XCTAssertEqual(makeDiagnostics(age: .milliseconds(milliseconds)).witnessAgeMicroseconds,
                           UInt64(milliseconds) * 1_000)
        }
    }

    func testBeforeFlagsAndNativeIdentityRemainSeparateFromOutcome() {
        var diagnostics = Diagnostics(
            showEpoch: 7, reserved: true, active: true, consumed: true, disproved: true,
            cooldownRemaining: 4, collectionSequence: .max, previousRegularSequence: .max - 1,
            previousRegularTimestamp: 2_000_000, capacityTimestamp: 2_500_000,
            nativeReportTimestamp: 2_000_000, currentBandwidthBps: 306_000,
            firstBandwidthBps: 306_000, witnessAge: .milliseconds(500), beforeTotalCapBps: 486_001
        )
        diagnostics.identity = .rejectedTimestamp
        diagnostics.reason = .rejectedTimestamp
        let log = fields(diagnostics)
        XCTAssertEqual(log["floorShowEpoch"], "7")
        for key in ["floorReserved", "floorActive", "floorConsumed", "floorDisproved"] {
            XCTAssertEqual(log[key], "true")
        }
        XCTAssertEqual(log["floorCooldownRemaining"], "4")
        XCTAssertEqual(log["collectionSeq"], String(UInt64.max))
        XCTAssertEqual(log["previousRegularSeq"], String(UInt64.max - 1))
        XCTAssertEqual(log["previousRegularReportMicros"], "2000000")
        XCTAssertEqual(log["capacityReportMicros"], "2500000")
        XCTAssertEqual(log["nativeReportMicros"], "2000000")
        XCTAssertEqual(log["floorIdentity"], "rejectedTimestamp")
        XCTAssertEqual(log["rttAllowsUpgrade"], "unknown")
    }

    func testOutcomeMutationPreservesBeforeSnapshotAndNeverClaimsNativeApplication() {
        var diagnostics = makeDiagnostics(current: 306_000, first: 306_000, age: .milliseconds(500))
        diagnostics.identity = .fresh
        diagnostics.queueKind = .measured
        diagnostics.queueMicroseconds = 0
        diagnostics.roundTripTimeDisposition = .retainedHealthy
        diagnostics.roundTripTimeAllowsUpgrade = true
        diagnostics.reason = .qualified
        XCTAssertEqual(diagnostics.proposedTotalCapBps, 486_001)
        diagnostics.reason = .admitted
        diagnostics.proposedTotalCapBps = 612_000
        XCTAssertEqual(diagnostics.beforeTotalCapBps, 486_001)
        XCTAssertEqual(diagnostics.firstBandwidthBps, 306_000)
        XCTAssertFalse(diagnostics.consumed)
        XCTAssertEqual(fields(diagnostics)["floorReason"], "admitted")
        XCTAssertEqual(fields(diagnostics)["floorQueueMicros"], "0")
        XCTAssertEqual(fields(diagnostics)["rttObservation"], "retainedHealthy")
        XCTAssertFalse(diagnostics.logFields.contains("nativeApply"))
        diagnostics.queueKind = .noNewPackets
        diagnostics.queueMicroseconds = nil
        XCTAssertEqual(fields(diagnostics)["floorQueueKind"], "noNewPackets")
        XCTAssertEqual(fields(diagnostics)["floorQueueMicros"], "unknown")
    }

    func testFormatterHasOnlyExactWhitelistedKeysAndFixedEnums() {
        let expectedKeys: Set<String> = [
            "floorReason", "floorIdentity", "floorShowEpoch", "floorReserved", "floorActive",
            "floorConsumed", "floorDisproved", "floorCooldownRemaining", "collectionSeq",
            "previousRegularSeq", "previousRegularReportMicros", "capacityReportMicros",
            "nativeReportMicros", "currentBweBps", "firstBweBps", "witnessAgeMicros",
            "beforeTotalCapBps", "proposedTotalCapBps", "floorQueueKind", "floorQueueMicros",
            "rttObservation", "rttAllowsUpgrade", "bandwidthTrend",
        ]
        for reason in Diagnostics.Reason.allCases {
            for identity in Diagnostics.Identity.allCases {
                var diagnostics = makeDiagnostics()
                diagnostics.reason = reason
                diagnostics.identity = identity
                XCTAssertEqual(Set(fields(diagnostics).keys), expectedKeys)
                XCTAssertEqual(fields(diagnostics)["floorReason"], reason.rawValue)
                XCTAssertEqual(fields(diagnostics)["floorIdentity"], identity.rawValue)
                XCTAssertEqual(diagnostics.logFields.split(separator: " ").count, expectedKeys.count)
                XCTAssertFalse(diagnostics.logFields.contains("\n"))
            }
        }
    }

    private typealias Diagnostics = WorldwideScreenFloorRecoveryDiagnostics

    private func makeDiagnostics(current: Double? = nil, first: Double? = nil, age: Duration? = nil) -> Diagnostics {
        Diagnostics(
            showEpoch: nil, reserved: false, active: false, consumed: false, disproved: false,
            cooldownRemaining: 0, collectionSequence: nil, previousRegularSequence: nil,
            previousRegularTimestamp: nil, capacityTimestamp: nil, nativeReportTimestamp: nil,
            currentBandwidthBps: current, firstBandwidthBps: first, witnessAge: age,
            beforeTotalCapBps: 486_001
        )
    }

    private func fields(_ diagnostics: Diagnostics) -> [String: String] {
        Dictionary(uniqueKeysWithValues: diagnostics.logFields.split(separator: " ").map {
            let pair = $0.split(separator: "=", maxSplits: 1)
            return (String(pair[0]), String(pair[1]))
        })
    }
}
