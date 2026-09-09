struct WorldwideScreenVideoSamplingCadence: Sendable {
    enum Sample: Equatable, Sendable {
        case regular
        case capacityOnly
    }

    static let regularInterval: Duration = .milliseconds(500)
    static let capacityInterval: Duration = .milliseconds(200)

    private(set) var nextRegularDeadline: ContinuousClock.Instant
    private var nextCapacityDeadline: ContinuousClock.Instant?
    private var capacityProbeEnabled = false
    private var inFlightSample: Sample?
    private var latestSchedulingInstant: ContinuousClock.Instant

    init(startedAt: ContinuousClock.Instant) {
        nextRegularDeadline = startedAt.advanced(by: Self.regularInterval)
        latestSchedulingInstant = startedAt
    }

    var nextDeadline: ContinuousClock.Instant {
        guard let nextCapacityDeadline else { return nextRegularDeadline }
        return min(nextRegularDeadline, nextCapacityDeadline)
    }

    mutating func setCapacityProbeEnabled(
        _ enabled: Bool,
        at now: ContinuousClock.Instant
    ) {
        latestSchedulingInstant = max(latestSchedulingInstant, now)
        guard capacityProbeEnabled != enabled else { return }
        capacityProbeEnabled = enabled
        nextCapacityDeadline = enabled
            ? latestSchedulingInstant.advanced(by: Self.capacityInterval)
            : nil
    }

    mutating func takeDueSample(at now: ContinuousClock.Instant) -> Sample? {
        latestSchedulingInstant = max(latestSchedulingInstant, now)
        guard inFlightSample == nil else { return nil }
        let sample: Sample
        if now >= nextRegularDeadline {
            sample = .regular
        } else if let nextCapacityDeadline,
                  now >= nextCapacityDeadline {
            sample = .capacityOnly
        } else {
            return nil
        }
        inFlightSample = sample
        return sample
    }

    // Call after every taken slot, including a skipped request, timeout, or rejected callback.
    mutating func didFinishSample(at now: ContinuousClock.Instant) {
        latestSchedulingInstant = max(latestSchedulingInstant, now)
        guard let sample = inFlightSample else { return }
        inFlightSample = nil
        if sample == .regular {
            // Measure from completion: delayed native work must not compress policy evidence.
            nextRegularDeadline = latestSchedulingInstant.advanced(by: Self.regularInterval)
        }
        if capacityProbeEnabled {
            nextCapacityDeadline = latestSchedulingInstant.advanced(by: Self.capacityInterval)
        }
    }
}
