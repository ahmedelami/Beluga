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

## Invariants and independent oracles

All policy cases below are in `macOS/Tests/CaptureServerTests`. Report-copy cases are
in `shared/Tests/WebRTCTransportTests`.

| Preserve | Sensitive boundary | Behavioral oracle |
| --- | --- | --- |
| Full startup pixels do not raise video or peer-wide ceilings; source FPS and explicit low caps still win. | `WorldwideScreenVideoAdaptationPolicy.currentRecommendation` and startup eligibility | `WorldwideScreenStartupSpatialPolicyTests`: Show ceilings, low ceiling, configured source FPS; sequence suite varies caps/FPS. |
| Qualified moderate capacity improves motion rather than freezing at cold-start 5 fps. Pixel-rate shaping is not bandwidth permission. | Startup recommendation shaping | `testQualifiedModerateBandwidthDoesNotFreezeMotionAtColdStartFPS`, `testQualifiedSpatialFPSRetainsOnMissingBWEAndRetiresOnConfirmedPressure`. |
| Missing, cached, malformed or stale evidence cannot mint health, raise caps, or masquerade as fresh congestion. Advancing request sequence alone is insufficient. | Native report identity fence before policy mutation | `testNewRequestWithStaleOrMissingNativeReportCannotApplyNegativeEvidence`, `testDuplicateNativeReportCannotPromoteStartupFPS`, RTT/freshness suites. |
| Diagnostic enrichment never becomes native route evidence. Report timestamp is identity, not a lease or a new RTT measurement. | `WebRTCScreenVideoStatisticsReport` copies and service sampler | `WebRTCScreenVideoStatisticsReportTests`, `testCachedDiagnosticRouteCannotTurnMissingNativeEvidenceIntoAReplacement`; service wiring check is supplementary. |
| Only an exact whole-pair gap can hold an already accepted probe cap. It cannot renew primary RTT health, extend the absolute deadline, or grow the cap. | `startupSparseProbeDeadline`, regular/fast report handoff | Sparse-pair and fresh-fast-RTT tests, including malformed ordinary reports, primary lease expiry, probe deadline and observable queue baseline. |
| Independent fresh route replacement, queue pressure and BWE collapse still win during a gap. | Fast-lane negative checks **before** bounded wait | `testFreshFastRTTBridgeStillAppliesIndependentPressureAndRouteBoundaries`, `testSparseFastSelectedPairStillAppliesImmediateSenderQueuePressure`. |
| Startup permission belongs to the exact peer and Show. Hide/replacement cannot resurrect it; rejected native apply retains only same-Show terminal disproof. | Lifecycle resets and `retainStartupSpatialModeTerminalState` | Lifecycle/failed-apply spatial tests and `WorldwideScreenStartupInvariantSequenceTests`. |
| Adaptation keeps the acknowledged capture surface, framebuffer mapping and input session. Pressure may degrade quality, not cause automatic blackouts or keyboard remounts. | Service apply path and input/capture transform | `WorldwideRemoteInputScaleTransitionTests`, surrounding video/floor suites; physical typing and presentation remain separate release checks. |
| Actual encoded/decoded detail survives delayed transport and eventually improves decoded FPS. A requested parameter is not a rendered frame. | Native production-policy fixture | `testDenseProductionPolicyDelayedNetworkWithDynamicFrameRateCharacterization`. |
| The native fixture cannot silently bypass its impairment path. | Pinned fixture-local UDP relay, all ICE candidates | `testDelayedNetworkBlackoutPreventsDirectICEBypass` plus the dynamic fixture's post-start blackout. |

`WorldwideScreenStartupInvariantSequenceTests` composes transitions rather than merely
checking isolated happy paths. Keep its seeds deterministic and diagnostics reproducible.
Assert observable ceilings, geometry, FPS, ownership and terminal state independently of
the implementation; do not compute all expectations by calling the function under test.

## Prove that regressions are caught

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
