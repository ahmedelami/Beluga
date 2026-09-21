#!/bin/bash
set -euo pipefail
exec /usr/bin/ruby - "$0" "$@" <<'RUBY'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

abort 'usage: scripts/test-validate-screen-startup.sh' unless ARGV.length == 1
abort 'runner self-tests require Darwin/macOS' unless RUBY_PLATFORM.include?('darwin')
source = File.join(File.dirname(File.realpath(ARGV.shift)), 'validate-screen-startup.sh')
runner_source = File.read(source)
required = runner_source[/REQUIRED_CLASSES = %w\[(.*?)\]/m, 1].split
pinned_methods = runner_source[/REQUIRED_METHODS = %w\[(.*?)\]/m, 1].split
native = runner_source[/NATIVE_METHODS = %w\[(.*?)\]/m, 1].split
capacity = runner_source[/CAPACITY_METHODS = %w\[(.*?)\]/m, 1].split
spatial_recovery = runner_source[/SPATIAL_RECOVERY_METHODS = %w\[(.*?)\]/m, 1].split
raise 'invariant sequence class is absent from the gate' unless required.include?('CaptureServerTests.WorldwideScreenStartupInvariantSequenceTests')
raise 'estimator snapshot class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoNativeEstimatorSnapshotTests')
raise 'probe duration witness class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoProbeDurationWitnessTests')
raise 'probe duration moving-weak profile class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests')
raise 'probe duration moving-recovery profile class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests')
raise 'encoder boundary trace class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoEncoderBoundaryTraceTests')
raise 'encoder boundary profile class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoEncoderBoundaryProfileTests')
raise 'native encoder log observer class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoNativeEncoderLogObserverTests')
raise 'QP hook admission class is absent from the gate' unless required.include?('CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests')
raise 'expected the two explicit native methods' unless native.length == 2
raise 'estimator diagnostic entered the ordinary native gate' if native.any? { |id| id.include?('Estimator') }
raise 'expected five distinct spatial recovery methods' unless spatial_recovery.length == 5 && spatial_recovery.uniq.length == 5

def assert(condition, message)
  raise message unless condition
end

Dir.mktmpdir('startup-runner-selftest-') do |temporary|
  root = File.join(temporary, 'repository')
  FileUtils.mkdir_p(File.join(root, 'scripts'))
  FileUtils.mkdir_p(File.join(root, 'shared/Sources/WebRTCTransport'))
  runner = File.join(root, 'scripts/validate-screen-startup.sh')
  FileUtils.cp(source, runner)
  File.write(File.join(root, 'Package.swift'), '// fixture manifest; never compiled\n')
  mutable_source = File.join(root, 'shared/Sources/WebRTCTransport/Fixture.swift')
  File.write(mutable_source, '// source identity fixture\n')
  developer = File.join(temporary, 'Reviewed Xcode.app/Contents/Developer')
  swift = File.join(developer, 'Toolchains/XcodeDefault.xctoolchain/usr/bin/swift')
  FileUtils.mkdir_p(File.dirname(swift))
  FileUtils.mkdir_p(File.join(developer, 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'))
  extra = 'CaptureServerTests.WorldwideScreenStartupAdditionalRegressionTests/testFutureCoverage'
  unrelated = 'CaptureServerTests.UnrelatedTests/testNotSelected'
  observer_native = %w[
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverConstruction
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorObserverWeak
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldWeak
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldDisabledRecovery
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldEnabledRecovery
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldSecondDrop
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRGrowthHoldAmple
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapWeak
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapDisabledRecovery
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapEnabledRecovery
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapSecondDrop
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeCapAmple
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15DelayedControl
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40DelayedCandidate
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingWeakControl
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingWeakCandidate
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration15MovingRecoveryControl
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate
    CaptureServerTests.WebRTCStartupClarityExperimentTests/testNativeEncoderBoundaryMovingRecoveryDiagnostic
  ]
  all_methods = required.map { |class_name| class_name + '/testFixture' } + pinned_methods + native + capacity + spatial_recovery + observer_native + [extra, unrelated]
  manifest = File.join(temporary, 'fake-methods.json')
  File.write(manifest, JSON.generate(all_methods))
  File.write(swift, <<~'FAKE')
    #!/usr/bin/ruby
    require 'json'
    mode = ENV.fetch('STARTUP_GATE_FAKE_MODE')
    trace = ENV.fetch('STARTUP_GATE_FAKE_TRACE')
    File.open(trace, 'a') { |file| file.puts JSON.generate(pid: Process.pid, argv: ARGV, native: ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT']) }
    methods = JSON.parse(File.read(ENV.fetch('STARTUP_GATE_FAKE_MANIFEST')))
    if ARGV.include?('--list-tests')
      sleep 5 if mode == 'timeout'
      exit 7 if mode == 'compile_failure'
      exit 0 if mode == 'no_match'
      methods.reject! { |id| id.include?('InvariantSequenceTests') } if mode == 'missing_class'
      methods.reject! { |id| id.include?('StartupVideoNativeEstimatorSnapshotTests') } if mode == 'missing_estimator_class'
      methods.reject! { |id| id.start_with?('CaptureServerTests.StartupVideoProbeDurationWitnessTests/') } if mode == 'missing_probe_duration_class'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testBothDurationsVerifyInitialRequestedByteBudgetsAndRoundTrip' } if mode == 'missing_probe_duration_budget_roundtrip'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testMissingInitialRequestsCannotVerify' } if mode == 'missing_probe_duration_initial_requests'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testLaterMatchingRequestsCannotReplaceTheFirstTwo' } if mode == 'missing_probe_duration_first_pair'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testWrongInitialIDsRatesCountsAndByteBudgetsFail' } if mode == 'missing_probe_duration_budget_fields'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testMissingCreatedPayloadCannotBorrowValues' } if mode == 'missing_probe_duration_payload'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testOnlyFifteenAndFortyMillisecondsAreAdmitted' } if mode == 'missing_probe_duration_domain'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testExistingHostClockAndNativeFailureFencesRemainRequired' } if mode == 'missing_probe_duration_native_fences'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationWitnessTests/testProbeFailureResultsDoNotInvalidateRequestedBudgetWitness' } if mode == 'missing_probe_duration_request_not_delivery'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationCompositionPreservesControlAndAddsOnlyFortyMilliseconds' } if mode == 'missing_probe_duration_composition'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationRequiresAllHeldObserverFlagsAndControlBeforeReservation' } if mode == 'missing_probe_duration_flags'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationRejectsPreexistingConfigurationAndBehaviorOverrides' } if mode == 'missing_probe_duration_trial_conflicts'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationOptInRequiresMatchingExactArmAndNoBorrowedSelection' } if mode == 'missing_probe_duration_selection'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationOptInRetainsProcessAndEnvironmentGates' } if mode == 'missing_probe_duration_process'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationReservationPreservesTokenTopologyAndRetirement' } if mode == 'missing_probe_duration_topology'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRequireMatchingArm' } if mode == 'missing_probe_duration_weak_selection'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRejectLegacyAndMultipleSelections' } if mode == 'missing_probe_duration_weak_isolation'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRequireCompleteFlagsAndOwnCohort' } if mode == 'missing_probe_duration_weak_flags'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRequireMatchingArm' } if mode == 'missing_probe_duration_recovery_selection'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRejectLegacyAndMultipleSelections' } if mode == 'missing_probe_duration_recovery_isolation'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRequireCompleteFlagsAndOwnCohort' } if mode == 'missing_probe_duration_recovery_flags'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoPacerBridgeTests/testProbeDurationRequiresExactDurationAndAllFlagsBeforeLoading' } if mode == 'missing_probe_duration_loader_flags'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoPacerBridgeTests/testProbeDurationCannotBypassArtifactDigestValidation' } if mode == 'missing_probe_duration_loader_digest'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoDefaultPacingProfileTests/testProbeDurationArmsPreserveOriginalDelayedWorkloadWithoutBorrowingCohorts' } if mode == 'missing_probe_duration_profile'
      methods.reject! { |id| id.start_with?('CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/') } if mode == 'missing_probe_duration_weak_profile_class'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testBothDurationArmsAcceptOnlyTheFixedMovingWeakProfile' } if mode == 'missing_probe_duration_weak_profile_acceptance'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testEveryBooleanProfileDriftIsRejectedIndependently' } if mode == 'missing_probe_duration_weak_profile_booleans'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testNumericAndOptionalProfileDriftIsRejectedIndependently' } if mode == 'missing_probe_duration_weak_profile_bounds'
      methods.reject! { |id| id.start_with?('CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/') } if mode == 'missing_probe_duration_recovery_profile_class'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testBothDurationArmsAcceptOnlyTheFixedMovingRecoveryProfile' } if mode == 'missing_probe_duration_recovery_profile_acceptance'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testEveryBooleanProfileDriftIsRejectedIndependently' } if mode == 'missing_probe_duration_recovery_profile_booleans'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testNumericAndOptionalProfileDriftIsRejectedIndependently' } if mode == 'missing_probe_duration_recovery_profile_bounds'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testTransparentEncoderCallsAndScalarSnapshotRoundTrip' } if mode == 'missing_encoder_trace_transparency'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFactoryOptionalCapabilitiesAndNilCreationArePreserved' } if mode == 'missing_encoder_trace_optional_factory'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFactoryWithoutOptionalMethodsDoesNotInventCapabilities' } if mode == 'missing_encoder_trace_absent_factory'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testOwnerAndArmAreSingleUseAndRequireValidClocks' } if mode == 'missing_encoder_trace_owner'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFixedWindowKeepsPreCaptureMetadataButExcludesFrameEdges' } if mode == 'missing_encoder_trace_window'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCapacityIsBoundedWithoutChangingForwarding' } if mode == 'missing_encoder_trace_capacity'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testInvalidAndRegressingClocksCannotCreateEvidence' } if mode == 'missing_encoder_trace_clock'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testLateCallbacksCannotBorrowReplacementRegistrationOrEncoder' } if mode == 'missing_encoder_trace_generation'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testSynchronousCallbackReentryPreservesReturnsAndNil' } if mode == 'missing_encoder_trace_reentry'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testNonzeroNativeResultsAndSuppressedOutputsRemainDiagnostics' } if mode == 'missing_encoder_trace_native_results'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testMalformedPayloadCannotBecomeEvidence' } if mode == 'missing_encoder_trace_payload'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testOnlyControl15AcceptsTheFixedMovingRecoveryProfile' } if mode == 'missing_encoder_profile_duration'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testEveryBooleanWorkloadDriftIsRejected' } if mode == 'missing_encoder_profile_booleans'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testNumericAndOptionalWorkloadDriftIsRejected' } if mode == 'missing_encoder_profile_numeric'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRequiresOwnControl15Selection' } if mode == 'missing_encoder_admission_selection'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRejectsLegacyMultipleAndCrossedSelections' } if mode == 'missing_encoder_admission_isolation'
      methods.reject! { |id| id == 'WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRequiresCompleteFlagsAndProcessOptIn' } if mode == 'missing_encoder_admission_flags'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testParsesExactDropFailureAndPropertyFormats' } if mode == 'missing_encoder_native_log_formats'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testHardwareAndLowLatencyMessagesRetainOnlyAllowedEnums' } if mode == 'missing_encoder_native_log_configuration'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testRejectsWrongSourceMalformedTrailingAndOversizedMessages' } if mode == 'missing_encoder_native_log_allowlist'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testNumericNativeWidthsAndZeroAutomaticValuesAreExact' } if mode == 'missing_encoder_native_log_numbers'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testFixedWindowKeepsPreArmConfigurationWithoutPreArmFrameEvidence' } if mode == 'missing_encoder_native_log_window'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testArmIsSingleUseAndRejectsInvalidOrOverflowingWindows' } if mode == 'missing_encoder_native_log_arm'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testCapacityRetainsFirst512EventsAndCumulativeOverflow' } if mode == 'missing_encoder_native_log_capacity'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testInvalidRegressingClocksAndMissingThreadRejectEvidenceButTiesRemainValid' } if mode == 'missing_encoder_native_log_clock'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testProcessScopedSnapshotRoundTripsWithoutRawTextAndNativeErrorsRemainObservations' } if mode == 'missing_encoder_native_log_scope'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testFinishRetiresAdmissionWithoutMintingPositiveEventPresence' } if mode == 'missing_encoder_native_log_retirement'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCallbackReceivedDuringReleaseRetainsOriginalInputIdentity' } if mode == 'missing_encoder_trace_during_release'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCallbackReceivedAfterReleaseRetainsOriginalInputIdentity' } if mode == 'missing_encoder_trace_after_release'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testInvalidationDuringCallbackRetainsOldAndCurrentGenerations' } if mode == 'missing_encoder_trace_during_callback'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testRejectedObservationsRespectClockCapacityAndRetirement' } if mode == 'missing_encoder_trace_rejected_bounds'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainCrossThreadCallbackPreservesOriginalOwnership' } if mode == 'missing_drain_cross_thread'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRejectsWrongRegistrationAndOtherEncoderIdentity' } if mode == 'missing_drain_wrong_owner'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRejectsConsumedUnknownAndDuplicateInputs' } if mode == 'missing_drain_consumed'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRequiresSuccessfulRecordedEncodeReturn' } if mode == 'missing_drain_success'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainLeaseRevokedByLifecycleBeforeOutput' } if mode == 'missing_drain_lifecycle'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainCallbackReturnRejectsLifecycleReentry' } if mode == 'missing_drain_return'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testActiveCallbackCannotBorrowReleaseDrainReturnAuthority' } if mode == 'missing_drain_active'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testDefaultPathDoesNotLoadOrCreateHook' } if mode == 'missing_qp_default'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testOtherFixturesCannotRequestHook' } if mode == 'missing_qp_fixture'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingStartupOptInIsRejectedBeforeLoading' } if mode == 'missing_qp_startup'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingPacerOptInIsRejectedBeforeLoading' } if mode == 'missing_qp_pacer'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testUnknownArmIsRejectedBeforeLoading' } if mode == 'missing_qp_arm'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingSealedPreloadedArtifactIsRejected' } if mode == 'missing_qp_seal'
      methods.reject! { |id| id == 'CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testStartupArmRequiresSameEligibilityAndPreloadedSeal' } if mode == 'missing_qp_startup_arm'
      methods.reject! { |id| id.include?('testShowKeepsExistingTrafficCeilingsButStartsWithFullPixels') } if mode == 'missing_method'
      methods.reject! { |id| id.include?('testConfiguredCapAndSourceFPSMatrixGivesUncertaintyNoAuthority') } if mode == 'missing_sequence_method'
      methods.reject! { |id| id.include?('testExactlyTwoAdvancingDelayEventsCannotVerify') } if mode == 'missing_estimator_method'
      methods.reject! { |id| id.include?('testProbeOnlyEventsAndProbeAfterTwoDelaySamplesCannotVerify') } if mode == 'missing_probe_witness_method'
      methods.reject! { |id| id.include?('testALRRequiresMembershipAndForbidsEvenZeroBitrate') } if mode == 'missing_alr_payload_method'
      methods.reject! { |id| id.include?('testSynchronousReentryCannotReuseFactoryHookBeforeRetirement') } if mode == 'missing_hook_reentry_method'
      methods.reject! { |id| id.include?('testEstimatorOptInCannotBorrowAnOrdinaryFactorTestSelection') } if mode == 'missing_estimator_admission_method'
      methods.reject! { |id| id.include?('testDelayedBaselineObserverCannotBorrowHoldOrProbeCapAdmission') } if mode == 'missing_baseline_estimator_admission'
      methods.reject! { |id| id.include?('testParsesOptionalReceiverDiagnosticsOnlyFromInboundVideo') } if mode == 'missing_receiver_inbound_parser'
      methods.reject! { |id| id.include?('testRetirementRejectsLateCompletionEvenWhenCollectorIgnoresCancellation') } if mode == 'missing_receiver_retirement'
      methods.reject! { |id| id.include?('testFinalCollectionDrainsAndRetiresDiagnosticRequestFirst') } if mode == 'missing_receiver_final_drain'
      methods.reject! { |id| id.include?('testDefaultPacingCohortRequiresItsOwnSelectionAndExactPairedFlags') } if mode == 'missing_default_pacing_admission'
      methods.reject! { |id| id.include?('testDelayedProfilesRejectCapacityWorkloadAndCadenceOrDelayDrift') } if mode == 'missing_default_pacing_profile'
      methods.reject! { |id| id.include?('testRecordedTransientLowCapacityRetainsAcceptedSurvivalPixelsUntilProbeExpiryAndRebound') } if mode == 'missing_transient_pressure_replay'
      methods.reject! { |id| id.include?('testPersistentLowCapacityAfterProbeExpiryRetiresAcceptedSurvivalPixels') } if mode == 'missing_persistent_pressure_replay'
      methods.reject! { |id| id.include?('testIndependentPressureDuringAcceptedSurvivalProbeRequiresFreshEvidence') } if mode == 'missing_independent_pressure_replay'
      methods.reject! { |id| id.include?('testALRGrowthHoldOptInRequiresItsOwnExactObserverSelection') } if mode == 'missing_alr_hold_selection'
      methods.reject! { |id| id.include?('testALRGrowthHoldRequiresObserverAndControlBeforeReservation') } if mode == 'missing_alr_hold_admission'
      methods.reject! { |id| id.include?('testALRProbeCapOptInRequiresItsOwnExactHeldObserverSelection') } if mode == 'missing_alr_probe_cap_selection'
      methods.reject! { |id| id.include?('testALRProbeCapRequiresHoldObserverAndControlBeforeReservation') } if mode == 'missing_alr_probe_cap_admission'
      methods.reject! { |id| id.include?('testAllSameMillisecondPairsCannotSupplyThreeIndependentMatches') } if mode == 'missing_pacing_distinct_clock'
      methods.reject! { |id| id.include?('testSameMillisecondContradictionRejectsEvenWithThreeDistinctMatches') } if mode == 'missing_pacing_tied_contradiction'
      methods.reject! { |id| id.include?('testDelayedChildCannotReuseFactoryHookAfterSuccessfulConstruction') } if mode == 'missing_hook_lifetime_method'
      methods.reject! { |id| id.include?('testDelayedNetworkBlackout') } if mode == 'missing_native'
      methods.reject! { |id| id.include?('testSerializedWeakColdStill') } if mode == 'missing_capacity'
      methods.reject! { |id| id.include?('testSpatialRecoveryEnabledMovingSecondCapacityDrop') } if mode == 'missing_spatial_recovery'
      if mode == 'source_change'
        File.open(ENV.fetch('STARTUP_GATE_FAKE_SOURCE'), 'a') { |file| file.puts '// changed while compiling' }
      end
      puts methods
      exit 0
    end
    filter = Regexp.new(ARGV.fetch(ARGV.index('--filter') + 1))
    selected = methods.select { |id| filter.match?(id) }
    native = selected.any? { |id| id.include?('WebRTCStartupClarityExperimentTests/') }
    spatial_recovery = selected.any? { |id| id.include?('/testSpatialRecovery') }
    exit 9 if mode == 'spatial_recovery_nonzero' && spatial_recovery
    exit 8 if mode == 'nonzero' || (mode == 'native_nonzero' && native)
    exit 0 if mode == 'false_green'
    if mode.start_with?('log_')
      if mode == 'log_swift_testing_only'
        puts '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
        exit 0
      end
      selected = [] if mode == 'log_no_cases'
      selected = selected.drop(1) if mode == 'log_omitted_case'
      selected << selected.first if mode == 'log_duplicate'
      selected << methods.find { |id| id.include?('UnrelatedTests/') } if mode == 'log_unexpected'
      puts "Test Suite 'Selected tests' started at 2026-09-19 11:20:48.308."
      selected.each_with_index do |id, index|
        class_name, name = id.split('/')
        prefix = "Test Case '-[#{class_name} #{name}]'"
        puts "#{prefix} started." unless mode == 'log_missing_start' && index.zero?
        skipped = native && (mode == 'log_skipped_native' || ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT'] != '1')
        state = skipped ? 'skipped' : mode == 'log_failed' ? 'failed' : 'passed'
        state = 'unrecognized' if mode == 'log_unrecognized_case'
        puts "#{prefix} #{state} (0.001 seconds)." unless mode == 'log_unfinished_case' && index == selected.length - 1
      end
      unless mode == 'log_missing_suite_end'
        repetitions = mode == 'log_duplicate_footer' ? 2 : 1
        repetitions.times do
          puts "Test Suite 'Selected tests' passed at 2026-09-19 11:20:52.295."
          next if mode == 'log_truncated_footer'
          count = selected.length + (mode == 'log_wrong_count' ? 1 : 0)
          skipped = mode == 'log_skipped_summary' ? '1 test skipped and ' : ''
          failures = mode == 'log_failed_summary' ? '1' : '0'
          puts "\t Executed #{count} tests, with #{skipped}#{failures} failures (0 unexpected) in 3.975 (3.987) seconds"
        end
      end
      if mode == 'log_case_after_footer'
        class_name, name = selected.first.split('/')
        puts "Test Case '-[#{class_name} #{name}]' started."
      end
      puts 'NATIVE_FIXTURE_DIAGNOSTIC scalar=1'
      puts '✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.'
      exit(mode == 'log_nonzero' ? 8 : 0)
    end
    selected = [] if (mode == 'empty_native' && native) || (mode == 'empty_spatial_recovery' && spatial_recovery)
    selected = selected.drop(1) if mode == 'omitted_case' && !native
    selected << selected.first if mode == 'duplicate_results'
    selected << methods.find { |id| id.include?('UnrelatedTests/') } if mode == 'unexpected_result'
    xml = ARGV.fetch(ARGV.index('--xunit-output') + 1)
    File.open(xml, 'w') do |file|
      file.puts '<testsuites><testsuite>'
      selected.each do |id|
        class_name, name = id.split('/')
        file.puts %Q{<testcase classname="#{class_name}" name="#{name}">}
        skipped = native && (mode == 'skipped_native' || ENV['OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT'] != '1')
        skipped ||= mode == 'skipped_default' && !native
        skipped ||= mode == 'skipped_spatial_recovery' && spatial_recovery
        file.puts '<skipped message="required opt-in absent"/>' if skipped
        file.puts '<failure message="fixture failure"/>' if mode == 'xml_failure'
        file.puts '</testcase>'
      end
      file.puts '</testsuite></testsuites>'
    end
  FAKE
  FileUtils.chmod(0755, swift)
  cases = 0
  run = lambda do |mode, native_enabled: false, expected_failure: nil, extra_args: [], omit_developer: false, scratch: nil, jobs: '2', inherited_native: '1'|
    cases += 1
    scratch ||= File.join(temporary, "scratch-#{cases}")
    trace = File.join(temporary, "trace-#{cases}.jsonl")
    environment = {
      'DEVELOPER_DIR' => omit_developer ? nil : developer,
      'STARTUP_GATE_FAKE_MODE' => mode,
      'STARTUP_GATE_FAKE_TRACE' => trace,
      'STARTUP_GATE_FAKE_MANIFEST' => manifest,
      'STARTUP_GATE_FAKE_SOURCE' => mutable_source,
      'OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT' => inherited_native,
    }
    args = ['/bin/bash', runner, '--scratch-path', scratch, '--jobs', jobs]
    args << '--native' if native_enabled
    output, status = Open3.capture2e(environment, *(args + extra_args))
    if expected_failure
      assert(!status.success?, "#{mode} unexpectedly passed: #{output}")
      assert(output.include?(expected_failure), "#{mode} lacked expected rejection #{expected_failure.inspect}: #{output}")
    else
      assert(status.success? && output.include?('screen-startup: PASS'), "#{mode} failed: #{output}")
    end
    calls = File.file?(trace) ? File.readlines(trace).map { |line| JSON.parse(line) } : []
    [calls, scratch, output]
  end

  run.call('no_match', expected_failure: 'empty selected test discovery')
  run.call('missing_class', expected_failure: 'required test class missing')
  run.call('missing_estimator_class', expected_failure: 'required test class missing from discovery: CaptureServerTests.StartupVideoNativeEstimatorSnapshotTests')
  run.call('missing_probe_duration_class', expected_failure: 'required test class missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests')
  run.call('missing_probe_duration_budget_roundtrip', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testBothDurationsVerifyInitialRequestedByteBudgetsAndRoundTrip')
  run.call('missing_probe_duration_initial_requests', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testMissingInitialRequestsCannotVerify')
  run.call('missing_probe_duration_first_pair', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testLaterMatchingRequestsCannotReplaceTheFirstTwo')
  run.call('missing_probe_duration_budget_fields', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testWrongInitialIDsRatesCountsAndByteBudgetsFail')
  run.call('missing_probe_duration_payload', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testMissingCreatedPayloadCannotBorrowValues')
  run.call('missing_probe_duration_domain', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testOnlyFifteenAndFortyMillisecondsAreAdmitted')
  run.call('missing_probe_duration_native_fences', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testExistingHostClockAndNativeFailureFencesRemainRequired')
  run.call('missing_probe_duration_request_not_delivery', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationWitnessTests/testProbeFailureResultsDoNotInvalidateRequestedBudgetWitness')
  run.call('missing_probe_duration_composition', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationCompositionPreservesControlAndAddsOnlyFortyMilliseconds')
  run.call('missing_probe_duration_flags', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationRequiresAllHeldObserverFlagsAndControlBeforeReservation')
  run.call('missing_probe_duration_trial_conflicts', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationRejectsPreexistingConfigurationAndBehaviorOverrides')
  run.call('missing_probe_duration_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationOptInRequiresMatchingExactArmAndNoBorrowedSelection')
  run.call('missing_probe_duration_process', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationOptInRetainsProcessAndEnvironmentGates')
  run.call('missing_probe_duration_topology', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationReservationPreservesTokenTopologyAndRetirement')
  run.call('missing_probe_duration_weak_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRequireMatchingArm')
  run.call('missing_probe_duration_weak_isolation', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRejectLegacyAndMultipleSelections')
  run.call('missing_probe_duration_weak_flags', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingWeakSelectionsRequireCompleteFlagsAndOwnCohort')
  run.call('missing_probe_duration_recovery_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRequireMatchingArm')
  run.call('missing_probe_duration_recovery_isolation', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRejectLegacyAndMultipleSelections')
  run.call('missing_probe_duration_recovery_flags', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testProbeDurationMovingRecoverySelectionsRequireCompleteFlagsAndOwnCohort')
  run.call('missing_probe_duration_loader_flags', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoPacerBridgeTests/testProbeDurationRequiresExactDurationAndAllFlagsBeforeLoading')
  run.call('missing_probe_duration_loader_digest', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoPacerBridgeTests/testProbeDurationCannotBypassArtifactDigestValidation')
  run.call('missing_probe_duration_profile', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoDefaultPacingProfileTests/testProbeDurationArmsPreserveOriginalDelayedWorkloadWithoutBorrowingCohorts')
  run.call('missing_probe_duration_weak_profile_class', expected_failure: 'required test class missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests')
  run.call('missing_probe_duration_weak_profile_acceptance', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testBothDurationArmsAcceptOnlyTheFixedMovingWeakProfile')
  run.call('missing_probe_duration_weak_profile_booleans', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testEveryBooleanProfileDriftIsRejectedIndependently')
  run.call('missing_probe_duration_weak_profile_bounds', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingWeakProfileTests/testNumericAndOptionalProfileDriftIsRejectedIndependently')
  run.call('missing_probe_duration_recovery_profile_class', expected_failure: 'required test class missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests')
  run.call('missing_probe_duration_recovery_profile_acceptance', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testBothDurationArmsAcceptOnlyTheFixedMovingRecoveryProfile')
  run.call('missing_probe_duration_recovery_profile_booleans', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testEveryBooleanProfileDriftIsRejectedIndependently')
  run.call('missing_probe_duration_recovery_profile_bounds', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoProbeDurationMovingRecoveryProfileTests/testNumericAndOptionalProfileDriftIsRejectedIndependently')
  run.call('missing_encoder_trace_transparency', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testTransparentEncoderCallsAndScalarSnapshotRoundTrip')
  run.call('missing_encoder_trace_optional_factory', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFactoryOptionalCapabilitiesAndNilCreationArePreserved')
  run.call('missing_encoder_trace_absent_factory', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFactoryWithoutOptionalMethodsDoesNotInventCapabilities')
  run.call('missing_encoder_trace_owner', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testOwnerAndArmAreSingleUseAndRequireValidClocks')
  run.call('missing_encoder_trace_window', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testFixedWindowKeepsPreCaptureMetadataButExcludesFrameEdges')
  run.call('missing_encoder_trace_capacity', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCapacityIsBoundedWithoutChangingForwarding')
  run.call('missing_encoder_trace_clock', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testInvalidAndRegressingClocksCannotCreateEvidence')
  run.call('missing_encoder_trace_generation', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testLateCallbacksCannotBorrowReplacementRegistrationOrEncoder')
  run.call('missing_encoder_trace_reentry', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testSynchronousCallbackReentryPreservesReturnsAndNil')
  run.call('missing_encoder_trace_native_results', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testNonzeroNativeResultsAndSuppressedOutputsRemainDiagnostics')
  run.call('missing_encoder_trace_payload', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testMalformedPayloadCannotBecomeEvidence')
  run.call('missing_encoder_profile_duration', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testOnlyControl15AcceptsTheFixedMovingRecoveryProfile')
  run.call('missing_encoder_profile_booleans', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testEveryBooleanWorkloadDriftIsRejected')
  run.call('missing_encoder_profile_numeric', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryProfileTests/testNumericAndOptionalWorkloadDriftIsRejected')
  run.call('missing_encoder_admission_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRequiresOwnControl15Selection')
  run.call('missing_encoder_admission_isolation', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRejectsLegacyMultipleAndCrossedSelections')
  run.call('missing_encoder_admission_flags', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEncoderBoundaryDiagnosticRequiresCompleteFlagsAndProcessOptIn')
  run.call('missing_encoder_native_log_formats', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testParsesExactDropFailureAndPropertyFormats')
  run.call('missing_encoder_native_log_configuration', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testHardwareAndLowLatencyMessagesRetainOnlyAllowedEnums')
  run.call('missing_encoder_native_log_allowlist', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testRejectsWrongSourceMalformedTrailingAndOversizedMessages')
  run.call('missing_encoder_native_log_numbers', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testNumericNativeWidthsAndZeroAutomaticValuesAreExact')
  run.call('missing_encoder_native_log_window', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testFixedWindowKeepsPreArmConfigurationWithoutPreArmFrameEvidence')
  run.call('missing_encoder_native_log_arm', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testArmIsSingleUseAndRejectsInvalidOrOverflowingWindows')
  run.call('missing_encoder_native_log_capacity', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testCapacityRetainsFirst512EventsAndCumulativeOverflow')
  run.call('missing_encoder_native_log_clock', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testInvalidRegressingClocksAndMissingThreadRejectEvidenceButTiesRemainValid')
  run.call('missing_encoder_native_log_scope', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testProcessScopedSnapshotRoundTripsWithoutRawTextAndNativeErrorsRemainObservations')
  run.call('missing_encoder_native_log_retirement', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEncoderLogObserverTests/testFinishRetiresAdmissionWithoutMintingPositiveEventPresence')
  run.call('missing_encoder_trace_during_release', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCallbackReceivedDuringReleaseRetainsOriginalInputIdentity')
  run.call('missing_encoder_trace_after_release', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testCallbackReceivedAfterReleaseRetainsOriginalInputIdentity')
  run.call('missing_encoder_trace_during_callback', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testInvalidationDuringCallbackRetainsOldAndCurrentGenerations')
  run.call('missing_encoder_trace_rejected_bounds', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testRejectedObservationsRespectClockCapacityAndRetirement')
  run.call('missing_drain_cross_thread', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainCrossThreadCallbackPreservesOriginalOwnership')
  run.call('missing_drain_wrong_owner', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRejectsWrongRegistrationAndOtherEncoderIdentity')
  run.call('missing_drain_consumed', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRejectsConsumedUnknownAndDuplicateInputs')
  run.call('missing_drain_success', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainRequiresSuccessfulRecordedEncodeReturn')
  run.call('missing_drain_lifecycle', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainLeaseRevokedByLifecycleBeforeOutput')
  run.call('missing_drain_return', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testReleaseDrainCallbackReturnRejectsLifecycleReentry')
  run.call('missing_drain_active', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoEncoderBoundaryTraceTests/testActiveCallbackCannotBorrowReleaseDrainReturnAuthority')
  run.call('missing_qp_default', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testDefaultPathDoesNotLoadOrCreateHook')
  run.call('missing_qp_fixture', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testOtherFixturesCannotRequestHook')
  run.call('missing_qp_startup', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingStartupOptInIsRejectedBeforeLoading')
  run.call('missing_qp_pacer', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingPacerOptInIsRejectedBeforeLoading')
  run.call('missing_qp_arm', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testUnknownArmIsRejectedBeforeLoading')
  run.call('missing_qp_seal', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testMissingSealedPreloadedArtifactIsRejected')
  run.call('missing_qp_startup_arm', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoQPOwnerHookAdmissionTests/testStartupArmRequiresSameEligibilityAndPreloadedSeal')
  run.call('missing_method', expected_failure: 'required safety method missing')
  run.call('missing_sequence_method', expected_failure: 'required safety method missing')
  run.call('missing_estimator_method', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEstimatorSnapshotTests/testExactlyTwoAdvancingDelayEventsCannotVerify')
  run.call('missing_probe_witness_method', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEstimatorSnapshotTests/testProbeOnlyEventsAndProbeAfterTwoDelaySamplesCannotVerify')
  run.call('missing_alr_payload_method', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativeEstimatorSnapshotTests/testALRRequiresMembershipAndForbidsEvenZeroBitrate')
  run.call('missing_alr_hold_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testALRGrowthHoldOptInRequiresItsOwnExactObserverSelection')
  run.call('missing_alr_hold_admission', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testALRGrowthHoldRequiresObserverAndControlBeforeReservation')
  run.call('missing_alr_probe_cap_selection', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testALRProbeCapOptInRequiresItsOwnExactHeldObserverSelection')
  run.call('missing_alr_probe_cap_admission', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testALRProbeCapRequiresHoldObserverAndControlBeforeReservation')
  run.call('missing_pacing_distinct_clock', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativePacingWitnessTests/testAllSameMillisecondPairsCannotSupplyThreeIndependentMatches')
  run.call('missing_pacing_tied_contradiction', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoNativePacingWitnessTests/testSameMillisecondContradictionRejectsEvenWithThreeDistinctMatches')
  run.call('missing_hook_reentry_method', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCNativeConfigurationHookTests/testSynchronousReentryCannotReuseFactoryHookBeforeRetirement')
  run.call('missing_estimator_admission_method', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testEstimatorOptInCannotBorrowAnOrdinaryFactorTestSelection')
  run.call('missing_baseline_estimator_admission', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testDelayedBaselineObserverCannotBorrowHoldOrProbeCapAdmission')
  run.call('missing_receiver_inbound_parser', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCVideoStartupStatisticsTests/testParsesOptionalReceiverDiagnosticsOnlyFromInboundVideo')
  run.call('missing_receiver_retirement', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoReceiverStatisticsProbeTests/testRetirementRejectsLateCompletionEvenWhenCollectorIgnoresCancellation')
  run.call('missing_receiver_final_drain', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoReceiverStatisticsProbeTests/testFinalCollectionDrainsAndRetiresDiagnosticRequestFirst')
  run.call('missing_default_pacing_admission', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCStartupPacingAdmissionTests/testDefaultPacingCohortRequiresItsOwnSelectionAndExactPairedFlags')
  run.call('missing_default_pacing_profile', expected_failure: 'required safety method missing from discovery: CaptureServerTests.StartupVideoDefaultPacingProfileTests/testDelayedProfilesRejectCapacityWorkloadAndCadenceOrDelayDrift')
  run.call('missing_transient_pressure_replay', expected_failure: 'required safety method missing from discovery: CaptureServerTests.WorldwideScreenSpatialRecoveryPolicyTests/testRecordedTransientLowCapacityRetainsAcceptedSurvivalPixelsUntilProbeExpiryAndRebound')
  run.call('missing_persistent_pressure_replay', expected_failure: 'required safety method missing from discovery: CaptureServerTests.WorldwideScreenSpatialRecoveryPolicyTests/testPersistentLowCapacityAfterProbeExpiryRetiresAcceptedSurvivalPixels')
  run.call('missing_independent_pressure_replay', expected_failure: 'required safety method missing from discovery: CaptureServerTests.WorldwideScreenSpatialRecoveryPolicyTests/testIndependentPressureDuringAcceptedSurvivalProbeRequiresFreshEvidence')
  run.call('missing_hook_lifetime_method', expected_failure: 'required safety method missing from discovery: WebRTCTransportTests.WebRTCNativeConfigurationHookTests/testDelayedChildCannotReuseFactoryHookAfterSuccessfulConstruction')
  run.call('missing_native', native_enabled: true, expected_failure: 'required native method missing')
  run.call('missing_capacity', extra_args: ['--capacity-experiment'], expected_failure: 'required capacity method missing')
  run.call('missing_spatial_recovery', extra_args: ['--spatial-recovery-experiment'], expected_failure: 'required spatial recovery method missing')
  run.call('spatial_recovery_nonzero', extra_args: ['--spatial-recovery-experiment'], expected_failure: 'spatial-recovery-1-1 exited unsuccessfully')
  run.call('empty_spatial_recovery', extra_args: ['--spatial-recovery-experiment'], expected_failure: 'empty selected test results')
  run.call('skipped_spatial_recovery', extra_args: ['--spatial-recovery-experiment'], expected_failure: 'required test skipped')
  run.call('success', extra_args: ['--capacity-experiment', '--spatial-recovery-experiment'], expected_failure: 'choose one experiment matrix')
  run.call('compile_failure', expected_failure: 'discover-and-build exited unsuccessfully')
  run.call('nonzero', expected_failure: 'deterministic exited unsuccessfully')
  run.call('native_nonzero', native_enabled: true, expected_failure: 'native-1 exited unsuccessfully')
  run.call('skipped_native', native_enabled: true, expected_failure: 'required test skipped')
  run.call('skipped_default', expected_failure: 'required test skipped')
  run.call('empty_native', native_enabled: true, expected_failure: 'empty selected test results')
  run.call('omitted_case', expected_failure: 'required tests missing from results')
  run.call('duplicate_results', expected_failure: 'duplicate test results')
  run.call('unexpected_result', expected_failure: 'unexpected test result')
  run.call('false_green', expected_failure: 'missing or duplicate Selected tests start record')
  run.call('xml_failure', expected_failure: 'required test failed')
  run.call('source_change', expected_failure: 'source changed during this invocation')
  run.call('timeout', expected_failure: 'exceeded its process deadline', extra_args: ['--timeout-seconds', '1'])
  run.call('log_success')
  run.call('log_success', native_enabled: true, inherited_native: '0')
  run.call('log_swift_testing_only', expected_failure: 'missing or duplicate Selected tests start record')
  run.call('log_no_cases', expected_failure: 'empty selected XCTest results')
  run.call('log_omitted_case', expected_failure: 'required tests missing from results')
  run.call('log_duplicate', expected_failure: 'duplicate XCTest start')
  run.call('log_unexpected', expected_failure: 'unexpected test result')
  run.call('log_skipped_native', native_enabled: true, expected_failure: 'required test skipped')
  run.call('log_failed', expected_failure: 'required test failed')
  run.call('log_missing_start', expected_failure: 'XCTest pass without matching start')
  run.call('log_unfinished_case', expected_failure: 'unfinished XCTest case')
  run.call('log_missing_suite_end', expected_failure: 'missing or duplicate Selected tests passed record')
  run.call('log_truncated_footer', expected_failure: 'missing or malformed Selected tests count footer')
  run.call('log_wrong_count', expected_failure: 'count footer disagrees with required method manifest')
  run.call('log_skipped_summary', expected_failure: 'footer reports skips or failures')
  run.call('log_failed_summary', expected_failure: 'footer reports skips or failures')
  run.call('log_duplicate_footer', expected_failure: 'missing or duplicate Selected tests passed record')
  run.call('log_case_after_footer', expected_failure: 'case record outside Selected tests suite')
  run.call('log_unrecognized_case', expected_failure: 'unrecognized XCTest case record')
  run.call('log_nonzero', expected_failure: 'deterministic exited unsuccessfully')
  calls, = run.call('success', expected_failure: 'set DEVELOPER_DIR explicitly', omit_developer: true)
  assert(calls.empty?, 'missing developer directory invoked Swift')
  calls, = run.call('success', expected_failure: 'unrecognized argument', extra_args: ['--unknown'])
  assert(calls.empty?, 'unrecognized option invoked Swift')
  calls, = run.call('success', expected_failure: '--jobs must be 1 or 2', jobs: '3')
  assert(calls.empty?, 'invalid jobs invoked Swift')
  ['/', Dir.home, root].each do |broad_path|
    calls, = run.call('success', scratch: broad_path, expected_failure: 'dedicated')
    assert(calls.empty?, 'broad scratch path invoked Swift')
  end
  calls, = run.call('success', scratch: 'relative-scratch', expected_failure: 'absolute dedicated build directory')
  assert(calls.empty?, 'relative scratch path invoked Swift')

  calls, scratch = run.call('success')
  assert(calls.length == 2, 'default invocation did not discover/build once and execute once')
  assert(calls.all? { |call| call['native'].nil? }, 'ambient native opt-in leaked into default phases')
  filter = Regexp.new(calls.last['argv'].fetch(calls.last['argv'].index('--filter') + 1))
  assert(filter.match?(extra), 'future WorldwideScreenStartup prefix coverage was omitted')
  assert(!filter.match?(unrelated), 'unrelated test entered the gate')
  assert(observer_native.none? { |id| filter.match?(id) }, 'estimator native diagnostics entered the deterministic gate')
  marker = File.join(scratch, 'existing-build-cache-marker')
  File.write(marker, 'keep')
  run.call('success', scratch: scratch)
  assert(File.read(marker) == 'keep', 'reusing the scratch path deleted its cache')
  assert(Dir.glob(File.join(scratch, 'validation-runs/startup-*')).length == 2, 'evidence paths were reused')

  calls, = run.call('success', native_enabled: true, inherited_native: '0')
  assert(calls.length == 4, 'native invocation must have one build and three execution phases')
  assert(!calls.first['argv'].include?('--skip-build'), 'first phase improperly skipped its build')
  assert(calls.drop(1).all? { |call| call['argv'].include?('--skip-build') }, 'same-invocation artifact was rebuilt')
  assert(calls.map { |call| call['pid'] }.uniq.length == 4, 'native methods shared a process')
  assert(calls.take(2).all? { |call| call['native'].nil? }, 'native opt-in leaked into build/default phase')
  assert(calls.drop(2).all? { |call| call['native'] == '1' }, 'native opt-in was not enforced')
  calls.drop(2).zip(native).each do |call, method|
    selection = Regexp.new(call['argv'].fetch(call['argv'].index('--filter') + 1))
    assert(all_methods.select { |id| selection.match?(id) } == [method], 'native phase did not select exactly its required method')
  end
  calls, = run.call('success', extra_args: ['--capacity-experiment'])
  expected = native + capacity * 3
  assert(calls.length == 2 + expected.length, 'capacity matrix must run three fresh-process rounds')
  assert(calls.map { |call| call['pid'] }.uniq.length == calls.length, 'capacity methods shared a process')
  assert(calls.take(2).all? { |call| call['native'].nil? }, 'native opt-in leaked into capacity build/default')
  calls.drop(2).zip(expected).each do |call, method|
    selection = Regexp.new(call['argv'].fetch(call['argv'].index('--filter') + 1))
    assert(all_methods.select { |id| selection.match?(id) } == [method], 'capacity phase selected wrong method')
    assert(call['native'] == '1' && call['argv'].include?('--skip-build'), 'capacity phase must use opt-in same-invocation artifact')
  end
  calls, = run.call('success', extra_args: ['--spatial-recovery-experiment'])
  expected = native + spatial_recovery * 3
  assert(calls.length == 2 + expected.length, 'spatial recovery must run exactly three fresh-process rounds')
  assert(calls.map { |call| call['pid'] }.uniq.length == calls.length, 'spatial recovery methods shared a process')
  assert(calls.take(2).all? { |call| call['native'].nil? }, 'native opt-in leaked into spatial recovery build/default')
  calls.drop(2).zip(expected).each do |call, method|
    selection = Regexp.new(call['argv'].fetch(call['argv'].index('--filter') + 1))
    assert(all_methods.select { |id| selection.match?(id) } == [method], 'spatial recovery phase selected wrong method')
    assert(call['native'] == '1' && call['argv'].include?('--skip-build'), 'spatial recovery must use same-invocation opt-in artifact')
    assert(capacity.none? { |id| selection.match?(id) }, 'old capacity matrix unexpectedly repeated')
  end
  puts "screen-startup runner self-tests: PASS (#{cases} scenarios; fake Swift only)"
end
RUBY
