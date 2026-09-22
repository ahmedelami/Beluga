# Beluga startup-quality handoff

Prepared 2026-09-22 from the isolated `fix/spatial-quality-recovery` checkout.
This file is a handoff record, not a release approval.

## Current source and release boundary

- Branch: `fix/spatial-quality-recovery`
- Head: `4871f5655a46f06e38b77fcd8ad691022ce4cccf` (`5.6 luna is taking over here compared to 6 astra ultra`)
- The working tree was clean when this handoff was written.
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

## Evidence and reproducibility

- Startup matrix evidence: `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-46182-103c3pe`
- Restored-source gate: `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-55334-1yayw68`
- Spatial-recovery source and native receipts are referenced inline in `SPATIAL_RECOVERY_EXPERIMENT.md`.
- Probe-duration receipts are in the scratch artifacts referenced from that document, including `PROBE_DURATION_MEDIA_PAIR_1.md`, `PROBE_DURATION_MOVING_WEAK_PAIR_1.md`, and `PROBE_DURATION_MOVING_RECOVERY_PAIR_1.md`.
- QP/encoder receipts include `ENCODER_NATIVE_LOG_DIAGNOSTIC_2.md`, `VT_QP_ABBA_2.md`, `QP_OWNER_NATIVE_PAIR_1.md`, and `QP_OWNER_NATIVE_DRAIN_PAIR_2.md` in the associated scratch directory.

## Next-agent guardrails

1. Preserve every recorded RED, partial matrix, and stale-callback failure; do not relabel it as acceptance.
2. Before any new candidate, add a narrow falsifier and a source-bound gate for the exact branch being changed.
3. Keep production behavior and release selectors unchanged until repeated native media/recovery evidence passes, including weak controls and subsequent-pressure continuity.
4. Do not restart or install the live host, operate the phone, change audio/network settings, or deploy/TestFlight from this handoff alone.
5. If a future candidate is proposed, report separately: source/tests, native diagnostic evidence, installed/running state, and deployment/TestFlight state.

## Bottom line

The experiments produced useful diagnosis and regression guards, but **no candidate made the production cut**. The current branch is not evidence that the user's live clear–blurry–clear behavior is fixed.
