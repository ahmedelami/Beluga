# Screen startup regression guardrails

Read this before changing screen adaptation, sender statistics, Show/Hide ownership,
capture geometry, or startup tests. The feature prioritizes readable full-size pixels
under the **existing** traffic ceilings; it does not speculate that a new connection
has full bandwidth. Tests reduce risk, but are not a guarantee against all regressions.

## Required contributor gate

From the repository root on macOS, explicitly select the reviewed Xcode Developer
directory and a dedicated absolute SwiftPM scratch path:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer \
  scripts/validate-screen-startup.sh --scratch-path /absolute/path/to/dedicated-startup-cache
```

For changes to this boundary, also run the native gate before calling it release-ready:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer \
  scripts/validate-screen-startup.sh --scratch-path /absolute/path/to/dedicated-startup-cache --native
```

The gate builds/discovers tests once per invocation and runs only that invocation's
build. It requires every selected test to actually pass, rejecting empty selections,
missing tests, skips, changed source, timeouts, and nonzero exits. `--native` requires
both reviewed native methods in separate fresh processes. Default `swift test` skips
the native experiments; a green default run is **not** a replacement for `--native`.
Do not share the scratch directory with a concurrent build. Use at most two jobs.

Run `scripts/test-validate-screen-startup.sh` after editing the gate. Its fake-runner
tests verify rejection paths; they are not a substitute for actual Swift/native tests.
These are local contributor checks, not hosted CI or remotely enforced branch rules.

Changes to post-congestion spatial recovery additionally require its paired native matrix:

```sh
DEVELOPER_DIR=/absolute/path/to/Xcode.app/Contents/Developer \
  scripts/validate-screen-startup.sh --scratch-path /absolute/path/to/dedicated-startup-cache --spatial-recovery-experiment
```

This mode includes the original native checks and three fresh-process rounds of five
recovery cases: disabled/enabled moving drop-and-recovery, enabled second drop, and
steady ample/weak moving controls. It is mutually exclusive with `--capacity-experiment`.
The command specifies required evidence, not a record of a successful run.

## Invariants and independent oracles

All policy cases below are in `macOS/Tests/CaptureServerTests`. Report-copy cases are
in `shared/Tests/WebRTCTransportTests`.

| Preserve | Sensitive boundary | Behavioral oracle |
| --- | --- | --- |
| While startup is unresolved, the exact Show keeps full pixels, native `maintainResolution`, and at least the survival video/peer cap floor while spending temporal FPS first. Configured ceilings, source FPS, and explicit low caps still win. Reaching the full temporal tier does not clear this Show-bound spatial authority; it stays latent until independent pressure, complete proof, or lifecycle replacement retires it. | `WorldwideScreenVideoAdaptationPolicy.currentRecommendation`, startup eligibility, and native sender application | `testShowKeepsExistingTrafficCeilingsButStartsWithFullPixels`, `testHealthyIntermediatePromotionsKeepPixelsAndFullQualificationReleasesFPS`, `testRawLowBandwidthMayReduceTemporalTierButKeepsFullPixels`, configured-ceiling/source-FPS cases; `testScreenVideoEncodingLimitsApplyAtomicallyAndFailClosed`. |
| Raw BWE may lower tier, bitrate, and FPS, but bandwidth alone retires startup pixels only after one stable sender recommendation and four fresh regular post-seed reports spanning at least two seconds. Every report must carry one atomic selected candidate-pair tuple: nonempty fingerprint, monotonic payload bytes, and positive finite same-pair BWE. Primary video send must be at least 80% of the native-time-weighted video target, selected-pair send must be at least 80% of the native-time-weighted same-pair BWE, and pair byte delta must be at least video byte delta. Aggregate audio-plus-video target is diagnostic only. | `observeStartupSpatialBandwidthEvidence`, `WebRTCSelectedCandidatePairOutboundDiagnostics`, regular-lane demand proof, and startup disproof cause | `testSustainedDemandProofRetiresFullPixelsOnlyOnFourthFreshReport`, `testBandwidthDemandProofRejectsUnexercisedTargetsAndBrokenCounters`, `testAggregateAudioTargetAloneCannotProvePathLimitation`, `testSelectedPairDemandProofRejectsMissingAndRegressingEvidence`, `testSelectedPairDeltaCannotTrailPrimaryVideoDelta`; `WebRTCSelectedCandidatePairOutboundDiagnosticsTests`. |
| Primary outbound-video `bytesSent` and `framesEncoded` are strict unsigned-integer progress counters. Negative, fractional, and Boolean `NSNumber` encodings fail closed independently; a malformed field cannot erase its valid sibling or participate in demand proof. | `WebRTCStatisticsParser.videoStatistics` progress-counter parsing | `testPrimaryOutboundVideoStrictProgressCountersRejectMalformedNSNumberValuesIndependently`. |
| A completed load proof needs an independent path-limitation witness: four consecutive regular intervals with `qualityLimitationReason == bandwidth`, or a failed below-reserve capacity probe bound to the same peer, Show, and selected pair. Exact failed-probe spatial authority requires a coherent atomic pair identity and pair BWE from the current report, with pair BWE exactly matching the admitted top-level BWE. Missing or mismatched atomic evidence may leave the conservative peer-wide failure latch set but cannot mint the exact witness. Interrupted limitation runs cannot qualify. A material BWE recovery invalidates the exact witness; Hide or replacement cannot reuse it. | Independent pressure corroboration, current-report pair/BWE coherence, and exact-Show probe-witness lifecycle | `testSustainedNativeBandwidthLimitationCanCorroborateOfferedLoad`, `testInterruptedNativeBandwidthLimitationCannotProvePathPressure`, `testBelowReserveFailureWithoutAtomicPairOnlyLatchesPeerWideAndCannotAuthorizePixels`, `testBelowReserveFailureWithMismatchedTopLevelAndAtomicBWECannotMintWitness`, `testExactShowAtomicFailedProbeWitnessCanCorroborateNonQLRSaturatedDemand`, `testBelowReserveProbeWitnessIsScopedToItsExactShow`, `testBelowReserveProbeWitnessIsInvalidatedByMaterialRecovery`. |
| Key-frame telemetry must remain homogeneous for the complete proof. When present, at least two byte/frame progress intervals must contain non-key frames. When absent for the whole window, all four intervals must advance video bytes and encoded frames. Counter appearance/disappearance, regression, or key-frame delta greater than frame delta resets the proof. | Key-frame continuity and demand-progress qualification | `testTwoKeyFrameOnlyBurstsAndStaticPlateausCannotProveDemand`, `testKeyFrameCounterAvailabilityChangeCannotReuseEarlierBursts`, `testMissingOptionalKeyFrameCounterStillAllowsCompleteDemandProof`, `testBandwidthDemandProofRejectsUnexercisedTargetsAndBrokenCounters`. |
| Static/no-progress, missing, cached, malformed, stale, reordered, or cadence-gap evidence cannot assemble bandwidth proof or blur the Show. A report that changes the sender recommendation contains pre-apply counters and must reset proof without becoming its baseline; proof starts on the next fresh report and remains bound to that exact recommendation. A material BWE rise of at least 32 kbps and 10% above any running proof-window low-water mark restarts the complete window, including U-shaped fall-then-recovery estimates. Raw fast-lane BWE never creates demand proof or otherwise grants spatial authority. | Native report identity, running BWE low-water mark, and recommendation fences before spatial authority | `testRecommendationTransitionReportCannotSeedDemandProof`, `testRisingStartupBandwidthRampNeverBlurs`, `testUShapedStartupBandwidthRecoveryRestartsDemandProof`, `testFastLaneBandwidthCollapseCannotRetireStartupPixels`, `testNewRequestWithStaleOrMissingNativeReportCannotApplyNegativeEvidence`, `testDuplicateNativeReportCannotPromoteStartupFPS`. |
| Qualified moderate capacity improves motion rather than freezing at cold-start 5 fps. Pixel-rate shaping is not bandwidth permission. | Startup recommendation shaping | `testQualifiedModerateBandwidthDoesNotFreezeMotionAtColdStartFPS`, `testQualifiedSpatialFPSRetainsOnMissingOrRawLowBWE`. |
| Diagnostic enrichment never becomes native route evidence. Report timestamp is identity, not a lease or a new RTT measurement. | `WebRTCScreenVideoStatisticsReport` copies and service sampler | `WebRTCScreenVideoStatisticsReportTests`, `testCachedDiagnosticRouteCannotTurnMissingNativeEvidenceIntoAReplacement`; service wiring check is supplementary. |
| Only an exact whole-pair gap can hold an already accepted probe cap. It cannot renew primary RTT health, extend the absolute deadline, or grow the cap. | `startupSparseProbeDeadline`, regular/fast report handoff | Sparse-pair and fresh-fast-RTT tests, including malformed ordinary reports, primary lease expiry, probe deadline and observable queue baseline. |
| Hard pressure remains immediate and independent of bandwidth proof: selected-route replacement, including an atomic selected-pair fingerprint change even when RTT telemetry is missing; fresh RTT above `max(1.5x baseline, baseline + 50 ms)`; send delay at least 200 ms once or above 100 ms twice. Missing or partial atomic pair diagnostics cannot assemble demand proof or impersonate a replacement. These hard signals remain authoritative at the probe deadline and may arrive on the fast lane; raw fast-lane BWE may only cancel speculative capacity and never retire startup pixels. | Atomic selected-pair identity and hard-pressure checks **before** bounded waits and temporal-first startup disproof | `testSelectedPairFingerprintReplacementRetiresFullPixelsWhenRouteMetadataMatches`, `testAtomicSelectedPairReplacementRetiresPixelsWithoutRTTEvidence`, `testImmediateQueuePressureAtProbeDeadlineStillRetiresFullPixels`, `testFreshInflatedRTTRetiresFullPixels`, `testFreshFastRTTBridgeStillAppliesIndependentPressureAndRouteBoundaries`, `testSparseFastSelectedPairStillAppliesImmediateSenderQueuePressure`, `testFastLaneImmediateQueuePressureStillRetiresStartupPixels`; atomic parser/copy tests reject partial tuple publication. |
| Startup permission belongs to the exact peer and Show. Hide/replacement cannot resurrect it; rejected native apply retains only same-Show terminal disproof. After the service selects its final retained-policy branch for an ambiguous native failure, it resets incomplete startup demand proof for the same owner and imports no positive authority. A same-owner material-recovery revocation of the exact failed-probe witness remains revoked, while the peer-wide failure latch remains conservative. | Lifecycle resets, `retainStartupSpatialModeTerminalState`, and post-branch `reconcileStartupSpatialStateAfterNativeFailure` | `testRejectedNativeApplyRetainsOnlyExactShowTerminalDisproof`, `testCopyingPositiveProposalCannotRearmDisprovedMode`, `testFailedNativeApplyAfterFullProposalCommitRestartsPartialDemandProof`, `testFailedNativeRecoveryProposalKeepsExactWitnessRevokedButPeerLatchConservative`, and `WorldwideScreenStartupInvariantSequenceTests`. |
| Capture-geometry replacement may re-arm full pixels only when the exact Show's terminal disproof is old-geometry demand, never when a later RTT, queue, or route negative proves path pressure. Mutable display diagnostics are not that authority. Raw fast BWE may cancel an inflated probe cap but must not make the terminal path-disproved. | `resetForCaptureGeometryEpoch`, authoritative disproof cause, fast recovery/probe negative lane | `testFramebufferRebuildRearmsDemandProvenPixelsAndRequiresFreshProof`, `testMutableDiagnosticCauseCannotVetoDemandGeometryRearm`, `testFastProbeBandwidthCollapseDoesNotBlockDemandGeometryRearm`, `testFastImmediateQueueAfterDemandDisproofSurvivesGeometryRebuild`, `testFramebufferRebuildCannotEraseHardPressureAfterDemandDisproof`. |
| A sender/source mutation begins a new evidence epoch. Rejected/expired native proposals, rollback/fallback, accepted writes, framebuffer rebuild, failed automatic resume, and Active ACK must fence any whole-peer request reserved under old limits. Only a newly minted exact failed-probe witness may survive its own known-cache origin restoration; corrective unknown-native reconciliation revokes it. | Native collection-sequence floor and sender-configuration evidence reset | `testExpiredNativeFallbackFencesReportReservedBeforeFallback`, `testBoundedNativeFailureFencesEvidenceBeforePublishingFallbackPolicy`, `testLaterSenderMutationFenceRejectsSequenceAllocatedAfterShowFence`, `testFailedAutomaticResumeFencesTemporarySenderBeforeReleasingActor`, `testAcceptedOriginRestoreKeepsFreshFailedProbeWitnessForNonQLRDemand`, `testCorrectiveNativeReconciliationRevokesWitnessMintedByUnknownConfiguration`, `testAcceptedUnrelatedSenderChangeRevokesCarriedFailedProbeWitness`. |
| A successor Show owns sender setup until Active ACK. Ordinary reports cannot mutate policy during that gate; queued predecessor native writes carry their old Show/Hide ID and are rejected by the peer after the successor request is received. A stale whole-peer callback cannot republish a route event from an earlier route revision. | Service Show gate, peer-native visibility token, route-revision admission | `testSuccessorShowGateRejectsOrdinaryAdaptationAndStaleCleanup`, `testShowTransitionGateAndNativeVisibilityTokenAreWiredAtMutationBoundaries`, `testScreenVideoEncodingLimitsRejectSupersededVisibilityRequestBeforeNativeMutation`, `testScreenVideoEncodingLimitsAcceptExactVisibilityRequestID`, `WebRTCWholePeerStatisticsRouteRevisionTests`. |
| Adaptation keeps the acknowledged capture surface, framebuffer mapping and input session. Pressure may degrade quality, not cause automatic blackouts or keyboard remounts. | Service apply path and input/capture transform | `WorldwideRemoteInputScaleTransitionTests`, surrounding video/floor suites; physical typing and presentation remain separate release checks. |
| Actual encoded/decoded detail survives delayed transport and eventually improves decoded FPS. A requested parameter is not a rendered frame. | Native production-policy fixture | `testDenseProductionPolicyDelayedNetworkWithDynamicFrameRateCharacterization`. |
| The native fixture cannot silently bypass its impairment path. | Pinned fixture-local UDP relay, all ICE candidates | `testDelayedNetworkBlackoutPreventsDirectICEBypass` plus the dynamic fixture's post-start blackout. |

`WorldwideScreenStartupInvariantSequenceTests` composes transitions rather than merely
checking isolated happy paths. Keep its seeds deterministic and diagnostics reproducible.
Assert observable ceilings, geometry, FPS, ownership and terminal state independently of
the implementation; do not compute all expectations by calling the function under test.

## Post-congestion spatial recovery

This is separate from cold-start permission. Recovering full pixels must never clear the
exact Show's startup disproof, create bandwidth authority, or weaken its existing guards.

| Preserve | Behavioral oracle |
| --- | --- |
| Only the exact active peer/Show can admit low-FPS full pixels at survival or better, with supported source FPS/caps and fresh post-adverse RTT, packet, frame and native-report evidence. | `WorldwideScreenSpatialRecoveryPolicyTests`, `WorldwideScreenSpatialRecoveryTests`: lifecycle, source-size, stale/malformed evidence and failed-apply cases. |
| Admission needs measured queue delay ≤20 ms. Only post-native full-size frame confirmation tolerates ≤100 ms; that tolerance grants no cap growth and cannot override independent pressure. | `testAdmissionQueueBoundaryRemainsTwentyMilliseconds`, `testPostApplyFullFrameConfirmationAcceptsOneHundredMillisecondsButNotMore`, `testConfirmationToleranceCannotOverrideFreshPressureOrAbsoluteDeadline`. |
| Confirmation requires actual advancing full-source encoded frames after native application. Typed neutral counters may preserve a bounded witness, never create one or renew its time, RTT lease or deadline. | `testRequiresNativeApplyThenTwoFullSourceProgressWitnesses`, `testOneFPSAlternatingMeasuredAndNoPacketPollsAdmitAndConfirmOnlyOnAdvancingFrames`, `testNeutralPollCannotCreateWitnessAndCannotSlideOriginalWitnessWindow`, malformed/reset cases. |
| The trial has a fixed 3-second publication deadline; retry backoff is 15/30/60 seconds with fresh witnesses. Existing capacity probes retain their own caps/deadlines; the trial cannot create a new probe. | `WorldwideScreenBoundedNativeApplicationTests`, `testAbsoluteDeadlineCannotBeExtendedByNativeApplyOrMissingReports`, `testCooldownRetriesUse15Then30Then60SecondsAndRequireNewWitnesses`, `WorldwideScreenSpatialRecoveryIntegrationTests`. |
| Before or after geometry admission, recovery-enabled discovery may hold an existing probe through an exact whole-pair statistics gap only under the same active peer, Show, attempt, probe origin/deadline and prior ordinary RTT lease. Fast health must await ordinary requalification; malformed evidence, pressure and lifecycle replacement cannot borrow this hold. | `WorldwideScreenSpatialRecoveryPolicyTests`: pre-admission and accepted whole-pair hold, malformed/partial/cached reports, deadline/pressure and Hide/successor cases. |
| Failed or stale native work cannot publish speculative recovery, erase a newer owner's cache, or overwrite newer native limits during fallback. Recheck both proposal deadlines after actor resume and before publication. | `WorldwideScreenNativeApplicationCacheTests`, `WebRTCScreenVideoEncodingReplacementTests`, failed-apply policy/reducer cases; service checks in `WorldwideRemoteInputScaleTransitionTests` are supplementary. |

The native recovery oracle requires actual weak-link pixel degradation, then decoded
1080×1920 with every contrast score >0.9 within 4 seconds of the actual capacity restore.
Require at least 2 seconds with eight changed-content observations, then no blurry frame
until the actual next drop or observation end. The second-drop case must degrade again
without capture blackout; steady controls protect unchanged paths. Use bounded source
timing, phase-marker plus pixel-change evidence, and the existing relay/blackout checks.
A requested scale, accepted sender parameter, policy phase or one sharp frame is not this
oracle. These synthetic checks do not prove installed-host or iPhone behavior.

Opt-in bottleneck diagnostics must not change packet scheduling or confuse modeled
residence with callback lateness. Retain only bounded scalar/header-class evidence.
A same-input disabled-policy shadow must compare initial and pre-native decisions,
retain its first divergence even if later expiry reconverges, and stop there. Cover
these with `StartupVideoDatagramSchedulerTests` and `StartupVideoPolicyShadowTests`;
the native drop comparison must actually observe enabled/disabled divergence.

Native pacing experiments are DEBUG/macOS-only, opt-in, audio-free host construction.
The injection must reject audio/viewer topology before factory work, close the actual
native peer on verification failure, and leave ordinary construction outside the
TaskLocal scope unchanged after success or throw. `WebRTCNativeConfigurationHookTests`
and `WebRTCScreenVideoEncodingReplacementTests` observe those boundaries.
`StartupVideoPacerBridgeTests` must reject wrong artifact identity before loading.
Removing native close or digest validation must fail their specific assertions.
Actual default/experimental/default native readback is required before streaming;
configuration intent alone does not prove the new peer received the setting.
Never promote a setting based on RTT alone: downstream residence, native sender
waiting and actual decoded detail all matter. Existing failed pacing trials remain
counterexamples; an ordinary startup gate does not replace their native acceptance.

The fixed pacing-factor experiment additionally requires a fresh process with one exact
selected XCTest and both opt-in flags. Freeze the complete existing field-trial baseline
before any native factory; admit only one video-only host and viewer under the exact
TaskLocal token. Ordinary prior construction, wrong topology/token, duplicate role, or
retirement must prevent later experimental construction. Never retune a running factory.
`WebRTCStartupPacingAdmissionTests` covers these gates and immutable trial composition.

`StartupVideoNativePacingObserverTests` and `StartupVideoNativePacingWitnessTests` require
bounded numeric SDK events, native worker identities independently read from the actual
host/viewer factories, post-binding/capture host pairs, advancing native timestamps, and
the received pacing rate computed from the logged estimate rather than pushback target.
ALR configuration logs alone are not consumer proof. Reject unknown attribution,
contradictory factors, ambiguous pairing, malformed or dropped evidence; exclude viewer
events. Require at least three unambiguous factor matches with distinct advancing native
millisecond timestamps and the complete unchanged ALR tuple. Sequential same-millisecond
pairs must still pass numeric checks, count only as `tiedPairs`, and cannot supply extra
independent matches. All callback uptimes must strictly advance; native timestamp
regressions still fail. Native worker binding and both factor trials are separate fresh-process checks;
passing the ordinary gate does not run them or imply their actual-pixel oracle passed.

The native estimator diagnostic is a separate DEBUG/macOS-only control-factor trial.
Require both explicit opt-in flags, one exact observer XCTest selection, the pinned
bridge/framework identities and a fresh process before any native factory. Preserve
the complete baseline and ordinary controller delegate; reject observer use with the
candidate factor or ordinary factor-test selection. Keep the video-only host/viewer
topology, token and one-peer-per-role fences. Its native construction and weak-link
methods are not part of the ordinary `NATIVE_METHODS` gate.

`WebRTCNativeConfigurationHookTests` must prove single-use construction, rejection of
synchronous reentry, rejection of inherited TaskLocal child hooks after both success
and throw, and unaffected ordinary construction outside the scope. Retain the observer
owner independently through native callbacks, blackout and peer close. Active evidence
requires one live logger; post-close evidence requires zero live loggers and balanced
creation/destruction with no lifetime failure. A successful construction with no
controller or events cannot stand in for a live observation witness.

`StartupVideoNativeEstimatorSnapshotTests` validates schema 2 and rejects schema 1,
with at most 1 MiB of JSON and 2048 retained numeric delay/loss/probe/ALR events in one
shared sequence. Require exactly one factory request,
interception, controller creation, default delegate, environment identity match and
logger creation, plus a called 25,000-us process interval. Invalid/dropped events,
rejected or unexpected factories, StartLogging attempts and environment, trial, selector
or lifetime failures all fail closed. Unknown event payloads are discarded and counted,
not retained as raw logs or promoted to evidence. Validate exact host worker identity,
sequence, kind-specific fields, positive applicable rates/times and nonregressing clocks even before
capture. Require at least three post-capture delay samples with advancing callback and
environment times; ties and two valid samples cannot supply three observations.

Probe/ALR events must never advance the delay witness. Delay/loss still require a
positive bitrate. `probeCreated`/`probeSuccess` require positive Int32 bitrate and cluster
ID; `probeFailure` requires that cluster ID and reason 0 through 2 but no bitrate.
Only creation carries positive UInt32 `minimumProbes` and `minimumBytes`. `alrState`
requires a Boolean `inAlr` and no bitrate or probe/delay/loss fields; all other variants
forbid `inAlr`. Reject missing, out-of-width and cross-variant fields. Validate pre-capture
events while excluding them from post-capture counts. Allow repeated results for one
cluster and absent matching requests; counts describe observations, not transmitted
packets, unique successful probes or causality. Read ALR from its native event, never
infer membership or a probe's trigger from rates or timing.

The witness establishes observability, not burst causality, and does not require overuse
to pass. Report delay overuse separately from loss-named updates. Cached Q8 fraction loss
and a reset expected-packet accumulator are not proof of zero network loss; an adjacent
loss-named `ApplyTargetLimits` update may follow a delay reduction. Preserve actual-pixel
and FPS assertions independently. The recorded estimator weak run verifies native
events but fails with seven blurred frames and 3.5 final fps; it is not a passing fix.
For schema 2, preserve the fixed three-control cohort in `PROBE_OBSERVATION_COHORT.md`:
one pixel pass and two failures are all retained. Both failures enter delay overuse
before the next observed probe request. This is not evidence for a periodic-probe
burst cause and does not authorize a 60-second ALR-interval trial or weaker guards.

### ALR delay-growth hold admission and evidence

The bounded hold candidate is DEBUG/macOS-only and adds exactly
`WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/` with the unchanged control factor 1.0
and estimator observer. Require both explicit experiment opt-ins, its own exact selected
XCTest method and a fresh video-only process before reservation or native factory work.
Reject borrowed baseline/ordinary selections, missing observer admission, other factors
and process reuse. The actual native controller environment must resolve the exact hold
value for its distinct observer owner; a baseline observer requires the key absent.
Do not add a global native setter, reconstruct SDK dependencies or retune a live factory.

Field-trial readback is configuration evidence, not proof that an ALR hold branch ran.
Correlate native ALR membership and delay/probe events with advancing decoded changed
frames, encoded frames, sender packets and bounded relay evidence. Equal-rate delay
events with unchanged state are not emitted: do not fabricate them or reduce the
three-delay witness. Preserve probe-estimate changes, non-ALR growth and genuine overuse
decreases independently.

The initial hold weak run passed with 49/49 sharp frames, final 5 fps, first frame
356.919 ms, eight advancing delay events and balanced teardown. Its constant-estimate
interval with advancing traffic matches the intended behavior, not direct branch-hit
proof; no overuse occurred, so pressure response remains unproven by that run. The fixed
three-round matrix of disabled recovery, enabled recovery, second drop, ample and weak
is now terminal: 11 passes followed by round 3 enabled-recovery failure, with 12/15 cases
completed and the last three not run. It stopped at the first failure without a rerun.
Do not count a partial matrix or the initial pass as completion. Fifty-four focused tests
and 65 fake-runner scenarios passed before matrix additions, not as evidence for the
added matrix.

The failed case verified its current native estimator/pacing snapshots but had no actual
shadow divergence or recovered sharp frame and ended at 1 fps; nine post-restoration
90×160 motion frames are continued delivery, not recovery. Its throwing recovered-frame
assertion executes the close catch but bypasses both the relay-blackout proof and final
native teardown snapshot/marker. Neither clean balanced teardown nor blackout passage is
proven there. The observed BWE stall at 192,627 then 181,925 bps and periodic 198,720-bps
probe requests remain below the existing floor-recovery requirement for a 486,001-bps
total cap. Preserve the 99,360-bps video cap and all recovery guards; a held ALR ramp is
not authority to raise ceilings or waive pressure/recovery evidence. This candidate
cannot be promoted. The pinned two-times-allocated probe cap supports this mechanism as
an inference; the native allocated-rate input was not logged. Exact receipts and passing
case detail are recorded in `SPATIAL_RECOVERY_EXPERIMENT.md`.

The separate ordinary gate `startup-20260920-33592-js07xn` has no hold flag selected:
531 deterministic methods and native case 1 passed, but native case 2 failed its actual
startup-detail assertion despite final 51.5 fps. All 333 covered source files remained
unchanged; 65 fake-runner scenarios passed separately. This native failure blocks release.
Do not call the restored full gate green or replace it with the hold candidate's initial
pass. Exact artifacts and prior failures remain in `SPATIAL_RECOVERY_EXPERIMENT.md`.

### ALR probe-cap skip admission and terminal evidence

The DEBUG-only `skipProbesBelowCurrentEstimate` candidate adds exactly
`WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0/`.
It defaults off, requires ALR growth hold plus the control estimator observer, rejects
any preexisting group, and admits its original five exact `testNativeEstimatorALRProbeCap`
matrix selections plus the separately selected
`testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic`. That receiver diagnostic
is not a sixth matrix case. Neither hold-only nor ordinary selections may borrow this authority.
Require the distinct native owner, actual original-environment readback, exact host
evidence and balanced lifetime. All caps, reserve, pressure/Show guards, timing and
pixel/FPS oracles remain unchanged. These diagnostic methods stay outside ordinary
`NATIVE_METHODS`.

The SDK compares the lesser of BWE and the network upper estimate strictly above the
lesser of peer maximum and twice positive allocation; zero allocation uses peer maximum.
Equality does not skip, and a lower finite network upper estimate can prevent skipping.
`RequestProbe` consumes its five-second recovery-request cooldown even when this
predicate returns no probes. Field-trial readback or missing probe events alone do not
prove a periodic ALR skip or available capacity.

The initial enabled-recovery pass recovered sharp pixels after 352.771 ms but did not
exercise the earlier exact floor-cap opportunity. The fixed matrix is terminal and red:
six passes, then round 2 enabled recovery failed only its pacing witness with
`outOfOrderHostEvidence` (seven host events). Seven of fifteen cases ran; eight did not.
That case did recover sharp pixels in 2,924.163 ms, retain 66 changed observations without
relapse, and finish at 12.5 fps with verified estimator evidence, blackout and balanced
teardown. Do not weaken the witness, substitute those positive results for the failure,
promote the candidate or rerun until green. Source/bridge receipts and the corrected
summary are recorded in `SPATIAL_RECOVERY_EXPERIMENT.md` and `ALR_PROBE_CAP_TRIAL.md`.
The seven rejected events have equal, not regressing, native millisecond timestamps
with advancing callback uptimes. The receiving-model correction now validates sequential
tied pairs numerically without adding independent matches; three distinct native
timestamps and strictly advancing callbacks remain required. Its 82 focused tests and
69 fake scenarios passed. Four independently compiled mutants produced 9/3/4/8 assertion
failures with zero unexpected errors and exact source restoration. No fresh full native
matrix with that correction had run at that checkpoint; do not rewrite the failed
matrix's result. Its separately declared corrected cohort is recorded below.
In that case the nominal periodic opportunity fell after
floor exit, so floor recovery itself does not establish an executed skip branch.

Before that correction, 61 focused safety tests and 67 fake-runner scenarios passed; candidate-selection
and missing-hold mutants each compiled and failed five assertions before exact source
restoration. The standalone actual-framework `ProbeCapControllerSmoke` passed seven
predicate cases; its config-off mutant compiled and failed case 2. That evidence covers
the common skip predicate, including equality/network-upper boundaries, not periodic
ALR, transmitted packets or decoded pixels. The earlier compiler initializer error is
not mutation evidence. The ordinary native startup gate and older matrix failures remain
independent release blockers.

The corrected-witness matrix is also terminal and red: seven passes, then round 2
second-drop failure, for 8/15 completed and seven unrun. The initial corrected trial
passed with 3,080.764-ms recovery and 13 fps. Source
`edcaba4212ee66e20821c044a5088c63fb1709e8028e29f22908356c273ad3ce` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47` remained unchanged.
Keep its authoritative receipt and separate `alr-probe-cap-matrix-2.summary-1.json`;
neither the summary nor earlier positive cases can certify an incomplete matrix.

Preserve the sustained-recovery oracle's fixed first-sharp two-second window, eight
changed transitions, timely boundary and maximum 500-ms inter-frame gap. The failed
case recovered sharp pixels after 719.290 ms, but the first two sharp frames at
8,785.787/9,691.261 ms were 905.473 ms apart. Its first window had only seven changed
transitions. All 56 later/recovered frames were sharp and final FPS was 5; these do
not erase the initial cadence failure. Since sustained recovery never qualified,
stage 3 never ran. The subsequent missing-second-drop unwrap threw, so blackout and
balanced post-close teardown were not verified; the close catch is not that proof.
Its active native estimator and corrected pacing witnesses did verify separately.

Round 1 enabled recovery did retain the exact low-allocation floor past nominal
last-probe-plus-five-seconds while ALR was true and traffic advanced. That improves
the relevant timing evidence, not direct internal skip-branch proof. Preserve this
distinction and every earlier red result; do not move the sustained window or relax
its assertions to relabel the failed case. Full details remain in
`SPATIAL_RECOVERY_EXPERIMENT.md` and `ALR_PROBE_CAP_CORRECTED_WITNESS_COHORT.md`.

### Separate periodic and receiver diagnostics do not replace red media oracles

The actual-framework periodic feedback harness now verifies native ALR entry and the
request boundary with the fixed 486,001-bps peer ceiling, 320,000-bps reserve and
166,001 → 99,360 → 166,001 allocation. Keep the exact 25-ms receipt/50-ms feedback
schedule for genuinely submitted non-probe packets; no forced BWE, RTT override or
invented probe feedback is allowed. At native ALR + five seconds, hold-only requests
198,720 bps while hold-plus-skip returns none at the same native BWE 308,030 bps.
Restoring the remaining allocation permits a useful 332,002-bps candidate request.
The config-off mutant compiles and fails that periodic probe-count assertion with
ALR and feedback intact. Retain the failed no-feedback predecessor separately.
`PERIODIC_ALR_FEEDBACK_ORACLE.md` pins identities, bounds and logs. This is actual
controller request proof, not probe delivery, feedback-trap or media-recovery proof.
Equality, lower network-upper and recovery-request cooldown limitations still apply.

Preserve the configuration distinction: production SDK-default pacing is 40 ms
(native configuration has no override), whereas hold/skip media and periodic harness
cohorts use diagnostic 20 ms. The separate baseline observer run passed at SDK default
with sharp pixels, 51 fps, 24 advancing delay events and balanced teardown. Its initial
888,571-bps estimate did not reproduce the failed ordinary gate's 656,555-bps estimate.
It cannot replace that red gate or establish the cause of its blur.

Receiver cadence collection must remain bounded, video-only, single-flight and
nonblocking on existing ordinary ticks, never an input to host policy or cadence.
Missing values stay absent; malformed counters, wrong inbound attribution, invalid
clocks, saturation and completions after retirement cannot become affirmative evidence.
RTP/callback timing and aggregate receiver counters are not individual-frame pipeline
or display attribution. The separate 20-ms `recovery-cadence-native-1.log` passed:
436.596-ms recovery from the conservative restore-start boundary, 11 sharp
frames/10 transitions in the fixed first window,
303.742-ms maximum recovered gap, actual second-drop degradation and 39 receiver
records; native witnesses, blackout and teardown passed. It did not reproduce the
905.473-ms failure and cannot certify matrix 2. Before it, 126 focused tests and 72
fake scenarios passed; four compiled receiver mutants failed 1/8/3/4 assertions,
then exact-source restoration passed 27 focused tests. Those are receiving-boundary
checks, not evidence of a product fix. See `RECOVERY_CADENCE_DIAGNOSTIC.md` and
`BASELINE_DELAYED_ESTIMATOR_COHORT.md` for exact receipts. All prior red matrices and
the ordinary native gate remain red; no diagnostic changes their case accounting.

### Separate SDK-default-selection cohort

The new default-selection cohort has its own seven exact methods and fixed
three-round order; it does not add cases to the original 20-ms matrices. Require
native absence of a burst override and rejection of contradictory configuration,
but do not call that observed 40-ms consumption. The value is SDK-source-derived;
all completed receipts say `runtime_window_readback: false`. Candidate ALR flags
remain explicit/default-off and all product caps and guards remain unchanged.
Bounded receiver collection in moving cases drains before final viewer statistics;
this diagnostic ordering is not a product correction for the historical cadence gap.

The cohort stopped RED: 19 passes, round 3 second-drop failure, 20/21 complete,
round 3 ample unrun. The failing case recovered sharp pixels in 377.358 ms and
passed the sustained window, then actually applied stage 3 at 14,005.081 ms.
All 30 later frames stayed full size, failing only the unchanged second-pressure
degradation assertion. Native witnesses, 39 receiver records, blackout and balanced
teardown passed independently. Do not assume this identifies a pressure-guard cause
or waive the assertion because the final frames were sharp at 5 fps.
Native overuse did lower BWE and return to normal, with low adjacent ordinary
queue/RTT samples; sustained overload or incorrect policy is not established.
Require contract/replay discrimination before a fix or independently justified
oracle revision, not forced unnecessary blur to make the old assertion pass.

The preceding 563 deterministic methods/75 fake scenarios, four compiled mutants
with 1/8/2/2 assertion failures and restored 53-test pass are separate evidence.
`DEFAULT_PACING_ALR_PROBE_CAP_COHORT.md` and `RECEIVER_MUTATION_EVIDENCE.md` pin the
receipts. All historical RED results remain intact; no default-on candidate flags,
40-ms runtime-consumption claim, promotion or deployment is authorized by this result.

## Prove that regressions are caught

The second-pressure contract now has three pinned deterministic replays: recorded
transient retention through fixed probe expiry/rebound, persistent low BWE after
expiry, and independent fresh pressure with stale/missing controls. All three and
their omission guards must remain in the contributor gate. Four compiled faults
failed 46/3/6/11 assertions; exact restoration passed 566 required methods and 78
fake scenarios. These protect production policy decisions, not decoded cadence.
The historical 800-kbps second-drop native RED is unchanged. See
`SPATIAL_RECOVERY_EXPERIMENT.md` and scratch `SECOND_PRESSURE_REPLAY_EVIDENCE.md`.

A four-case native controller-only duration experiment observes jitter sensitivity
but is not a product fix: 100-ms common probe duration costs about 6.57× the bytes
in the fixed comparison and is not startup-only. A duration-off mutant must reject
actual native cluster configuration. Do not replace packet/pixel tests with that
controller result or install the global trial on the strength of it alone.

The separate24-case native-controller FIFO sweep passed for15/25/40/100ms,
8Mbps/600kbps and0/4055/10000us tail extensions.40ms is the shortest tested
duration retaining670400bps on every ample case, not a universal optimum. Its
baseline-preserving Configuration-group variant passed with identical output.
Duration-off and FIFO-bypass mutants failed18/12 cases respectively before packet
submission; this is configuration/serialization guard coverage, not proof of
downstream arithmetic or an exercised delay-overuse detector.

The new exact15/40ms delayed media pair is default-off and separate from every
older cohort. Both arms must retain factor1, SDK-default pacing, ALR hold+skip,
the original50ms/dynamic-FPS/12s/cursor-only fixture and all pixel/blackout/lifetime
assertions. Never borrow a capacity/moving workload or a different cohort's
selector. Preserve the17 pinned admission, loader, profile and
`StartupVideoProbeDurationWitnessTests` methods and their omission guards.
The new native owner must validate exact original-environment trial strings;
the receiving witness must independently check the first two actual created
requests (IDs1/2,rates900000/905041,minimum5probes,bytes1688/1697 or4500/4525)
without searching later matches. Full native host/time/error witnesses still win.
Requested byte minima are not proof of transmitted probe bytes or actual duration.
Run this initial control/candidate pair once and retain any failure. It is not the
ordinary native gate or recovery-matrix acceptance, and authorizes no deployment.

The separately selected moving-weak duration pair retains the existing 800 kbps
outbound / 8 Mbps return, 2 ms one-way, twelve-second moving workload. Pin the
six additional weak-selection/profile methods and missing-class/method guards.
Its pre-factory validator must reject a higher-capacity, cursor-only, warmed,
shaped, differently paced or recovery-sequence substitution. Keep all decoded
frames sharp, final FPS >=4, genuine pixel changes, bounded source cadence,
native byte-budget/ownership witnesses, relay blackout and balanced teardown.
Do not borrow the delayed pair's result or reclassify old REDs. This weak pair
is still separate from recovery and ordinary native acceptance.

The separately selected moving-recovery duration pair uses 15 ms control and
40 ms candidate with the same sixteen-second moving, dynamic-FPS workload:
8 → 0.8 → 8 Mbps outbound, 8 Mbps return and 2 ms one-way delay, with the drop
scheduled at 4 seconds and restore at 8 seconds. Both arms enable and require
spatial recovery; neither has warmup, initial shaping or a second drop. Keep
SDK-default pacing, factor 1, ALR hold+skip and both timing collectors unchanged.
Preserve its six pinned admission/profile methods, class/method omission guards,
and assertion-failing selector, Boolean and numeric-profile mutations.
Actual decoded degradation between the applied drop and restore is required to
exercise recovery. Its absence fails qualification but is not automatically a
product regression and must not be repaired by forcing unnecessary blur.
Require first full-pixel sharp recovery within four seconds of actual restore,
then the fixed two-second window starting at that first sharp frame: at least
eight genuine content changes, gaps no greater than 500 ms and a boundary frame
within 500 ms of the window end. No later blurry frame may pass. Preserve source
cadence, decoder continuity, native request-budget/host/error witnesses, relay
blackout, receiver-drain and balanced native-lifetime checks. This pair neither
replaces the ordinary native gate nor proves promotion or deployment readiness;
the historical second-drop oracle and all earlier RED results remain unchanged.

The separately named encoder-boundary diagnostic is test-only and control15-only.
Its explicit tracing flag must not authorize any older selector, candidate40,
default-pacing cohort or missing held-observer flag. Delegate its workload checks
to the exact moving-recovery profile above; the six-second encoder observation
window must not shorten the sixteen-second media fixture or change its assertions.
Keep both new trace/profile classes, all seventeen trace/profile/admission methods
and their missing-method guards in the contributor gate. The native diagnostic
itself remains outside the ordinary native selections. Preserve transparent native
arguments, return values, optional factory capabilities and callback generation;
retain bounded scalar metadata only, never frames or encoded payloads. Require
assertion-failing window, return-forwarding, stale-generation and selection
mutations. Structural trace validity alone cannot prove any encoded output, and
encoder callbacks cannot replace actual decoded pixels, cadence, blackout or
balanced teardown. This diagnostic supplies no promotion or deployment authority.

The accompanying native H.264 log observer is explicitly process-wide: callback
threads do not identify an encoder, RTP frame or peer. Keep its ten parser/window/
retirement tests and the four encoder callback-rejection tests pinned with omission
guards. Retain only allowlisted numeric/enum events, at most 512, with configuration
metadata before arm and a fixed six-second capture window. Sample live clocks inside
the collector lock; finish retires collection, never the process-owned SDK sink.
No logging, dispatch or SDK reentry is allowed from its callback. Drops, encode
errors and property failures are observations, not automatic structural failures;
absence is not proof that native encoding succeeded. Pre-arm configuration may
race the capture timestamp and requires a separate receiving-time bound. Retain
the first diagnostic's RED result; richer evidence cannot relabel it.

Schema 3 distinguishes active output from synchronous release-drain output. The
pinned H.264 encoder can deliver its final pending callbacks while invalidation
is still running. Admit only unconsumed inputs with an already recorded successful
encode return, exact original encoder/registration identity, and the current
single-release retirement fence. Consume each input once; input history and
release depth alone never confer authority. Start, callback registration, nested
release, and release return revoke the lease. Recheck it before both output and
callback-return publication; a callback already executing before release never
acquires drain authority. Native calls and callback forwarding stay outside locks,
with unchanged results. Drain counters are explicit subsets of total output and
return counts, not new media-progress proof. Preserve the earlier schema-2 RED
receipts as-run. Require deterministic successful, late, duplicate, unreturned,
wrong-owner/registration and reentrant/cross-thread drain tests, plus compiled
assertion-failing mutations, before any fresh native comparison.

When changing an invariant or its oracle, make a small deliberate mutation in an isolated
checkout, run its targeted test, and require an **assertion failure** for the broken
behavior. A compiler error, empty selection, skip, or timeout is not mutation evidence.
Restore the production source before rerunning the full gate or committing. Never deploy
a mutation. Useful independent mutations:

1. Clamp every intermediate startup tier to 5 fps: the moderate-bandwidth test must fail.
2. Bypass native timestamp admission: stale/missing-report negative-evidence tests must fail.
3. Remove the exact sparse-gap/probe marker from fast RTT requalification: malformed-ordinary
   evidence must fail closed rather than acquiring the bounded wait.
4. Feed the diagnostic fallback route into `nativeSnapshot`: report-copy provenance tests
   must fail even when ordinary diagnostics still look plausible.
5. Lower the estimator witness threshold from three to two: the exact-two-samples test
   must fail. Remove host attribution, controller-create or native-failure checks:
   their focused negative cases must fail despite otherwise valid samples.
6. Remove single-use hook admission: synchronous reentry and delayed-child tests must
   reject the mutation. Test constructor success and throw separately; do not claim
   independent retirement-check coverage when another consumed-hook guard masks it.
7. Accept absent ALR membership, a failure-event bitrate, cross-variant fields or
   out-of-width probe values, or count probe/ALR events as delay proof: the focused
   schema-2 model assertions must reject each mutation. The completed borrowed-delay,
   missing-ALR and failure-bitrate mutants produced four, one and four assertion failures
   with exact model restoration; these are receiving-model, not native-producer mutations.
8. Allow the ALR hold to borrow another test's selection or omit its required observer:
   the dedicated admission assertions must fail. The completed selection mutant produced
   two assertion failures; the observer-admission mutant produced three plus one unexpected
   error, followed by exact source restoration. The unexpected error is not assertion
   evidence, and these mutation results do not turn the failed ordinary native gate green.
9. Allow the probe-cap candidate to borrow hold-only selections, or omit its hold
   prerequisite: each dedicated admission mutant must fail assertions, not merely
   compile, skip or time out. Both completed mutants failed five assertions with no
   unexpected errors and exact field-trial source restoration. Separately force the
   actual-framework smoke harness's skip configuration off: case 2 must fail its
   probe-count assertion; a compiler error is not a substitute.

Do not “fix” red tests by widening deadlines, deleting adverse fixtures, weakening pixel
assertions, accepting skips, or blessing current implementation output. Understand which
contract failed and preserve an independent regression that would reject the old behavior.

## Scope and safety

The native gate uses synthetic pixels and video-only peers with bounded fixture-local UDP
delay. It does not install or launch the host app, change audio routes, connect a phone,
or alter system networking. Keep those restrictions intact. Do not replace its fixed
packet bounds/deadlines with unlimited buffering or retry loops.

Passing source and loopback checks is not proof of deployment, real Internet loss,
moving-content load, simultaneous microphone/playout, continuous physical typing, or
iPhone presentation. Follow `TESTING_ORACLES.md` and protected-runtime instructions for
those boundaries. See `STARTUP_SPATIAL_FIRST.md` for measured evidence and limitations.
