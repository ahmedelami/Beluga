#if os(macOS)
import Foundation
@preconcurrency import LiveKitWebRTC

struct StartupVideoEncoderBoundarySnapshot: Codable, Equatable, Sendable {
    enum Failure: String, Codable, Sendable {
        case owner, arm, lifetime, clock, overflow, payload, callback
    }

    struct Counts: Codable, Equatable, Sendable {
        var factoryWrapCount: UInt64 = 0
        var factoryRejectionCount: UInt64 = 0
        var encoderCreatedCount: UInt64 = 0
        var encoderCreationFailureCount: UInt64 = 0
        var armCount: UInt64 = 0
        var armRejectionCount: UInt64 = 0
        var retainedEventCount: UInt64 = 0
        var startEntryCount: UInt64 = 0
        var rateEntryCount: UInt64 = 0
        var encodeEntryCount: UInt64 = 0
        var encodeReturnCount: UInt64 = 0
        var encodedOutputCount: UInt64 = 0
        var outputCallbackReturnCount: UInt64 = 0
        var releaseDrainOutputCount: UInt64 = 0
        var releaseDrainReturnCount: UInt64 = 0
        var preCaptureFrameEventCount: UInt64 = 0
        var outsideWindowEventCount: UInt64 = 0
        var retiredEventCount: UInt64 = 0
        var staleCallbackCount: UInt64 = 0
        var unmatchedOutputCount: UInt64 = 0
        var duplicateRTPCount: UInt64 = 0
        var invalidClockCount: UInt64 = 0
        var regressingClockCount: UInt64 = 0
        var invalidPayloadCount: UInt64 = 0
        var droppedEventCount: UInt64 = 0
        var nonzeroReturnCount: UInt64 = 0
        var rejectedCallbackCount: UInt64 = 0
        var retainedRejectionCount: UInt64 = 0
        var droppedRejectionCount: UInt64 = 0
        var counterSaturated = false
    }

    struct Rejection: Codable, Equatable, Sendable {
        enum Reason: String, Codable, Sendable {
            case staleRegistration, inactiveEncoder, unmatchedInput, encoderDeallocated
            case invalidatedBeforeOutput, invalidatedDuringCallback
        }
        enum ReleasePhase: String, Codable, Sendable {
            // Wrapper lifetime context only: afterRelease means at least one release
            // returned. Correlate the original/current generations and lifecycle events
            // before attributing this callback to a specific released generation.
            case none, duringRelease, afterRelease, unavailable
        }

        var sequence: UInt64 = 0
        var uptimeNanoseconds: UInt64 = 0
        let reason: Reason
        let releasePhase: ReleasePhase
        let encoderID: UInt64
        let rtpTimestamp: UInt32
        var inputSequence: UInt64?
        var inputEncoderGeneration: UInt64?
        var inputCallbackGeneration: UInt64?
        let callbackRegistrationGeneration: UInt64
        var currentEncoderGeneration: UInt64?
        var currentCallbackGeneration: UInt64?
        var currentEncoderIsActive: Bool?
    }

    struct Event: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case encoderCreated, callbackRegistered, startEntry, startReturn, rateEntry, rateReturn
            case encodeEntry, encodeReturn, encodedOutput, outputCallbackReturn, releaseEntry, releaseReturn

            var isFrame: Bool {
                switch self {
                case .encodeEntry, .encodeReturn, .encodedOutput, .outputCallbackReturn: true
                default: false
                }
            }
        }
        enum Phase: String, Codable, Sendable { case beforeCapture, captureWindow }
        enum OutputOwnership: String, Codable, Sendable { case active, releaseDrain }

        var sequence: UInt64 = 0
        var uptimeNanoseconds: UInt64 = 0
        var phase: Phase = .beforeCapture
        let kind: Kind
        let encoderID: UInt64
        var encoderGeneration: UInt64 = 0
        var callbackGeneration: UInt64 = 0
        var inputSequence: UInt64?
        var rtpTimestamp: UInt32?
        var sourceTimestampNanoseconds: Int64?
        var captureTimeMilliseconds: Int64?
        var width: Int32?
        var height: Int32?
        var byteCount: UInt64?
        var bitrateKbps: UInt32?
        var minimumBitrateKbps: UInt32?
        var maximumBitrateKbps: UInt32?
        var framesPerSecond: UInt32?
        var numberOfCores: Int32?
        var result: Int?
        var callbackResult: Bool?
        var callbackIsPresent: Bool?
        var outputOwnership: OutputOwnership?
        var releaseRetirementGeneration: UInt64?
    }

    let schemaVersion: Int
    let capacity: Int
    let windowNanoseconds: UInt64
    let captureStartedAtUptimeNanoseconds: UInt64?
    let isRetired: Bool
    let counts: Counts
    let events: [Event]
    let rejectionCapacity: Int
    let rejections: [Rejection]
    let failures: [Failure]
    let isVerified: Bool
}

/// Observes the outer app encoder boundary, not VideoToolbox or the resume fence inside it.
final class StartupVideoEncoderBoundaryTrace: @unchecked Sendable {
    typealias Event = StartupVideoEncoderBoundarySnapshot.Event
    typealias Rejection = StartupVideoEncoderBoundarySnapshot.Rejection
    private typealias Counts = StartupVideoEncoderBoundarySnapshot.Counts
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private let capacity: Int
    private let windowNanoseconds: UInt64 = 6_000_000_000
    private var counts = Counts()
    private var events: [Event] = []
    private let rejectionCapacity = 64
    private var rejections: [Rejection] = []
    private var captureStart: UInt64?
    private var captureEnd: UInt64?
    private var lastClock: UInt64 = 0
    private var retired = false

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         capacity: Int = 512) {
        self.now = now
        self.capacity = max(1, min(capacity, 512))
        events.reserveCapacity(self.capacity)
        rejections.reserveCapacity(rejectionCapacity)
    }

    func wrapFactory(_ downstream: any LKRTCVideoEncoderFactory) throws -> any LKRTCVideoEncoderFactory {
        try lock.withLock {
            guard counts.factoryWrapCount == 0, captureStart == nil, !retired else {
                increment(\.factoryRejectionCount)
                throw TraceError.owner
            }
            increment(\.factoryWrapCount)
        }
        return BoundaryEncoderFactory(downstream: downstream, trace: self)
    }

    func arm(captureStartedAtUptimeNanoseconds start: UInt64) throws {
        try lock.withLock {
            let end = start.addingReportingOverflow(windowNanoseconds)
            let armTime = now()
            guard counts.factoryWrapCount == 1, captureStart == nil, !retired,
                  start > 0, !end.overflow, armTime > 0, armTime >= lastClock, start <= armTime else {
                increment(\.armRejectionCount)
                throw TraceError.arm
            }
            captureStart = start
            captureEnd = end.partialValue
            lastClock = armTime
            increment(\.armCount)
        }
    }

    func snapshot() -> StartupVideoEncoderBoundarySnapshot { lock.withLock { snapshotLocked() } }

    func finish() -> StartupVideoEncoderBoundarySnapshot {
        lock.withLock {
            retired = true
            return snapshotLocked()
        }
    }

    private enum TraceError: Error { case owner, arm }

    fileprivate func createdEncoder() -> UInt64 {
        lock.withLock {
            increment(\.encoderCreatedCount)
            return counts.encoderCreatedCount
        }
    }

    fileprivate func reject(_ key: WritableKeyPath<StartupVideoEncoderBoundarySnapshot.Counts, UInt64>) {
        lock.withLock { increment(key) }
    }

    fileprivate func rejectCallback(_ value: Rejection,
        counter: WritableKeyPath<StartupVideoEncoderBoundarySnapshot.Counts, UInt64>) {
        lock.withLock {
            increment(counter)
            guard !retired else { increment(\.retiredEventCount); return }
            let time = now()
            guard time > 0 else { increment(\.invalidClockCount); return }
            guard time >= lastClock else { increment(\.regressingClockCount); return }
            lastClock = time
            guard let start = captureStart, let end = captureEnd else {
                increment(\.preCaptureFrameEventCount)
                return
            }
            guard time >= start else { increment(\.invalidClockCount); return }
            guard time < end else { increment(\.outsideWindowEventCount); return }
            guard rejections.count < rejectionCapacity else {
                increment(\.droppedRejectionCount)
                increment(\.droppedEventCount)
                return
            }
            var rejection = value
            rejection.sequence = UInt64(rejections.count + 1)
            rejection.uptimeNanoseconds = time
            rejections.append(rejection)
            increment(\.retainedRejectionCount)
        }
    }

    fileprivate func mayTrackInput() -> Bool {
        lock.withLock { !retired && captureEnd.map { now() < $0 } != false }
    }

    fileprivate func mayObserveOutput() -> Bool {
        lock.withLock {
            guard !retired else { increment(\.retiredEventCount); return false }
            guard let start = captureStart, let end = captureEnd else {
                increment(\.preCaptureFrameEventCount)
                return false
            }
            let time = now()
            guard time > 0, time >= start else { increment(\.invalidClockCount); return false }
            guard time >= lastClock else { increment(\.regressingClockCount); return false }
            guard time < end else { increment(\.outsideWindowEventCount); return false }
            return true
        }
    }

    /// The clock and publication share one lock; no downstream call is made under this lock.
    @discardableResult
    fileprivate func record(_ value: Event) -> UInt64? {
        lock.withLock {
            guard !retired else { increment(\.retiredEventCount); return nil }
            let time = now()
            guard time > 0 else { increment(\.invalidClockCount); return nil }
            guard time >= lastClock else { increment(\.regressingClockCount); return nil }
            lastClock = time
            var event = value
            if let start = captureStart, let end = captureEnd {
                guard time >= start else { increment(\.invalidClockCount); return nil }
                guard time < end else { increment(\.outsideWindowEventCount); return nil }
                event.phase = .captureWindow
            } else if event.kind.isFrame {
                increment(\.preCaptureFrameEventCount)
                return nil
            }
            guard event.encoderID > 0, event.encoderID <= counts.encoderCreatedCount,
                  (event.width.map { $0 > 0 } ?? true),
                  (event.height.map { $0 > 0 } ?? true),
                  (event.sourceTimestampNanoseconds.map { $0 > 0 } ?? true),
                  (event.byteCount.map { $0 > 0 } ?? true) else {
                increment(\.invalidPayloadCount)
                return nil
            }
            guard events.count < capacity else { increment(\.droppedEventCount); return nil }
            event.sequence = UInt64(events.count + 1)
            event.uptimeNanoseconds = time
            events.append(event)
            increment(\.retainedEventCount)
            switch event.kind {
            case .startEntry: increment(\.startEntryCount)
            case .rateEntry: increment(\.rateEntryCount)
            case .encodeEntry: increment(\.encodeEntryCount)
            case .encodeReturn: increment(\.encodeReturnCount)
            case .encodedOutput:
                increment(\.encodedOutputCount)
                if event.outputOwnership == .releaseDrain { increment(\.releaseDrainOutputCount) }
            case .outputCallbackReturn:
                increment(\.outputCallbackReturnCount)
                if event.outputOwnership == .releaseDrain { increment(\.releaseDrainReturnCount) }
            default: break
            }
            if let result = event.result, result != 0 { increment(\.nonzeroReturnCount) }
            if event.callbackResult == false { increment(\.rejectedCallbackCount) }
            return event.sequence
        }
    }

    private func increment(_ key: WritableKeyPath<Counts, UInt64>) {
        if counts[keyPath: key] == UInt64.max { counts.counterSaturated = true }
        else { counts[keyPath: key] += 1 }
    }

    private func snapshotLocked() -> StartupVideoEncoderBoundarySnapshot {
        var failures: [StartupVideoEncoderBoundarySnapshot.Failure] = []
        if counts.factoryWrapCount != 1 || counts.factoryRejectionCount != 0 { failures.append(.owner) }
        if counts.armCount != 1 || counts.armRejectionCount != 0 { failures.append(.arm) }
        if !retired || counts.retiredEventCount != 0 { failures.append(.lifetime) }
        if counts.invalidClockCount != 0 || counts.regressingClockCount != 0 { failures.append(.clock) }
        if counts.droppedEventCount != 0 || counts.counterSaturated { failures.append(.overflow) }
        if counts.invalidPayloadCount != 0 { failures.append(.payload) }
        if counts.staleCallbackCount != 0 || counts.unmatchedOutputCount != 0
            || counts.duplicateRTPCount != 0 { failures.append(.callback) }
        return .init(schemaVersion: 3, capacity: capacity, windowNanoseconds: windowNanoseconds,
                     captureStartedAtUptimeNanoseconds: captureStart, isRetired: retired,
                     counts: counts, events: events, rejectionCapacity: rejectionCapacity,
                     rejections: rejections, failures: failures, isVerified: failures.isEmpty)
    }
}

private final class BoundaryEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    private let downstream: any LKRTCVideoEncoderFactory
    private let trace: StartupVideoEncoderBoundaryTrace

    init(downstream: any LKRTCVideoEncoderFactory, trace: StartupVideoEncoderBoundaryTrace) {
        self.downstream = downstream
        self.trace = trace
        super.init()
    }

    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard let encoder = downstream.createEncoder(info) else {
            trace.reject(\.encoderCreationFailureCount)
            return nil
        }
        let id = trace.createdEncoder()
        trace.record(.init(kind: .encoderCreated, encoderID: id))
        return BoundaryEncoder(downstream: encoder, trace: trace, id: id)
    }
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { downstream.supportedCodecs() }
    func implementations() -> [LKRTCVideoCodecInfo] {
        downstream.implementations?() ?? downstream.supportedCodecs()
    }
    func encoderSelector() -> (any LKRTCVideoEncoderSelector)? { downstream.encoderSelector?() }
    func queryCodecSupport(_ info: LKRTCVideoCodecInfo, scalabilityMode: String?) -> LKRTCVideoEncoderCodecSupport {
        downstream.queryCodecSupport?(info, scalabilityMode: scalabilityMode)
            ?? LKRTCVideoEncoderCodecSupport(supported: false)
    }
    override func responds(to selector: Selector!) -> Bool {
        switch NSStringFromSelector(selector) {
        case "implementations", "encoderSelector", "queryCodecSupport:scalabilityMode:":
            (downstream as AnyObject).responds(to: selector)
        default: super.responds(to: selector)
        }
    }
}

private final class BoundaryEncoder: NSObject, LKRTCVideoEncoder {
    private typealias Event = StartupVideoEncoderBoundarySnapshot.Event
    private typealias Rejection = StartupVideoEncoderBoundarySnapshot.Rejection
    private struct Input {
        let sequence: UInt64?
        let generation: UInt64
        let callbackGeneration: UInt64
        var successfulSubmission = false
        // Set only when a still-pending input is consumed from the current release lease.
        // A normal callback already in flight can never acquire this authority later.
        var drainRetirementGeneration: UInt64?
    }
    private struct DrainLease {
        let generation: UInt64
        let callbackGeneration: UInt64
        let retirementGeneration: UInt64
        var pending: [UInt32: Input]
    }
    private let downstream: any LKRTCVideoEncoder
    private let trace: StartupVideoEncoderBoundaryTrace
    private let id: UInt64
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var callbackGeneration: UInt64 = 0
    private var active = false
    private var releaseDepth: UInt64 = 0
    private var releaseHasReturned = false
    private var inputs: [UInt32: Input] = [:]
    private var drainLease: DrainLease?
    // The same fixed 512-timestamp history also preserves rejected callback provenance.
    private var inputHistory: [UInt32: Input] = [:]

    init(downstream: any LKRTCVideoEncoder, trace: StartupVideoEncoderBoundaryTrace, id: UInt64) {
        self.downstream = downstream
        self.trace = trace
        self.id = id
        super.init()
    }

    private func event(_ kind: Event.Kind) -> Event {
        lock.withLock {
            .init(kind: kind, encoderID: id, encoderGeneration: generation,
                  callbackGeneration: callbackGeneration)
        }
    }

    func setCallback(_ callback: ((LKRTCEncodedImage, any LKRTCCodecSpecificInfo) -> Bool)?) {
        let registration = lock.withLock { () -> UInt64 in
            callbackGeneration += 1
            drainLease = nil
            inputs.removeAll(keepingCapacity: true)
            return callbackGeneration
        }
        var metadata = event(.callbackRegistered)
        metadata.callbackIsPresent = callback != nil
        trace.record(metadata)
        guard let callback else { downstream.setCallback(nil); return }
        let trace = trace
        let id = id
        downstream.setCallback { [weak self] image, info in
            let observes = trace.mayObserveOutput()
            let input = observes ? self?.takeInput(timestamp: image.timeStamp, registration: registration) : nil
            if observes, self == nil {
                trace.rejectCallback(.init(reason: .encoderDeallocated, releasePhase: .unavailable,
                    encoderID: id, rtpTimestamp: image.timeStamp,
                    callbackRegistrationGeneration: registration), counter: \.staleCallbackCount)
            }
            if let self, let input, let sequence = input.sequence {
                var output = Event(kind: .encodedOutput, encoderID: self.id,
                                   encoderGeneration: input.generation,
                                   callbackGeneration: input.callbackGeneration)
                output.inputSequence = sequence
                output.rtpTimestamp = image.timeStamp
                output.captureTimeMilliseconds = image.captureTimeMs
                output.width = image.encodedWidth
                output.height = image.encodedHeight
                output.byteCount = UInt64(image.buffer.count)
                output.outputOwnership = input.drainRetirementGeneration == nil ? .active : .releaseDrain
                output.releaseRetirementGeneration = input.drainRetirementGeneration
                self.recordIfCurrent(output, input: input, timestamp: image.timeStamp,
                                     rejectionReason: .invalidatedBeforeOutput)
            }
            let result = callback(image, info)
            if let self, let input, let sequence = input.sequence {
                var returned = Event(kind: .outputCallbackReturn, encoderID: self.id,
                                     encoderGeneration: input.generation,
                                     callbackGeneration: input.callbackGeneration)
                returned.inputSequence = sequence
                returned.rtpTimestamp = image.timeStamp
                returned.callbackResult = result
                returned.outputOwnership = input.drainRetirementGeneration == nil ? .active : .releaseDrain
                returned.releaseRetirementGeneration = input.drainRetirementGeneration
                self.recordIfCurrent(returned, input: input, timestamp: image.timeStamp,
                                     rejectionReason: .invalidatedDuringCallback)
            }
            return result
        }
    }

    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.withLock {
            generation += 1
            active = false
            drainLease = nil
            inputs.removeAll(keepingCapacity: true)
        }
        var entry = event(.startEntry)
        entry.width = Int32(settings.width)
        entry.height = Int32(settings.height)
        entry.bitrateKbps = settings.startBitrate
        entry.minimumBitrateKbps = settings.minBitrate
        entry.maximumBitrateKbps = settings.maxBitrate
        entry.framesPerSecond = settings.maxFramerate
        entry.numberOfCores = numberOfCores
        trace.record(entry)
        let result = downstream.startEncode(with: settings, numberOfCores: numberOfCores)
        lock.withLock { if generation == entry.encoderGeneration { active = result == 0 } }
        let returned = Event(kind: .startReturn, encoderID: id, encoderGeneration: entry.encoderGeneration,
                             callbackGeneration: entry.callbackGeneration, result: result)
        trace.record(returned)
        return result
    }

    func release() -> Int {
        let entry = lock.withLock {
            var value = Event(kind: .releaseEntry, encoderID: id, encoderGeneration: generation,
                              callbackGeneration: callbackGeneration)
            // The pinned H.264 implementation retains its callback during synchronous
            // VT invalidation. Only successfully returned, unconsumed submissions may
            // drain there. History is provenance, never admission authority. Nested
            // release revokes the outer lease and cannot create another one.
            let pending = active && releaseDepth == 0 ? inputs.filter {
                $0.value.successfulSubmission && $0.value.sequence != nil
                    && $0.value.generation == generation
                    && $0.value.callbackGeneration == callbackGeneration
            } : [:]
            let mayDrain = active && releaseDepth == 0
            generation += 1
            active = false
            releaseDepth += 1
            value.releaseRetirementGeneration = generation
            drainLease = mayDrain ? DrainLease(generation: value.encoderGeneration,
                callbackGeneration: value.callbackGeneration, retirementGeneration: generation,
                pending: pending) : nil
            inputs.removeAll(keepingCapacity: true)
            trace.record(value)
            return value
        }
        let result = downstream.release()
        lock.withLock {
            if drainLease?.retirementGeneration == entry.releaseRetirementGeneration { drainLease = nil }
            releaseDepth -= 1
            releaseHasReturned = true
            trace.record(.init(kind: .releaseReturn, encoderID: id, encoderGeneration: entry.encoderGeneration,
                callbackGeneration: entry.callbackGeneration, result: result,
                releaseRetirementGeneration: entry.releaseRetirementGeneration))
        }
        return result
    }

    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?,
                frameTypes: [NSNumber]) -> Int {
        var entry = event(.encodeEntry)
        let timestamp = UInt32(bitPattern: frame.timeStamp)
        entry.rtpTimestamp = timestamp
        entry.sourceTimestampNanoseconds = frame.timeStampNs
        entry.width = frame.width
        entry.height = frame.height
        let sequence = trace.record(entry)
        if trace.mayTrackInput() {
            lock.withLock {
                if inputHistory[timestamp] != nil { trace.reject(\.duplicateRTPCount) }
                else if active, generation == entry.encoderGeneration,
                        callbackGeneration == entry.callbackGeneration {
                    if inputHistory.count >= 512 { trace.reject(\.droppedEventCount) }
                    else {
                        let input = Input(sequence: sequence, generation: generation,
                                          callbackGeneration: callbackGeneration)
                        inputHistory[timestamp] = input
                        inputs[timestamp] = input
                    }
                }
            }
        }
        let result = downstream.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        if let sequence {
            lock.withLock {
                let recorded = trace.record(.init(kind: .encodeReturn, encoderID: id,
                    encoderGeneration: entry.encoderGeneration, callbackGeneration: entry.callbackGeneration,
                    inputSequence: sequence, rtpTimestamp: timestamp, result: result))
                if inputs[timestamp]?.sequence == sequence {
                    if result != 0 { inputs.removeValue(forKey: timestamp) }
                    else if recorded != nil { inputs[timestamp]?.successfulSubmission = true }
                }
            }
        }
        return result
    }

    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        var entry = event(.rateEntry)
        entry.bitrateKbps = bitrateKbit
        entry.framesPerSecond = framerate
        trace.record(entry)
        let result = downstream.setBitrate(bitrateKbit, framerate: framerate)
        trace.record(.init(kind: .rateReturn, encoderID: id, encoderGeneration: entry.encoderGeneration,
                           callbackGeneration: entry.callbackGeneration, result: Int(result)))
        return result
    }

    private func takeInput(timestamp: UInt32, registration: UInt64) -> Input? {
        lock.withLock {
            if !active, registration == callbackGeneration,
               let lease = drainLease, lease.retirementGeneration == generation,
               lease.callbackGeneration == registration,
               var input = lease.pending[timestamp], input.generation == lease.generation,
               input.callbackGeneration == registration, input.successfulSubmission {
                drainLease?.pending.removeValue(forKey: timestamp)
                input.drainRetirementGeneration = lease.retirementGeneration
                return input
            }
            guard active, registration == callbackGeneration else {
                rejectLocked(registration == callbackGeneration ? .inactiveEncoder : .staleRegistration,
                             timestamp: timestamp, registration: registration,
                             input: originalInput(timestamp: timestamp, registration: registration),
                             counter: \.staleCallbackCount)
                return nil
            }
            guard let input = inputs[timestamp], input.generation == generation,
                  input.callbackGeneration == registration else {
                rejectLocked(.unmatchedInput, timestamp: timestamp, registration: registration,
                             input: originalInput(timestamp: timestamp, registration: registration),
                             counter: \.unmatchedOutputCount)
                return nil
            }
            inputs.removeValue(forKey: timestamp)
            return input
        }
    }

    private func originalInput(timestamp: UInt32, registration: UInt64) -> Input? {
        guard let input = inputHistory[timestamp], input.callbackGeneration == registration else { return nil }
        return input
    }

    private func recordIfCurrent(_ event: Event, input: Input, timestamp: UInt32,
                                 rejectionReason: Rejection.Reason) {
        lock.withLock {
            let ownsOutput: Bool
            if let retirement = input.drainRetirementGeneration {
                ownsOutput = !active && generation == retirement
                    && drainLease?.retirementGeneration == retirement
                    && drainLease?.generation == input.generation
                    && drainLease?.callbackGeneration == input.callbackGeneration
                    && callbackGeneration == input.callbackGeneration
            } else {
                ownsOutput = active && input.generation == generation
                    && input.callbackGeneration == callbackGeneration
            }
            guard ownsOutput else {
                rejectLocked(rejectionReason, timestamp: timestamp,
                             registration: input.callbackGeneration, input: input,
                             counter: \.staleCallbackCount)
                return
            }
            trace.record(event)
        }
    }

    private func rejectLocked(_ reason: Rejection.Reason, timestamp: UInt32, registration: UInt64,
                              input: Input?,
                              counter: WritableKeyPath<StartupVideoEncoderBoundarySnapshot.Counts, UInt64>) {
        let phase: Rejection.ReleasePhase = releaseDepth > 0 ? .duringRelease
            : (releaseHasReturned ? .afterRelease : .none)
        trace.rejectCallback(.init(reason: reason, releasePhase: phase, encoderID: id,
            rtpTimestamp: timestamp, inputSequence: input?.sequence,
            inputEncoderGeneration: input?.generation, inputCallbackGeneration: input?.callbackGeneration,
            callbackRegistrationGeneration: registration, currentEncoderGeneration: generation,
            currentCallbackGeneration: callbackGeneration, currentEncoderIsActive: active), counter: counter)
    }

    func implementationName() -> String { downstream.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { downstream.scalingSettings() }
    var resolutionAlignment: Int { downstream.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { downstream.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { downstream.supportsNativeHandle }
}
#endif
