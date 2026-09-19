# Spatial-first startup: evidence and limits

Source base: `2cb336976d61ca4c149191a05489f22982014e86`.
Work branch: `perf/clear-first-screen`. Measurements below were made on 2026-09-19
with the pinned Xcode 26.6 / bundled LiveKit SDK, not the installed host or iPhone.

## Change

A new eligible Show starts with full source pixels at at most 5 fps. It retains the
existing video and peer-wide bitrate ceilings. This is not permission to use the
full-bandwidth tier. Qualified intermediate tiers preserve these startup pixels;
qualified full releases the frame-rate limit. Confirmed congestion restores the
ordinary spatial/temporal policy without restarting capture. Explicitly low configured
ceilings do not opt in.

Ownership is exact peer + Show. Missing/stale reports cannot supply positive or
negative capacity evidence. Native apply failure retains only a terminal same-Show
disproof, not the unapplied quality proposal. See `TESTING_ORACLES.md` for boundaries.

## Native characterization

All profiles used 1080x1920 synthetic desktop detail and 5 input frames/sec. Each
case ran in a fresh test process using real H.264 encoding/decoding, no audio tracks,
no host service, no phone, and no user pixels. Contrast compares phase-known decoded
dark/light stripe pairs against source contrast; it is not a readability score.

| Dense profile | Initial total ceiling | First decoded frame | 2-pixel stripe contrast |
| --- | ---: | ---: | ---: |
| A: quarter dimensions | 905,041 bps | 348 ms, 270x480 | 0.000 |
| B: full dimensions | 905,041 bps | 316 ms, 1080x1920 | 0.977 |
| C: full dimensions | 1,693,440 bps | 237 ms, 1080x1920 | 1.004 |

Simple-pattern repeat timings varied: A 285-533 ms; B 239-247 ms. Do not extrapolate
these timings to a remote iPhone or claim that full-size frames always encode faster.

The native production-policy loopback presented full 1080x1920 detail at 261 ms and
kept that geometry/contrast through a 10-second observation. Its zero local ICE RTT
correctly did not authorize FPS upgrades. This proves startup survival, not recovery
to full frame rate. Synthetic policy tests separately exercise qualified promotion.

The pre-Show experiment observed sender-scoped BWE increase from 300,000 to 1,693,440
bps in about 1.56 s, with zero encoded video frames/media bytes and successful native
padding-probe feedback. This background-probing behavior was NOT added to production.
Process-global feedback is supplemental, not a peer-specific authorization.

## Reproduction and unproven boundaries

Build tests once using the repository's pinned toolchain. Then set
`OPENSTEAMER_RUN_STARTUP_CLARITY_EXPERIMENT=1` and use `swift test --skip-build --filter`
to run one `WebRTCStartupClarityExperimentTests` method per fresh process. The default
test run skips these diagnostic experiments. Run `WorldwideScreenStartupSpatialPolicyTests`
and the surrounding video/floor/capacity policy suites normally.

Validation for this candidate: 239 focused adaptation/floor/capacity tests passed.
Three independent mutations (removing full-pixel shaping, accepting stale native
reports, and discarding failed-apply terminal disproof) each failed its behavioral
regression. The original policy file was restored byte-for-byte and all 239 tests
passed again.

The startup mode may remain at 5 fps until full capacity is qualified or real pressure
returns it to ordinary adaptation. These fixtures do not establish moving-content load,
Internet packet loss/latency, simultaneous microphone/audio load, or iPhone presentation.
No deployment or physical-device result is implied by these source-level experiments.
