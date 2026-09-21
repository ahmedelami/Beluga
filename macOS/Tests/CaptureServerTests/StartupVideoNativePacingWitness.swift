#if os(macOS)
import Foundation

struct StartupVideoNativePacingBinding: Codable, Equatable, Sendable {
    let hostWorkerID: UInt64
    let viewerWorkerID: UInt64
    let registeredAtUptimeNanoseconds: UInt64
}

struct StartupVideoNativePacingMatchedPair: Codable, Equatable, Sendable {
    let bweSequence: UInt64
    let pacerSequence: UInt64
    let nativeTimestampMilliseconds: Int64
    let callbackGapNanoseconds: UInt64
    let estimateBps: UInt64
    let pushbackTargetBps: UInt64
    let pacingKbps: UInt64
    let expectedPacingBps: UInt64
}

struct StartupVideoNativePacingWitnessSummary: Codable, Equatable, Sendable {
    enum Failure: String, Codable, Sendable {
        case invalidBinding, invalidCaptureStart, unsupportedExpectedFactor, incompleteBatch
        case invalidEvent, outOfOrderHostEvidence, unknownThreadEvidence, ambiguousPairing
        case contradictedFactorObserved, insufficientMatchedPairs
        case missingALRCorroboration, conflictingALRSettings
    }

    struct Counts: Codable, Equatable, Sendable {
        var examinedEvents = 0
        var beforeObservationBoundary = 0
        var excludedViewerEvents = 0
        var unknownThreadEvents = 0
        var invalidEvents = 0
        var outOfOrderHostEvents = 0
        var matchingALRSettings = 0
        var conflictingALRSettings = 0
        var unmatchedBWEs = 0
        var unmatchedPacers = 0
        var ambiguousBWEs = 0
        var ambiguousPacers = 0
        var latePairs = 0
        var ratioMismatches = 0
        var ambiguousFactorMatches = 0
        var contradictedFactorMatches = 0
        var matchedPairs = 0
        // Completed rate matches sharing the preceding BWE's native millisecond. These
        // are checked for contradictions but cannot supply another independent match.
        var tiedPairs = 0
        var omittedMatchedPairDetails = 0
    }

    let binding: StartupVideoNativePacingBinding
    let observationStartsAtUptimeNanoseconds: UInt64
    let expectedFactor: Double
    let counts: Counts
    let matchedPairs: [StartupVideoNativePacingMatchedPair]
    let failures: [Failure]
    var isVerified: Bool { failures.isEmpty }
}

/// Numeric receiving-boundary evidence for one independently bound host worker. ALR logs remain
/// process-scoped corroboration; they cannot make a rate match or identify a peer themselves.
enum StartupVideoNativePacingWitness {
    private static let maximumGapNanoseconds: UInt64 = 100_000_000
    private static let maximumPairDetails = 32

    static func evaluate(
        batch: StartupVideoNativePacingBatch,
        binding: StartupVideoNativePacingBinding,
        captureStartedAtUptimeNanoseconds: UInt64,
        expectedFactor: Double
    ) -> StartupVideoNativePacingWitnessSummary {
        typealias Failure = StartupVideoNativePacingWitnessSummary.Failure
        var failures: [Failure] = []
        func fail(_ reason: Failure) {
            if !failures.contains(reason) { failures.append(reason) }
        }
        var counts = StartupVideoNativePacingWitnessSummary.Counts()
        var pairs: [StartupVideoNativePacingMatchedPair] = []
        let boundary = max(binding.registeredAtUptimeNanoseconds, captureStartedAtUptimeNanoseconds)
        let numerator: UInt64 = expectedFactor == 1.15 ? 115 : 100
        let contradictedNumerator: UInt64 = numerator == 115 ? 100 : 115
        if expectedFactor != 1.0 && expectedFactor != 1.15 { fail(.unsupportedExpectedFactor) }
        if binding.hostWorkerID == 0 || binding.viewerWorkerID == 0
            || binding.hostWorkerID == binding.viewerWorkerID
            || binding.registeredAtUptimeNanoseconds == 0
            || binding.registeredAtUptimeNanoseconds < batch.startedAtUptimeNanoseconds {
            fail(.invalidBinding)
        }
        if captureStartedAtUptimeNanoseconds == 0
            || captureStartedAtUptimeNanoseconds < batch.startedAtUptimeNanoseconds {
            fail(.invalidCaptureStart)
        }
        if batch.droppedEventCount != 0 || batch.invalidObservationTimeCount != 0
            || batch.invalidThreadIDCount != 0
            || batch.matchingEventCount != UInt64(batch.events.count)
            || batch.events.count > StartupVideoNativePacingCollector.capacity {
            fail(.incompleteBatch)
        }

        var pending: (event: StartupVideoNativePacingEvent, isTied: Bool)?
        var ambiguous = false
        var lastHostCallback: UInt64?
        var lastNativeTimestamp: Int64?

        // A malformed over-cap batch cannot trigger unbounded witness processing.
        for (index, event) in batch.events.prefix(StartupVideoNativePacingCollector.capacity).enumerated() {
            counts.examinedEvents += 1
            guard event.sequence == UInt64(index + 1), event.threadID != 0,
                  event.callbackUptimeNanoseconds >= batch.startedAtUptimeNanoseconds,
                  event.processObserverAgeMilliseconds
                    == (event.callbackUptimeNanoseconds - batch.startedAtUptimeNanoseconds) / 1_000_000 else {
                counts.invalidEvents += 1
                fail(.invalidEvent)
                pending = nil
                ambiguous = false
                continue
            }
            if case let .alrSettings(factor, queue, usage, start, end, group) = event.payload {
                if factor == expectedFactor && queue == 2_875 && usage == 80 && start == 40
                    && end == -60 && group == 3 {
                    counts.matchingALRSettings += 1
                } else {
                    counts.conflictingALRSettings += 1
                    fail(.conflictingALRSettings)
                }
                continue
            }
            guard event.callbackUptimeNanoseconds > boundary else {
                counts.beforeObservationBoundary += 1
                continue
            }
            if event.threadID == binding.viewerWorkerID {
                counts.excludedViewerEvents += 1
                continue
            }
            guard event.threadID == binding.hostWorkerID else {
                counts.unknownThreadEvents += 1
                fail(.unknownThreadEvidence)
                continue
            }
            if let lastHostCallback, event.callbackUptimeNanoseconds <= lastHostCallback {
                counts.outOfOrderHostEvents += 1
                fail(.outOfOrderHostEvidence)
                pending = nil
                ambiguous = false
                continue
            }
            lastHostCallback = event.callbackUptimeNanoseconds
            switch event.payload {
            case let .bweUpdated(timestamp, pushback, estimate):
                guard timestamp > 0, estimate > 0, estimate <= Int64.max,
                      pushback <= Int64.max,
                      scaledRate(estimate, numerator: numerator) != nil,
                      scaledRate(estimate, numerator: contradictedNumerator) != nil else {
                    counts.invalidEvents += 1
                    fail(.invalidEvent)
                    pending = nil
                    ambiguous = false
                    continue
                }
                // The pinned SDK logs rounded milliseconds and also emits updates for
                // pushback-only changes. Completed sequential pairs may share this value;
                // callback order and pairing remain independent, stricter checks.
                guard lastNativeTimestamp == nil || timestamp >= lastNativeTimestamp! else {
                    counts.outOfOrderHostEvents += 1
                    fail(.outOfOrderHostEvidence)
                    pending = nil
                    ambiguous = false
                    continue
                }
                let isTied = timestamp == lastNativeTimestamp
                lastNativeTimestamp = timestamp
                if ambiguous {
                    counts.ambiguousBWEs += 1
                } else if pending != nil {
                    counts.ambiguousBWEs += 2
                    fail(.ambiguousPairing)
                    pending = nil
                    ambiguous = true
                } else {
                    pending = (event, isTied)
                }
            case let .pacerUpdated(pacingKbps, paddingBudgetKbps):
                let (observedRate, rateOverflow) = pacingKbps.multipliedReportingOverflow(by: 1_000)
                guard !rateOverflow, pacingKbps <= Int64.max, paddingBudgetKbps <= Int64.max else {
                    counts.invalidEvents += 1
                    fail(.invalidEvent)
                    pending = nil
                    ambiguous = false
                    continue
                }
                if ambiguous {
                    counts.ambiguousPacers += 1
                    ambiguous = false
                    continue
                }
                guard let pendingBWE = pending,
                      case let .bweUpdated(timestamp, pushback, estimate) = pendingBWE.event.payload else {
                    counts.unmatchedPacers += 1
                    continue
                }
                let bwe = pendingBWE.event
                pending = nil
                let gap = event.callbackUptimeNanoseconds - bwe.callbackUptimeNanoseconds
                guard gap <= maximumGapNanoseconds else {
                    counts.latePairs += 1
                    counts.unmatchedBWEs += 1
                    counts.unmatchedPacers += 1
                    continue
                }
                guard let expectedRate = scaledRate(estimate, numerator: numerator),
                      let contradictedRate = scaledRate(estimate, numerator: contradictedNumerator) else {
                    counts.invalidEvents += 1
                    fail(.invalidEvent)
                    continue
                }
                let matches = withinOneKbps(observedRate, expectedRate)
                let contradicts = withinOneKbps(observedRate, contradictedRate)
                if matches && contradicts {
                    counts.ambiguousFactorMatches += 1
                } else if contradicts {
                    counts.contradictedFactorMatches += 1
                    fail(.contradictedFactorObserved)
                } else if matches {
                    if pendingBWE.isTied {
                        counts.tiedPairs += 1
                    } else if pairs.count < maximumPairDetails {
                        counts.matchedPairs += 1
                        pairs.append(StartupVideoNativePacingMatchedPair(
                            bweSequence: bwe.sequence,
                            pacerSequence: event.sequence,
                            nativeTimestampMilliseconds: timestamp,
                            callbackGapNanoseconds: gap,
                            estimateBps: estimate,
                            pushbackTargetBps: pushback,
                            pacingKbps: pacingKbps,
                            expectedPacingBps: expectedRate
                        ))
                    } else {
                        counts.matchedPairs += 1
                        counts.omittedMatchedPairDetails += 1
                    }
                } else {
                    // Allocation floors and upper-link clamps can legitimately alter this ratio.
                    // Such an update is not a pacing-factor witness.
                    counts.ratioMismatches += 1
                }
            case .alrSettings:
                break
            }
        }
        if pending != nil { counts.unmatchedBWEs += 1 }
        if counts.matchedPairs < 3 { fail(.insufficientMatchedPairs) }
        if counts.matchingALRSettings == 0 { fail(.missingALRCorroboration) }
        return StartupVideoNativePacingWitnessSummary(
            binding: binding,
            observationStartsAtUptimeNanoseconds: boundary,
            expectedFactor: expectedFactor.isFinite ? expectedFactor : 0,
            counts: counts,
            matchedPairs: pairs,
            failures: failures
        )
    }

    private static func withinOneKbps(_ observed: UInt64, _ expected: UInt64) -> Bool {
        observed >= expected ? observed - expected <= 1_000 : expected - observed <= 1_000
    }

    private static func scaledRate(_ rate: UInt64, numerator: UInt64) -> UInt64? {
        // Integer quotient/remainder preserves the small rounding allowance at large values.
        let (whole, overflow) = (rate / 100).multipliedReportingOverflow(by: numerator)
        guard !overflow else { return nil }
        let (result, additionOverflow) = whole.addingReportingOverflow((rate % 100) * numerator / 100)
        return additionOverflow ? nil : result
    }
}
#endif
