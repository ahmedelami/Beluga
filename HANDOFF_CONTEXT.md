# Beluga startup-quality handoff

Prepared 2026-09-22 from the isolated `fix/spatial-quality-recovery` checkout.
This file is a handoff record, not a release approval.

## Current source and release boundary

- Branch: `fix/spatial-quality-recovery`
- Diagnostic code baseline before this handoff: `4871f5655a46f06e38b77fcd8ad691022ce4cccf`
  (`5.6 luna is taking over here compared to 6 astra ultra`). The first handoff-only
  child was `7dd2da7b796bd5d43c59340325e4159265ea41ad`; use Git rather than this document
  to identify the branch's current documentation head.
- The working tree was clean when the original handoff was written.
- The work below is diagnostic/experimental. No candidate was installed on the Mac host, uploaded to TestFlight, deployed to production, or validated on the user's iPhone as a release.
- Do not describe passing deterministic tests or a passing isolated native run as proof of a production fix.

## What was measured

### Startup burst characterization

`STARTUP_BURST_EXPERIMENT.md` records the completed synthetic matrix:

- 33/33 matrix phases, the two existing native checks, and 362 deterministic methods passed without skips.
- Cold first sharp frame was about 0.33–0.36 s on both ample and weak modeled links. The two-second warmup added about two seconds before capture and is not a user-transparent optimization.
- The moving-content 1-fps startup hold is rejected: on the weak link it stayed at 90x160/1 fps and non-sharp through the deadline.
- In the 8 → 0.8 → 8 Mbps recovery cases, motion returned but the stream ended at 720x1280 rather than restoring 1080x1920. The existing sustainable-tier thresholds explain that result.
- Decision: do not ship the tested warmup/1-fps variants and do not loosen congestion thresholds.

### Spatial-recovery policy work

`SPATIAL_RECOVERY_EXPERIMENT.md` is the detailed chronology. The important release facts are:

- Many deterministic policy/oracle gates and deliberate source-mutation checks passed, and source restoration was verified by hashes.
- Native recovery matrices remain incomplete or RED. Examples include the weak steady-control failure, missing second-drop proof, and ordinary-lane evidence gaps. These are retained failures, not passes to be retried until green.
- One pre-admission-hold cohort completed 9/15 phases before a weak control failed; the incomplete cohort is not an acceptance result.
- The 40 ms probe-duration candidate passed isolated feedback and media pairs but did not demonstrate a net improvement: the moving-recovery pair was about 1.03 s slower to recover than the 15 ms control. Keep the candidate default-off.
- No cached, missing, malformed, stale, or cross-lane evidence may authorize a new geometry trial. Existing pressure, ownership, deadline, packet, RTT, and source/capture-continuity guards remain binding.

### Encoder/QP diagnostics

- Native encoder-boundary diagnostics showed sparse output after encoder entry and then aligned seven dropped inputs with native H.264 drop notices in the synthetic path. This does not identify a production VideoToolbox failure by itself.
- The isolated QP39/unset ABBA comparison delivered 3/12 frames with QP39 and 8/12 unset, but the unset arm sent about 10x the bytes; it is not bandwidth-safe release evidence. Hardware-status readback was unsupported, not proof of hardware/software mode.
- The actual-WebRTC QP comparison verified owned QP assignments/omissions, but the unset arm was RED because of an outer callback trace failure. A later ownership/drain pair passed its lifecycle checks and showed earlier changing pixels, while recovery was 508 ms slower in the unset arm.
- Interpretation: this supports, at most, a separately bounded startup-only diagnostic. It does not justify changing global QP policy, congestion behavior, or deployment.

### Bounded startup-only QP follow-up

The later scratch evidence in `QP_STARTUP_ONLY_PLAN.md` must be retained alongside
the earlier negative results:

- The test-only treatment omits the owned QP39 assignment only until one
  process-owned deadline measured from the first owned native encode admission.
  Owner, generation, and session replacement cannot rearm it. Before a first
  post-deadline admission, a deferred live session must restore QP39 with both a
  successful native setter and typed readback. It does not use a timer, flush,
  reset, or forced keyframe. Uncertain ownership or failed restoration fails the
  diagnostic closed and prevents further omission.
- The public VideoToolbox live-restoration prerequisite passed: 14/18 inputs
  decoded; inputs 10 through 17 after restoration were all full-pixel with minimum
  signed contrast 0.985596. Typed readback changed from -1 at 1811.494 ms to 39 at
  2005.322 ms and remained 39 through 3409.250 ms. The contributor gate passed
  640 required methods, its fake runner passed 155 scenarios, and fresh control,
  startup, and replacement-owner native prerequisites passed. The native receipt
  still says `numeric_oracle_pending:true`, so it is not standalone numeric media
  proof. Compiled no-restoration and owner-rearm mutants were rejected with 17 and
  23 assertions respectively.
- The fixed 2.0-second pair passed both strict receipts and advanced first changing
  full-size content from 2365.846 ms to 1224.317 ms, but ended at 5 decoded fps in
  the startup arm versus 13 in control. That sustained-cadence regression blocks
  promotion even though ownership, restoration, recovery, blackout, and teardown
  gates passed.
- The 1.0-second investigation remains RED and incomplete. Its first startup run
  failed closed because the compiled Swift admission still required 2.0 seconds.
  After a proper rebuild, the fresh control failed the unchanged no-reblur
  assertion; the candidate arm was therefore not run. The earlier isolated control
  cannot be represented as a pair.
- One 1.5-second control/startup pair passed both strict receipts under temporary
  source seal `8c1a349e...` and hook seal `cd91743c...`. First changing content was
  2201.642 ms control versus 1231.758 ms startup; recovery was 3455.082 ms versus
  1951.114 ms; final decoded cadence was 13.5 versus 13.0 fps. Ownership,
  restoration, capacity, pixel, no-relapse, blackout, and teardown checks passed.
  The unusually slow control recovery compared with the 2.0-second pair leaves
  run-order/process variance unresolved. At the time of that pair the temporary
  1.5-second source, hook, and oracle were restored to their sealed 2.0-second
  baseline, so this was evidence only, not a current deployable implementation.

#### Predeclared 1.5-second replication

Before any production work, the next falsifier is one fresh-process four-arm ABBA
replication using the unchanged strict 8 -> 0.8 -> 8 Mbps moving-recovery fixture:
control A, startup A, startup B, control B. The diagnostic must stop on the first
RED and retain that failure. Both order directions must show an earlier first
changing full-size frame for startup, recovery must not be slower in either paired
comparison, and each startup final decoded fps must be at least 90% of its paired
control (so the 2.0-second 5-versus-13 regression cannot pass). Every existing
ownership, restoration, source/capture continuity, capacity, pixel, no-reblur,
blackout, and teardown assertion remains binding. Passing this replication still
does not authorize production or release; the next lanes would be steady weak-link
and subsequent-pressure continuity evidence.

The branch now admits only the exact `control1500` and `startup1500` test arms for
this replication, maps them to the unchanged native control/startup modes, and
requires the preloaded hook to report exactly 1,500,000,000 ns. Arbitrary or
lookalike durations remain rejected. Before the native run, 9/9 focused admission
tests, 157/157 fake-runner scenarios, and the full 642-method deterministic
contributor gate passed without skips. Evidence for the latter is
`/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260923-38133-qqq6s3`.

#### Replication result: RED

The four fresh arms all passed their unchanged strict per-process receipts, but
the predeclared aggregate acceptance failed and the investigation stopped:

| Arm | First changed full-size frame | Recovery latency | Final decoded fps |
| --- | ---: | ---: | ---: |
| control A | 2359.830 ms | 330.178 ms | 12.5 |
| startup A | 1235.689 ms | 388.558 ms | 13.0 |
| startup B | 1223.774 ms | 2353.937 ms | 12.5 |
| control B | 2372.085 ms | 2401.956 ms | 12.5 |

Startup advanced the first changed full-size frame by 1124.141 ms in pair A and
1148.311 ms in pair B, and both cadence ratios cleared the 90% floor. Pair B
recovery was 48.020 ms faster, but pair A recovery was 58.380 ms slower. The
predeclared rule required recovery to be no slower in both order directions, so
the 1.5-second candidate is **not accepted**. Do not average the opposite recovery
results, retry away this RED, or proceed to the weak-link or subsequent-pressure
lanes from this candidate.

All four arms used source identity `01e538e3...`, test binary `153a0e4a...`, QP
hook `cd91743c...`, QP oracle `22ce0e88...`, runner `25b92d23...`, bridge
`a0a59e41...`, and drain oracle `0dc76666...`. The independently rechecked summary
is `/Volumes/t7/beluga-startup-burst.fkXnsz/pacer-bridge.xjZwtL/startup-qp-media-abba-6.summary.json`
(SHA-256 `7c088b00ca3fc457c19f9457648ca8df663b4fd43380ef81e81bac53d7281e4c`).
The active generic scratch artifact remains the reproducible sealed 1.5-second
hook; the prior sealed 2.0-second library is preserved separately as
`libVTQPStartupHook-2000ms-c6b4d507.dylib`. Neither artifact is production code or
installed state.

## Evidence and reproducibility

- Startup matrix evidence: `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-46182-103c3pe`
- Restored-source gate: `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-55334-1yayw68`
- Spatial-recovery source and native receipts are referenced inline in `SPATIAL_RECOVERY_EXPERIMENT.md`.
- Probe-duration receipts are in the scratch artifacts referenced from that document, including `PROBE_DURATION_MEDIA_PAIR_1.md`, `PROBE_DURATION_MOVING_WEAK_PAIR_1.md`, and `PROBE_DURATION_MOVING_RECOVERY_PAIR_1.md`.
- QP/encoder receipts include `ENCODER_NATIVE_LOG_DIAGNOSTIC_2.md`, `VT_QP_ABBA_2.md`, `QP_OWNER_NATIVE_PAIR_1.md`, and `QP_OWNER_NATIVE_DRAIN_PAIR_2.md` in the associated scratch directory.
- Startup-only QP receipts and exact artifact seals are recorded in
  `/Volumes/t7/beluga-startup-burst.fkXnsz/pacer-bridge.xjZwtL/QP_STARTUP_ONLY_PLAN.md`.
  Preserve `startup-qp-media-pair-3-*`, both 1.0-second pair-4 RED attempts, and
  `startup-qp-media-pair-5-15-*` with their `.result.json` receipts.

## Next-agent guardrails

1. Preserve every recorded RED, partial matrix, and stale-callback failure; do not relabel it as acceptance.
2. Before any new candidate, add a narrow falsifier and a source-bound gate for the exact branch being changed.
3. Keep production behavior and release selectors unchanged until repeated native media/recovery evidence passes, including weak controls and subsequent-pressure continuity.
4. Do not restart or install the live host, operate the phone, change audio/network settings, or deploy/TestFlight from this handoff alone.
5. If a future candidate is proposed, report separately: source/tests, native diagnostic evidence, installed/running state, and deployment/TestFlight state.

## Bottom line

The experiments produced useful diagnosis and regression guards, but **no candidate made the production cut**. The current branch is not evidence that the user's live clear–blurry–clear behavior is fixed.
