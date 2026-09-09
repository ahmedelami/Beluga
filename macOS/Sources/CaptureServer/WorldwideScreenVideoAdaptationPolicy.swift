import WebRTCTransport

enum WorldwideScreenVideoAdaptationTier: Int, CaseIterable, Equatable, Sendable {
    case full
    case high
    case balanced
    case constrained
    case critical
    case survival
    case emergency
    case audioPriority

    fileprivate var bitrateBasisPoints: Int {
        switch self {
        case .full: 10_000
        case .high: 6_700
        case .balanced: 4_200
        case .constrained: 2_100
        case .critical: 800
        case .survival: 300
        case .emergency: 100
        case .audioPriority: 25
        }
    }

    fileprivate var framesPerSecond: Int {
        switch self {
        case .full: 60
        case .high: 45
        case .balanced: 30
        case .constrained: 20
        case .critical: 10
        case .survival: 5
        case .emergency: 2
        case .audioPriority: 1
        }
    }

    fileprivate var scaleResolutionDownBy: Double {
        switch self {
        case .full: 1
        case .high: 1.25
        case .balanced: 1.5
        case .constrained: 2
        case .critical: 3
        case .survival: 4
        case .emergency: 8
        case .audioPriority: 12
        }
    }

    fileprivate var nextHigherQuality: Self? {
        Self(rawValue: rawValue - 1)
    }

    fileprivate var nextLowerQuality: Self? {
        Self(rawValue: rawValue + 1)
    }
}

struct WorldwideScreenVideoEncodingRecommendation: Equatable, Sendable {
    let tier: WorldwideScreenVideoAdaptationTier
    let maximumBitrateBps: Int
    let maximumTotalRTPBitrateBps: Int
    let maximumFramesPerSecond: Int
    let scaleResolutionDownBy: Double

    var webRTCLimits: WebRTCScreenVideoEncodingLimits {
        WebRTCScreenVideoEncodingLimits(
            maximumBitrateBps: maximumBitrateBps,
            maximumFramesPerSecond: maximumFramesPerSecond,
            scaleResolutionDownBy: scaleResolutionDownBy,
            maximumTotalRTPBitrateBps: maximumTotalRTPBitrateBps
        )
    }
}

enum WorldwideScreenVideoAutomaticSuspensionDecision: Equatable, Sendable {
    case suspend
    case resume
}

/// Converts transport capacity into a stable, single-layer screen-video encoding ceiling.
struct WorldwideScreenVideoAdaptationPolicy: Equatable, Sendable {
    private enum PacketQueueObservation: Equatable, Sendable {
        case measured(Double)
        case noNewPackets
        case unavailableOrReset
    }

    enum RoundTripTimeDisposition: String, Equatable, Sendable {
        case legacy
        case provisionalHealthy
        case freshHealthy
        case freshInflated
        case retainedHealthy
        case retainedInflated
        case unavailable
        case expired
        case reseeded
        case reordered
    }

    private enum NativeRoundTripTimeHealth: Equatable, Sendable {
        case unknown, healthy, inflated
    }

    private struct RoundTripTimeEvidence {
        let hasFreshPressure: Bool
        let allowsUpgrade: Bool
        let permitsLegacyMissingValue: Bool
    }

    private struct RoundTripTimeObservationFence: Equatable, Sendable {
        let measurement: WebRTCRoundTripTimeMeasurement
        let current: Double?
    }

    private struct AutomaticResumeProbeRestoration: Equatable, Sendable {
        let belowReserveProbeDisprovedSenderLimitation: Bool
        let applicationLimitedProbeCooldownSamplesRemaining: Int
        let applicationLimitedProbeFailureCount: Int
    }

    struct PromotionCapacityContinuity: Equatable, Sendable {
        let tier: WorldwideScreenVideoAdaptationTier
        var maximumTotalRTPBitrateBps: Int
        let deadline: ContinuousClock.Instant
    }

    private struct CapacityProbeSample: Equatable, Sendable {
        let packetsSent: UInt64?
        let totalPacketSendDelaySeconds: Double?
    }

    private struct FloorRecoveryWitness: Equatable, Sendable {
        let observedAt: ContinuousClock.Instant
        let bandwidthBps: Double
    }

    /// The dedicated video sampler runs independently from the one-second microphone-health
    /// stream. Calibrate evidence windows to its 500 ms cadence, then keep first-reaction counts
    /// bounded below five seconds when the one-second statistics stream is used as a fallback.
    static let sampleIntervalMilliseconds = 500
    static let fallbackSampleIntervalMilliseconds = 1_000
    static let requiredHealthyUpgradeSampleCount = sampleCount(for: 1_000)
    static let requiredSuspendedHealthyUpgradeSampleCount = fallbackSampleCount(
        for: 8_000
    )
    static let requiredPositiveBandwidthBootstrapSampleCount = sampleCount(for: 500)
    // Raising the peer-wide BWE ceiling does not change decoded geometry. Once RTT and advancing
    // low-delay packet evidence are established, one fresh 500 ms sample may request the bounded
    // native probe instead of waiting through another visible-quality interval.
    static let requiredApplicationLimitedUpgradeSampleCount = sampleCount(for: 500)
    static let applicationLimitedProbeGraceSampleCount = sampleCount(for: 3_500)
    static let applicationLimitedProbeGraceDuration = Duration.milliseconds(3_500)
    static let promotionCapacityContinuityDuration = Duration.seconds(2)
    static let initialApplicationLimitedProbeCooldownSampleCount = sampleCount(for: 8_000)
    static let maximumApplicationLimitedProbeCooldownSampleCount = sampleCount(for: 64_000)
    /// A visible sender drains stale probe cooldown within two one-second fallback samples even
    /// when an older failed probe installed the longer backoff retained for suspended recovery.
    static let maximumActiveApplicationLimitedProbeCooldownSampleCount =
        sampleCount(for: 1_000)
    /// When native candidate-pair bandwidth is unavailable, use a slower additive probe backed by
    /// both a stable RTT baseline and advancing low-delay outbound packets. This prevents an
    /// optional stats field from pinning a healthy session at its conservative startup tier.
    /// With no optional BWE field, require two consecutive low-delay RTT/queue reports for each
    /// additive tier. This reacts within one second while preventing alternating pressure samples
    /// from bouncing the encoder ceiling every poll.
    static let requiredUnavailableBandwidthUpgradeSampleCount = sampleCount(for: 1_000)
    static let requiredSuspensionPressureSampleCount = fallbackSampleCount(
        for: 3_000
    )
    /// A paused sender cannot produce a useful outbound bitrate estimate. Even when the last
    /// estimate remains positive-but-low, a long latency-stable window permits one bounded probe;
    /// a failed probe resets this counter and therefore supplies the same full cooldown again.
    static let requiredStableSuspensionResumeProbeSampleCount =
        fallbackSampleCount(for: 16_000)
    static let requiredMaximumSuspensionResumeProbeSampleCount =
        fallbackSampleCount(for: 64_000)
    static let requiredBandwidthOnlyDowngradeSampleCount = sampleCount(for: 1_000)
    /// Encoder reconfiguration and key-frame bursts can produce one high packet-send-delay delta
    /// even when the path is healthy. Require a second consecutive queue-pressure sample before
    /// treating queue delay as congestion; RTT inflation and bandwidth collapse remain immediate.
    static let requiredQueuePressureSampleCount = sampleCount(for: 1_000)

    private static let minimumVideoBitrateBps = 32_000
    private static let audioAndControlReserveBps = 320_000.0
    private static let baselineReferenceMaximumVideoBitrateBps = 9_344_000
    private static let downgradeHeadroomMultiplier = 1.25
    private static let upgradeMarginMultiplier = 1.35
    /// The native controller is capped at the same configured total. Treat a small estimator gap
    /// at that ceiling as cap saturation rather than requiring an exact floating-point sample.
    private static let configuredCapacitySaturationRatio = 0.95
    private static let applicationLimitedSaturationRatio = 0.80
    private static let applicationLimitedProbeImmediateAbortRatio = 0.75
    private static let roundTripTimeRelativeInflationMultiplier = 1.5
    private static let roundTripTimeAbsoluteInflationSeconds = 0.050
    private static let maximumRoundTripTimeBaselineFallPerSample = 0.010
    static let roundTripTimeBootstrapSampleCount = 3
    /// Observation age, not the exact ping age: only a distinct cumulative watermark renews it.
    /// This spans the pinned native stable-pair ping interval without granting indefinite health.
    static let roundTripTimeObservationValidity = Duration.seconds(4)
    private static let maximumAveragePacketSendDelaySeconds = 0.100
    private static let immediateAveragePacketSendDelaySeconds = 0.200
    private static let maximumUpgradePacketSendDelaySeconds = 0.020
    private static let lowDelayPacketQueueObservationValidity =
        Duration.milliseconds(1_500)

    private static func sampleCount(for windowMilliseconds: Int) -> Int {
        max(
            1,
            (windowMilliseconds + sampleIntervalMilliseconds - 1)
                / sampleIntervalMilliseconds
        )
    }

    private static func fallbackSampleCount(
        for windowMilliseconds: Int
    ) -> Int {
        max(
            1,
            (windowMilliseconds + fallbackSampleIntervalMilliseconds - 1)
                / fallbackSampleIntervalMilliseconds
        )
    }

    let configuredTotalRTPBitrateBps: Int
    let maximumTierVideoBitrateBps: Int
    let baseFramesPerSecond: Int
    private(set) var peerGeneration: UInt64?
    private(set) var currentTier: WorldwideScreenVideoAdaptationTier
    private(set) var healthyUpgradeSampleCount = 0
    private(set) var bandwidthOnlyDowngradeSampleCount = 0
    private(set) var queuePressureSampleCount = 0
    private(set) var unavailableBandwidthSampleCount = 0
    private(set) var positiveBandwidthBootstrapSampleCount = 0
    private(set) var applicationLimitedUpgradeSampleCount = 0
    private(set) var applicationLimitedProbeHealthySampleCount = 0
    private(set) var applicationLimitedProbeGraceSamplesRemaining = 0
    private(set) var applicationLimitedProbeDeadline:
        ContinuousClock.Instant?
    private(set) var applicationLimitedProbeCooldownSamplesRemaining = 0
    private(set) var applicationLimitedProbeFailureCount = 0
    private(set) var belowReserveProbeDisprovedSenderLimitation = false
    private var automaticResumeProbeRestoration:
        AutomaticResumeProbeRestoration?
    private(set) var applicationLimitedProbeOriginTier:
        WorldwideScreenVideoAdaptationTier?
    private(set) var applicationLimitedProbeBestQualifiedTier:
        WorldwideScreenVideoAdaptationTier?
    private(set) var applicationLimitedProbeMaximumTotalRTPBitrateBps: Int?
    private(set) var promotionCapacityContinuity: PromotionCapacityContinuity?
    private(set) var automaticSuspensionPressureSampleCount = 0
    private(set) var stableSuspensionResumeProbeSampleCount = 0
    private(set) var maximumSuspensionResumeProbeSampleCount = 0
    private(set) var bandwidthEstimateIsUnavailable = false
    private(set) var lastSampleHasLatencyPressure = false
    private(set) var lastSampleHasPositiveSuspensionPressure = false
    private(set) var lastAveragePacketSendDelaySeconds: Double?
    private var lastLowDelayPacketQueueObservation:
        ContinuousClock.Instant?
    private var lastSoftPacketQueuePressureObservation:
        ContinuousClock.Instant?
    private(set) var roundTripTimeBaselineSeconds: Double?
    private var roundTripTimeBootstrapSamples: [Double] = []
    private(set) var roundTripTimeDisposition: RoundTripTimeDisposition = .unavailable
    private(set) var roundTripTimeObservationAge: Duration?
    private(set) var roundTripTimeReferenceIsProvisional = false
    private(set) var lastConsumedCollectionSequence: UInt64?
    private var roundTripTimeWatermark: WebRTCRoundTripTimeMeasurement?
    private var roundTripTimeObservationFence: RoundTripTimeObservationFence?
    private var nativeRoundTripTimeHealth: NativeRoundTripTimeHealth = .unknown
    private var usesNativeRoundTripTimeEvidence = false
    private var lastRoundTripTimeAdvancement: ContinuousClock.Instant?
    private var lastMeasuredRoundTripTimeSeconds: Double?
    private var permitsInitialRoundTripTimeReference = true
    private var distinctHealthyRoundTripTimeReferenceCount = 0
    private(set) var selectedRoute: WebRTCICERouteDiagnostics?
    private var lastOutboundVideoPacketsSent: UInt64?
    private var lastOutboundVideoTotalPacketSendDelaySeconds: Double?
    private var capacityProbeSample: CapacityProbeSample?
    private var capacityProbeBandwidthHighWatermark: Double?
    private var capacityProbeNativeReportTimestamp: Double?
    private var lastCapacityProbeCollectionSequence: UInt64?
    private var capacityProbeGrowthIsVetoed = false
    private var floorRecoveryShowEpoch: UInt64?
    private var floorRecoveryVisibilityIsReserved = false
    private var floorRecoveryVisibilityIsActive = false
    private(set) var floorRecoveryAttemptConsumed = false
    private(set) var floorRecoveryProbeWasCancelled = false
    private var floorRecoveryProbeSeedBandwidthBps: Double?
    private var floorRecoveryFirstWitness: FloorRecoveryWitness?
    private var floorRecoveryLastRegularSequence: UInt64?
    private var floorRecoveryLastRegularTimestamp: Double?
    private var floorRecoveryLastCooldownObservation: ContinuousClock.Instant?

    var floorRecoveryProbeIsActive: Bool {
        floorRecoveryProbeSeedBandwidthBps != nil
            && applicationLimitedProbeOriginTier == .audioPriority
    }

    init(
        configuredTotalRTPBitrateBps: Int,
        baseFramesPerSecond: Int
    ) {
        self.configuredTotalRTPBitrateBps = min(
            Int(UInt32.max),
            max(1, configuredTotalRTPBitrateBps)
        )
        let videoBudget = max(
            0,
            Double(self.configuredTotalRTPBitrateBps)
                - Self.audioAndControlReserveBps
        ) / Self.downgradeHeadroomMultiplier
        maximumTierVideoBitrateBps = min(
            self.configuredTotalRTPBitrateBps,
            max(Self.minimumVideoBitrateBps, Int(videoBudget.rounded(.down)))
        )
        self.baseFramesPerSecond = max(1, baseFramesPerSecond)
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: self.configuredTotalRTPBitrateBps
        )
    }

    var currentRecommendation: WorldwideScreenVideoEncodingRecommendation {
        let tierRecommendation = recommendation(for: currentTier)
        let ordinaryRecommendation = WorldwideScreenVideoEncodingRecommendation(
            tier: currentTier,
            maximumBitrateBps: tierRecommendation.maximumBitrateBps,
            maximumTotalRTPBitrateBps: promotionCapacityContinuity.flatMap {
                $0.tier == currentTier ? $0.maximumTotalRTPBitrateBps : nil
            } ?? tierRecommendation.maximumTotalRTPBitrateBps,
            maximumFramesPerSecond: tierRecommendation.maximumFramesPerSecond,
            scaleResolutionDownBy: tierRecommendation.scaleResolutionDownBy
        )
        guard applicationLimitedProbeOriginTier != nil,
              let applicationLimitedProbeMaximumTotalRTPBitrateBps else {
            return ordinaryRecommendation
        }
        // A capacity probe raises libwebrtc's peer-wide BWE ceiling in bounded steps while keeping
        // scale and frame cadence stable. The global-ceiling path can initiate or extend a native
        // probe without requiring ALR; the 2x bound prevents its padding burst from starving audio.
        return WorldwideScreenVideoEncodingRecommendation(
            tier: currentTier,
            maximumBitrateBps: maximumTierVideoBitrateBps,
            maximumTotalRTPBitrateBps:
                applicationLimitedProbeMaximumTotalRTPBitrateBps,
            maximumFramesPerSecond:
                ordinaryRecommendation.maximumFramesPerSecond,
            scaleResolutionDownBy:
                ordinaryRecommendation.scaleResolutionDownBy
        )
    }

    var currentTierMinimumSustainableBitrateBps: Int {
        Int(requiredOutgoingBitrateBps(for: currentTier).rounded(.up))
    }

    var nextHigherTierMinimumDirectUpgradeBitrateBps: Int? {
        guard let nextHigherTier = currentTier.nextHigherQuality else {
            return nil
        }
        let requiredBitrate = requiredOutgoingBitrateBps(for: nextHigherTier)
        guard requiredBitrate <= Double(configuredTotalRTPBitrateBps) else {
            return nil
        }
        return Int(
            min(
                Double(configuredTotalRTPBitrateBps),
                requiredBitrate * Self.upgradeMarginMultiplier
            ).rounded(.up)
        )
    }

    func recommendation(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> WorldwideScreenVideoEncodingRecommendation {
        let maximumBitrateBps = min(
            maximumTierVideoBitrateBps,
            referenceVideoBitrateBps(for: tier)
        )
        return WorldwideScreenVideoEncodingRecommendation(
            tier: tier,
            maximumBitrateBps: maximumBitrateBps,
            maximumTotalRTPBitrateBps:
                maximumTotalRTPBitrateBps(for: tier),
            maximumFramesPerSecond: min(
                baseFramesPerSecond,
                tier.framesPerSecond
            ),
            scaleResolutionDownBy: tier.scaleResolutionDownBy
        )
    }

    /// Returns true only when a different peer lifetime reset the adaptation state.
    @discardableResult
    mutating func bind(toPeerGeneration generation: UInt64) -> Bool {
        guard peerGeneration != generation else { return false }
        peerGeneration = generation
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
        )
        selectedRoute = nil
        resetPathMeasurements()
        // Collection order and native measurement identity belong to the peer, not the sampler
        // cadence, geometry, Show/Hide lifetime, or selected-route diagnostics lifetime.
        lastConsumedCollectionSequence = nil
        floorRecoveryShowEpoch = nil
        floorRecoveryVisibilityIsReserved = false
        floorRecoveryVisibilityIsActive = false
        floorRecoveryAttemptConsumed = false
        floorRecoveryProbeWasCancelled = false
        floorRecoveryProbeSeedBandwidthBps = nil
        floorRecoveryFirstWitness = nil
        floorRecoveryLastRegularSequence = nil
        floorRecoveryLastRegularTimestamp = nil
        floorRecoveryLastCooldownObservation = nil
        lastCapacityProbeCollectionSequence = nil
        capacityProbeNativeReportTimestamp = nil
        roundTripTimeWatermark = nil
        roundTripTimeObservationFence = nil
        lastRoundTripTimeAdvancement = nil
        lastMeasuredRoundTripTimeSeconds = nil
        roundTripTimeObservationAge = nil
        permitsInitialRoundTripTimeReference = true
        resetAutomaticSuspensionMeasurements()
        return true
    }

    mutating func beginFloorRecoveryVisibility(peerGeneration generation: UInt64, showEpoch: UInt64) {
        bind(toPeerGeneration: generation)
        guard showEpoch > 0, showEpoch > (floorRecoveryShowEpoch ?? 0) else { return }
        endFloorRecoveryVisibility()
        floorRecoveryShowEpoch = showEpoch
        floorRecoveryVisibilityIsReserved = true
        floorRecoveryAttemptConsumed = false
        floorRecoveryProbeWasCancelled = false
    }

    mutating func activateFloorRecoveryVisibility(peerGeneration generation: UInt64, showEpoch: UInt64) {
        guard peerGeneration == generation, floorRecoveryShowEpoch == showEpoch,
              floorRecoveryVisibilityIsReserved else { return }
        floorRecoveryVisibilityIsActive = true
    }

    mutating func endFloorRecoveryVisibility() {
        floorRecoveryVisibilityIsReserved = false
        floorRecoveryVisibilityIsActive = false
        floorRecoveryFirstWitness = nil
        if floorRecoveryProbeIsActive {
            revertApplicationLimitedProbeIfActive()
        }
    }

    /// Spend the Show-bound attempt before native application can suspend. Copy no positive
    /// health or speculative limits, and never let a predecessor consume a successor's allowance.
    mutating func retainFloorRecoveryAttemptConsumption(from observed: Self) {
        guard peerGeneration == observed.peerGeneration,
              let epoch = floorRecoveryShowEpoch, epoch == observed.floorRecoveryShowEpoch,
              observed.floorRecoveryAttemptConsumed else { return }
        floorRecoveryAttemptConsumed = true
        floorRecoveryFirstWitness = nil
        if let sequence = observed.floorRecoveryLastRegularSequence {
            floorRecoveryLastRegularSequence = max(floorRecoveryLastRegularSequence ?? 0, sequence)
        }
        if let timestamp = observed.floorRecoveryLastRegularTimestamp {
            floorRecoveryLastRegularTimestamp = max(floorRecoveryLastRegularTimestamp ?? 0, timestamp)
        }
    }

    /// Clears latency history when ICE invalidates the selected path, while retaining the
    /// conservative quality tier learned for this peer lifetime.
    mutating func invalidateSelectedRoute() {
        selectedRoute = nil
        revertApplicationLimitedProbeIfActive()
        resetPathMeasurements()
    }

    /// Revokes RTT health synchronously at Hide, even if Show arrives before an inactive stats
    /// report. Preserve peer-owned identity/order and the path reference; only advancement can
    /// reauthorize RTT health. The service's statistics epoch owns partial-window reset/fencing.
    mutating func invalidateRoundTripTimeObservation() {
        floorRecoveryFirstWitness = nil
        revokeRoundTripTimeHealth()
        permitsInitialRoundTripTimeReference = false
    }

    /// Prevents threshold evidence collected on one cadence, or before a long observation gap,
    /// from being combined with a later sample. Stable route baselines and any already-applied
    /// probe remain intact; only incomplete evidence windows are discarded.
    mutating func resetIncompleteEvidenceWindow() {
        floorRecoveryFirstWitness = nil
        capacityProbeSample = nil
        capacityProbeBandwidthHighWatermark = nil
        promotionCapacityContinuity = nil
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
        unavailableBandwidthSampleCount = 0
        positiveBandwidthBootstrapSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeBestQualifiedTier = nil
    }

    /// Returns a recommendation only when the current sender should apply new limits.
    mutating func update(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool = false,
        availableOutgoingBitrateBps: Double?,
        currentRoundTripTimeSeconds: Double?,
        roundTripTimeObservation: WebRTCRoundTripTimeObservation? = nil,
        collectionSequence: UInt64? = nil,
        requireRoundTripTimeObservation: Bool = false,
        selectedRoute: WebRTCICERouteDiagnostics? = nil,
        outboundVideoPacketsSent: UInt64? = nil,
        outboundVideoTotalPacketSendDelaySeconds: Double? = nil,
        nativeReportTimestampMicroseconds: Double? = nil,
        observedAt: ContinuousClock.Instant = .now
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        let didResetForNewPeer = bind(toPeerGeneration: generation)
        // Time still passes when a report is rejected. Aging an existing lease is not renewing
        // it or consuming the report, and prevents stale stable-resume authorization.
        roundTripTimeObservationAge = lastRoundTripTimeAdvancement.map {
            $0.duration(to: observedAt)
        }
        if requireRoundTripTimeObservation, collectionSequence == nil {
            floorRecoveryFirstWitness = nil
            // Native request ordering is part of the evidence boundary. Unordered metadata may
            // expire a wall-clock lease, but cannot change BWE/queue/RTT measurement state.
            revokeRoundTripTimeHealth()
            usesNativeRoundTripTimeEvidence = true
            lastSampleHasLatencyPressure = false
            lastSampleHasPositiveSuspensionPressure = false
            return expireApplicationLimitedProbeWithoutReport(
                peerGeneration: generation,
                isCaptureActive: isCaptureActive,
                observedAt: observedAt
            )
        }
        if let collectionSequence {
            if let lastCapacityProbeCollectionSequence,
               collectionSequence <= lastCapacityProbeCollectionSequence {
                floorRecoveryFirstWitness = nil
                return expireApplicationLimitedProbeWithoutReport(
                    peerGeneration: generation,
                    isCaptureActive: isCaptureActive,
                    observedAt: observedAt
                )
            }
            if let lastConsumedCollectionSequence,
               collectionSequence <= lastConsumedCollectionSequence {
                floorRecoveryFirstWitness = nil
                // A slower fallback request may finish after a newer fast-lane report. Reject
                // the entire older report, including BWE/queue/cap changes, before consuming it.
                roundTripTimeDisposition = .reordered
                lastSampleHasLatencyPressure = false
                lastSampleHasPositiveSuspensionPressure = false
                return expireApplicationLimitedProbeWithoutReport(
                    peerGeneration: generation,
                    isCaptureActive: isCaptureActive,
                    observedAt: observedAt
                )
            }
            lastConsumedCollectionSequence = collectionSequence
        }
        capacityProbeGrowthIsVetoed = false
        let floorRecoveryReportIsFresh = consumeFloorRecoveryReportIdentity(
            sequence: collectionSequence,
            timestamp: nativeReportTimestampMicroseconds,
            requiresNativeEvidence: requireRoundTripTimeObservation
        )
        defer {
            recordCapacityProbeBaseline(
                nativeReportTimestampMicroseconds: nativeReportTimestampMicroseconds,
                availableOutgoingBitrateBps: availableOutgoingBitrateBps,
                packetsSent: outboundVideoPacketsSent,
                totalPacketSendDelaySeconds: outboundVideoTotalPacketSendDelaySeconds
            )
        }
        let previousRecommendation = currentRecommendation
        let hadPromotionCapacityContinuity = promotionCapacityContinuity != nil
        updatePromotionCapacityContinuity(
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            isCaptureActive: isCaptureActive,
            observedAt: observedAt
        )
        let changedRecommendation = updateNetworkEvidence(
            peerGeneration: generation,
            didResetForNewPeer: didResetForNewPeer,
            isCaptureActive: isCaptureActive,
            isAutomaticallySuspended: isAutomaticallySuspended,
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            currentRoundTripTimeSeconds: currentRoundTripTimeSeconds,
            roundTripTimeObservation: roundTripTimeObservation
                ?? (requireRoundTripTimeObservation ? .unavailable : nil),
            selectedRoute: selectedRoute,
            outboundVideoPacketsSent: outboundVideoPacketsSent,
            outboundVideoTotalPacketSendDelaySeconds:
                outboundVideoTotalPacketSendDelaySeconds,
            floorRecoveryReportIsFresh: floorRecoveryReportIsFresh,
            observedAt: observedAt
        )
        if lastSampleHasLatencyPressure {
            promotionCapacityContinuity = nil
        }
        // Cap expiry/shrink must reach the sender even when no visible tier changed.
        guard isCaptureActive,
              changedRecommendation != nil
                || (hadPromotionCapacityContinuity
                    && currentRecommendation != previousRecommendation) else {
            return nil
        }
        return currentRecommendation
    }

    /// An unsuccessful native cap increase does not erase a report already observed. Retain
    /// only ordering/identity fences; the unapplied budget and positive health stay unchanged.
    mutating func retainCapacityProbeObservationIdentity(from observed: Self) {
        guard peerGeneration == observed.peerGeneration,
              applicationLimitedProbeOriginTier != nil,
              applicationLimitedProbeOriginTier == observed.applicationLimitedProbeOriginTier,
              let sequence = observed.lastCapacityProbeCollectionSequence,
              sequence > (lastConsumedCollectionSequence ?? 0),
              sequence > (lastCapacityProbeCollectionSequence ?? 0) else {
            return
        }
        lastCapacityProbeCollectionSequence = sequence
        capacityProbeNativeReportTimestamp = observed.capacityProbeNativeReportTimestamp
        roundTripTimeObservationFence = observed.roundTripTimeObservationFence
    }

    /// Intermediate reports can grow or revoke speculative capacity, never qualify geometry.
    /// Positive RTT/queue leases still belong exclusively to the ordinary 500 ms reducer.
    mutating func updateCapacityProbe(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        availableOutgoingBitrateBps: Double?,
        currentRoundTripTimeSeconds: Double?,
        roundTripTimeObservation: WebRTCRoundTripTimeObservation?,
        collectionSequence: UInt64?,
        nativeReportTimestampMicroseconds: Double?,
        selectedRoute: WebRTCICERouteDiagnostics? = nil,
        outboundVideoPacketsSent: UInt64?,
        outboundVideoTotalPacketSendDelaySeconds: Double?,
        observedAt: ContinuousClock.Instant = .now,
        diagnostics: ((WorldwideScreenCapacityProbeDiagnostics) -> Void)? = nil
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        var evaluation = WorldwideScreenCapacityProbeDiagnostics(
            origin: applicationLimitedProbeOriginTier,
            collectionSequence: collectionSequence,
            previousNativeReportTimestamp: capacityProbeNativeReportTimestamp,
            nativeReportTimestamp: nativeReportTimestampMicroseconds,
            beforeTotalCapBps: currentRecommendation.maximumTotalRTPBitrateBps
        )
        defer {
            evaluation.proposedTotalCapBps = currentRecommendation.maximumTotalRTPBitrateBps
            diagnostics?(evaluation)
        }
        guard peerGeneration == generation, isCaptureActive else {
            evaluation.reason = .inactive
            return nil
        }
        if let expired = expireApplicationLimitedProbeWithoutReport(
            peerGeneration: generation,
            isCaptureActive: isCaptureActive,
            observedAt: observedAt
        ) {
            evaluation.reason = .expired
            return expired
        }
        guard let origin = applicationLimitedProbeOriginTier,
              let currentCeiling = applicationLimitedProbeMaximumTotalRTPBitrateBps,
              let collectionSequence,
              collectionSequence > (lastConsumedCollectionSequence ?? 0),
              collectionSequence > (lastCapacityProbeCollectionSequence ?? 0),
              let timestamp = nativeReportTimestampMicroseconds,
              timestamp.isFinite, timestamp > 0,
              let previousTimestamp = capacityProbeNativeReportTimestamp,
              timestamp > previousTimestamp else {
            return nil
        }
        // The native timestamp is a report identity, not an elapsed-time clock. Equal or
        // regressing UTC timestamps cannot mint capacity proof even with a new request number.
        capacityProbeNativeReportTimestamp = timestamp
        lastCapacityProbeCollectionSequence = collectionSequence
        let baseline = capacityProbeSample
        capacityProbeSample = CapacityProbeSample(
            packetsSent: outboundVideoPacketsSent,
            totalPacketSendDelaySeconds: outboundVideoTotalPacketSendDelaySeconds
        )
        // Positive fast observations advance only the identity fence, never the ordinary
        // reference or health lease. Negative identities must poison subsequent ordinary use.
        var validation = self
        let rtt = validation.consumeRoundTripTimeEvidence(
            current: validRoundTripTime(currentRoundTripTimeSeconds),
            observation: roundTripTimeObservation ?? .unavailable,
            observedAt: observedAt
        )
        roundTripTimeObservationFence = validation.roundTripTimeObservationFence
        guard rtt.allowsUpgrade else {
            evaluation.reason = .roundTripTime
            revokeRoundTripTimeHealth()
            permitsInitialRoundTripTimeReference = false
            if !rtt.hasFreshPressure {
                roundTripTimeWatermark = validation.roundTripTimeWatermark
                roundTripTimeDisposition = validation.roundTripTimeDisposition
                if validation.roundTripTimeBaselineSeconds == nil {
                    roundTripTimeBaselineSeconds = nil
                    roundTripTimeBootstrapSamples = []
                    distinctHealthyRoundTripTimeReferenceCount = 0
                    roundTripTimeReferenceIsProvisional = false
                }
            }
            // Leave a fresh inflated measurement unconsumed: the ordinary lane must still
            // apply its one RTT-pressure decision, not lose it to this capacity-only abort.
            failApplicationLimitedProbe(revertingTo: origin)
            return currentRecommendation
        }
        if selectedRoute != self.selectedRoute {
            evaluation.reason = .routeChanged
            // Sender-filtered stats can reveal a route change before the ordinary route event.
            // Its RTT tuple must not become new health when the next regular report reuses it.
            revokeRoundTripTimeHealth()
            permitsInitialRoundTripTimeReference = false
            roundTripTimeWatermark = validation.roundTripTimeWatermark
            failApplicationLimitedProbe(revertingTo: origin)
            return currentRecommendation
        }
        guard let baseline,
              let previousBandwidth = capacityProbeBandwidthHighWatermark,
              nativeRoundTripTimeHealth == .healthy,
              let advancement = lastRoundTripTimeAdvancement,
              advancement.duration(to: observedAt) >= .zero,
              advancement.duration(to: observedAt) <= Self.roundTripTimeObservationValidity else {
            evaluation.reason = .missingPrimaryEvidence
            failApplicationLimitedProbe(revertingTo: origin)
            return currentRecommendation
        }
        evaluation.recordQueue(
            previousPackets: baseline.packetsSent,
            previousDelay: baseline.totalPacketSendDelaySeconds,
            packets: outboundVideoPacketsSent,
            delay: outboundVideoTotalPacketSendDelaySeconds
        )
        validation.lastOutboundVideoPacketsSent = baseline.packetsSent
        validation.lastOutboundVideoTotalPacketSendDelaySeconds =
            baseline.totalPacketSendDelaySeconds
        let queue = validation.packetQueueObservationSinceLastSample(
            packetsSent: outboundVideoPacketsSent,
            totalPacketSendDelaySeconds: outboundVideoTotalPacketSendDelaySeconds
        )
        let queueAllowsGrowth: Bool
        switch queue {
        case let .measured(delay):
            if delay >= Self.immediateAveragePacketSendDelaySeconds {
                evaluation.reason = .immediateQueue
                failApplicationLimitedProbe(revertingTo: origin)
                return currentRecommendation
            }
            queueAllowsGrowth = delay <= Self.maximumUpgradePacketSendDelaySeconds
        case .noNewPackets:
            queueAllowsGrowth = lastLowDelayPacketQueueObservation.map {
                isFreshPacketQueueObservation($0, at: observedAt)
            } ?? false
        case .unavailableOrReset:
            queueAllowsGrowth = false
        }
        guard let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            evaluation.reason = .missingBandwidth
            capacityProbeGrowthIsVetoed = true
            return nil
        }
        let collapseThreshold = applicationLimitedProbeCollapseThreshold(for: origin)
        evaluation.collapseThresholdBps =
            WorldwideScreenCapacityProbeDiagnostics.boundedInteger(collapseThreshold)
        if availableOutgoingBitrateBps < collapseThreshold {
            evaluation.reason = .bandwidthCollapse
            failApplicationLimitedProbe(revertingTo: origin)
            return currentRecommendation
        }
        // Neutral transition bursts withhold growth for this regular observation window;
        // they do not turn a 200 ms poll into an extra congestion/backoff decision.
        guard queueAllowsGrowth,
              let queuePermission = lastLowDelayPacketQueueObservation,
              isFreshPacketQueueObservation(queuePermission, at: observedAt) else {
            evaluation.reason = .queueWithheld
            capacityProbeGrowthIsVetoed = true
            return nil
        }
        guard !capacityProbeGrowthIsVetoed else {
            evaluation.reason = .growthVetoed
            return nil
        }
        guard availableOutgoingBitrateBps > previousBandwidth else {
            evaluation.reason = .bandwidthNotAdvanced
            return nil
        }
        capacityProbeBandwidthHighWatermark = availableOutgoingBitrateBps
        let nextCeiling = boundedApplicationLimitedProbeCeiling(
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            currentCeilingBps: currentCeiling
        )
        guard nextCeiling > currentCeiling else {
            evaluation.reason = .atCeiling
            return nil
        }
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nextCeiling
        evaluation.reason = .increased
        return currentRecommendation
    }

    private mutating func recordCapacityProbeBaseline(
        nativeReportTimestampMicroseconds: Double?,
        availableOutgoingBitrateBps: Double?,
        packetsSent: UInt64?,
        totalPacketSendDelaySeconds: Double?
    ) {
        guard let timestamp = nativeReportTimestampMicroseconds,
              timestamp.isFinite, timestamp > 0,
              timestamp >= (capacityProbeNativeReportTimestamp ?? 0) else {
            capacityProbeSample = nil
            return
        }
        capacityProbeNativeReportTimestamp = timestamp
        guard applicationLimitedProbeOriginTier != nil,
              let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            capacityProbeSample = nil
            capacityProbeBandwidthHighWatermark = nil
            return
        }
        capacityProbeBandwidthHighWatermark = max(
            capacityProbeBandwidthHighWatermark ?? 0,
            availableOutgoingBitrateBps
        )
        capacityProbeSample = CapacityProbeSample(
            packetsSent: packetsSent,
            totalPacketSendDelaySeconds: totalPacketSendDelaySeconds
        )
    }

    private mutating func updateNetworkEvidence(
        peerGeneration generation: UInt64,
        didResetForNewPeer: Bool,
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool,
        availableOutgoingBitrateBps: Double?,
        currentRoundTripTimeSeconds: Double?,
        roundTripTimeObservation: WebRTCRoundTripTimeObservation?,
        selectedRoute: WebRTCICERouteDiagnostics?,
        outboundVideoPacketsSent: UInt64?,
        outboundVideoTotalPacketSendDelaySeconds: Double?,
        floorRecoveryReportIsFresh: Bool,
        observedAt: ContinuousClock.Instant
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        if let selectedRoute,
           selectedRoute != self.selectedRoute {
            let isInitialRoute = self.selectedRoute == nil
                && roundTripTimeWatermark == nil
                && permitsInitialRoundTripTimeReference
            self.selectedRoute = selectedRoute
            revertApplicationLimitedProbeIfActive()
            resetPathMeasurements()
            if isInitialRoute {
                permitsInitialRoundTripTimeReference = true
            }
        }

        // Pre-Show and manually hidden sessions have no outbound video with which to interpret
        // WebRTC's optional bandwidth estimate or packet-send delay. V27 treated those absent
        // samples as congestion and could walk all the way to audioPriority before the first Show.
        // Reset to the configured conservative start tier and consume path samples only for an
        // active sender or an explicit automatic-pause recovery probe.
        guard isCaptureActive || isAutomaticallySuspended else {
            currentTier = Self.initialTier(
                configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
            )
            resetPathMeasurements()
            // Hidden reports cannot authorize a later Show using a cached measurement. Keep a
            // valid watermark as a tombstone, without treating it as RTT/queue/BWE health.
            if case let .measurement(measurement) = roundTripTimeObservation,
               isValidRoundTripTimeWatermark(measurement) {
                roundTripTimeWatermark = measurement
            }
            resetAutomaticSuspensionMeasurements()
            return nil
        }

        let currentRoundTripTimeSeconds = validRoundTripTime(
            currentRoundTripTimeSeconds
        )
        let roundTripTimeEvidence = consumeRoundTripTimeEvidence(
            current: currentRoundTripTimeSeconds,
            observation: roundTripTimeObservation,
            observedAt: observedAt
        )
        // Only a fresh inflated native watermark applies additional RTT-only descent. Retained
        // unhealthy/unknown RTT still vetoes upgrades, without suppressing fresh queue pressure.
        let roundTripTimeIsInflated = roundTripTimeEvidence.hasFreshPressure
        let packetQueueObservation = packetQueueObservationSinceLastSample(
                packetsSent: outboundVideoPacketsSent,
                totalPacketSendDelaySeconds:
                    outboundVideoTotalPacketSendDelaySeconds
            )
        let averagePacketSendDelaySeconds: Double?
        switch packetQueueObservation {
        case let .measured(value):
            averagePacketSendDelaySeconds = value
        case .noNewPackets, .unavailableOrReset:
            averagePacketSendDelaySeconds = nil
        }
        lastAveragePacketSendDelaySeconds = averagePacketSendDelaySeconds
        let packetQueueSampleIsInflated = averagePacketSendDelaySeconds.map {
            $0 > Self.maximumAveragePacketSendDelaySeconds
        } ?? false
        let packetQueueSampleRequiresImmediateResponse =
            averagePacketSendDelaySeconds.map {
                $0 >= Self.immediateAveragePacketSendDelaySeconds
            } ?? false
        switch packetQueueObservation {
        case .measured where packetQueueSampleIsInflated
            && !roundTripTimeIsInflated:
            if let lastSoftPacketQueuePressureObservation,
               !isFreshPacketQueueObservation(
                   lastSoftPacketQueuePressureObservation,
                   at: observedAt
               ) {
                queuePressureSampleCount = 0
            }
            if queuePressureSampleCount < Int.max {
                queuePressureSampleCount += 1
            }
            lastSoftPacketQueuePressureObservation = observedAt
        case .noNewPackets where !roundTripTimeIsInflated:
            if let lastSoftPacketQueuePressureObservation,
               !isFreshPacketQueueObservation(
                   lastSoftPacketQueuePressureObservation,
                   at: observedAt
               ) {
                queuePressureSampleCount = 0
                self.lastSoftPacketQueuePressureObservation = nil
            }
        case .measured, .unavailableOrReset, .noNewPackets:
            queuePressureSampleCount = 0
            lastSoftPacketQueuePressureObservation = nil
        }
        let packetQueueIsInflated = packetQueueSampleIsInflated
            && (packetQueueSampleRequiresImmediateResponse
                || queuePressureSampleCount >= Self.requiredQueuePressureSampleCount)
        switch packetQueueObservation {
        case let .measured(averagePacketSendDelaySeconds):
            lastLowDelayPacketQueueObservation =
                averagePacketSendDelaySeconds
                    <= Self.maximumUpgradePacketSendDelaySeconds
                ? observedAt
                : nil
        case .noNewPackets:
            if let lastLowDelayPacketQueueObservation,
               !isFreshPacketQueueObservation(
                   lastLowDelayPacketQueueObservation,
                   at: observedAt
               ) {
                self.lastLowDelayPacketQueueObservation = nil
            }
        case .unavailableOrReset:
            lastLowDelayPacketQueueObservation = nil
        }
        let packetQueueAllowsUpgrade: Bool
        if let averagePacketSendDelaySeconds {
            packetQueueAllowsUpgrade = averagePacketSendDelaySeconds
                <= Self.maximumUpgradePacketSendDelaySeconds
        } else if let lastLowDelayPacketQueueObservation {
            let observationAge = lastLowDelayPacketQueueObservation.duration(
                to: observedAt
            )
            packetQueueAllowsUpgrade = observationAge >= .zero
                && observationAge
                    <= Self.lowDelayPacketQueueObservationValidity
        } else {
            packetQueueAllowsUpgrade = false
        }
        let roundTripTimeAllowsUpgrade = roundTripTimeEvidence.allowsUpgrade
        let directUpgradeEvidenceIsHealthy = averagePacketSendDelaySeconds.map {
            $0 <= Self.maximumUpgradePacketSendDelaySeconds
                && (roundTripTimeEvidence.permitsLegacyMissingValue
                    || roundTripTimeAllowsUpgrade)
        } ?? roundTripTimeAllowsUpgrade
        let strictUpgradeEvidenceIsHealthy = packetQueueAllowsUpgrade
            && roundTripTimeAllowsUpgrade
        let latencyPressure = roundTripTimeIsInflated || packetQueueIsInflated
        let latencyEvidenceIsPositivelyHealthy = !latencyPressure
            && directUpgradeEvidenceIsHealthy
        lastSampleHasLatencyPressure = latencyPressure

        let floorRecoveryMayBegin = observeFloorRecoveryWitness(
            reportIsFresh: floorRecoveryReportIsFresh,
            queue: packetQueueObservation,
            roundTripTimeAllowsUpgrade: roundTripTimeAllowsUpgrade,
            bandwidthBps: availableOutgoingBitrateBps,
            isCaptureActive: isCaptureActive,
            observedAt: observedAt
        )

        guard let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            bandwidthOnlyDowngradeSampleCount = 0
            applicationLimitedUpgradeSampleCount = 0
            if let probeOriginTier = applicationLimitedProbeOriginTier {
                applicationLimitedProbeHealthySampleCount = 0
                let probeDeadlineExpired = applicationLimitedProbeDeadline.map {
                    observedAt >= $0
                } ?? true
                if latencyPressure {
                    failApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = true
                    return isCaptureActive ? currentRecommendation : nil
                } else if probeDeadlineExpired {
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                } else if applicationLimitedProbeGraceSamplesRemaining > 1 {
                    applicationLimitedProbeGraceSamplesRemaining -= 1
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                } else {
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }
            if !bandwidthEstimateIsUnavailable {
                healthyUpgradeSampleCount = 0
            }
            bandwidthEstimateIsUnavailable = true
            if unavailableBandwidthSampleCount < Int.max {
                unavailableBandwidthSampleCount += 1
            }
            // Missing BWE is telemetry, not new proof of congestion. Preserve a prior failed
            // raised-ceiling probe below the reserved floor, however: that probe already removed
            // the sender-limit ambiguity and remains actionable until capacity is positively
            // re-established or an automatic resume authorizes a fresh recovery probe.
            lastSampleHasPositiveSuspensionPressure = latencyPressure
                || belowReserveProbeDisprovedSenderLimitation
            if latencyPressure {
                healthyUpgradeSampleCount = 0
                guard let lowerTier = currentTier.nextLowerQuality else {
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                }
                currentTier = lowerTier
                resetQueueEvidenceForTierTransition()
                return isCaptureActive ? currentRecommendation : nil
            }
            if consumeApplicationLimitedProbeCooldown(
                isCaptureActive: isCaptureActive
            ) {
                healthyUpgradeSampleCount = 0
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }

            // Candidate-pair availableOutgoingBitrate is optional. Once both independent latency
            // signals are healthy, cautiously probe one tier at a time instead of freezing the
            // startup scale forever. Each probe must earn a fresh complete window.
            guard isCaptureActive,
                  let upgradeTier = currentTier.nextHigherQuality,
                  requiredOutgoingBitrateBps(for: upgradeTier)
                    <= Double(configuredTotalRTPBitrateBps),
                  packetQueueAllowsUpgrade,
                  roundTripTimeAllowsUpgrade else {
                healthyUpgradeSampleCount = 0
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            healthyUpgradeSampleCount += 1
            guard healthyUpgradeSampleCount
                    >= Self.requiredUnavailableBandwidthUpgradeSampleCount else {
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            currentTier = upgradeTier
            resetQueueEvidenceForTierTransition()
            healthyUpgradeSampleCount = 0
            return currentRecommendation
        }
        if bandwidthEstimateIsUnavailable {
            healthyUpgradeSampleCount = 0
        }
        bandwidthEstimateIsUnavailable = false
        unavailableBandwidthSampleCount = 0
        let effectiveAvailableOutgoingBitrateBps: Double
        if availableOutgoingBitrateBps
            >= Double(configuredTotalRTPBitrateBps)
                * Self.configuredCapacitySaturationRatio {
            effectiveAvailableOutgoingBitrateBps = Double(
                configuredTotalRTPBitrateBps
            )
        } else {
            effectiveAvailableOutgoingBitrateBps = availableOutgoingBitrateBps
        }
        let capacitySustainableTier = sustainableTier(
            for: effectiveAvailableOutgoingBitrateBps
        )
        let independentlyQualifiedUpgradeTier = highestQualifiedUpgradeTier(
            for: effectiveAvailableOutgoingBitrateBps
        )
        let requiredAudioPriorityBitrateBps = requiredOutgoingBitrateBps(
            for: .audioPriority
        )
        if effectiveAvailableOutgoingBitrateBps
            >= requiredAudioPriorityBitrateBps {
            belowReserveProbeDisprovedSenderLimitation = false
            automaticResumeProbeRestoration = nil
        }
        let estimatorMayBeApplicationLimited = estimatorIsApplicationLimited(
            effectiveAvailableOutgoingBitrateBps
        )

        // Only a positive estimate already near the sender ceiling can be self-limited. Give that
        // exact cold-start case one bounded window for RTT/queue evidence; a genuinely low or
        // flapping estimate remains actionable on its first valid sample.
        if latencyPressure {
            positiveBandwidthBootstrapSampleCount =
                Self.requiredPositiveBandwidthBootstrapSampleCount
            applicationLimitedUpgradeSampleCount = 0
        } else if positiveBandwidthBootstrapSampleCount
            < Self.requiredPositiveBandwidthBootstrapSampleCount {
            if independentlyQualifiedUpgradeTier != nil {
                positiveBandwidthBootstrapSampleCount =
                    Self.requiredPositiveBandwidthBootstrapSampleCount
            } else if estimatorMayBeApplicationLimited {
                positiveBandwidthBootstrapSampleCount += 1
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            } else {
                positiveBandwidthBootstrapSampleCount =
                    Self.requiredPositiveBandwidthBootstrapSampleCount
            }
        }

        if let probeOriginTier = applicationLimitedProbeOriginTier {
            let probeQualifiedTier = capacitySustainableTier.rawValue
                < probeOriginTier.rawValue
                ? capacitySustainableTier
                : nil
            let probeCapacityCollapsed =
                effectiveAvailableOutgoingBitrateBps
                    < applicationLimitedProbeCollapseThreshold(for: probeOriginTier)
            let probeDeadlineExpired = applicationLimitedProbeDeadline.map {
                observedAt >= $0
            } ?? true
            if latencyPressure || probeCapacityCollapsed {
                if probeCapacityCollapsed,
                   effectiveAvailableOutgoingBitrateBps
                    < requiredAudioPriorityBitrateBps {
                    // Raising the sender ceiling removed the censoring ambiguity but the estimate
                    // stayed below the reserved floor. Preserve that evidence across backoff so a
                    // genuinely constrained path can still accumulate bounded pause pressure.
                    belowReserveProbeDisprovedSenderLimitation = true
                }
                failApplicationLimitedProbe(revertingTo: probeOriginTier)
                if capacitySustainableTier.rawValue > probeOriginTier.rawValue {
                    // This is still one terminal decision for the report: independently worse BWE
                    // may protect the audio/control reserve, while probe-only latency merely
                    // restores the unchanged visible origin tier.
                    currentTier = capacitySustainableTier
                    resetQueueEvidenceForTierTransition()
                }
                lastSampleHasPositiveSuspensionPressure = latencyPressure
                    || effectiveAvailableOutgoingBitrateBps
                        < requiredAudioPriorityBitrateBps
                return isCaptureActive ? currentRecommendation : nil
            } else if packetQueueSampleIsInflated,
                      !packetQueueIsInflated,
                      !roundTripTimeIsInflated {
                // A single transition burst neither confirms capacity nor consumes sample grace.
                // The absolute deadline still bounds the ceiling-only probe.
                applicationLimitedUpgradeSampleCount = 0
                applicationLimitedProbeHealthySampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                if probeDeadlineExpired {
                    if applicationLimitedProbeBestQualifiedTier == nil,
                       effectiveAvailableOutgoingBitrateBps
                        < requiredAudioPriorityBitrateBps {
                        belowReserveProbeDisprovedSenderLimitation = true
                    }
                    finishApplicationLimitedProbe(
                        revertingTo: probeOriginTier
                    )
                    return isCaptureActive ? currentRecommendation : nil
                }
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }

            if strictUpgradeEvidenceIsHealthy,
               let qualifiedTier = probeQualifiedTier {
                if applicationLimitedProbeBestQualifiedTier == qualifiedTier {
                    if applicationLimitedProbeHealthySampleCount < Int.max {
                        applicationLimitedProbeHealthySampleCount += 1
                    }
                } else {
                    applicationLimitedProbeBestQualifiedTier = qualifiedTier
                    applicationLimitedProbeHealthySampleCount = 1
                }
            } else {
                applicationLimitedProbeHealthySampleCount = 0
            }

            // A proven intermediate tier is useful immediately; the grace window bounds
            // unresolved probes, not how long a qualified improvement must stay hidden.
            if applicationLimitedProbeHealthySampleCount
                >= Self.requiredHealthyUpgradeSampleCount,
               let qualifiedTier = applicationLimitedProbeBestQualifiedTier {
                completeApplicationLimitedProbe(
                    committing: qualifiedTier,
                    availableOutgoingBitrateBps: availableOutgoingBitrateBps,
                    observedAt: observedAt
                )
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive ? currentRecommendation : nil
            }

            if !probeDeadlineExpired,
               applicationLimitedProbeGraceSamplesRemaining > 1,
               strictUpgradeEvidenceIsHealthy,
               let currentProbeCeiling =
                applicationLimitedProbeMaximumTotalRTPBitrateBps {
                let nextProbeCeiling = boundedApplicationLimitedProbeCeiling(
                    availableOutgoingBitrateBps:
                        effectiveAvailableOutgoingBitrateBps,
                    currentCeilingBps: currentProbeCeiling
                )
                if nextProbeCeiling > currentProbeCeiling {
                    applicationLimitedProbeMaximumTotalRTPBitrateBps =
                        nextProbeCeiling
                    applicationLimitedProbeGraceSamplesRemaining -= 1
                    applicationLimitedUpgradeSampleCount = 0
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }

            if applicationLimitedProbeGraceSamplesRemaining > 0 {
                applicationLimitedProbeGraceSamplesRemaining -= 1
            }
            applicationLimitedUpgradeSampleCount = 0
            lastSampleHasPositiveSuspensionPressure = false
            if probeDeadlineExpired
                || applicationLimitedProbeGraceSamplesRemaining == 0 {
                if applicationLimitedProbeBestQualifiedTier == nil,
                   effectiveAvailableOutgoingBitrateBps
                    < requiredAudioPriorityBitrateBps {
                    belowReserveProbeDisprovedSenderLimitation = true
                }
                finishApplicationLimitedProbe(revertingTo: probeOriginTier)
                return isCaptureActive ? currentRecommendation : nil
            }
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        if independentlyQualifiedUpgradeTier != nil,
           directUpgradeEvidenceIsHealthy,
           !latencyPressure {
            resetApplicationLimitedProbeBackoff()
        }

        if floorRecoveryMayBegin,
           beginApplicationLimitedProbe(
               from: .audioPriority,
               availableOutgoingBitrateBps: effectiveAvailableOutgoingBitrateBps,
               observedAt: observedAt
           ) {
            floorRecoveryAttemptConsumed = true
            floorRecoveryProbeWasCancelled = false
            floorRecoveryProbeSeedBandwidthBps = effectiveAvailableOutgoingBitrateBps
            floorRecoveryFirstWitness = nil
            lastSampleHasPositiveSuspensionPressure = false
            return currentRecommendation
        }

        // A near-ceiling estimate is censored by the sender and therefore cannot prove that the
        // path itself is congested. Below the absolute audio/control reserve, extend that neutral
        // treatment only at audioPriority: applying it at higher tiers could pin a truly starved
        // path above the fail-closed floor when strict probe telemetry is unavailable. At the
        // floor, fresh RTT and queue evidence may authorize one bounded higher-ceiling probe.
        let audioPriorityProbeIsFeasible = currentTier == .audioPriority
            && currentTier.nextHigherQuality.map {
                requiredOutgoingBitrateBps(for: $0)
                    <= Double(configuredTotalRTPBitrateBps)
            } == true
        let senderLimitedEstimateCanHoldCurrentTier =
            effectiveAvailableOutgoingBitrateBps
                >= requiredAudioPriorityBitrateBps
            || (audioPriorityProbeIsFeasible
                && !belowReserveProbeDisprovedSenderLimitation)
        let applicationLimitedHoldIsHealthy = !latencyPressure
            && isCaptureActive
            && independentlyQualifiedUpgradeTier == nil
            && estimatorMayBeApplicationLimited
            && senderLimitedEstimateCanHoldCurrentTier
        if applicationLimitedHoldIsHealthy {
            bandwidthOnlyDowngradeSampleCount = 0
            guard currentTier.nextHigherQuality != nil else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            guard !consumeApplicationLimitedProbeCooldown(
                isCaptureActive: isCaptureActive
            ) else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            guard strictUpgradeEvidenceIsHealthy else {
                applicationLimitedUpgradeSampleCount = 0
                lastSampleHasPositiveSuspensionPressure = false
                return isCaptureActive && didResetForNewPeer
                    ? currentRecommendation
                    : nil
            }
            applicationLimitedUpgradeSampleCount += 1
            if applicationLimitedUpgradeSampleCount
                >= Self.requiredApplicationLimitedUpgradeSampleCount {
                applicationLimitedUpgradeSampleCount = 0
                if beginApplicationLimitedProbe(
                    from: currentTier,
                    availableOutgoingBitrateBps:
                        effectiveAvailableOutgoingBitrateBps,
                    observedAt: observedAt
                ) {
                    lastSampleHasPositiveSuspensionPressure = false
                    return isCaptureActive ? currentRecommendation : nil
                }
            }
            lastSampleHasPositiveSuspensionPressure = false
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        } else {
            applicationLimitedUpgradeSampleCount = 0
        }

        if packetQueueSampleIsInflated,
           !packetQueueIsInflated,
           !roundTripTimeIsInflated,
           capacitySustainableTier.rawValue <= currentTier.rawValue {
            // One transition-sized queue delta is neither healthy upgrade evidence nor proof that
            // a sender-censored BWE is the path capacity. Hold the visible tier for one sample.
            healthyUpgradeSampleCount = 0
            bandwidthOnlyDowngradeSampleCount = 0
            lastSampleHasPositiveSuspensionPressure = false
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        lastSampleHasPositiveSuspensionPressure = latencyPressure
            || effectiveAvailableOutgoingBitrateBps
                < requiredOutgoingBitrateBps(for: .audioPriority)

        var sustainableTier = capacitySustainableTier
        if packetQueueIsInflated,
           !roundTripTimeIsInflated,
           let lowerTier = currentTier.nextLowerQuality {
            // Queue-only congestion walks down one tier per fresh sample. This remains a fast
            // 500 ms response while avoiding a direct collapse based on a censored BWE.
            if lowerTier.rawValue > sustainableTier.rawValue {
                sustainableTier = lowerTier
            }
        } else if latencyPressure,
           let lowerTier = currentTier.nextLowerQuality,
           lowerTier.rawValue > sustainableTier.rawValue {
            sustainableTier = lowerTier
        }
        if sustainableTier.rawValue > currentTier.rawValue {
            healthyUpgradeSampleCount = 0
            if latencyEvidenceIsPositivelyHealthy {
                if bandwidthOnlyDowngradeSampleCount < Int.max {
                    bandwidthOnlyDowngradeSampleCount += 1
                }
                guard bandwidthOnlyDowngradeSampleCount
                        >= Self.requiredBandwidthOnlyDowngradeSampleCount else {
                    return isCaptureActive && didResetForNewPeer
                        ? currentRecommendation
                        : nil
                }
            }
            bandwidthOnlyDowngradeSampleCount = 0
            currentTier = sustainableTier
            resetQueueEvidenceForTierTransition()
            return isCaptureActive ? currentRecommendation : nil
        }
        bandwidthOnlyDowngradeSampleCount = 0

        guard sustainableTier.rawValue < currentTier.rawValue,
              let highestUpgradeTier = independentlyQualifiedUpgradeTier else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        // A paused sender cannot supply a fresh trustworthy capacity estimate. Preserve the
        // historical one-tier recovery probe until exact receiver presentation reopens ordinary
        // capture; only an active sender may jump directly to the proven target.
        let upgradeTier = isCaptureActive
            ? highestUpgradeTier
            : (currentTier.nextHigherQuality ?? highestUpgradeTier)
        guard !latencyPressure,
              directUpgradeEvidenceIsHealthy else {
            healthyUpgradeSampleCount = 0
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }

        healthyUpgradeSampleCount += 1
        let requiredUpgradeSampleCount = isCaptureActive
            ? Self.requiredHealthyUpgradeSampleCount
            : Self.requiredSuspendedHealthyUpgradeSampleCount
        guard healthyUpgradeSampleCount
                >= requiredUpgradeSampleCount else {
            return isCaptureActive && didResetForNewPeer
                ? currentRecommendation
                : nil
        }
        // The estimate already proves this target with both downgrade headroom and its own
        // upgrade margin. Select the highest independently qualified tier so crossing into the
        // next tier's raw sustainable band can never make recovery worse.
        currentTier = upgradeTier
        resetQueueEvidenceForTierTransition()
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        return isCaptureActive ? currentRecommendation : nil
    }

    /// Expires only temporary raised ceilings when both statistics lanes stop
    /// producing native reports. Absence is neither healthy nor congested evidence, so this path
    /// cannot alter baselines, evidence counts, ordinary tiers, or automatic-suspension state.
    mutating func expireApplicationLimitedProbeWithoutReport(
        peerGeneration generation: UInt64,
        isCaptureActive: Bool,
        observedAt: ContinuousClock.Instant = .now
    ) -> WorldwideScreenVideoEncodingRecommendation? {
        if peerGeneration == generation {
            roundTripTimeObservationAge = lastRoundTripTimeAdvancement.map {
                $0.duration(to: observedAt)
            }
        }
        guard peerGeneration == generation,
              isCaptureActive else {
            return nil
        }
        let previousRecommendation = currentRecommendation
        if let continuity = promotionCapacityContinuity,
           observedAt >= continuity.deadline {
            promotionCapacityContinuity = nil
        }
        if let originTier = applicationLimitedProbeOriginTier,
           let deadline = applicationLimitedProbeDeadline,
           observedAt >= deadline {
            finishApplicationLimitedProbe(revertingTo: originTier)
        }
        return currentRecommendation != previousRecommendation
            ? currentRecommendation
            : nil
    }

    /// Recovers a session created by an older automatic-suspension policy, but never turns an
    /// acknowledged visible session opaque. Network adaptation owns encoding limits only: even
    /// under genuine congestion the audio-priority 1 fps recommendation remains the visible floor.
    /// Explicit Hide, authorization loss, and transport uncertainty continue to own fail-closed
    /// capture teardown outside this policy.
    mutating func automaticSuspensionDecision(
        isCaptureActive: Bool,
        isAutomaticallySuspended: Bool
    ) -> WorldwideScreenVideoAutomaticSuspensionDecision? {
        if isAutomaticallySuspended {
            automaticSuspensionPressureSampleCount = 0
            if maximumSuspensionResumeProbeSampleCount
                < Self.requiredMaximumSuspensionResumeProbeSampleCount {
                maximumSuspensionResumeProbeSampleCount += 1
            }
            if currentTier != .audioPriority {
                stableSuspensionResumeProbeSampleCount = 0
                maximumSuspensionResumeProbeSampleCount = 0
                return .resume
            }
            // Relative RTT pressure can remain permanently elevated after a path settles at a new
            // stable latency. Never turn that stale baseline into a permanent pause: permit one
            // bounded probe after a much longer maximum-pause window. A failed probe resets both
            // counters and therefore enforces the complete cooldown before another attempt.
            if maximumSuspensionResumeProbeSampleCount
                >= Self.requiredMaximumSuspensionResumeProbeSampleCount {
                stableSuspensionResumeProbeSampleCount = 0
                maximumSuspensionResumeProbeSampleCount = 0
                return .resume
            }
            let nativeRTTAllowsStableResume = nativeRoundTripTimeHealth == .healthy
                && roundTripTimeObservationAge.map {
                    $0 >= .zero && $0 <= Self.roundTripTimeObservationValidity
                } == true
            guard !lastSampleHasLatencyPressure,
                  !usesNativeRoundTripTimeEvidence || nativeRTTAllowsStableResume else {
                stableSuspensionResumeProbeSampleCount = 0
                return nil
            }
            if stableSuspensionResumeProbeSampleCount
                < Self.requiredStableSuspensionResumeProbeSampleCount {
                stableSuspensionResumeProbeSampleCount += 1
            }
            guard stableSuspensionResumeProbeSampleCount
                    >= Self.requiredStableSuspensionResumeProbeSampleCount else {
                return nil
            }
            stableSuspensionResumeProbeSampleCount = 0
            return .resume
        }

        stableSuspensionResumeProbeSampleCount = 0
        maximumSuspensionResumeProbeSampleCount = 0
        automaticSuspensionPressureSampleCount = 0
        return nil
    }

    /// Consumes retained below-reserve evidence only after the suspension coordinator accepts the
    /// exact resume attempt. A rejected decision therefore cannot weaken the pause invariant.
    mutating func automaticResumeAttemptBegan() {
        endFloorRecoveryVisibility()
        promotionCapacityContinuity = nil
        guard automaticResumeProbeRestoration == nil else { return }
        automaticResumeProbeRestoration = AutomaticResumeProbeRestoration(
            belowReserveProbeDisprovedSenderLimitation:
                belowReserveProbeDisprovedSenderLimitation,
            applicationLimitedProbeCooldownSamplesRemaining:
                applicationLimitedProbeCooldownSamplesRemaining,
            applicationLimitedProbeFailureCount:
                applicationLimitedProbeFailureCount
        )
        belowReserveProbeDisprovedSenderLimitation = false
        applicationLimitedUpgradeSampleCount = 0
        resetApplicationLimitedProbeBackoff()
    }

    mutating func automaticResumeAttemptSucceeded() {
        promotionCapacityContinuity = nil
        automaticResumeProbeRestoration = nil
    }

    mutating func automaticResumeAttemptFailed() {
        floorRecoveryFirstWitness = nil
        if floorRecoveryProbeIsActive {
            floorRecoveryProbeWasCancelled = true
        }
        floorRecoveryProbeSeedBandwidthBps = nil
        if let restoration = automaticResumeProbeRestoration {
            belowReserveProbeDisprovedSenderLimitation =
                restoration.belowReserveProbeDisprovedSenderLimitation
            applicationLimitedProbeCooldownSamplesRemaining =
                restoration.applicationLimitedProbeCooldownSamplesRemaining
            applicationLimitedProbeFailureCount =
                restoration.applicationLimitedProbeFailureCount
        }
        automaticResumeProbeRestoration = nil
        currentTier = .audioPriority
        resetQueueEvidenceForTierTransition()
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        resetAutomaticSuspensionMeasurements()
    }

    mutating func resetForInactiveCapture() {
        currentTier = Self.initialTier(
            configuredTotalRTPBitrateBps: configuredTotalRTPBitrateBps
        )
        resetPathMeasurements()
        resetAutomaticSuspensionMeasurements()
    }

    private func sustainableTier(
        for availableOutgoingBitrateBps: Double
    ) -> WorldwideScreenVideoAdaptationTier {
        WorldwideScreenVideoAdaptationTier.allCases.first { tier in
            let requiredBitrate = requiredOutgoingBitrateBps(for: tier)
            return requiredBitrate <= Double(configuredTotalRTPBitrateBps)
                && availableOutgoingBitrateBps >= requiredBitrate
        } ?? .audioPriority
    }

    private func highestQualifiedUpgradeTier(
        for availableOutgoingBitrateBps: Double
    ) -> WorldwideScreenVideoAdaptationTier? {
        WorldwideScreenVideoAdaptationTier.allCases.first { tier in
            guard tier.rawValue < currentTier.rawValue else { return false }
            let requiredBitrate = requiredOutgoingBitrateBps(for: tier)
            guard requiredBitrate <= Double(configuredTotalRTPBitrateBps) else {
                return false
            }
            let upgradeThreshold = min(
                Double(configuredTotalRTPBitrateBps),
                requiredBitrate * Self.upgradeMarginMultiplier
            )
            return availableOutgoingBitrateBps >= upgradeThreshold
        }
    }

    private func requiredOutgoingBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Double {
        // Tier selection is based on calibrated codec demand. The separately configured 50 Mbps
        // RTP value remains a native sender ceiling, but must not multiply the bandwidth required
        // to choose a resolution/fps tier.
        return Double(Self.baselineReferenceVideoBitrateBps(for: tier))
            * Self.downgradeHeadroomMultiplier
            + Self.audioAndControlReserveBps
    }

    private mutating func consumeFloorRecoveryReportIdentity(
        sequence: UInt64?, timestamp: Double?, requiresNativeEvidence: Bool
    ) -> Bool {
        guard requiresNativeEvidence,
              let sequence, sequence > (floorRecoveryLastRegularSequence ?? 0),
              let timestamp, timestamp.isFinite, timestamp > 0,
              timestamp > max(floorRecoveryLastRegularTimestamp ?? 0,
                              capacityProbeNativeReportTimestamp ?? 0) else {
            floorRecoveryFirstWitness = nil
            return false
        }
        floorRecoveryLastRegularSequence = sequence
        floorRecoveryLastRegularTimestamp = timestamp
        return true
    }

    private mutating func observeFloorRecoveryWitness(
        reportIsFresh: Bool,
        queue: PacketQueueObservation,
        roundTripTimeAllowsUpgrade: Bool,
        bandwidthBps: Double?,
        isCaptureActive: Bool,
        observedAt: ContinuousClock.Instant
    ) -> Bool {
        guard reportIsFresh, isCaptureActive, floorRecoveryVisibilityIsActive,
              !floorRecoveryAttemptConsumed, !belowReserveProbeDisprovedSenderLimitation,
              currentTier == .audioPriority, applicationLimitedProbeOriginTier == nil,
              usesNativeRoundTripTimeEvidence, nativeRoundTripTimeHealth == .healthy,
              roundTripTimeAllowsUpgrade,
              let bandwidthBps, bandwidthBps.isFinite, bandwidthBps > 0,
              !estimatorIsApplicationLimited(bandwidthBps),
              bandwidthBps * 2 > Double(currentRecommendation.maximumTotalRTPBitrateBps) else {
            floorRecoveryFirstWitness = nil
            return false
        }
        if let first = floorRecoveryFirstWitness,
           !isFreshPacketQueueObservation(first.observedAt, at: observedAt) {
            floorRecoveryFirstWitness = nil
        }
        switch queue {
        case let .measured(delay) where delay <= Self.maximumUpgradePacketSendDelaySeconds:
            break
        case .noNewPackets:
            return false
        case .measured, .unavailableOrReset:
            floorRecoveryFirstWitness = nil
            return false
        }
        if applicationLimitedProbeCooldownSamplesRemaining > 0 {
            floorRecoveryFirstWitness = nil
            if floorRecoveryLastCooldownObservation.map({
                $0.duration(to: observedAt) >= .milliseconds(Self.sampleIntervalMilliseconds)
            }) ?? true {
                floorRecoveryLastCooldownObservation = observedAt
                _ = consumeApplicationLimitedProbeCooldown(isCaptureActive: true)
            }
            return false
        }
        guard let first = floorRecoveryFirstWitness else {
            floorRecoveryFirstWitness = FloorRecoveryWitness(observedAt: observedAt, bandwidthBps: bandwidthBps)
            return false
        }
        // A slightly early completion does not throw away the first healthy regular window.
        guard first.observedAt.duration(to: observedAt) >= .milliseconds(Self.sampleIntervalMilliseconds),
              bandwidthBps > first.bandwidthBps else { return false }
        return true
    }

    private func applicationLimitedProbeCollapseThreshold(
        for origin: WorldwideScreenVideoAdaptationTier
    ) -> Double {
        if origin == .audioPriority, let seed = floorRecoveryProbeSeedBandwidthBps {
            return seed * Self.applicationLimitedProbeImmediateAbortRatio
        }
        // Sender headroom is not codec demand: at 50 Mbps the nominal high-tier ceiling
        // would make even the full 16.2 Mbps probe budget look like a capacity collapse.
        return max(
            requiredOutgoingBitrateBps(for: .audioPriority),
            Double(Self.baselineReferenceVideoBitrateBps(for: origin))
                * Self.applicationLimitedProbeImmediateAbortRatio
        )
    }

    private func maximumTotalRTPBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        Int(
            min(
                Double(configuredTotalRTPBitrateBps),
                requiredOutgoingBitrateBps(for: tier)
                    * Self.upgradeMarginMultiplier
            ).rounded(.up)
        )
    }

    private static func initialTier(
        configuredTotalRTPBitrateBps: Int
    ) -> WorldwideScreenVideoAdaptationTier {
        let configuredQualityCeiling =
            WorldwideScreenVideoAdaptationTier.allCases.first { tier in
                let referenceVideoBitrate = baselineReferenceVideoBitrateBps(
                    for: tier
                )
                let required = Double(referenceVideoBitrate)
                    * downgradeHeadroomMultiplier
                    + audioAndControlReserveBps
                return required <= Double(configuredTotalRTPBitrateBps)
            } ?? .audioPriority
        return WorldwideScreenVideoAdaptationTier(
            rawValue: max(
                WorldwideScreenVideoAdaptationTier.survival.rawValue,
                configuredQualityCeiling.rawValue
            )
        ) ?? .audioPriority
    }

    private func referenceVideoBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        let referenceMaximumVideoBitrateBps = max(
            Self.baselineReferenceMaximumVideoBitrateBps,
            maximumTierVideoBitrateBps
        )
        return max(
            Self.minimumVideoBitrateBps,
            referenceMaximumVideoBitrateBps
                * tier.bitrateBasisPoints / 10_000
        )
    }

    private static func baselineReferenceVideoBitrateBps(
        for tier: WorldwideScreenVideoAdaptationTier
    ) -> Int {
        max(
            minimumVideoBitrateBps,
            baselineReferenceMaximumVideoBitrateBps
                * tier.bitrateBasisPoints / 10_000
        )
    }

    private func boundedApplicationLimitedProbeCeiling(
        availableOutgoingBitrateBps: Double,
        currentCeilingBps: Int
    ) -> Int {
        guard availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            return currentCeilingBps
        }
        let fullProbeCeiling = maximumTotalRTPBitrateBps(for: .full)
        let doubledEstimate = min(
            Double(fullProbeCeiling),
            availableOutgoingBitrateBps * 2
        )
        return max(
            currentCeilingBps,
            Int(doubledEstimate.rounded(.down))
        )
    }

    private func estimatorIsApplicationLimited(
        _ availableOutgoingBitrateBps: Double
    ) -> Bool {
        return availableOutgoingBitrateBps
            >= Double(maximumTotalRTPBitrateBps(for: currentTier))
                * Self.applicationLimitedSaturationRatio
    }

    private mutating func beginApplicationLimitedProbe(
        from originTier: WorldwideScreenVideoAdaptationTier,
        availableOutgoingBitrateBps: Double,
        observedAt: ContinuousClock.Instant
    ) -> Bool {
        guard let probeTier = originTier.nextHigherQuality,
              requiredOutgoingBitrateBps(for: probeTier)
                <= Double(configuredTotalRTPBitrateBps) else {
            return false
        }
        floorRecoveryProbeSeedBandwidthBps = nil
        let currentCeiling = currentRecommendation.maximumTotalRTPBitrateBps
        applicationLimitedProbeOriginTier = originTier
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeHealthySampleCount = 0
        let probeCeiling = boundedApplicationLimitedProbeCeiling(
            availableOutgoingBitrateBps: availableOutgoingBitrateBps,
            currentCeilingBps: currentCeiling
        )
        guard probeCeiling > currentCeiling else {
            applicationLimitedProbeOriginTier = nil
            return false
        }
        applicationLimitedProbeMaximumTotalRTPBitrateBps = probeCeiling
        capacityProbeBandwidthHighWatermark = availableOutgoingBitrateBps
        capacityProbeGrowthIsVetoed = false
        promotionCapacityContinuity = nil
        // This is a bitrate/BWE-ceiling-only transition. Preserve the fresh low-delay packet
        // observation so a 1 fps sender can evaluate the next no-packet poll; visible tier changes
        // still reset queue evidence through complete/fail paths.
        applicationLimitedProbeGraceSamplesRemaining =
            Self.applicationLimitedProbeGraceSampleCount
        applicationLimitedProbeDeadline = observedAt.advanced(
            by: Self.applicationLimitedProbeGraceDuration
        )
        applicationLimitedUpgradeSampleCount = 0
        healthyUpgradeSampleCount = 0
        return true
    }

    private mutating func completeApplicationLimitedProbe(
        committing tier: WorldwideScreenVideoAdaptationTier,
        availableOutgoingBitrateBps: Double? = nil,
        observedAt: ContinuousClock.Instant? = nil
    ) {
        let probeCeiling = applicationLimitedProbeMaximumTotalRTPBitrateBps
        floorRecoveryProbeSeedBandwidthBps = nil
        floorRecoveryProbeWasCancelled = false
        currentTier = tier
        resetQueueEvidenceForTierTransition()
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedUpgradeSampleCount = 0
        belowReserveProbeDisprovedSenderLimitation = false
        automaticResumeProbeRestoration = nil
        resetApplicationLimitedProbeBackoff()
        if let availableOutgoingBitrateBps,
           availableOutgoingBitrateBps.isFinite,
           availableOutgoingBitrateBps > 0,
           let observedAt,
           let probeCeiling {
            let provenCeiling = Int(min(
                Double(configuredTotalRTPBitrateBps),
                Double(probeCeiling),
                availableOutgoingBitrateBps
            ).rounded(.down))
            if provenCeiling > maximumTotalRTPBitrateBps(for: tier) {
                // Preserve observed capacity through the geometry change, not the doubled probe.
                promotionCapacityContinuity = PromotionCapacityContinuity(
                    tier: tier,
                    maximumTotalRTPBitrateBps: provenCeiling,
                    deadline: observedAt.advanced(
                        by: Self.promotionCapacityContinuityDuration
                    )
                )
            }
        }
    }

    private mutating func updatePromotionCapacityContinuity(
        availableOutgoingBitrateBps: Double?,
        isCaptureActive: Bool,
        observedAt: ContinuousClock.Instant
    ) {
        guard var continuity = promotionCapacityContinuity else { return }
        guard isCaptureActive,
              continuity.tier == currentTier,
              observedAt < continuity.deadline,
              let availableOutgoingBitrateBps,
              availableOutgoingBitrateBps.isFinite,
              availableOutgoingBitrateBps > 0 else {
            promotionCapacityContinuity = nil
            return
        }
        let provenCeiling = Int(min(
            Double(configuredTotalRTPBitrateBps),
            availableOutgoingBitrateBps
        ).rounded(.down))
        continuity.maximumTotalRTPBitrateBps = min(
            continuity.maximumTotalRTPBitrateBps,
            provenCeiling
        )
        promotionCapacityContinuity = continuity.maximumTotalRTPBitrateBps
            > maximumTotalRTPBitrateBps(for: currentTier)
            ? continuity
            : nil
    }

    private mutating func finishApplicationLimitedProbe(
        revertingTo originTier: WorldwideScreenVideoAdaptationTier
    ) {
        if applicationLimitedProbeHealthySampleCount
            >= Self.requiredHealthyUpgradeSampleCount,
           let qualifiedTier = applicationLimitedProbeBestQualifiedTier {
            completeApplicationLimitedProbe(committing: qualifiedTier)
        } else {
            failApplicationLimitedProbe(revertingTo: originTier)
        }
    }

    private mutating func revertApplicationLimitedProbeIfActive() {
        guard let applicationLimitedProbeOriginTier else { return }
        if floorRecoveryProbeIsActive {
            floorRecoveryProbeWasCancelled = true
            floorRecoveryProbeSeedBandwidthBps = nil
        }
        currentTier = applicationLimitedProbeOriginTier
        resetQueueEvidenceForTierTransition()
        self.applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
    }

    /// Retains the long exponential backoff for an actually suspended legacy sender, but never
    /// lets stale failure history hide a changed network from a currently visible session for
    /// longer than the active reevaluation window.
    private mutating func consumeApplicationLimitedProbeCooldown(
        isCaptureActive: Bool
    ) -> Bool {
        if isCaptureActive {
            applicationLimitedProbeCooldownSamplesRemaining = min(
                applicationLimitedProbeCooldownSamplesRemaining,
                Self.maximumActiveApplicationLimitedProbeCooldownSampleCount
            )
        }
        guard applicationLimitedProbeCooldownSamplesRemaining > 0 else {
            return false
        }
        applicationLimitedProbeCooldownSamplesRemaining -= 1
        return true
    }

    private mutating func failApplicationLimitedProbe(
        revertingTo originTier: WorldwideScreenVideoAdaptationTier
    ) {
        if floorRecoveryProbeIsActive {
            floorRecoveryProbeWasCancelled = true
            floorRecoveryProbeSeedBandwidthBps = nil
            belowReserveProbeDisprovedSenderLimitation = true
        }
        currentTier = originTier
        resetQueueEvidenceForTierTransition()
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeFailureCount = min(
            applicationLimitedProbeFailureCount + 1,
            Int.bitWidth - 1
        )
        let exponent = min(
            applicationLimitedProbeFailureCount - 1,
            3
        )
        applicationLimitedProbeCooldownSamplesRemaining = min(
            Self.maximumApplicationLimitedProbeCooldownSampleCount,
            Self.initialApplicationLimitedProbeCooldownSampleCount
                * (1 << exponent)
        )
    }

    private mutating func resetApplicationLimitedProbeBackoff() {
        applicationLimitedProbeCooldownSamplesRemaining = 0
        applicationLimitedProbeFailureCount = 0
    }

    private mutating func resetPathMeasurements() {
        floorRecoveryFirstWitness = nil
        if floorRecoveryProbeIsActive {
            floorRecoveryProbeWasCancelled = true
        }
        floorRecoveryProbeSeedBandwidthBps = nil
        capacityProbeSample = nil
        capacityProbeBandwidthHighWatermark = nil
        promotionCapacityContinuity = nil
        healthyUpgradeSampleCount = 0
        bandwidthOnlyDowngradeSampleCount = 0
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
        unavailableBandwidthSampleCount = 0
        positiveBandwidthBootstrapSampleCount = 0
        applicationLimitedUpgradeSampleCount = 0
        applicationLimitedProbeHealthySampleCount = 0
        applicationLimitedProbeGraceSamplesRemaining = 0
        applicationLimitedProbeDeadline = nil
        applicationLimitedProbeOriginTier = nil
        applicationLimitedProbeBestQualifiedTier = nil
        applicationLimitedProbeMaximumTotalRTPBitrateBps = nil
        belowReserveProbeDisprovedSenderLimitation = false
        automaticResumeProbeRestoration = nil
        resetApplicationLimitedProbeBackoff()
        roundTripTimeBaselineSeconds = nil
        roundTripTimeBootstrapSamples = []
        revokeRoundTripTimeHealth()
        permitsInitialRoundTripTimeReference = false
        roundTripTimeReferenceIsProvisional = false
        distinctHealthyRoundTripTimeReferenceCount = 0
        lastOutboundVideoPacketsSent = nil
        lastOutboundVideoTotalPacketSendDelaySeconds = nil
        bandwidthEstimateIsUnavailable = false
        lastSampleHasLatencyPressure = false
        lastSampleHasPositiveSuspensionPressure = false
        lastAveragePacketSendDelaySeconds = nil
    }

    private mutating func resetQueueEvidenceForTierTransition() {
        floorRecoveryFirstWitness = nil
        capacityProbeSample = nil
        capacityProbeBandwidthHighWatermark = nil
        promotionCapacityContinuity = nil
        queuePressureSampleCount = 0
        lastLowDelayPacketQueueObservation = nil
        lastSoftPacketQueuePressureObservation = nil
    }

    private mutating func resetAutomaticSuspensionMeasurements() {
        automaticSuspensionPressureSampleCount = 0
        stableSuspensionResumeProbeSampleCount = 0
        maximumSuspensionResumeProbeSampleCount = 0
    }

    private func validRoundTripTime(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private mutating func revokeRoundTripTimeHealth() {
        nativeRoundTripTimeHealth = .unknown
        roundTripTimeDisposition = .unavailable
    }

    private func isValidRoundTripTimeWatermark(
        _ measurement: WebRTCRoundTripTimeMeasurement
    ) -> Bool {
        let fingerprint = measurement.selectedCandidatePairFingerprint.utf8
        return fingerprint.count == 64
            && fingerprint.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && measurement.totalRoundTripTimeSeconds.isFinite
            && measurement.totalRoundTripTimeSeconds >= 0
    }

    private mutating func consumeRoundTripTimeEvidence(
        current: Double?,
        observation: WebRTCRoundTripTimeObservation?,
        observedAt: ContinuousClock.Instant
    ) -> RoundTripTimeEvidence {
        let unknown = RoundTripTimeEvidence(
            hasFreshPressure: false,
            allowsUpgrade: false,
            permitsLegacyMissingValue: false
        )
        usesNativeRoundTripTimeEvidence = observation != nil
        guard let observation else {
            // Compatibility is explicit and limited to direct legacy/synthetic callers. Actual
            // host snapshots request strict observation handling at the service boundary.
            roundTripTimeDisposition = .legacy
            let inflated = roundTripTimeIsInflated(current)
            if let current { updateRoundTripTimeBaseline(current) }
            return RoundTripTimeEvidence(
                hasFreshPressure: inflated,
                allowsUpgrade: roundTripTimeAllowsUpgrade(current),
                permitsLegacyMissingValue: current == nil
            )
        }

        roundTripTimeObservationAge = lastRoundTripTimeAdvancement.map {
            $0.duration(to: observedAt)
        }
        guard case let .measurement(measurement) = observation,
              isValidRoundTripTimeWatermark(measurement) else {
            // Never forget the consumed watermark: missing metadata followed by the same old
            // measurement cannot revive health or apply the same pressure a second time.
            if let fence = roundTripTimeObservationFence {
                roundTripTimeWatermark = fence.measurement
                permitsInitialRoundTripTimeReference = false
            }
            revokeRoundTripTimeHealth()
            return unknown
        }

        let previousFence = roundTripTimeObservationFence
        roundTripTimeObservationFence = RoundTripTimeObservationFence(
            measurement: measurement,
            current: current
        )
        if let previousFence {
            let replacedPair = measurement.selectedCandidatePairFingerprint
                != previousFence.measurement.selectedCandidatePairFingerprint
            let regressed = measurement.totalRoundTripTimeSeconds
                    < previousFence.measurement.totalRoundTripTimeSeconds
                || measurement.responsesReceived
                    < previousFence.measurement.responsesReceived
            let contradictoryScalar = measurement == previousFence.measurement
                && current != previousFence.current
            if replacedPair || regressed || contradictoryScalar {
                roundTripTimeWatermark = measurement
                permitsInitialRoundTripTimeReference = false
                revokeRoundTripTimeHealth()
                roundTripTimeDisposition = contradictoryScalar ? .unavailable : .reseeded
                if replacedPair {
                    roundTripTimeBaselineSeconds = nil
                    roundTripTimeBootstrapSamples = []
                    distinctHealthyRoundTripTimeReferenceCount = 0
                    roundTripTimeReferenceIsProvisional = false
                }
                return unknown
            }
        }

        let previous = roundTripTimeWatermark
        let isFirstForPeer = previous == nil && permitsInitialRoundTripTimeReference
        permitsInitialRoundTripTimeReference = false
        roundTripTimeWatermark = measurement

        if let previous {
            let replacedPair = measurement.selectedCandidatePairFingerprint
                != previous.selectedCandidatePairFingerprint
            let regressed = measurement.totalRoundTripTimeSeconds
                    < previous.totalRoundTripTimeSeconds
                || measurement.responsesReceived < previous.responsesReceived
            if replacedPair || regressed {
                // Every pair change is a seed, including A -> B -> A. Counter resets also seed
                // unknown; neither event is a newly measured ping merely because values differ.
                revokeRoundTripTimeHealth()
                roundTripTimeDisposition = .reseeded
                if replacedPair {
                    roundTripTimeBaselineSeconds = nil
                    roundTripTimeBootstrapSamples = []
                    distinctHealthyRoundTripTimeReferenceCount = 0
                    roundTripTimeReferenceIsProvisional = false
                }
                return unknown
            }
        } else if !isFirstForPeer {
            revokeRoundTripTimeHealth()
            roundTripTimeDisposition = .reseeded
            return unknown
        }

        // Even with valid counters, missing/zero/non-finite/inconsistent scalar RTT is not health.
        // Consume its watermark so reusing it with a repaired scalar still requires advancement.
        guard let current,
              measurement.totalRoundTripTimeSeconds >= current,
              roundTripTimeObservationAge.map({ $0 >= .zero }) ?? true else {
            revokeRoundTripTimeHealth()
            return unknown
        }
        let advanced = previous.map {
            measurement.totalRoundTripTimeSeconds > $0.totalRoundTripTimeSeconds
                || measurement.responsesReceived > $0.responsesReceived
        } ?? isFirstForPeer
        guard advanced else {
            guard current == lastMeasuredRoundTripTimeSeconds else {
                // A changed scalar without a changed native watermark is contradictory, not a
                // new ping. Revoke retained health without minting another RTT penalty.
                revokeRoundTripTimeHealth()
                return unknown
            }
            switch nativeRoundTripTimeHealth {
            case .healthy:
                guard let age = roundTripTimeObservationAge,
                      age <= Self.roundTripTimeObservationValidity else {
                    nativeRoundTripTimeHealth = .unknown
                    roundTripTimeDisposition = .expired
                    return unknown
                }
                roundTripTimeDisposition = .retainedHealthy
                return RoundTripTimeEvidence(
                    hasFreshPressure: false,
                    allowsUpgrade: true,
                    permitsLegacyMissingValue: false
                )
            case .inflated:
                roundTripTimeDisposition = .retainedInflated
            case .unknown:
                roundTripTimeDisposition = .unavailable
            }
            return unknown
        }

        lastRoundTripTimeAdvancement = observedAt
        lastMeasuredRoundTripTimeSeconds = current
        roundTripTimeObservationAge = .zero
        if roundTripTimeBaselineSeconds == nil {
            // One explicitly provisional reference avoids waiting for three 2.5-second ICE
            // pings before startup. Fresh queue and consecutive qualified BWE reports remain
            // mandatory for the existing raised-cap probe; this is not extra capacity evidence.
            roundTripTimeBaselineSeconds = current
            roundTripTimeBootstrapSamples = []
            distinctHealthyRoundTripTimeReferenceCount = 1
            roundTripTimeReferenceIsProvisional = true
        } else if !roundTripTimeIsInflated(current) {
            updateRoundTripTimeBaseline(current)
            distinctHealthyRoundTripTimeReferenceCount = min(
                Self.roundTripTimeBootstrapSampleCount,
                distinctHealthyRoundTripTimeReferenceCount + 1
            )
            roundTripTimeReferenceIsProvisional = distinctHealthyRoundTripTimeReferenceCount
                < Self.roundTripTimeBootstrapSampleCount
        }
        let inflated = roundTripTimeIsInflated(current)
        nativeRoundTripTimeHealth = inflated ? .inflated : .healthy
        roundTripTimeDisposition = inflated
            ? .freshInflated
            : (isFirstForPeer ? .provisionalHealthy : .freshHealthy)
        return RoundTripTimeEvidence(
            hasFreshPressure: inflated,
            allowsUpgrade: !inflated,
            permitsLegacyMissingValue: false
        )
    }

    private mutating func updateRoundTripTimeBaseline(_ current: Double) {
        guard let baseline = roundTripTimeBaselineSeconds else {
            roundTripTimeBootstrapSamples.append(current)
            guard roundTripTimeBootstrapSamples.count
                    >= Self.roundTripTimeBootstrapSampleCount else {
                return
            }
            roundTripTimeBaselineSeconds = roundTripTimeBootstrapSamples
                .sorted()[roundTripTimeBootstrapSamples.count / 2]
            roundTripTimeBootstrapSamples = []
            return
        }
        if current < baseline {
            roundTripTimeBaselineSeconds = max(
                current,
                baseline - Self.maximumRoundTripTimeBaselineFallPerSample
            )
        }
    }

    private func roundTripTimeIsInflated(_ current: Double?) -> Bool {
        guard let current,
              let roundTripTimeBaselineSeconds else {
            return false
        }
        let inflationThreshold = max(
            roundTripTimeBaselineSeconds
                * Self.roundTripTimeRelativeInflationMultiplier,
            roundTripTimeBaselineSeconds
                + Self.roundTripTimeAbsoluteInflationSeconds
        )
        return current > inflationThreshold
    }

    private func roundTripTimeAllowsUpgrade(_ current: Double?) -> Bool {
        guard let current,
              let roundTripTimeBaselineSeconds else {
            return false
        }
        let inflationThreshold = max(
            roundTripTimeBaselineSeconds
                * Self.roundTripTimeRelativeInflationMultiplier,
            roundTripTimeBaselineSeconds
                + Self.roundTripTimeAbsoluteInflationSeconds
        )
        return current <= inflationThreshold
    }

    private func isFreshPacketQueueObservation(
        _ observation: ContinuousClock.Instant,
        at observedAt: ContinuousClock.Instant
    ) -> Bool {
        let age = observation.duration(to: observedAt)
        return age >= .zero
            && age <= Self.lowDelayPacketQueueObservationValidity
    }

    private mutating func packetQueueObservationSinceLastSample(
        packetsSent: UInt64?,
        totalPacketSendDelaySeconds: Double?
    ) -> PacketQueueObservation {
        guard let packetsSent,
              let totalPacketSendDelaySeconds,
              totalPacketSendDelaySeconds.isFinite,
              totalPacketSendDelaySeconds >= 0 else {
            lastOutboundVideoPacketsSent = nil
            lastOutboundVideoTotalPacketSendDelaySeconds = nil
            return .unavailableOrReset
        }
        defer {
            lastOutboundVideoPacketsSent = packetsSent
            lastOutboundVideoTotalPacketSendDelaySeconds =
                totalPacketSendDelaySeconds
        }
        guard let previousPackets = lastOutboundVideoPacketsSent,
              let previousDelay =
                lastOutboundVideoTotalPacketSendDelaySeconds else {
            return .unavailableOrReset
        }
        guard packetsSent >= previousPackets,
              totalPacketSendDelaySeconds >= previousDelay else {
            return .unavailableOrReset
        }
        guard packetsSent > previousPackets else {
            return totalPacketSendDelaySeconds == previousDelay
                ? .noNewPackets
                : .unavailableOrReset
        }
        return .measured(
            (totalPacketSendDelaySeconds - previousDelay)
                / Double(packetsSent - previousPackets)
        )
    }
}
