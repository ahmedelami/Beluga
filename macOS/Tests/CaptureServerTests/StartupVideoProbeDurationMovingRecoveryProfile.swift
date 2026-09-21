#if os(macOS)
@testable import WebRTCTransport

/// Admission for the separately named moving-recovery duration pair. These flags
/// select the existing 16-second branch with a drop at 4s and restore at 8s.
/// This is not a runtime timing witness or permission to alter the weak/delayed fixtures.
enum StartupVideoProbeDurationMovingRecoveryProfile {
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
              bitsPerSecond == 8_000_000,
              oneWayDelayMilliseconds == 2,
              followsPolicyFPS, movingContent,
              warmupMilliseconds == 0,
              !shapeInitialCapture, capacityDropAndRecovery,
              spatialRecoveryEnabled, requiresSpatialRecovery, !secondCapacityDrop,
              collectTrafficTiming, collectReceiverTiming,
              pacerMode == .sdkDefault, pacingFactor == 1,
              observeEstimator, holdDelayGrowthInALR, skipProbesBelowCurrentEstimate,
              !hasOtherObserver else {
            throw WebRTCTransportError.nativeFailure(
                "Probe duration requires the exact isolated 15/40 ms moving-recovery profile")
        }
    }
}
#endif
