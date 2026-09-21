#if os(macOS)
@testable import WebRTCTransport

/// Admission for the separately named moving-weak duration pair. These flags
/// select the existing fixture's 12-second policy-following branch; this is not
/// a runtime timing witness or permission to modify the delayed nil experiment.
enum StartupVideoProbeDurationMovingWeakProfile {
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
        guard [15, 40].contains(durationMilliseconds),
              bitsPerSecond == 800_000,
              oneWayDelayMilliseconds == 2,
              followsPolicyFPS, movingContent,
              warmupMilliseconds == 0,
              !shapeInitialCapture, !capacityDropAndRecovery,
              spatialRecoveryEnabled, !requiresSpatialRecovery, !secondCapacityDrop,
              collectTrafficTiming, collectReceiverTiming,
              pacerMode == .sdkDefault, pacingFactor == 1,
              observeEstimator, holdDelayGrowthInALR, skipProbesBelowCurrentEstimate,
              !hasOtherObserver else {
            throw WebRTCTransportError.nativeFailure(
                "Probe duration requires the exact isolated 15/40 ms moving-weak profile")
        }
    }
}
#endif
