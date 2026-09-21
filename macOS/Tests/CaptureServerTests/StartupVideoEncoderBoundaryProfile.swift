#if os(macOS)
@testable import WebRTCTransport

/// Encoder tracing observes the existing recovery workload; it cannot select another arm.
enum StartupVideoEncoderBoundaryProfile {
    static func validate(
        durationMilliseconds: Int,
        bitsPerSecond: UInt64,
        oneWayDelayMilliseconds: Int?,
        followsPolicyFPS: Bool,
        movingContent: Bool,
        warmupMilliseconds: Int,
        shapeInitialCapture: Bool,
        capacityDropAndRecovery: Bool,
        spatialRecoveryEnabled: Bool,
        requiresSpatialRecovery: Bool,
        secondCapacityDrop: Bool,
        collectTrafficTiming: Bool,
        collectReceiverTiming: Bool,
        pacerMode: StartupVideoPacerMode?,
        pacingFactor: Double?,
        observeEstimator: Bool,
        holdDelayGrowthInALR: Bool,
        skipProbesBelowCurrentEstimate: Bool,
        hasOtherObserver: Bool
    ) throws {
        guard durationMilliseconds == 15 else {
            throw WebRTCTransportError.nativeFailure("Encoder boundary tracing requires the control15 recovery profile")
        }
        try StartupVideoProbeDurationMovingRecoveryProfile.validate(
            durationMilliseconds: durationMilliseconds,
            bitsPerSecond: bitsPerSecond,
            oneWayDelayMilliseconds: oneWayDelayMilliseconds,
            followsPolicyFPS: followsPolicyFPS,
            movingContent: movingContent,
            warmupMilliseconds: warmupMilliseconds,
            shapeInitialCapture: shapeInitialCapture,
            capacityDropAndRecovery: capacityDropAndRecovery,
            spatialRecoveryEnabled: spatialRecoveryEnabled,
            requiresSpatialRecovery: requiresSpatialRecovery,
            secondCapacityDrop: secondCapacityDrop,
            collectTrafficTiming: collectTrafficTiming,
            collectReceiverTiming: collectReceiverTiming,
            pacerMode: pacerMode,
            pacingFactor: pacingFactor,
            observeEstimator: observeEstimator,
            holdDelayGrowthInALR: holdDelayGrowthInALR,
            skipProbesBelowCurrentEstimate: skipProbesBelowCurrentEstimate,
            hasOtherObserver: hasOtherObserver)
    }
}
#endif
