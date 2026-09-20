# Startup burst characterization

This is an isolated, synthetic video-only experiment, not a production adaptation
change or a deployment. It investigates the observed clear–blurry–clear startup
without relaxing real-congestion guards or changing any running host or phone.

## Comparisons

- 8 Mbps and 0.8 Mbps host-to-viewer UDP-payload service rates, 8 Mbps reverse
  service, and 2 ms propagation each way. These are modeled links, not real WANs.
- Identical dense still content and synthetic photo/text motion at 30 Hz in wall
  time. Source sampling follows the production adaptation policy.
- Cold start versus a two-second connected, no-screen-frame warmup at the same
  sender ceiling. This is a quiet warmup, **not** a deliberately raised-capacity
  padding probe; missing encoder counters stay unknown in the evidence.
- Moving-content cold start versus capture limited to 1 fps for the first two
  seconds. The first full-resolution frame is unchanged. Restoration responds
  within a bounded polling interval; actual source submissions are recorded.
- A moving-content 8 → 0.8 → 8 Mbps capacity change at four/eight seconds.

The matrix runs each of eleven cases three times in separate fresh processes.
Fixture buffers are prepared before ICE starts so image generation cannot quietly
warm the estimator. Report first-frame latency from capture, Show, and transport
readiness separately; a fixed warmup must not hide its added user-visible delay.

## Measurement and limits

Native reports retain optional encoded/key/huge-frame counts, cumulative encode
time and QP, feedback counts, target bitrate, and a bounded quality-reason enum.
Missing/malformed fields remain unknown. These fields do not grant adaptation
permission and do not identify an individual encoded frame's size.

The decoder measures actual dimensions, signed fine-stripe contrast, a synthetic
motion-phase marker, and dense-region pixel differences. Frame counts alone do
not prove changed content. Fine-stripe contrast is not subjective iPhone text
readability or image-wide fidelity. Timestamps here are local fixture timing,
not glass-to-glass measurements on the user's phone.

The relay serializes independently in each direction, retains partial service
across rate changes, and bounds pending data at 4 MiB/4,096 packets and two seconds
of packet age. It counts UDP payload bits, not IP/link overhead. Original fixed
delay is retained when rates are absent, except prolonged stalled callbacks now
expire under the explicit age bound. ICE pinning and pre/post-start blackout
checks prove the peers did not bypass the impairment. Saturated observation
storage cannot satisfy the blackout check.

Actual delivery lateness and release-batch maxima are distinct from ideal modeled
serialization. Qualify or reject scheduling-dominated runs rather than treating
catch-up batches as faithful network pacing. The native cumulative packet-delay
delta is retrospective average packet send delay, not instantaneous queue depth.
The timing/units distinction follows the
[WebRTC statistics definitions](https://www.w3.org/TR/webrtc-stats/#dom-rtcoutboundrtpstreamstats-totalpacketsenddelay).

## Reproduction

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer \
  scripts/validate-screen-startup.sh \
  --scratch-path /absolute/dedicated/startup-build \
  --jobs 2 --capacity-experiment

ruby scripts/summarize-startup-capacity.rb /absolute/gate-evidence-directory
```

The runner builds once, checks the source identity between phases, rejects absent
or skipped methods, and requires the deterministic suites and the two existing
native checks before the capacity matrix. Its fake-runner checks validate result
handling, not product behavior. The summary reads only completed passing phases
and explicitly reports a partial matrix as partial.

Native experiments use synthetic buffers and `.videoControlOnly` peers. They do
not capture the desktop, connect a phone, start the host app, modify system
networking, touch pairing, or take microphone/audio ownership. Production/WAN,
duplex audio, and real iPhone presentation remain separate acceptance boundaries.

## Results

Completed 2026-09-20: 33/33 matrix phases, the two existing native checks,
and 362 deterministic methods passed without skips. A pass means the
characterization ran and its integrity checks succeeded; it does **not** mean
the candidate improved performance. Three runs per case are a small experiment,
not a statistical reliability guarantee. Case order is fixed, not randomized;
small timing differences cannot be uniquely attributed to estimator warmup.

First-frame values below are medians from capture submission, and the first
decoded frame met the fine-detail criterion in every run. The blurred-duration
column measures displayed non-sharp frames after that first sharp frame, within
the 12-second observation window (16 seconds for drop/recovery).

| Link / content | Cold first sharp | Warm first sharp | Cold / warm final decoded FPS | Blur in stable cold/warm cases |
| --- | ---: | ---: | ---: | ---: |
| 8 Mbps / still | 346 ms | 238 ms | 13 / 12.5 | 0 s |
| 8 Mbps / moving | 334 ms | 244 ms | 13 / 13 | 0 s |
| 0.8 Mbps / still | 350 ms | 463 ms | 5 / 5 | 0 s |
| 0.8 Mbps / moving | 361 ms | 420 ms | 5 / 5 | 0 s |

The warm start adds approximately two seconds before capture. Median time from
transport readiness to first picture was 2.31–2.55 seconds for the warm cases,
versus 0.35–0.37 seconds for the cold cases. All warmup encoder samples actually
reported zero encoded frames; no samples were missing. This does not validate a
deliberate padding-probe warmup or predict hidden-time user behavior.

The moving-content two-second **1-fps hold is rejected** as a production candidate:

- At 8 Mbps, first picture was 340 ms median and final cadence 13 fps: no useful
  demonstrated improvement over ordinary startup.
- At 0.8 Mbps, first picture was still 358 ms median, but all three runs became
  90×160 at 1 fps and stayed non-sharp through the observation deadline. They spent
  5.164–5.196 seconds displaying degraded frames after the first sharp frame.
- Maximum interval-average native sender packet delay was 894–922 ms. Relay
  release lateness in those runs was 1.87–14.75 ms; no queue overflow or age expiry
  occurred. That supports sender-side buffering, not a stalled relay timer, but
  does not make the native pressure signal false or identify one frame as its cause.
- Actual source submission timestamps prove the 1-fps hold was released. These
  results reject this particular hold, not every possible form of encoder shaping.

In the **8 → 0.8 → 8 Mbps** runs, all three cases recovered motion to 29.5–30 fps,
but ended at **720×1280**, not the original 1080×1920, eight seconds after capacity
was restored. The 10.625–10.889 seconds of non-sharp display includes both genuine
congestion and the unrecovered tail; it is not a measurement of recovery delay alone.
Code inspection explains why waiting is not enough: after same-Show startup
disproof, only the ordinary full tier restores scale 1, and its sustainable
threshold is 12 Mbps (16.2 Mbps for direct upgrade). The 8 Mbps path instead fits
the balanced tier; ordinary recovery cannot trade back to full pixels at 13 fps.

Across the matrix there were no relay overflow/expiry drops. One ordinary weak
moving run had a 28.91 ms maximum release-lateness outlier; do not overinterpret
small latency differences from these local runs. Unchanged stable-path baselines
did **not** reproduce the original live 406 ms sender-delay episode. No claim is
made that its root cause has been reproduced or that the live blur issue is fixed.

### Decision and next experiment

Do not ship either tested startup variant or loosen the congestion thresholds.
Keep the optional diagnostics and reusable fixture. The next supported candidate
is a **separately authorized, bounded full-pixel/low-FPS recovery trial** after
fresh evidence establishes recovered capacity. It must not clear or resurrect
the retired startup permission, exceed existing traffic ceilings, overlap probes,
or borrow cached/missing evidence. Exact peer/Show/route ownership, fresh RTT and
packet-delay evidence, cancellation on genuine pressure, expiry without reports,
and the existing input/capture continuity fences remain required. That candidate
has not been implemented or validated by this experiment.

### Retained evidence

- Matrix/source identity and per-phase results:
  `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-46182-103c3pe`.
- Source manifest SHA-256:
  `3880d9c7f9b01db919af921c40b4a83a5312dfd2e01cb33d8e1f1ab46c970887`.
- Runner fake tests: 50 scenarios passed. Initial attempts retained a compile
  diagnostic and then an interleaved stdout/XCTest failure; neither was counted.
  The successful invocation rebuilt with the expression split and diagnostics
  flushed before method return; no rejection rule was relaxed.
- Mutation evidence: `/Volumes/t7/beluga-startup-burst.fkXnsz/mutations.RA0iez`.
  Removing finite-rate serialization produced two assertions in
  `testIdleTimeDoesNotAccumulateBurstCredit`; dropping `keyFramesEncoded` produced
  one assertion in `testParsesOptionalEncoderDiagnosticsWithoutReplacingExistingEvidence`.
  Both built and ran exactly one test, exited nonzero, and failed assertions—not
  compilation, skipping, timeout, or an empty test selection. Neither mutant ran
  a native fixture or touched production. Source hashes were restored exactly.
- Final restored-source validation:
  `/Volumes/t7/beluga-startup-burst.fkXnsz/swift-build/validation-runs/startup-20260920-55334-1yayw68`.
  All 362 deterministic methods and both fresh-process native methods passed.
  Its source identity exactly matches the 33-phase matrix above, so the matrix
  need not be rerun after restoring the deliberate mutations.
- The running host remained PID 66690, started 2026-09-19 22:40:30, at the same
  installed executable path. No host install/restart, TestFlight upload, phone
  operation, or production policy change occurred during this experiment.
