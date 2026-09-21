#if os(macOS)
import Foundation

struct StartupVideoNativeEstimatorSnapshot: Codable, Equatable, Sendable {
    static let maximumBytes = 1_048_576
    static let maximumEvents = 2_048

    struct Event: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case delay, loss, probeCreated, probeSuccess, probeFailure, alrState }
        var sequence: UInt64
        var kind: Kind
        var bitrateBps: Int64?
        var callbackUptimeNanoseconds: UInt64
        var threadID: UInt64
        var environmentTimeMicroseconds: Int64
        var detectorState: Int?
        var fractionLoss: Int?
        var expectedPackets: Int?
        var probeClusterID: Int? = nil
        var minimumProbes: UInt64? = nil
        var minimumBytes: UInt64? = nil
        var failureReason: Int? = nil
        var inAlr: Bool? = nil

        var hasValidFields: Bool {
            guard kind == .alrState || inAlr == nil else { return false }
            let estimatorFieldsAbsent = detectorState == nil && fractionLoss == nil && expectedPackets == nil
            let probeFieldsAbsent = probeClusterID == nil && minimumProbes == nil
                && minimumBytes == nil && failureReason == nil
            let validProbeID = probeClusterID.map { $0 > 0 && $0 <= Int(Int32.max) } == true
            let validProbeBitrate = bitrateBps.map { $0 > 0 && $0 <= Int64(Int32.max) } == true
            switch kind {
            case .delay:
                return bitrateBps.map { $0 > 0 } == true && probeFieldsAbsent
                    && detectorState.map { (0...2).contains($0) } == true
                    && fractionLoss == nil && expectedPackets == nil
            case .loss:
                return bitrateBps.map { $0 > 0 } == true && probeFieldsAbsent && detectorState == nil
                    && fractionLoss.map { (0...255).contains($0) } == true
                    && expectedPackets.map { $0 >= 0 } == true
            case .probeCreated:
                return estimatorFieldsAbsent && validProbeID && validProbeBitrate && failureReason == nil
                    && minimumProbes.map { $0 > 0 && $0 <= UInt64(UInt32.max) } == true
                    && minimumBytes.map { $0 > 0 && $0 <= UInt64(UInt32.max) } == true
            case .probeSuccess:
                return estimatorFieldsAbsent && validProbeID && validProbeBitrate
                    && minimumProbes == nil && minimumBytes == nil && failureReason == nil
            case .probeFailure:
                return estimatorFieldsAbsent && validProbeID && bitrateBps == nil
                    && minimumProbes == nil && minimumBytes == nil
                    && failureReason.map { (0...2).contains($0) } == true
            case .alrState:
                return estimatorFieldsAbsent && probeFieldsAbsent && bitrateBps == nil && inAlr != nil
            }
        }
    }

    enum DecodeFailure: Error { case oversizedData, tooManyEvents }

    var schemaVersion: UInt64
    var capacity: UInt64
    var collectionStartUptimeNanoseconds: UInt64
    var interceptionCount: UInt64
    var controllerCreateCount: UInt64
    var processIntervalCallCount: UInt64
    var defaultDelegateCount: UInt64
    var environmentIdentityMatches: UInt64
    var liveLoggerCount: UInt64
    var loggerCreatedCount: UInt64
    var loggerDestroyedCount: UInt64
    var invalidEventCount: UInt64
    var droppedEventCount: UInt64
    var unknownEventCount: UInt64
    var rejectedCreateCount: UInt64
    var unexpectedFactoryCount: UInt64
    var startLoggingAttemptCount: UInt64
    var environmentIdentityFailureCount: UInt64
    var fieldTrialFailureCount: UInt64
    var selectorFailureCount: UInt64
    var lifetimeFailureCount: UInt64
    var factoryRequestCount: UInt64
    var processIntervalMicroseconds: UInt64
    var events: [Event]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw DecodeFailure.oversizedData }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    /// Establishes event observability. An overuse observation alone does not establish its cause.
    func evaluate(
        hostWorkerID: UInt64,
        captureStartedAtUptimeNanoseconds: UInt64
    ) -> StartupVideoNativeEstimatorSummary {
        typealias Failure = StartupVideoNativeEstimatorSummary.Failure
        var failures: [Failure] = []
        func fail(_ failure: Failure) {
            if !failures.contains(failure) { failures.append(failure) }
        }
        var counts = StartupVideoNativeEstimatorSummary.Counts(snapshot: self)
        if schemaVersion != 2 { fail(.unsupportedSchema) }
        if capacity != UInt64(Self.maximumEvents) { fail(.invalidCapacity) }
        if events.count > Self.maximumEvents { fail(.eventCapacityExceeded) }
        if hostWorkerID == 0 { fail(.invalidHostWorker) }
        if collectionStartUptimeNanoseconds == 0
            || captureStartedAtUptimeNanoseconds < collectionStartUptimeNanoseconds {
            fail(.invalidCaptureBoundary)
        }
        if factoryRequestCount != 1 || interceptionCount != 1 || defaultDelegateCount != 1 {
            fail(.invalidFactoryEvidence)
        }
        if controllerCreateCount != 1 { fail(.invalidControllerEvidence) }
        if environmentIdentityMatches != 1 { fail(.invalidEnvironmentIdentity) }
        if liveLoggerCount != 1 || loggerCreatedCount != 1 || loggerDestroyedCount != 0 {
            fail(.invalidLoggerLifetime)
        }
        if processIntervalCallCount < 1 || processIntervalMicroseconds != 25_000 {
            fail(.invalidProcessInterval)
        }
        if [invalidEventCount, droppedEventCount, rejectedCreateCount, unexpectedFactoryCount,
            startLoggingAttemptCount, environmentIdentityFailureCount, fieldTrialFailureCount,
            selectorFailureCount, lifetimeFailureCount].contains(where: { $0 != 0 }) {
            fail(.nativeFailureReported)
        }

        var previousCallback: UInt64?
        var previousClock: Int64?
        var lastProofCallback: UInt64?
        var lastProofClock: Int64?
        var delayOveruseCount: UInt64 = 0
        var firstOveruse: UInt64?
        for (index, event) in events.prefix(Self.maximumEvents).enumerated() {
            var valid = true
            func reject(_ failure: Failure) { fail(failure); valid = false }
            if event.sequence != UInt64(index) + 1 { reject(.invalidSequence) }
            if !event.hasValidFields { reject(.invalidEventFields) }
            if event.threadID == 0 || event.threadID != hostWorkerID { reject(.wrongWorkerThread) }
            if event.callbackUptimeNanoseconds == 0
                || event.callbackUptimeNanoseconds < collectionStartUptimeNanoseconds
                || event.environmentTimeMicroseconds <= 0 {
                reject(.invalidEventTime)
            }
            if let previousCallback, event.callbackUptimeNanoseconds < previousCallback {
                reject(.callbackTimeRegressed)
            }
            if let previousClock, event.environmentTimeMicroseconds < previousClock {
                reject(.environmentTimeRegressed)
            }
            previousCallback = event.callbackUptimeNanoseconds
            previousClock = event.environmentTimeMicroseconds
            guard valid else { counts.invalidRetainedEventCount += 1; continue }
            switch event.kind {
            case .delay: counts.delayEventCount += 1
            case .loss: counts.lossEventCount += 1
            case .probeCreated: counts.probeCreatedEventCount += 1
            case .probeSuccess: counts.probeSuccessEventCount += 1
            case .probeFailure: counts.probeFailureEventCount += 1
            case .alrState: counts.alrStateEventCount += 1
            }
            guard event.callbackUptimeNanoseconds >= captureStartedAtUptimeNanoseconds else {
                counts.preCaptureEventCount += 1
                continue
            }
            switch event.kind {
            case .delay:
                counts.postCaptureDelayEventCount += 1
                if event.detectorState == 2 {
                    delayOveruseCount += 1
                    if firstOveruse == nil { firstOveruse = event.callbackUptimeNanoseconds }
                }
                if (lastProofCallback == nil || event.callbackUptimeNanoseconds > lastProofCallback!)
                    && (lastProofClock == nil || event.environmentTimeMicroseconds > lastProofClock!) {
                    counts.advancingPostCaptureDelayEventCount += 1
                    lastProofCallback = event.callbackUptimeNanoseconds
                    lastProofClock = event.environmentTimeMicroseconds
                }
            case .loss:
                counts.postCaptureLossEventCount += 1
            case .probeCreated:
                counts.postCaptureProbeCreatedEventCount += 1
            case .probeSuccess:
                counts.postCaptureProbeSuccessEventCount += 1
            case .probeFailure:
                counts.postCaptureProbeFailureEventCount += 1
            case .alrState:
                counts.postCaptureALRStateEventCount += 1
            }
        }
        if counts.advancingPostCaptureDelayEventCount < 3 { fail(.insufficientAdvancingDelayEvents) }
        return StartupVideoNativeEstimatorSummary(
            isVerified: failures.isEmpty,
            hostWorkerID: hostWorkerID,
            collectionStartUptimeNanoseconds: collectionStartUptimeNanoseconds,
            captureStartedAtUptimeNanoseconds: captureStartedAtUptimeNanoseconds,
            processIntervalMicroseconds: processIntervalMicroseconds,
            counts: counts,
            delayOveruseCount: delayOveruseCount,
            firstPostCaptureOveruseUptimeNanoseconds: firstOveruse,
            failures: failures
        )
    }
}

extension StartupVideoNativeEstimatorSnapshot {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(UInt64.self, forKey: .schemaVersion)
        capacity = try values.decode(UInt64.self, forKey: .capacity)
        collectionStartUptimeNanoseconds = try values.decode(UInt64.self, forKey: .collectionStartUptimeNanoseconds)
        interceptionCount = try values.decode(UInt64.self, forKey: .interceptionCount)
        controllerCreateCount = try values.decode(UInt64.self, forKey: .controllerCreateCount)
        processIntervalCallCount = try values.decode(UInt64.self, forKey: .processIntervalCallCount)
        defaultDelegateCount = try values.decode(UInt64.self, forKey: .defaultDelegateCount)
        environmentIdentityMatches = try values.decode(UInt64.self, forKey: .environmentIdentityMatches)
        liveLoggerCount = try values.decode(UInt64.self, forKey: .liveLoggerCount)
        loggerCreatedCount = try values.decode(UInt64.self, forKey: .loggerCreatedCount)
        loggerDestroyedCount = try values.decode(UInt64.self, forKey: .loggerDestroyedCount)
        invalidEventCount = try values.decode(UInt64.self, forKey: .invalidEventCount)
        droppedEventCount = try values.decode(UInt64.self, forKey: .droppedEventCount)
        unknownEventCount = try values.decode(UInt64.self, forKey: .unknownEventCount)
        rejectedCreateCount = try values.decode(UInt64.self, forKey: .rejectedCreateCount)
        unexpectedFactoryCount = try values.decode(UInt64.self, forKey: .unexpectedFactoryCount)
        startLoggingAttemptCount = try values.decode(UInt64.self, forKey: .startLoggingAttemptCount)
        environmentIdentityFailureCount = try values.decode(UInt64.self, forKey: .environmentIdentityFailureCount)
        fieldTrialFailureCount = try values.decode(UInt64.self, forKey: .fieldTrialFailureCount)
        selectorFailureCount = try values.decode(UInt64.self, forKey: .selectorFailureCount)
        lifetimeFailureCount = try values.decode(UInt64.self, forKey: .lifetimeFailureCount)
        factoryRequestCount = try values.decode(UInt64.self, forKey: .factoryRequestCount)
        processIntervalMicroseconds = try values.decode(UInt64.self, forKey: .processIntervalMicroseconds)
        var encodedEvents = try values.nestedUnkeyedContainer(forKey: .events)
        events = []
        while !encodedEvents.isAtEnd {
            guard events.count < Self.maximumEvents else { throw DecodeFailure.tooManyEvents }
            events.append(try encodedEvents.decode(Event.self))
        }
    }
}

struct StartupVideoNativeEstimatorSummary: Codable, Equatable, Sendable {
    enum Failure: String, Codable, Sendable {
        case unsupportedSchema, invalidCapacity, eventCapacityExceeded, invalidHostWorker
        case invalidCaptureBoundary, invalidFactoryEvidence, invalidControllerEvidence
        case invalidEnvironmentIdentity, invalidLoggerLifetime, invalidProcessInterval
        case nativeFailureReported, invalidSequence, invalidEventFields, wrongWorkerThread
        case invalidEventTime, callbackTimeRegressed, environmentTimeRegressed
        case insufficientAdvancingDelayEvents
    }

    struct Counts: Codable, Equatable, Sendable {
        let factoryRequestCount: UInt64
        let interceptionCount: UInt64
        let controllerCreateCount: UInt64
        let defaultDelegateCount: UInt64
        let environmentIdentityMatches: UInt64
        let liveLoggerCount: UInt64
        let loggerCreatedCount: UInt64
        let loggerDestroyedCount: UInt64
        let processIntervalCallCount: UInt64
        let invalidEventCount: UInt64
        let droppedEventCount: UInt64
        let unknownEventCount: UInt64
        let rejectedCreateCount: UInt64
        let unexpectedFactoryCount: UInt64
        let startLoggingAttemptCount: UInt64
        let environmentIdentityFailureCount: UInt64
        let fieldTrialFailureCount: UInt64
        let selectorFailureCount: UInt64
        let lifetimeFailureCount: UInt64
        let retainedEventCount: UInt64
        var delayEventCount: UInt64 = 0
        var lossEventCount: UInt64 = 0
        var probeCreatedEventCount: UInt64 = 0
        var probeSuccessEventCount: UInt64 = 0
        var probeFailureEventCount: UInt64 = 0
        var alrStateEventCount: UInt64 = 0
        var preCaptureEventCount: UInt64 = 0
        var postCaptureDelayEventCount: UInt64 = 0
        var postCaptureLossEventCount: UInt64 = 0
        var postCaptureProbeCreatedEventCount: UInt64 = 0
        var postCaptureProbeSuccessEventCount: UInt64 = 0
        var postCaptureProbeFailureEventCount: UInt64 = 0
        var postCaptureALRStateEventCount: UInt64 = 0
        var advancingPostCaptureDelayEventCount: UInt64 = 0
        var invalidRetainedEventCount: UInt64 = 0

        init(snapshot: StartupVideoNativeEstimatorSnapshot) {
            factoryRequestCount = snapshot.factoryRequestCount
            interceptionCount = snapshot.interceptionCount
            controllerCreateCount = snapshot.controllerCreateCount
            defaultDelegateCount = snapshot.defaultDelegateCount
            environmentIdentityMatches = snapshot.environmentIdentityMatches
            liveLoggerCount = snapshot.liveLoggerCount
            loggerCreatedCount = snapshot.loggerCreatedCount
            loggerDestroyedCount = snapshot.loggerDestroyedCount
            processIntervalCallCount = snapshot.processIntervalCallCount
            invalidEventCount = snapshot.invalidEventCount
            droppedEventCount = snapshot.droppedEventCount
            unknownEventCount = snapshot.unknownEventCount
            rejectedCreateCount = snapshot.rejectedCreateCount
            unexpectedFactoryCount = snapshot.unexpectedFactoryCount
            startLoggingAttemptCount = snapshot.startLoggingAttemptCount
            environmentIdentityFailureCount = snapshot.environmentIdentityFailureCount
            fieldTrialFailureCount = snapshot.fieldTrialFailureCount
            selectorFailureCount = snapshot.selectorFailureCount
            lifetimeFailureCount = snapshot.lifetimeFailureCount
            retainedEventCount = UInt64(snapshot.events.count)
        }
    }

    let isVerified: Bool
    let hostWorkerID: UInt64
    let collectionStartUptimeNanoseconds: UInt64
    let captureStartedAtUptimeNanoseconds: UInt64
    let processIntervalMicroseconds: UInt64
    let counts: Counts
    let delayOveruseCount: UInt64
    let firstPostCaptureOveruseUptimeNanoseconds: UInt64?
    let failures: [Failure]
}
#endif
