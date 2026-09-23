# V88 startup-quality live decision: rollback, not promotion

Date: 2026-09-23. This is a design and release decision, not a new adaptation
patch or proof that the preceding version solves every network condition.

## Goal and constraints we kept

The user wanted the remote Mac screen to become readable quickly and stay usable:
no clear-to-blurry dip at connection, no long-lived severe blur after a pressure
event, and no automatic black screen. Adaptation should preserve motion, typing,
audio, and the acknowledged Show session while responding to genuinely weak
bandwidth. Existing traffic ceilings and independent congestion guards still
apply; sharp pixels are not permission to overload the path.

## Direction tried in V88

Source commit `4f53f14cce2ae6731c297448f30f66f24d50268d` strengthened the
existing full-pixel startup overlay into a persistent **temporal-first** guard:
keep full-size pixels for the exact peer/Show while an early bandwidth estimate
may lower bitrate and frame rate. Bandwidth alone needs
sustained, same-pair offered-load evidence and an independent path-limitation
witness before it can retire that spatial privilege. A fresh queue, RTT, or route
hard-pressure signal may still retire it immediately. This was meant to avoid
the earlier clear -> blurry -> clear response to an unproven early estimate,
without weakening congestion safety. It did not invent the first full-size
frame. The source-sealed deterministic/native checks passed before installation,
but they were not a live-quality oracle.

## What the live V88 session actually showed

The installed, sole Mac `CaptureServer` was V88 (PID 37994; executable SHA-256
`545692d03e84339fd7b8d2bf70e7f572318725f05803b0681d649f1866b211d9`).
The user reported an initially clear image becoming extremely blurry and never
recovering. Filtered host telemetry for one peer/Show corroborated the encoded
resolution transition; no client-side screenshot or decoded-pixel trace was
collected for this session.

| Relative to first sampled frame | Observed host state |
| --- | --- |
| 0 s | 1080×1920 at 8 fps, startup spatial guard active, estimated available bitrate 478 kbps, RTT 4 ms. |
| ~0.51 s | Send queue 403.9 ms; guard disproved as `confirmedQueuePressure`, tier `audioPriority`. |
| ~1.04 s | 90×160 at 1 fps; send queue 927 ms. Observed peak queue: 1,225 ms. |
| Following ~72 s | 175/177 samples at 90×160 and 176/177 at `audioPriority`; maximum sampled estimate 972 kbps. No admitted spatial-recovery attempt (`spatialRecoveryAttempt=0`), and no qualified capacity-probe tier (`probeBest=none`). Later samples remained 90×160 even when instantaneous queue was 0 ms and RTT ~4 ms. |

The 403.9 ms queue exceeded the existing one-sample 200 ms hard-pressure
threshold. The immediate spatial downshift therefore followed a deliberate
safety guard; it was **not** raw bandwidth alone bypassing the new proof rule.
What failed was the end-to-end user goal: full pixels survived only briefly,
then the severe floor persisted for the sampled session. The V88 formulation
must not be described as a successful startup-quality fix.

## Inference versus unknowns

The full-resolution startup burst under a sub-Mbps estimate may have helped
create the queue pressure, but the logs do not isolate that cause from actual
link capacity, WebRTC sender pacing, or other transport behavior. A later zero
instantaneous queue does not alone prove sustainable capacity. The zero
`spatialRecoveryAttempt` count says no recovery trial was admitted in these
samples; it does **not** identify which admission condition prevented one.
We have no controlled, same-link decoded-pixel V86/V88 A/B for this report.

## Decision and next falsifier

V88 remains in source as a failed live candidate and diagnostic record, not the
installed host. A fresh one-shot V89 transaction restored the exact preserved,
signed V86 Mac host after the viewer and product microphone route naturally
released. Independent post-install checks found sole running PID 94637,
executable SHA-256
`b6d51fce0a9d2169d2ee28749210a3faee6f1f7360063060c97b11c298e63d5b`,
the expected signed bundle/plist, display, pairing, audio routes, and committed
rollback receipt. V88 evidence and rollback backup were retained. This was a
Mac-host rollback; no iOS/TestFlight build changed. User-visible quality on V86
still needs a fresh physical reconnect observation.

Do not respond by disabling the queue/RTT/route hard-pressure guard, raising
traffic ceilings, forcing a long warmup or 1-fps hold, or calling a single sharp
frame recovery. The next candidate should first falsify the burst hypothesis
with synchronized encoded **and decoded** pixel/FPS timing, selected-pair BWE,
video/pair send rate, sender queue/residence, RTT, packet and recovery-admission
reasons across steady ample, steady weak, drop/recovery, and second-drop cases.
It needs a bounded path from necessary downscale back to readable pixels when
capacity is proven, without blackout, input remount, or audio regression. Keep
the existing [startup guardrails](SCREEN_STARTUP_REGRESSION_GUARDRAILS.md) and
[handoff history](HANDOFF_CONTEXT.md) binding; source tests alone are not release
approval.

Evidence: safe filtered `Worldwide screen network peerGeneration=1 showEpoch=1`
records in `/var/tmp/opensteamer-worldwide-host.log` (around collection-time
lines 6044398, 6044403, 6044417, and 6045972); private diagnostic note
`/Volumes/t7/beluga-v88-blur-regression-2026-09-23.md`; V89 result/journal under
`~/Library/Application Support/opensteamer/paired-host-updates-v89/`.
Raw host logs may contain pairing material and must not be committed or copied
wholesale.
