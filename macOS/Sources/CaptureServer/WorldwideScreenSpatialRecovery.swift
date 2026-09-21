enum WorldwideScreenSpatialRecoveryPacketEvidence: Equatable, Sendable {
    case measured(Double)
    case noNewPackets
    case unavailable
}

struct WorldwideScreenSpatialRecoveryFrameEvidence: Equatable, Sendable {
    let encodedFrames: UInt64
    let encodedWidth: Int
    let encodedHeight: Int
    let sourceWidth: Int
    let sourceHeight: Int

    var isValid: Bool {
        encodedWidth > 0 && encodedHeight > 0 && sourceWidth > 0 && sourceHeight > 0
            && encodedWidth <= sourceWidth && encodedHeight <= sourceHeight
            && sourceWidth <= Int(Int32.max) && sourceHeight <= Int(Int32.max)
    }

    var isFullSourceSize: Bool {
        isValid && encodedWidth == sourceWidth && encodedHeight == sourceHeight
    }
}

/// A separately owned spatial trial; it never revives startup permission or
/// changes bitrate ceilings. The caller supplies admitted ordinary native evidence.
struct WorldwideScreenSpatialRecovery: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case inactive, observing, pending, trial, accepted, cooldown, retired
    }

    private struct SourceSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    private struct Witness: Equatable, Sendable {
        let observedAt: ContinuousClock.Instant
        let capacityBps: Double
    }

    private enum FrameProgress: Equatable {
        case advanced, unchanged, baselineOrReset, unavailable
    }

    static let trialDuration: Duration = .seconds(3)
    static let minimumWitnessInterval: Duration = .milliseconds(500)
    static let maximumWitnessInterval: Duration = .milliseconds(1_500)
    static let maximumRTTAge: Duration = .seconds(4)
    static let maximumQueueDelaySeconds = 0.020
    // Keeping successfully applied, advancing full-size geometry is not new
    // admission or capacity-growth permission. Trial confirmation tolerates the
    // existing ordinary soft-pressure boundary; independent pressure still wins.
    static let maximumConfirmationQueueDelaySeconds = 0.100

    private(set) var phase: Phase = .inactive
    private(set) var attempt: UInt64 = 0
    private(set) var peerGeneration: UInt64?
    private(set) var showEpoch: UInt64?
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var retryNotBefore: ContinuousClock.Instant?
    private(set) var appliedAt: ContinuousClock.Instant?
    private var attemptStartedAt: ContinuousClock.Instant?
    private var lastObservationAt: ContinuousClock.Instant?
    private var lastAdverseAt: ContinuousClock.Instant?
    private var terminalAt: ContinuousClock.Instant?
    private var consecutiveFailures = 0
    private var sourceSize: SourceSize?
    private var lastFrames: WorldwideScreenSpatialRecoveryFrameEvidence?
    private var admissionWitness: Witness?
    private var confirmationWitness: Witness?

    var isArmed: Bool { phase != .inactive && phase != .retired }
    var isTrialActive: Bool { phase == .pending || phase == .trial }
    var isActive: Bool { phase == .trial || phase == .accepted }

    mutating func begin(
        peerGeneration: UInt64,
        showEpoch: UInt64,
        at now: ContinuousClock.Instant = .now
    ) {
        guard peerGeneration > 0, showEpoch > 0 else { return }
        if let previousPeer = self.peerGeneration, let previousShow = self.showEpoch {
            guard peerGeneration > previousPeer
                || (peerGeneration == previousPeer && showEpoch > previousShow) else { return }
        }
        self = Self()
        self.peerGeneration = peerGeneration
        self.showEpoch = showEpoch
        phase = .observing
        lastObservationAt = now
        lastAdverseAt = now
    }

    /// Keep the peer/Show tombstone so a replay cannot renew the same authority.
    mutating func end() {
        guard peerGeneration != nil else { return }
        retire(at: lastObservationAt)
    }

    /// Cadence gaps discard partial positive evidence, not attempts or deadlines.
    mutating func clearWitnesses() {
        admissionWitness = nil
        confirmationWitness = nil
        lastFrames = nil
    }

    mutating func observe(
        at now: ContinuousClock.Instant,
        eligible: Bool,
        pressure: Bool,
        capacityBps: Double?,
        requiredCapacityBps: Double,
        healthyRTTAdvancedAt: ContinuousClock.Instant?,
        packetEvidence: WorldwideScreenSpatialRecoveryPacketEvidence,
        frames: WorldwideScreenSpatialRecoveryFrameEvidence?,
        allowsTrial: Bool
    ) {
        guard isArmed, advanceClock(to: now) else { return }
        expireCurrentTrial(at: now)
        if pressure {
            lastAdverseAt = now
            clearWitnesses()
            if isTrialActive || phase == .accepted { failAttempt(at: now) }
            return
        }

        let frameProgress = consumeFrames(frames, at: now)
        guard isArmed else { return }
        guard eligible else {
            lastAdverseAt = now
            clearWitnesses()
            if isTrialActive || phase == .accepted { failAttempt(at: now) }
            return
        }
        // Unknown telemetry leaves accepted geometry alone, but actual advancing
        // smaller frames contradict acceptance independently of RTT/BWE availability.
        if phase == .accepted {
            if frameProgress == .advanced, let frames, frames.isValid, !frames.isFullSourceSize {
                failAttempt(at: now)
            }
            return
        }
        guard phase != .pending else { return }
        if let retryNotBefore, now < retryNotBefore {
            admissionWitness = nil
            confirmationWitness = nil
            return
        }
        guard let frames, frames.isValid,
              let capacityBps, capacityBps.isFinite, capacityBps > 0,
              requiredCapacityBps.isFinite, requiredCapacityBps > 0,
              capacityBps >= requiredCapacityBps,
              let healthyRTTAdvancedAt, let lastAdverseAt,
              healthyRTTAdvancedAt > lastAdverseAt,
              healthyRTTAdvancedAt <= now,
              healthyRTTAdvancedAt.duration(to: now) <= Self.maximumRTTAge else {
            admissionWitness = nil
            confirmationWitness = nil
            return
        }

        let maximumMeasuredDelay = phase == .trial
            ? Self.maximumConfirmationQueueDelaySeconds : Self.maximumQueueDelaySeconds
        let measuredAcceptableDelay: Bool
        switch packetEvidence {
        case let .measured(delay) where delay.isFinite && delay >= 0
            && delay <= maximumMeasuredDelay:
            measuredAcceptableDelay = true
        case .noNewPackets:
            measuredAcceptableDelay = false
        case .measured, .unavailable:
            admissionWitness = nil
            confirmationWitness = nil
            return
        }
        if frameProgress == .unchanged {
            // A genuine between-frame poll can retain the original witness, not
            // create/confirm one or slide its clock. Packet absence is typed proof.
            if phase == .trial, let appliedAt, now > appliedAt, frames.isFullSourceSize {
                Self.preserveWitness(at: now, capacityBps: capacityBps, existing: &confirmationWitness)
            } else if phase != .trial, allowsTrial {
                Self.preserveWitness(at: now, capacityBps: capacityBps, existing: &admissionWitness)
            } else {
                admissionWitness = nil
                confirmationWitness = nil
            }
            return
        }
        guard frameProgress == .advanced, measuredAcceptableDelay else {
            admissionWitness = nil
            confirmationWitness = nil
            return
        }

        if phase == .trial {
            guard let appliedAt, now > appliedAt, frames.isFullSourceSize else {
                confirmationWitness = nil
                return
            }
            if Self.witnessResult(at: now, capacityBps: capacityBps, existing: &confirmationWitness) {
                phase = .accepted
                deadline = nil
                retryNotBefore = nil
                consecutiveFailures = 0
                admissionWitness = nil
                confirmationWitness = nil
            }
        } else {
            guard allowsTrial else {
                admissionWitness = nil
                return
            }
            phase = .observing
            if Self.witnessResult(at: now, capacityBps: capacityBps, existing: &admissionWitness) {
                guard attempt < UInt64.max else {
                    retire(at: now)
                    return
                }
                attempt += 1
                attemptStartedAt = now
                phase = .pending
                deadline = now.advanced(by: Self.trialDuration)
                retryNotBefore = nil
                appliedAt = nil
                admissionWitness = nil
                confirmationWitness = nil
            }
        }
    }

    mutating func expire(at now: ContinuousClock.Instant) {
        guard isArmed, advanceClock(to: now) else { return }
        expireCurrentTrial(at: now)
    }

    /// The admission deadline is absolute; a late native success cannot extend it.
    mutating func markApplied(at now: ContinuousClock.Instant) {
        guard isArmed, advanceClock(to: now) else { return }
        expireCurrentTrial(at: now)
        guard phase == .pending else { return }
        phase = .trial
        appliedAt = now
        confirmationWitness = nil
    }

    /// Use before committing another terminal policy transition after native
    /// apply failed: that commit must not accidentally install a pending trial.
    mutating func rejectPendingApplication(at now: ContinuousClock.Instant) {
        guard phase == .pending, advanceClock(to: now) else { return }
        failAttempt(at: now)
    }

    /// Before an await, reserve the attempt as failed in the committed copy.
    /// Only committing the complete, successfully applied proposal installs a trial.
    mutating func retainAttemptConsumption(from observed: Self) {
        guard sameActiveOwner(as: observed), observed.attempt > attempt,
              let began = observed.attemptStartedAt else { return }
        attempt = observed.attempt
        attemptStartedAt = began
        lastObservationAt = latest(lastObservationAt, observed.lastObservationAt)
        consecutiveFailures = max(consecutiveFailures, observed.consecutiveFailures)
        failAttempt(at: began)
    }

    /// Copies only terminal identity and negative state. A predecessor attempt,
    /// Show, or peer cannot cancel a successor or import speculative geometry.
    mutating func retainTerminalState(from observed: Self) {
        guard sameActiveOwner(as: observed),
              observed.phase == .cooldown || observed.phase == .retired,
              observed.attempt >= attempt,
              let observedTerminalAt = observed.terminalAt,
              terminalAt.map({ observedTerminalAt >= $0 }) ?? true else { return }
        attempt = observed.attempt
        attemptStartedAt = observed.attemptStartedAt
        lastObservationAt = latest(lastObservationAt, observed.lastObservationAt)
        lastAdverseAt = latest(lastAdverseAt, observed.lastAdverseAt)
        terminalAt = observedTerminalAt
        consecutiveFailures = max(consecutiveFailures, observed.consecutiveFailures)
        phase = observed.phase
        retryNotBefore = observed.phase == .retired
            ? nil : latest(retryNotBefore, observed.retryNotBefore)
        deadline = nil
        appliedAt = nil
        clearWitnesses()
    }

    private mutating func consumeFrames(
        _ frames: WorldwideScreenSpatialRecoveryFrameEvidence?,
        at now: ContinuousClock.Instant
    ) -> FrameProgress {
        if let frames,
           frames.sourceWidth > 0, frames.sourceHeight > 0,
           frames.sourceWidth <= Int(Int32.max), frames.sourceHeight <= Int(Int32.max),
           let sourceSize,
           sourceSize != SourceSize(width: frames.sourceWidth, height: frames.sourceHeight) {
            retire(at: now)
            return .unavailable
        }
        guard let frames, frames.isValid else {
            clearWitnesses()
            return .unavailable
        }
        let size = SourceSize(width: frames.sourceWidth, height: frames.sourceHeight)
        guard sourceSize == nil || sourceSize == size else {
            retire(at: now)
            return .unavailable
        }
        sourceSize = size
        let previous = lastFrames
        lastFrames = frames
        if let previous {
            if frames.encodedFrames > previous.encodedFrames { return .advanced }
            if frames == previous { return .unchanged }
        }
        admissionWitness = nil
        confirmationWitness = nil
        return .baselineOrReset
    }

    private mutating func expireCurrentTrial(at now: ContinuousClock.Instant) {
        guard isTrialActive, let deadline, now >= deadline else { return }
        failAttempt(at: now)
    }

    private mutating func failAttempt(at now: ContinuousClock.Instant) {
        consecutiveFailures = min(3, consecutiveFailures + 1)
        let delay: Duration = consecutiveFailures == 1 ? .seconds(15)
            : (consecutiveFailures == 2 ? .seconds(30) : .seconds(60))
        phase = .cooldown
        retryNotBefore = now.advanced(by: delay)
        lastAdverseAt = latest(lastAdverseAt, now)
        terminalAt = now
        deadline = nil
        appliedAt = nil
        clearWitnesses()
    }

    private mutating func retire(at now: ContinuousClock.Instant?) {
        phase = .retired
        terminalAt = latest(terminalAt, now)
        lastAdverseAt = latest(lastAdverseAt, now)
        deadline = nil
        retryNotBefore = nil
        appliedAt = nil
        clearWitnesses()
    }

    private mutating func advanceClock(to now: ContinuousClock.Instant) -> Bool {
        guard lastObservationAt.map({ now >= $0 }) ?? true else { return false }
        lastObservationAt = now
        return true
    }

    private func sameActiveOwner(as observed: Self) -> Bool {
        isArmed && peerGeneration != nil && showEpoch != nil
            && peerGeneration == observed.peerGeneration && showEpoch == observed.showEpoch
    }

    private static func witnessResult(
        at now: ContinuousClock.Instant,
        capacityBps: Double,
        existing: inout Witness?
    ) -> Bool {
        if let first = existing {
            guard capacityBps >= first.capacityBps else {
                existing = nil
                return false
            }
            let age = first.observedAt.duration(to: now)
            if age >= .zero && age < minimumWitnessInterval { return false }
            if age >= minimumWitnessInterval && age <= maximumWitnessInterval { return true }
        }
        existing = Witness(observedAt: now, capacityBps: capacityBps)
        return false
    }

    private static func preserveWitness(
        at now: ContinuousClock.Instant,
        capacityBps: Double,
        existing: inout Witness?
    ) {
        guard let first = existing,
              capacityBps >= first.capacityBps,
              first.observedAt.duration(to: now) >= .zero,
              first.observedAt.duration(to: now) <= maximumWitnessInterval else {
            existing = nil
            return
        }
        // Higher neutral BWE only raises the later witness's rejection threshold;
        // it supplies no permission or time extension of its own.
        existing = Witness(observedAt: first.observedAt, capacityBps: capacityBps)
    }

    private func latest(
        _ left: ContinuousClock.Instant?, _ right: ContinuousClock.Instant?
    ) -> ContinuousClock.Instant? {
        if let left, let right { return max(left, right) }
        return left ?? right
    }
}
