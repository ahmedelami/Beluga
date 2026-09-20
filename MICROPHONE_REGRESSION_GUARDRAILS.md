# Microphone regression guardrails

Read this before changing microphone admission, audio-session policy, native recording
lifecycle, MediaPlayer setup, reconnect, or audio diagnostics. Keep
[AGENTS.md](AGENTS.md), [TESTING_ORACLES.md](TESTING_ORACLES.md), and
[protected-runtime requirements](USER_PROTECTED_LEGACY_RUNTIME.md) in force.

## Invariants that must survive edits

| Boundary | Preserve | Regression oracle |
| --- | --- | --- |
| Ordinary microphone policy | Request default sharing. Accept actual default **or** long-form only for ordinary `playAndRecord` / default mode / options40. Keep actual/requested values separate. Hosted-call playback remains default-only; output-only remains long-form-only. Never infer notification origin or capture permission from sharing. | `testOrdinaryRawMicrophoneProfileRequiresExactTupleAndSupportedEffectivePolicy`; Rust `ordinary_raw_microphone_profile_rejects_other_policies_and_all_tuple_or_owner_changes` |
| Framework `stopRecording` | Revoke authorization, drain capture and clear recording generations immediately. Do **not** rebuild the audio session or consume an app operation here. Retain the truthful configured input-bus state until the exact authorized output-only operation disposes/rebuilds it. A bare restart must not reopen input. | `testFrameworkMicrophoneStopClosesCaptureWithoutStealingOutputOnlyTransaction` |
| Public mic-off / transport loss | Revoke and mute before waiting for the policy owner or entering a native setter that can block/fail. Only the exact output-only token may write the replacement policy. No fallback write, reused token or late completion may affect a successor. | `testTransportUncertaintyClosesMicrophonePrivacyBeforeOutputOnlyOwnerReturns`; `testPublicOutputOnlyDisableClosesMicrophonePrivacyBeforeNativeAttemptForSuccessAndFailure` |
| Pending route convergence | A category observation can advance only its exact current Pending transaction's chained route cursor, with matching generations, deadline, ownership, profile and pinned output. It is not reason-8 evidence, startup settlement or capture authorization. | `testPendingCategoryRouteCursorRequiresExactChainedTransactionEvidence` |
| Fresh admission | Require current peer/transport, granted permission, allowed call state, exact built-in input, raw RemoteIO processing, and the exact approved native recording generation. A prior connection's policy, capability, statistics or receipt is never fresh proof. | `testSuspendedRawMicrophoneStatisticsReadCannotRepublishAcrossEveryRevocationBoundary`; `testMicrophoneApprovalRejectsZeroWrongStaleRevokedAndRetiredGenerations` |
| User intent and reconnect | Manual off and denied permission must not loop back on during the same session. A genuinely new authenticated session gets its own admission lifetime. Replacement waits for exact prior-peer teardown. | `testManualMicrophoneOffCancelsPendingAutomaticAttemptAndPersistsAcrossRecovery`; `testNewAuthenticatedSessionMayRetryAutomaticMicrophoneAfterDenial`; `testReplacementConnectionWaitsForRetiredPeerCloseBeforeAudioActivation` |
| Failure evidence | Retain the first concrete rejection, requested/actual policy and pre-rollback route evidence. Diagnostics explain failures; they never grant authority or turn failed capture into success. | `testCategoryObservationFailureDetailPrecedesGenericFailureAndIgnoresRetiredReceipts`; `IOSAudioDiagnosticsJournalTests` |
| Mac process-tap startup | Keep `kAudioAggregateDeviceTapAutoStartKey` false on every fresh aggregate. Nonzero waits for tapped playback and can stall a fresh microphone reader on a silent Mac. Preserve the real output clock, private/unmuted tap, exclusions and exact native teardown. Never work around this with synthetic playback or a Voice Memos launch. | `testEveryFreshAggregateStartsWithoutWaitingForTappedPlayback`; production-aligned `TapStartupProbe` comparison with tap-only retirement and clean reader/writer teardown |

The native boundaries are in `shared/Sources/IOSWebRTCAudioDeviceShim/IOSWebRTCAudioDeviceShim.m`.
The Swift stop/ownership ordering is in `WebRTCPeer.performIPhoneMicrophoneOutputOnlyDisable`.
The effective-policy contract must agree with `WebRTCIOSOrdinaryRawMicrophonePolicy`,
`AudioTransactionTarget.acceptsObservedRouteSharingPolicy` and Rust `Target::accepts_observed`.
Do not update just one layer. Changes to Rust source require its existing source/artifact
manifest and XCFramework rebuild/verification workflow, not a hand-edited manifest.

## Required checks for microphone-affecting code changes

Run the complete signed Simulator audio suites, not only the test that motivated the edit.
Use the reviewed installed Xcode and an existing dedicated test cache. Set these paths
explicitly; the result bundle must be new. Do not use a physical-phone destination for
this Simulator command or disable signing to make a failure disappear.

```sh
xcodebuild test \
  -project iOS/opensteamer/opensteamer.xcodeproj \
  -scheme opensteamer -configuration Debug \
  -destination "platform=iOS Simulator,id=${BELUGA_SIMULATOR_UDID:?select the test simulator}" \
  -derivedDataPath "${BELUGA_MIC_DERIVED_DATA:?reuse the test cache}" \
  -resultBundlePath "${BELUGA_MIC_RESULT_BUNDLE:?choose a fresh result path}" \
  -parallel-testing-enabled NO -jobs 2 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 90 \
  -maximum-test-execution-time-allowance 90 \
  -only-testing:opensteamerTests/WorldwideAudioLifecycleTests \
  -only-testing:opensteamerTests/WebRTCAudioPlaybackSessionTests \
  -only-testing:opensteamerTests/IOSAudioDiagnosticsJournalTests \
  DEVELOPMENT_TEAM=MSMG8CJLB3

(cd iOS/opensteamer/Rust/AudioTransactionAuthority && cargo test --locked)
```

Run Cargo from that crate directory with its pinned `rust-toolchain.toml`; reuse the
installed toolchain instead of upgrading it. If the Rust contract is unchanged, reuse
its already-bound evidence within the same immutable validation invocation.

Important reconnect/late-work cases in `WorldwideAudioLifecycleTests` include:

- `testReconnectNoOutboundRTPLifecycleCompositionRecoversOnceAcrossDelayedSameTargetNotification`
- `testTransportUncertaintyRetiresEstablishedMicrophoneBeforeHealthyReAdmission`
- `testFreshPreparationWaitsForExactRetiredPeerClose`
- `testDeferredMicrophonePermissionCannotCrossRevocationBoundaries`
- `testRetiredPollingProofCannotApplyHealthyDiagnosticsToReplacementAudio`
- `testRetiredRecoveryAuthorizationBlocksDelayedNativeSideEffect`

Require independent negative mutations when changing a sensitive invariant: restore
strict-default-only matching, allow an unsupported policy, remove the actual Pending
cursor update, or restore the unowned stop-time rebuild. Each targeted oracle must fail
for its intended defect. Restore the exact source and rerun affected suites before
committing. Never install or upload a deliberately broken variant.

For Mac tap startup, mutate only the production aggregate's auto-start value back to
true and require the aggregate configuration test to fail. The native comparison is
opt-in and needs an approved idle boundary; follow
`macOS/VirtualAudioDriver/Probes/TapStartupProbe.md`. A matched native startup result
does not prove Codex transcription or real paired-phone reconnect behavior.

## Physical coverage: keep the claims separate

- `testPhysicalSoleViewerRemoteIOCapturesMicrophoneAcrossPublicAdmissionCycles` uses
  the spare development app's production RemoteIO, a registered MediaPlayer command,
  normal local WebRTC, three on/off cycles, real category/tag-drain receipts, advancing
  native capture and sender energy/RTP, and frozen capture after mic-off. Use a fresh
  inert development test process and its documented setup. It stores no PCM and does
  not touch the primary pairing or Mac host. This is **not** a reconnect test.
- `PairedReconnectPhysicalUITests.testThreeSameProcessHostRestartsThenColdRelaunchPreservePairing`
  is the existing real paired reconnect gate. Its coordinated driver is
  `iOS/opensteamer/scripts/validate-testflight-paired-reconnect.sh`. It requires six
  distinct microphone lifecycle proofs across initial/replacement connections,
  explicit disconnect/reconnect and cold relaunch, with fresh session/policy/transport
  identities and advancing capture/RTP evidence. Follow the driver's guarded runtime
  prerequisites; do not launch the UI test alone, restart the shared host, reset pairing
  or take the primary phone's audio ownership just to obtain a green result.
- For a claim about Mac consumption, require source-correlated capture from the visible
  product microphone as described in `TESTING_ORACLES.md`. Sender RTP, native callbacks,
  host forwarding and a green UI label do not establish intelligible far-end call audio.

Record the exact commit, app build, device, result bundle, skipped tests and scope proved.
A comment-only change does not need another TestFlight upload. A microphone behavior
change needs the applicable physical evidence; explicitly report any unexecuted reconnect,
route-change or call scenario instead of borrowing proof from an easier test.

## Enforcement and known baseline

There is currently no checked-in CI workflow. The archive/upload script verifies the
release artifact but does **not** run XCTest or consume these test results. These are
required engineering/release checks, not an existing automatic CI merge block. Do not
claim CI enforcement without wiring and verifying it separately.

Build 80's behavior changes passed 419 runnable Simulator audio tests (22 explicit/physical
skips), 35 Rust tests, the targeted negative mutations, and two fresh spare-phone launches
with three complete mic on/off cycles each. The user then confirmed the paired phone's
microphone works. The full disruptive paired reconnect gate was **not** rerun for build 80;
keep that evidence gap visible. Comments and tests reduce regression risk, not a guarantee
against every future OS, route or network failure.
