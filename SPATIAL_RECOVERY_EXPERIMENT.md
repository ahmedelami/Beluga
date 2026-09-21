# Spatial recovery candidate — in progress

This isolated experiment follows `STARTUP_BURST_EXPERIMENT.md`. The running host,
TestFlight app, audio devices, and system network settings have not been changed.
It is **not release-ready**.

## Acceptance declared before the candidate run

Use synthetic moving 1080×1920 video on the fixture-local bounded UDP relay:
8 Mbps, then 0.8 Mbps at 4 seconds, then 8 Mbps at 8 seconds. Require actual
downscaled decoded frames during the weak interval, and full-source-size decoded
detail (all stripe contrasts >0.9) within 4 seconds of the actual restoration.
Require at least 2 seconds of sustained sharpness with changing decoded content.
A second drop must still degrade quality without stopping the visible source.
Candidate-off and steady ample/weak controls remain separate checks.

## First candidate: rejected by its native oracle

The first version admitted recovery only at the balanced/high ordinary tiers,
after bitrate discovery ended. Its 33 new deterministic tests passed, but those
tests were insufficient to prove the requested decoded behavior.

Evidence directory: `/Volumes/t7/beluga-startup-burst.fkXnsz/spatial-first.IyIaub`.
The test executable used for both runs had SHA-256
`c8c7f3ab8b6e43f395a738c86cd1e4df806eaba1d72803382927b015bebaf4a8`.
These are diagnostic runs, not the final source-manifest-bound release gate.

| Run | Actual restoration | Outcome |
| --- | --- | --- |
| ON (`native.log`) | 8.067 s after capture | No recovery attempt and no sharp full-size recovery within the 16 s observation; native assertion failed. |
| OFF (`off.log`) | 8.078 s after capture | No sharp full-size recovery; characterization passed because OFF does not require recovery. |

In ON, measured BWE stayed near 0.77 Mbps until about 11.1 seconds and reached
the balanced ordinary tier only near 14.65 seconds. In OFF it reached balanced
near 11.65 seconds. One run each does not attribute that timing difference to
the candidate; ON never actually began a spatial trial. It does show that
waiting for the ordinary balanced ramp is not sufficient for the declared goal.

The next revision permits a separately qualified full-pixel trial at the existing
constrained tier's ordinary caps (5 fps), ending any overlapping bitrate discovery
without granting extra traffic. Unsupported lower tiers no longer masquerade as
fresh adverse RTT evidence on every healthy report. The original startup disproof
remains terminal. The four-second target has not been relaxed.

## Constrained-tier candidate: still too late

The source-bound gate at
`swift-build/validation-runs/startup-20260920-21553-jaeaox` passed 415 deterministic
methods and both original fresh-process native methods. Its first OFF control had
no full-size recovery. ON restored full-size decoded detail 5,826.718 ms after the
actual capacity restoration (8.081 s to 13.908 s), missing the four-second target;
the two-second sustained-sharpness assertion also failed. The gate stopped there.

Measured BWE remained about 0.677 Mbps through 10.094 s and the ordinary tier
remained survival until 12.626 s. Constrained qualification at 13.144 s and the
full-pixel trial at 13.660 s still waited for bitrate discovery. The native apply
and decoder added about 248 ms after that trial. This isolates admission behind
the ordinary tier ramp as the dominant delay in this run, not native application.

The failing test's JSON was interleaved with two XCTest assertion lines; diagnosis
removed only those lines in memory, without changing retained evidence. Flush the
JSON before assertions in subsequent runs. Do not count that repaired diagnostic
parse as a valid completed machine-readable gate.

## Earlier survival-tier candidate: fast but not sustained

The diagnostic run at `spatial-survival.TcpkJX/native.log` first restored full sharp
pixels 2,111.514 ms after capacity returned (8.005 s to 10.117 s). It still failed
the unchanged sustained-sharpness oracle: two fresh fast-lane packet-delay samples
revoked the trial at 11.056 s, and downscaled decoded output resumed at 11.437 s.
All 46 selected recovery tests passed before this run; this was not a full gate.

At admission, stopping an existing authorized capacity probe contracted the native
total ceiling from 3.442 Mbps to the survival tier's 0.905 Mbps despite measured
BWE of 1.721 Mbps. Full-size moving frames then accumulated local pacer delay while
RTT remained 6 ms and the restored relay drained normally. The negative guard did
its job. Do not remove it or treat these full-size frame counters as success.

This suggests testing whether spatial recovery can preserve an already-authorized
ordinary capacity probe, as startup spatial mode already does, rather than coupling
the geometry change to that ceiling contraction. That would revise the candidate's
no-overlap design, not raise the existing probe/configured ceilings or relax any
native acceptance target. It needs explicit interaction and failed-apply tests.

## A short-window pass was insufficient

`spatial-retained-probe.1X6tLh/native.log` passed the original native assertions:
first sharp recovery was 230.044 ms after restoration and lasted two seconds.
The full trace nevertheless showed the trial expiring at 10.618 s and a later
return to downscaled output. No capacity probe was active at this run's admission,
so it does not establish benefit from preserving an existing probe. It is **not**
successful recovery. The native oracle now additionally requires full sharpness
from first recovery until the next actual capacity drop or the observation end.

The failed confirmation window had sharp moving full-size output, native RTT of
5–7 ms, and local packet-delay averages around 34–55 ms. There was no affirmative
pressure; the new candidate's strict 20 ms confirmation threshold kept resetting
its witnesses until expiry. The next diagnostic separates geometry confirmation
from capacity-growth admission: admission stays at 20 ms, while an already-applied
trial may confirm below the existing 100 ms soft-pressure boundary. This cannot
raise any bitrate cap. Greater delay, fresh pressure, missing evidence, native
identity, RTT, encoded-frame progress, deadline, and retry guards remain binding.
Boundary tests and the strengthened complete-interval pixel oracle must validate
this distinction before treating it as an improvement.

## Confirmation revision and cross-lane evidence loss

`spatial-confirmation.VkP53m/native.log` recovered sharpness in 3,468.588 ms,
stayed sharp through the complete restored interval, and ended accepted at 13 fps.
The subsequent gate `startup-20260920-31816-16ibui6` passed 427 deterministic
methods, both original native methods, OFF and ON, but failed the second-drop case:
full detail returned in 2,990.161 ms, then the trial expired before the actual
second capacity drop. This is not a completed matrix or release-ready candidate.

That failing trace exposed cross-lane packet-window loss. Ordinary reports at
11.187, 12.193 and 13.200 s had advancing full-size encoded-frame counts but no
new packets *since the immediately preceding fast poll*. The shared recovery
packet baseline hid real packet progress since the previous ordinary report.
The reducer correctly refused to turn no-packet evidence into confirmation;
the producer needs distinct ordinary-positive and fast-negative baselines, with
cross-lane invalidation on malformed/reset evidence. The next candidate changes
that provenance boundary, not the frame, capacity, pressure or deadline guards.

## Separate ordinary and fast packet windows

`spatial-window.JicPnj/deterministic.log` passed all 51 selected recovery methods.
Its second-drop native diagnostic (`native.log`) restored full sharp detail in
1,984.284 ms, retained it until the real second drop at 14.093 s, and then degraded
without stopping the source. All native assertions passed. This is one diagnostic
run, not the required repeated matrix; the complete gate is running separately.

## Repeated matrix: remaining sparse-statistics motion collapse

The next gate `startup-20260920-35630-zfjg6n` passed 429 deterministic methods,
both original native cases, OFF and ON. The second-drop case recovered full pixels
in 3,504.788 ms and retained sharpness, but failed the required motion continuity;
the fixture correctly refused to trigger a second drop without that proof.

At 12.107 s, while recovery was already accepted, one fast report had no BWE or
RTT. With about 535 ms still left on the existing capacity probe and the preceding
healthy RTT only 2.462 s old, the policy reverted its critical-tier probe to the
audio-priority origin and cut the cap from 14.324 Mbps to 0.486 Mbps. A healthy
ordinary report arrived about 96 ms later. Requested FPS nevertheless fell from
5 to 1. This is separate from pixel acceptance: the existing cold-start bounded
sparse-pair protection is not currently available to independent recovery.

The next revision must preserve only an already-owned, unexpired probe during an
exact whole-pair gap, under its prior primary RTT lease. It must not borrow startup
permission, grow capacity, renew time, or excuse malformed evidence and independent
congestion. The trace now records native route/RTT-observation absence and encoded
dimensions explicitly to distinguish those boundaries in subsequent experiments.

## Recovery-owned sparse-pair hold

`spatial-sparse.RDuGGH/deterministic.log` passed 108 targeted recovery/startup methods,
including the six new sparse-pair groups. Its second-drop native diagnostic (`native.log`)
passed: full decoded detail returned 2,329.589 ms after the restoration lower bound
at 8.077749 s, stayed sharp through the actual second drop at 14.075405 s, and
degraded again without source blackout. This remains one diagnostic, not a completed
repeated matrix. The independent reporter check correctly excluded the prior failing
phase and reported only 2/15 completed phases for that older gate.

Review then found a separate ordinary-lane boundary: repeated fresh whole-pair gaps
could exhaust the sample-count grace before the original probe deadline, despite the
new valid hold marker. The next narrow correction preserves that grace only while the
recovery-owned hold is valid, after existing pressure and absolute-deadline checks.
Repeated ordinary gaps and exact-deadline expiry need direct regression coverage;
startup behavior and malformed/partial evidence must remain unchanged.

The next source-bound gate, `startup-20260920-42291-osiexc` (source SHA-256
`503fe2f8edc590a14d5c7981f819a02e1427859d20d03120467f6bce17708b5d`),
passed all 437 deterministic methods, both original native cases, OFF and ON,
then failed the second-drop case. Full sharpness took 7,642.039 ms after capacity
restored. No second drop occurred because the four-second recovery oracle failed.

This failure occurred **before** spatial admission. Ordinary whole-pair omissions
at 9.601235 s and 12.120422 s revoked primary RTT health and erased the independent
probe's packet baseline. Healthy-looking fast reports about 202 ms later canceled
the existing probes, contracting to the 0.486 Mbps audio-priority origin. The prior
ordinary RTT was only about 2.2 seconds old and each probe had more than two seconds
remaining. The current hold required an already-applied geometry trial or acceptance,
so it could not protect discovery while recovery was still observing.

The next candidate separates retaining an already-authorized discovery probe from
geometry admission: fresh whole-pair omission may preserve only that exact active
peer/Show's probe and prior primary RTT lease, without creating capacity, renewing
health/time, or confirming pixels. Pre-admission negative checks, malformed/cached
evidence and lifecycle fencing need explicit tests. Added native scalar/decision
diagnostics must distinguish actual fast-validation outcomes from retained policy
RTT disposition; neither a finite scalar nor the policy label proves a fresh ping.

## Pre-admission hold: recovery passes, weak control still fails

Gate `startup-20260920-45068-psib1b` used source SHA-256
`9292688a06975420a085c385cce45364e8b87a428bf52c5d359e4fc06174eb27`.
All 440 deterministic methods and both original native methods passed. Nine of the
required fifteen matrix phases passed before the second-round steady-weak control
failed. The four completed enabled recovery cases were:

| Phase | Recovery after restoration | Blurry recovered frames before next drop/end |
| --- | --- | --- |
| Round 1, one drop | 367.759 ms | 0 |
| Round 1, second drop | 2,353.669 ms | 0 |
| Round 2, one drop | 226.179 ms | 0 |
| Round 2, second drop | 381.208 ms | 0 |

The second-drop runs also passed actual-motion and subsequent-pressure acceptance.
Round 1's steady ample/weak controls and round 2's ample control passed. The matrix
is **incomplete and failed**, not nine successful phases constituting acceptance.

The new native trace directly exercised an accepted recovery's sparse hold in round
1's second-drop case: ordinary omission at 12,149.466 ms, two fast measurements with
`missingPrimaryEvidence`, then ordinary `freshHealthy` at 12,653.029 ms. The fast
reports kept the 13,911,576 bps cap; only the fresh ordinary report changed it.
The same absolute probe deadline, 13,113.107917 ms, survived throughout. None of the
nine completed native phases exercised the new hold while recovery was *observing*;
that branch currently has deterministic reproduction proof, not native occurrence.

The failed weak control (`spatial-recovery-2-5.log`) retained sharp full pixels and
5 fps until a fresh 57 ms RTT at 7,556.218 ms crossed the existing 56 ms threshold
derived from a 6 ms reference. This was before any recovery attempt or hold, while
startup remained active; the candidate's discovery-hold authority was inactive.
The ordinary congestion response then reduced geometry, with first decoded blur
at 8,121.6 ms. The all-sharp control remains a blocking failure; neither its pixel
assertion nor the RTT pressure guard has been relaxed.

Comparing approximately 4.53–7.56 seconds with the passing weak run showed stable
5-fps submissions and 15 encoded-frame advances in both. Failed forwarded traffic
averaged 650.5 kbps (video 621.4 kbps) on the 800 kbps relay, versus 619.8/600.8 kbps
in the passing run. Mean sender packet delay was 28.7 versus 30.0 ms; sampled relay
queue peaked at 8,325 versus 5,600 bytes. No ordinary policy probe was active before
the failed RTT spike, and there were no new keyframe, huge-frame, NACK or PLI events.
This points toward frame-burst timing rather than sustained overload or a new policy
probe, but does not identify the exact packet that delayed the ping. A complete
ON/OFF native-timing equivalence or packet-level causal proof has not been established.

## Passive packet timing and same-input policy comparison

The next diagnostic adds opt-in, bounded STUN Binding header classifications and
scalar relay times, without changing queue order, deadlines, capacity, or socket
scheduling. Modeled residence includes propagation and serialization; callback
lateness is measured separately. Actual residence ends at a successful send
attempt's entry, not remote delivery. No packet payload, endpoint, transaction ID,
or authenticated/decrypted media classification is retained. The RTP-shaped byte
counter is not a padding or encoded-video byte measurement.

In `spatial-packet-timing.XzskhV`, the first 94 focused deterministic checks passed.
The first weak and ample native diagnostics both passed, at 5 and 12.5 final decoded
fps respectively. Their test executable SHA-256 was
`37d724b819d5910fff3e1019356c352c0bacec815edc9ac3b3059517f3dd8040`.
These are diagnostic runs, not a source-bound release gate or resolution of the
earlier failed weak control.

Weak-link Binding packets spent up to 37.319 ms in modeled residence, versus 9.433 ms
on the ample link. Maximum Binding callback lateness was below 1 ms host-to-viewer
in both. In the weak run, the request received at 7,116.969 ms waited 29.122 ms in
the modeled bottleneck; the next ordinary native observation at 7,541.869 ms advanced
the response count to seven with a 33 ms current RTT. This supports a bottleneck
queueing mechanism, but the run did not reproduce the earlier 57 ms failure and the
trace does not retain transaction IDs to prove exact request/response pairing.

The same native report objects and observation times also fed a disabled-recovery
shadow policy. Both steady runs retained equal checked decisions throughout.
Review found that comparison after native application alone could miss decisions
that diverged before an await and reconverged during expiry. That oracle is being
hardened to capture initial and pre-apply decisions. The immutable first-divergence
recorder also compares resumed-time expiry and stops after the first difference;
it never represents later shared inputs as an independent counterfactual network.
All 98 focused methods passed, including four new recorder cases.

With the hardened recorder, `drop-hardened-1.log` passed: the policies first differed
at the **beforeApply** boundary at 10,668.954 ms (candidate scale 1, shadow scale 3),
after both had already disproved startup at 4,745.381 ms. Full-pixel decoded recovery
took 3,363.546 ms after restoration and no recovered frame blurred again.
`weak-hardened-2.log` and `weak-hardened-3.log` both stayed sharp at 5 fps with no
checked policy divergence. The third weak run nevertheless reached a fresh 55 ms
RTT. Its host Binding request at 9,597.656 ms spent 50.153 ms in modeled residence
and 0.350 ms in callback lateness. This is close to the previously failing guard,
not evidence that the underlying risk disappeared. Stop unchanged weak reruns here.

Three diagnostic mutations failed their intended assertions: replacing modeled
residence with callback lateness (the 158.8/2.8 ms ordering test), skipping the
before-apply comparison (missing first divergence), and enabling recovery in the
supposed disabled shadow (native positive comparison had no divergence). Logs use
the `mutant-` prefix in the same directory. Each mutated file was restored to its
exact pre-mutation SHA-256. The gate-runner self-test also passed all 56 fake-runner
scenarios after adding the new recorder class to its required manifest.
Neither the all-sharp acceptance nor congestion guards changed.

The restored source-bound gate `startup-20260920-64867-der3ml` passed **452 deterministic
methods and both original native methods**, source SHA-256
`f64c62e0d355cab79321bbfec7b45ac879c1cba7af0a7f461135188c6560bbb5`.
The five production files fingerprinted during the earlier mutation audit remain
byte-identical. This gate validates the diagnostic changes and restoration, not
the failed full recovery matrix or a pacing fix. The live host remains PID 66690
with its Sep 19 22:40:30 start time.

## Next candidate: native packet burst window, not weaker pressure detection

The pinned native SDK has a per-PeerConnection `pacer_burst_interval`; its default
transport burst window is 40 ms, while zero requests more accurate packet pacing.
The Objective-C configuration does not expose it. A generic video-pacing rate
field trial is not an equivalent change and is overridden by screenshare ALR's
configured rate factor. No field trial or production setting has been changed.

The separate prototype directory `pacer-bridge.xjZwtL` contains a typed subclass
of the exact pinned Objective-C configuration conversion, plus a configuration-only
smoke harness. Its configuration-only baseline and restored run now pass after
artifact identity and ABI review. Four deliberate mutations (missing/nonzero interval,
unrelated DSCP change, and a clock flag omitted by the SDK comparator) fail their
intended checks; source restoration is recorded in `mutation-results.json`.
The prototype includes an explicit comparison for that omitted flag. At this initial
stage it had not created a PeerConnection or verified native GetConfiguration.
The later per-peer and streaming experiments below supersede that limitation, but
reject the pacing candidates as fixes.
It must never be presented as a public stable SDK API or as proof
of actual packet scheduling, WAN quality, iPhone behavior or audio compatibility.

Using the pinned official prefixed release recipe, isolated Mac GN generation
succeeded in 5.928 seconds (`gn-generation-environment.log`). This generated settings
only, not an SDK build or runtime invocation. The first attempt lacked `vpython3`;
the existing vendor environment supplied it, and the inspected partial output's
unchanged arguments were reused. The generated settings use matching Clang 22 and
Chromium libc++ ABI 2; the local Mac SDK is 26.5 versus the original artifact's
26.0. That difference must be recorded in the compatibility review.

The prototype review found no relevant SDK-version-dependent native storage layout.
It uses the matching copied Chromium libc++ headers textually, never Simulator
objects/modules. A first syntax check caught missing explicit property synthesis;
the ordinary source correction fixed it. Linking then required the exact pinned
libc++ `verbose_abort.cpp`, compiled with the derived Mac libc++ flags, because the
SDK does not export its hardening abort helper. The original print-and-abort behavior
was preserved; no stub, unresolved-symbol suppression or relaxed hardening was used.
No whole SDK build occurred. The smoke executable SHA-256 is
`f8d02e6c3a8fcff7d3c8e4660253d34fc7b270fb97dbc75500f7477d37022e0e`.
This proves configuration conversion only, not packet pacing or a resolved weak-link
failure. The earlier failed matrix remains unresolved and blocking release acceptance.

Primary implementation references: [pinned pacer configuration](https://raw.githubusercontent.com/webrtc-sdk/webrtc/39d2180660d43d2e1630e564e3afe1c1fb72746e/api/transport/network_types.h),
[pinned native configuration](https://raw.githubusercontent.com/webrtc-sdk/webrtc/39d2180660d43d2e1630e564e3afe1c1fb72746e/api/peer_connection_interface.h),
and [official prefixed release recipe](https://github.com/webrtc-sdk/webrtc-build/blob/440d978c6f8f6a89d53c6f8ac0d096a7b44f73e5/build/apple/xcframework.sh).

## Native pacing trials: actual readback passes, weak-link clarity still fails

The test-only DEBUG/macOS hook now constructs only audio-free host peers and verifies
the actual native GetConfiguration before exposing them. A contradictory expectation
must fail, and the default setting is rechecked after experimental construction.
The first test failed closed because SwiftPM loads its byte-identical framework copy
from the products directory. Independent SHA/UUID verification justified adding only
that exact path to the allowlist; the loaded-artifact checks remain mandatory.

Evidence is in `pacer-bridge.xjZwtL`: native default/zero/default passes with bridge
SHA-256 `d62a6a1ba85115055753b0637b6b2b24f80e4a3f89bd0a5d50a2e18f936edd2b`;
default/zero/20-ms/default passes with
`aad255eb5eb13471508b1abf3ad90bf2fd5bc24dfd9f708d81da726b3988cfff`.
Fresh-process `default-weak-1.log`, `zero-weak-1.log`, and `twenty-weak-1.log` all fail
the unchanged all-sharp weak-link oracle. They contain 10, 16, and 12 blurred frames,
respectively. Maximum native RTT is 78, 18, and 20 ms; maximum ordinary sender delay
is 52.77, 96.12, and 101.55 ms. First frames arrive in 406, 360, and 399 ms.
Reducing the burst window reduced downstream STUN residence but increased native
waiting; it did not solve clarity. Zero and 20 ms both suffer a fresh BWE collapse
before disproof (849975→582753 at 6550 ms and 905041→591862 at 7552 ms), with
`latencyPressure=false` at those decisions. Neither maximum queue delay nor RTT was
their immediate disproof reason. Do not weaken that guard or call these candidates
successful because RTT alone improved. Each setting was attempted once; these are
counterexamples, not estimates of failure probability.

The ordinary/zero/20-ms trials keep the same ceilings, moving pixels, policy, native
readback, relay bounds and blackout checks. No ample/drop matrix is justified for
these rejected settings until a new evidence-backed mechanism addresses the failure.
No production configuration, audio ownership, installed host, TestFlight artifact,
commit or remote branch changed. Native pacing remains opt-in test infrastructure,
not a release dependency or stable SDK API. The live host is still PID 66690,
started Sep 19 at 22:40:30.

The hook/topology/artifact safety baseline passes eight focused methods. Four separate
negative mutations then reach their intended assertion failures: omitted native close,
omitted artifact digest, a missing native pacer setting, and an always-accepting native
verifier. `native-mutation-results.json` records exact restored source hashes and logs.
The first unconditional always-accept implementation failed compilation as unreachable
code and is explicitly not counted; the compiled conditional mutant fails the real
contradictory-readback assertion. No mutation reached an installed app or release.
The startup gate runner self-test passes all 56 scenarios with the added safety classes.

After restoration, `native-readback-restored.log` again passes all four native
configurations. The source-bound `--native` gate in
`startup-20260920-86769-cghgwn` passes **458 deterministic methods plus both original
native cases without skips**, source SHA-256
`be53c7ce4ba7c821bf0b349724bf2fbae7b3687454bc76345619c3d3a17fa637`.
This proves the new experimental hooks and safeguards preserve that gate; it does
not resolve any of the three failed weak-link pacing trials or the earlier matrix.

The next prepared hypothesis is a modest screenshare pacing factor of 1.15 against
an explicit 1.0 control, keeping the interval at 20 ms and every ceiling unchanged.
`pacer-bridge.xjZwtL/PER_PEER_PACING_PLAN.md` records pinned-source APIs and limitations.
Prefer a fresh audio-free test-process startup trial with a bounded numeric native
consumer witness over immediately expanding the private per-peer constructor.
The complete existing probing trial baseline must survive unchanged; process-scoped
logs must not be mislabeled as peer-owned. A factor configuration or lookup alone
is not actual pacer-consumption proof. At that checkpoint no factor experiment had run.

### Fixed-factor experiment: native consumption proved, clarity still rejected

The DEBUG/macOS-only startup admission now freezes the complete trial string in a fresh,
explicitly selected audio-free XCTest process. It cannot change any existing factory,
admits only one exact-token host and viewer, and stays closed after retirement. The
numeric observer retains at most 4096 allowlisted events and no raw SDK text. Its host
attribution uses a separately pinned native bridge to read the actual factory worker
thread IDs, not timing or rate guesses. `worker-binding-native-1.log` proves host/viewer
IDs are distinct and stable. Twenty-nine focused admission/observer/witness tests pass.

Source review binds the synchronous path through GoogCC's BWE log, transport
`PostUpdates`, `TaskQueuePacedSender.SetConfig`, and the receiving `PacingController`
rate log. Native logger callbacks stay on that worker. The upper-link pacing clamp is
disabled by the exact frozen trial set. ALR tuple logs remain only process-scoped
corroboration; at least three post-capture native host BWE/pacer pairs must independently
match the factor and reject its alternative.

Both fresh processes used the same source SHA-256
`c938d4d19a1f21514d8e2bec6c4e0825109f11b0a1930559b232f54af77ed8f5`
and worker bridge SHA-256
`d42515f8b01477dc955b8d686ae339f9252d2d1735f98c2272a952c39f77b7db`.
The runner's initial missing root `Package.resolved` preflight stopped before spawn;
source enumeration was corrected to cover the manifests actually present. Each measured
factor was then attempted once, under an external 180-second process deadline.

| Fresh weak-link run | Native matching pairs | First frame | Max RTT | Max ordinary sender delay | Blurred frames |
| --- | ---: | ---: | ---: | ---: | ---: |
| `factor-control-weak-1.log`, 1.0, 20 ms | 45 | 402 ms | 24 ms | 113.10 ms | 12 |
| `factor-candidate-weak-1.log`, 1.15, 20 ms | 40 | 312 ms | 15 ms | 63.86 ms | 16 |

Both native-consumption witnesses pass: five matching full ALR tuples each, no ambiguous
pairs, contradictory factors, unknown threads or dropped events. Both runs nevertheless
fail the unchanged actual-pixel all-sharp assertion. Lower queue delay/RTT is not success.
The first disproof is BWE-driven in each run with `latencyPressure=false`: control at
7569.8 ms with 571103 bps, candidate at 7054.8 ms with 541792 bps. Neither failed because
of the RTT threshold. Do not promote 1.15, sweep factors until green, or erase the earlier
failures. The recovery matrix remains red and no live host, audio route, app, release,
commit or remote branch was changed.

Four new independent negative mutations compile and fail their specific assertions:
removing video-only admission, accepting a different selected test, accepting unknown
worker attribution, and substituting positive configuration intent for numeric rate
consumption. `factor-mutation-results.json` records logs and exact restored hashes.
The gate now requires all three new safety classes (29 methods), and its 56 fake-runner
scenarios pass. Restored native-gate evidence is recorded separately when complete;
none of these safety results turns the failed factor experiment into a fix.

After restoration, `startup-20260920-258-f07w5s` passes **487 deterministic methods
and both original fresh-process native cases without skips**. Its source SHA-256 is
`d7fa7aa2e9feed526bb2af97b50d6a41a430688c324b7ad10fce60e2821fcdff`.
The current factor trials still fail their distinct decoded-pixel requirement; this
gate is restoration/regression evidence, not a substitute for the recovery matrix.

The next diagnostic question is whether periodic full-resolution frames trigger native
delay-based overuse despite lower long-window throughput. Current event data rules out
congestion-window pushback as the observed reduction: every host pushback target equals
its estimate. NACK/PLI counters are zero before disproof. Modeled relay serialization
reaches 59.84 ms (control) and 83.19 ms (candidate), whereas callback lateness stays near
1 ms. This is not yet proof of native delay-estimator causality. Prefer one unchanged
factor-1.0 control with bounded host-native estimator-state evidence before modifying
cadence, native estimators, or policy. Preserve all current negative evidence and guards.

### Estimator observer: native delay overuse precedes policy disproof

The next factor-1.0, 20-ms control adds a DEBUG/macOS-only native estimator observer
in one fresh, exactly selected, video-only test process. It retains the source cadence,
modeled network, traffic ceilings, production policy and all clarity/pressure assertions.
The observer preserves the ordinary controller delegate and binds its events to the
actual host worker and environment. It keeps at most 2048 numeric delay/loss events;
unknown event payloads are discarded and counted, and no raw SDK text is retained.

`pacer-bridge.xjZwtL/estimator-native-construction-1.log` passes actual initializer
interception and worker binding. Before network admission, its controller-create count
and event count are zero; construction alone is not an estimator-observation witness.
`estimator-focused-tests-3.log` passes 33 focused safety tests: eight admission, eight
hook lifecycle and seventeen snapshot/model tests. The last completed gate-runner check
passes 61 fake-runner scenarios, including missing synchronous-reentry coverage. Four separate negative mutants compile and fail their
intended assertions: lowering the delay-sample minimum from three to two, removing the
controller-create check, removing exact host-worker attribution, and removing single-use
hook admission during synchronous reentry. The model and `WebRTCPeer` source hashes are
restored exactly afterward. The restored source then passes
`startup-20260920-17612-rgewp4`: **512 deterministic methods and both original
fresh-process native methods, without skips**. Its source SHA-256 is
`b378d4944d6c7e3e2a5c3a6f3ff2af324f449d52be6d77c55d2f6ecc6ad82fce`.
All 333 covered source-file hashes were independently checked unchanged afterward.
This gate does not run the separate observer diagnostic or clear the failed recovery matrix.

The measured weak-link run is `pacer-bridge.xjZwtL/estimator-native-weak-1.log`, with
source SHA-256 `993128fb83eeccf4eb91bee3a00cc2bed1f3343b172dc06f15b55c62e1c0ebd5`
and bridge SHA-256 `9fa6f8cca4842e787f705008dd90e0b702ed9dc8207534311aab5ad5b6bd0206`.
Its result JSON records unchanged source, no timeout and exit status 1. The native
estimator witness verifies 116 advancing post-capture delay events and 40 post-capture
loss-named events, with one earlier loss event excluded from proof. The independent
pacing witness has 44 factor-1.0 matches. Exactly one requested/intercepted factory,
controller, delegate, environment match and live logger are observed, with a 25,000-us
process interval and zero invalid, dropped, rejected, identity or lifetime failures.
The observer counts 51 unknown events without retaining their payloads.

| Observation | Time after capture | Evidence |
| --- | ---: | --- |
| First native delay overuse | 9,326.525 ms | The delay estimate falls from 1,062,980 to 604,044 bps, then reaches 585,539 and 572,922 bps in two further overuse events. |
| First policy startup disproof | 9,577.935 ms | Fresh BWE is 574,771 bps, RTT is 13 ms and ordinary sender delay is 46.55 ms; `latencyPressure=false`. |
| First blurred decoded frame | 10,134.434 ms | Decoded dimensions fall to 134×240 with contrast below 0.9. |

The run **fails** the unchanged weak-link oracle: seven decoded frames are blurred,
and final decoded cadence is 3.5 fps against the required 4 fps. Native estimator
observability passes; the clarity experiment does not. Teardown separately reports
`live=0 created=1 destroyed=1 failures=0` after native close.

Every retained loss-named event has `fractionLoss=0`. This field is cached Q8 loss,
and `expectedPackets=0` may reflect the reset packet accumulator; neither proves an
absence of network loss. The adjacent loss-named update follows `ApplyTargetLimits`
after the delay reduction and is not an independent loss-cause observation. The trace
establishes that actual native delay overuse and bitrate reduction precede policy
disproof and blur. It does not establish that frame bursts caused the overuse, that
all network loss was absent, or that observer-on/off timings are equivalent. No
cadence, estimator, cap or congestion-guard change is justified by timing order alone.

Construction hooks are single use and reject synchronous reentry as well as delayed
TaskLocal child reuse after either success or throw. The observer owner has a separate
lifetime: it remains retained through callbacks, blackout and native close until logger
destruction is accounted for. The ordinary gate now includes the snapshot/model class
and pins its safety methods alongside admission and hook-lifetime tests. Native observer
construction and weak-link methods remain separate exact opt-in diagnostics, outside
the ordinary `NATIVE_METHODS` manifest. These changes do not update an installed host
or release artifact, and the failed recovery matrix remains unresolved.

### Schema 2 probe and ALR cohort: no observed periodic-probe cause

Schema 2 extends the same bounded observer with exact `probeCreated`, `probeSuccess`,
`probeFailure` and `alrState` events alongside delay/loss. ALR membership comes directly
from the controller environment's `RtcEventAlrState`; it is not inferred from a low send
rate or a probe request. Common sequence, host-worker, environment-clock and capture
boundaries still apply to the shared 2048-event array and 1-MiB decoder. Only three
advancing post-capture delay events can verify observability; probe and ALR observations
do not contribute to that proof. Schema 1 fails the schema-2 evaluator.

Bitrate is optional on the wire but required positive for delay/loss and bounded to
positive Int32 for probe-created/success events. Probe failure and ALR events must omit
bitrate. All three probe kinds require a positive Int32 cluster ID; only creation has
positive UInt32 `minimumProbes`/`minimumBytes`, and only failure has reason 0 through 2.
Only ALR has a required Boolean `inAlr`. Every variant rejects the other variants' fields.
The creation event records a request before transport/pacer delivery, not transmitted
probe packets. Successful result observations may repeat for one cluster ID; their
count is not a count of distinct or completed probe clusters. No result is required for
each retained request, and no inferred trigger or causal classification is recorded.

The first schema-2 weak control passed. Before further processes ran, the protocol in
`pacer-bridge.xjZwtL/PROBE_OBSERVATION_COHORT.md` fixed the cohort at three total controls,
including that first run, with all outcomes retained. The remaining two runs use the
same source and pinned artifact, factor 1.0, 20-ms burst interval, 800-kbps modeled link,
capture cadence, geometry, policy, caps and pixel/FPS oracles. The cohort was neither
stopped on its first pass nor extended after its failures.

All three `estimator-probes-native-weak-{1,2,3}.log.result.json` receipts record source
SHA-256 `a439e48028f539e3c24b65a3e8be54e34f560470e27c082bbd89e18393878da5`
and bridge SHA-256 `1dd9032eb1d9c51604bb239d74902a8f3fcdba40d3114f7fb259bef5f51d5c72`,
unchanged source and no timeout. The corresponding `.log` files contain the native
observations and unchanged acceptance results:

| Run | Pixel/FPS result | Blurred frames | Final fps | Advancing delay events | Total probe requests | Successful result observations | ALR entry after capture |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | PASS | 0 | 5.0 | 104 | 7 | 18 | 782.578 ms |
| 2 | FAIL | 9 | 3.5 | 109 | 12 | 32 | 783.022 ms |
| 3 | FAIL | 12 | 4.5 | 87 | 13 | 35 | 814.285 ms |

Each request total includes two pre-capture requests, which are validated but excluded
from post-capture counts. All successful result observations are post-capture; no probe
failure event is observed. Each run records one ALR entry and no ALR exit during its
observation window. All three native witnesses verify with zero unknown, invalid,
dropped, attribution or lifetime failures, and balanced close receipts report
`live=0 created=1 destroyed=1 failures=0`. A passing observation witness is separate
from the pixel result: run 2 fails both clarity and the 4-fps floor, while run 3 exceeds
that cadence floor but still fails clarity.

Run 2's first delay overuse occurs at 8,534.650 ms with a 593,947-bps estimate. Its last
preceding probe result is at 4,655.812 ms, a 3,878.838-ms gap; the next recorded probe
request is not until 9,540.518 ms. Run 3's first overuse occurs at 7,436.854 ms with a
575,209-bps estimate, 2,809.285 ms after its preceding result at 4,627.569 ms; its next
recorded request is at 8,481.041 ms. Thus both failing overuse transitions precede even
the next observed probe request. The trace does not identify a periodic-probe burst as
the cause. Do not run the proposed 60-second ALR-interval trial on this evidence.

The passing run does not erase either failed cohort member, the schema-1 failure or
the earlier pacing failures, and three controls do not establish a reliability rate.
At that cohort checkpoint, 45 focused safety methods and 63 fake-runner scenarios
passed; the newer mutation and gate results are recorded below. No production behavior,
capture/probe timing, cap, pixel assertion or congestion guard was relaxed; no
deployment, commit or push was performed.

### ALR delay-growth hold: initial pass, fixed matrix rejected

The next bounded candidate adds only
`WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/` to the frozen diagnostic configuration.
The pinned SDK holds ordinary delay-based AIMD increases while in ALR, but still accepts
probe estimates, growth outside ALR and genuine delay-overuse decreases. This is a
source-based candidate, not a proven cause: the failing controls' intervening growth
fits ordinary AIMD growth, but the passing control grew too. No 60-second probe-interval
trial is authorized by these observations.

Admission remains DEBUG/macOS-only, explicitly selected fresh-process XCTest, control
pacing factor 1.0, video-only and estimator-observed. The hold option cannot borrow an
ordinary pacing or baseline observer selection, omit the observer, reuse a process,
or retune a live factory. A distinct retained native observer owner expects exactly
`Enabled` at the actual controller's original environment; the baseline owner requires
the hold key absent. Preserve the default SDK delegate, original clock/field trials/task
queues, host attribution, bounded schema-2 witness and balanced logger lifetime.

The predeclared single initial `testNativeEstimatorALRGrowthHoldWeak` passed the unchanged
800-kbps moving-relay, factor-1.0, 20-ms-burst oracle: first frame 356.919 ms, all 49
observed frames sharp, zero blurred frames and final 5 fps. Eight advancing native delay
events and the pacing witness verified; native teardown was balanced. The retained
`alr-growth-hold-native-weak-1.log` and `.log.result.json` bind source
`79c337f9689fe1d6482ea0467172a74c71bcd7e72e4797c5c26ce9f837576f19` and bridge
`7abb982c86cf24bced2bd0b65b1e9a6dd9eced114a928327d318e66d23cf5b3c`, with unchanged
source and no timeout.

Independent trace review found a 4,872.181-ms interval from 4,671.749 to 9,543.930 ms
with sender BWE fixed at 758,659 bps while 24 sharp changed frames, 20 encoded-frame
increments, 244 packets and 287,025 forwarded relay bytes advanced. Native delay events
occurred at probe updates; probe 7 subsequently raised the estimate while still in ALR.
This matches the intended hold behavior with advancing traffic, not a direct branch-hit
proof. No delay overuse occurred in this run, so it cannot prove the preserved response
to real pressure. A single passing weak control is neither a fix nor production proof.

Before matrix additions, 54 focused tests and 65 fake-runner scenarios passed. The three
schema-2 receiving-model mutants in `ALR_GROWTH_HOLD_TRIAL.md` completed: borrowing delay
proof, missing ALR membership and failure-event bitrate produced four, one and four
assertion failures respectively, followed by exact model restoration to
`c1fed322b8ca63c199478819b0ea05170f60a9a41546255b2b5d5e70dae58763`.
The later `alr-growth-hold-mutation-borrow-selection.log` produced two assertion failures;
`alr-growth-hold-mutation-observer-admission.log` produced three assertion failures plus
one unexpected error. The field-trial source was restored to its prior SHA-256 prefix
`a98884cf`. These are Swift receiving-model/admission mutations, not native producer
mutations; the unexpected error is not counted as assertion evidence.

The next stage was fixed before further outcomes: three fresh-process rounds, each in
the exact order disabled recovery, enabled recovery, second drop, ample and weak, under
one source/bridge identity. That matrix is now terminal and failed: 11 cases passed,
then round 3 enabled recovery failed. Twelve of fifteen cases completed; the final
second-drop, ample and weak cases did not run. The runner stopped at the first failure
as declared, retaining every result without a rerun. All twelve receipts preserve source
`2dae8d4953d050cc62e82217b3cf90b780af4c7de87b74c9a401d3f2b3f783b4` and bridge
`7abb982c86cf24bced2bd0b65b1e9a6dd9eced114a928327d318e66d23cf5b3c`, with unchanged
source. Retain `alr-growth-hold-matrix-1.result.json` and its per-case logs/receipts.

| Case | Round 1 | Round 2 | Round 3 |
| --- | --- | --- | --- |
| Disabled recovery | Characterization passed; no full-pixel recovery | Characterization passed; no full-pixel recovery | Characterization passed; no full-pixel recovery |
| Enabled recovery | Passed; sharp recovery after 437.546 ms | Passed; sharp recovery after 1,840.457 ms | Failed; no shadow divergence or recovered sharp frame; final 1 fps |
| Second drop | Passed; recovery after 389.990 ms, then actual degradation | Passed; recovery after 2,304.937 ms, then actual degradation | Not run |
| Steady ample | Passed; all sharp, 13 fps | Passed; all sharp, 13 fps | Not run |
| Steady weak | Passed; all sharp, 5 fps | Passed; all sharp, 5 fps | Not run |

Recovery latencies are measured from the actual capacity restoration. All four passing
enabled/second-drop intervals retained sharp changed content without relapse before the
next actual drop or observation end. Disabled characterization passes do not prove
recovery. The two weak matrix passes plus the initial weak pass do not replace the
failed enabled case or any unrun case.

Round 3 enabled recovery failed both actual shadow-divergence admission
(`firstShadowDivergence` was nil) and the throwing recovered-pixel `XCTUnwrap`; the current
native estimator and pacing snapshots verified, but there was no recovered sharp frame.
Nine post-restoration 90×160 motion frames confirm continuing low-resolution content,
not recovered detail.
The throw invokes the close catch, then bypasses the final teardown snapshot/marker and
the relay-blackout proof. No final teardown marker exists for this case: do not claim
balanced native teardown or a passed blackout check from catch execution alone.

The retained trace shows BWE stalled at 192,627 then 181,925 bps with floor caps of
486,001 total and 99,360 video bps. Periodic probe requests were 198,720 bps, exactly
twice the video cap. Even twice those BWE estimates or that requested probe rate remains
below the total floor cap required by the existing recovery qualification. With ordinary
ALR growth held, this is an observed recovery stall, not evidence that the guard should
be relaxed or the cap raised. Pinned `probe_controller.cc:552–561,597–600` caps requests at
`min(max_bitrate, 2 * max_total_allocated_bitrate)` and disables further probing on reaching
that cap. The measured two-times-video requests match this source-backed mechanism, but
the native allocated-rate input itself was not logged; this is an inference, not its
direct readback. The hold candidate cannot be promoted; preserve pixels, FPS, geometry, caps,
congestion guards and deadlines. All matrix processes are terminal, with no rerun or fix
claimed.

The separate ordinary gate `startup-20260920-33592-js07xn`, with no hold flag selected,
passed 531 deterministic methods and original native case 1, but original native case 2
failed one startup-detail assertion. Decoded width fell from 1080 to 134 at 1,152.93 ms,
then to 270 before returning to 1080 at 3,494.21 ms; final 51.5 fps did not repair the
earlier detail failure. Gate source identity
`2e38959358038ee949b4ccb27f2d40e9a5ee2a927632526cc793d0c843e368d3` was independently
rechecked across all 333 covered files with no changes. Its 65 fake-runner scenarios
passed separately. This is not a restored full-gate pass: the ordinary native failure
blocks release independently of the failed hold matrix. Earlier green gates and all
failed recovery, pacing and observer runs remain historical evidence, not substitutes.

### ALR probe-cap skip: predicate verified, fixed matrix still rejected

The next DEBUG/macOS-only candidate retains ALR growth hold, factor 1.0, the
20-ms pacing window and the default SDK controller delegate, adding only:

`WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0/`

`skipProbesBelowCurrentEstimate` defaults off and requires the held control estimator
observer. Its original five exact `testNativeEstimatorALRProbeCap{Weak,DisabledRecovery,
EnabledRecovery,SecondDrop,Ample}` selections define the fixed matrix. The later separate
`testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic` adds receiver observation,
not a sixth matrix case. Neither may borrow ordinary, observer or hold-only admission.
Reject any preexisting group rather than overriding the baseline.
The distinct retained native owner verifies the group at actual controller creation;
the existing owners require it absent. Sender/peer caps, the audio reserve, pressure
checks, Show ownership, source cadence, geometry and all deadlines remain unchanged.

The SDK predicate skips only when `min(network upper estimate, estimated BWE)` is
strictly greater than `min(peer maximum, 2 * total allocation)` for positive allocation;
with zero allocation the limit is the peer maximum. Equality does not skip, and a
finite network upper estimate at or below the limit prevents the skip despite higher
BWE. Schema-2 events do not expose either allocation or network-upper readback.
`RequestProbe` still consumes its five-second recovery-request cooldown when the
predicate returns no probes. This candidate does not manufacture capacity, raise a
probe limit, suppress genuine pressure or guarantee recovery of an already-low estimate.

The predeclared initial enabled-recovery run passed, with first frame 341.715 ms,
sharp recovery 352.771 ms after restoration and final 5 fps. It did not exercise the
earlier exact 486,001/99,360-bps peer/video floor opportunity, so this pass is not proof
that the low-allocation trap was repaired or that the skip predicate executed there.
The initial receipt and every completed matrix receipt preserve source
`81dd4fcac0e66420bfea0b321558b6333f8bb5d2f6c2baec27d3eb7ea3fdfe65` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`, unchanged before
and after each fresh process. Evidence is retained in
`/Volumes/t7/beluga-startup-burst.fkXnsz/pacer-bridge.xjZwtL/`:
`ALR_PROBE_CAP_TRIAL.md`, `alr-probe-cap-native-enabled-recovery-1.log` and its receipt,
`alr-probe-cap-matrix-1.result.json`, `alr-probe-cap-matrix-1.summary-2.json`, and all
per-case logs/receipts. The revised summary is descriptive; receipts and original
assertions determine pass/fail.

The fixed matrix stopped at its first failure: six passes followed by round 2 enabled
recovery failing, for 7/15 completed and eight unrun. Round 1 enabled recovery restored
sharp pixels after 426.972 ms; second drop recovered after 407.915 ms and subsequently
degraded under actual renewed pressure. Both retained sharp recovered intervals.
Round 1 ample/weak controls were all sharp at 13/5 fps. The two disabled-recovery
passes are characterizations, not recovered-pixel proof.

Round 2 enabled recovery failed only the exact-host pacing witness:
`outOfOrderHostEvidence`, with seven out-of-order host events. It nevertheless restored
sharp pixels after 2,924.163 ms, retained 66 changed-content observations without
recovered-interval blur, and ended at 12.5 fps. Its native estimator witness verified;
the relay-blackout assertions completed and teardown recorded
`live=0 created=1 destroyed=1 failures=0`. Unlike the earlier hold-only failure, this
nonthrowing pacing assertion did not bypass those later checks. These distinct positive
results must not erase the pacing failure: the matrix remains red, the eight remaining
cases are not passes, and no promotion, rerun-until-green or witness-policy relaxation
is justified.

Read-only examination located all seven rejected host sequences (50, 66, 72, 84, 92,
98, 106): their native millisecond timestamps were equal to the preceding BWE timestamp,
not decreasing, while callback uptimes strictly advanced. SDK
`MaybeTriggerOnNetworkChanged` can emit a changed pushback target with an unchanged
estimate, and `at_time.ms()` can coalesce those updates. The receiving-model correction
now accepts numerically checked sequential tied pairs only as `tiedPairs`; they do not
increase independent-match counts. Verification still requires three matches with
distinct advancing native millisecond timestamps, strictly advancing callback uptimes
and all existing provenance/ambiguity guards. The correction's deterministic validation
below does not rewrite the original red receipt; no fresh full native matrix with the
corrected witness had run at that checkpoint. The separately declared cohort below
records the subsequent result.

This case did enter the 486,001/99,360-bps floor from 5,556.434 through 8,086.029 ms,
then exited by 8,588.312 ms. Its last pre-floor probe was at 4,756.193 ms, putting the
nominal five-second periodic opportunity at 9,756.193 ms, after floor exit. The earlier
hold-only failure's corresponding last probe was about 2,715 ms, putting that opportunity
near 7,715 ms inside its floor interval. This timing confound means even the new case's
floor recovery is not direct evidence that the skip branch ran.

Before the matrix, 61 focused safety tests passed (20 admission, eight hook, four bridge
and 29 estimator-model tests), and 67 fake-runner scenarios passed separately. Borrowed
candidate selection and missing-hold admission mutants each compiled and produced five
assertion failures with zero unexpected errors. Field-trial source was restored exactly
to `403c3b99228620133bec26853ee95cb8e288fea2b1c7c9b84a8ec68218d4b12b`.

After the receiving correction, `alr-probe-cap-tied-witness-focused-1.log` passed
82 tests (the prior 61 plus 21 pacing-witness tests), and
`alr-probe-cap-tied-witness-gate-selftest-1.log` passed 69 fake scenarios. Four independent
compiled mutants failed assertions with zero unexpected errors: strict native-ms
comparison, nine failures across two tests; allowed regression, three across one;
counted ties, four across one; duplicate callbacks, eight across one. Retain
`pacing-tied-witness-mutation-{strict-ms,allow-regression,count-ties,duplicate-callback}-1.log`.
The restored witness SHA-256 is
`72b6bdd74b3bbc94537d00ff684342d2be730dda5a2c01a1fb51e03668b8f354`; test SHA-256 is
`17e486589bf1890bc630067bf98132fb7da2f8792617fcdfadd550e9f47ebdf5`.
These are deterministic and mutation passes, not a corrected-matrix or ordinary-gate
pass. The floor/periodic phase confound above prevents a mechanism claim for that
earlier case.

The separate `ProbeCapControllerSmoke.mm` harness invoked the actual pinned framework's
controller with immutable per-case trials and no peer, media, packets or sockets. All
seven cases passed: config-off floor control, candidate floor then useful raised cap,
below-cap usefulness, exact equality, one bps above/below the cap, and a lower network
upper estimate. The config-off mutant compiled and failed its intended probe-count
assertion in case 2. Harness source is
`bae0f689f971427f63fd4cfd6803ff960c1d5dcb4aa136936f3583f720ccb9ad`; passing binary is
`0f8d144ec0169606c00c5f2861f0ceaffa91a5681077326e951dce78d771500e`; mutant binary is
`6179fd48d2388150e86b7c89f3210c4411b39cae9e99f9e4fbc4e7f60cb701d1`.
`compile-probe-cap-controller-smoke-1.log` retains an initial warnings-as-errors
initializer failure, corrected using a named `ProcessInterval`; compile log 2 and
config-off-mutant compile log 1 succeeded. The runtime logs retain seven passes and the
case-2 assertion failure against the same framework identity. The initial compiler
failure is not mutation evidence. This proves the shared native predicate only, not
periodic ALR execution, transport/pixel recovery or genuine-overuse preservation.

### Corrected-witness cohort: terminal cadence failure

`ALR_PROBE_CAP_CORRECTED_WITNESS_COHORT.md` declared a new initial trial and fixed
three-round matrix after the receiving-model correction. The initial trial passed:
sharp recovery after 3,080.764 ms and final 13 fps. Its receipt and all eight completed
matrix receipts preserve source
`edcaba4212ee66e20821c044a5088c63fb1709e8028e29f22908356c273ad3ce` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`, unchanged before
and after each process. `alr-probe-cap-matrix-2.result.json` is authoritative;
`alr-probe-cap-matrix-2.summary-1.json` is a separate descriptive projection made with
the existing summarizer, not a replacement receipt or reclassification.

Matrix 2 stopped red after seven passes and round 2 second-drop failure: 8/15 cases
completed, seven unrun. No failed case was retried and no old red result was relabeled.

| Case | Round 1 | Round 2 | Round 3 |
| --- | --- | --- | --- |
| Disabled recovery | Characterization passed | Characterization passed | Not run |
| Enabled recovery | Passed; 2,758.524-ms recovery | Passed; 396.509-ms recovery | Not run |
| Second drop | Passed; 3,053.091-ms recovery, then actual renewed degradation | Failed sustained cadence; no second drop occurred | Not run |
| Steady ample | Passed; all sharp, 13 fps | Not run | Not run |
| Steady weak | Passed; all sharp, 5 fps | Not run | Not run |

The failed case restored capacity at 8,066.497 ms and first decoded sharp 1080×1920
at 8,785.787 ms, within the four-second limit (719.290-ms recovery). Its next sharp
frame arrived at 9,691.261 ms: a 905.473-ms gap, exceeding the sustained oracle's
500-ms maximum. The fixed first-sharp two-second window ends at 10,785.787 ms and
contains eight sharp frames but only seven changed-content transitions, below eight
required. Its boundary frame at 10,914.696 ms is timely; that does not repair the
gap or missing transition. All 56 recovered frames stayed sharp, with 55 changed
transitions overall and final 5 fps. Later healthy frames cannot erase the bad
first recovery window.

`hasSustainedSpatialRecovery` remains anchored to that first sharp frame. Because
it never becomes true, the fixture never applies capacity stage 3; the second-drop
assertion subsequently throws on absent `secondCapacityDropAt`. This is a failed
recovery-cadence contract, not a demonstrated pixel relapse or a failed response to
a second drop that actually happened. Source submissions continued at roughly 200 ms
(maximum 201.901 ms around the decoded gap); retained data does not join individual
capture, encoder, packet and decoder frames, so the downstream cause remains open.

The active native estimator and corrected pacing witnesses verified: 27 advancing
delay events, 55 independent pacing matches and 24 tied pairs, with zero invalid,
dropped, unknown or active lifetime failures. The throwing second-drop assertion
then invokes the close catch but bypasses the relay-blackout check and final native
teardown snapshot/marker. Neither marker exists for this case. Do not claim passed
blackout or balanced teardown from the successful active snapshot or catch execution.

Separately, round 1 enabled recovery supplies the first matching timing opportunity:
native ALR remains true, the exact 486,001/99,360-bps floor persists beyond the last
probe at 2,525.961 ms plus the nominal five seconds, and floor samples at 7,580.047
and 8,081.763 ms still show BWE 486,001, queue zero and RTT 7 ms. Packets and relay
bytes advance; the next probe is only after ordinary discovery enlarges the cap.
This is sampled ALR/floor/elapsed-period evidence, not direct internal allocation,
network-upper, controller-state or skip-branch readback. It cannot turn this incomplete
failed matrix into a pass or authorize a wider window, weaker cadence guard or higher cap.

The ordinary startup native gate remains independently red, and every prior failed
matrix/control remains retained. Only the separately validated receiving witness changed;
no production behavior or guard changed, and no deployment, commit or push was performed.

### Actual-native periodic ALR request oracle: bounded mechanism proof

The separate `ProbeCapPeriodicALRFeedbackSmoke.mm` uses the actual pinned framework's
GoogCC controller and ALR detector, immutable per-case trials and public sent/feedback/
process inputs. It keeps the peer ceiling at 486,001 bps, the 320,000-bps reserve and
allocation sequence 166,001 → 99,360 → 166,001. Non-probe 1,000-byte packets are
submitted every 100 ms, received after exactly 25 ms and fed back 50 ms after send;
each feedback result copies a genuinely submitted record. Process ticks are 25 ms.
No RTT override, forced BWE, private controller state, probe feedback, media, peer,
socket or global trial is used. The 20-ms controller pacing setting is diagnostic,
not the production SDK-default 40-ms setting.

The first no-feedback revision remains red in `probe-cap-periodic-alr-smoke-1.log`:
both cases entered ALR but failed `seed_estimate_changed_without_feedback` after
126 process calls and 32 sends, before the periodic boundary. Pinned SDK source
explains the missing-feedback RTT timeout; the log did not print the new BWE, so a
calculated backoff value is not an observed measurement. This rejected fixture was
not overwritten or retuned. A separately declared feedback revision then passed
on its first compile/run, with both cases entering native ALR at 425 ms and ordinary
feedback naturally increasing the estimate from 300,000 to 308,030 bps before ALR.

| Relative native time | Hold only | Hold plus skip |
| --- | --- | --- |
| 5,400 ms, before periodic eligibility | No request; BWE 308,030, 54 feedbacks | Same |
| 5,425 ms, floor allocation 99,360 | One 198,720-bps request | No request |
| 5,450 ms, allocation restored to 166,001 | No request | One useful 332,002-bps request |
| 10,425 ms, control's next periodic boundary | One useful 332,002-bps request | No request; its next boundary is later |

Each normal case completed 418 process calls and 104 sent/received/feedback records,
with one native ALR entry, no exit and balanced logger lifetime. The separately
compiled config-off mutant changes only the skip mapping, retains the assertions,
and fails `unexpected_probe_count` at the candidate's 5,425-ms boundary: it returns
198,720 bps instead of no request. Its control passes; the candidate still has ALR,
BWE 308,030 and 54 feedbacks, so this is not a compiler or missing-ALR failure.
Its one outstanding ordinary packet at termination is not a completed feedback.

Normal source/binary SHA-256 are
`f5578b537b6012bafde0eb7c0fe179ca52d1b629c5d4580c154bd8786d20a09e` /
`ad0007612b4d80ed2f4303647680a7bc3f735052d378b783f27626c05609ad65`;
mutant source/binary are
`44201f6f3164a4b38f3f255dc3575283c82c4a020b18d441a27ad49c3d40f234` /
`aa1564efa312b7009f2018f68164a4eb807c66fb0e0c613a560c31176d1d596e`.
The unchanged normal artifacts, clean compile logs, raw run logs, framework identity
and retained failed revision are recorded in scratch `PERIODIC_ALR_FEEDBACK_ORACLE.md`.
All native harness runs were bounded to 20 seconds wall time and 10 seconds CPU.
This closes the periodic request/suppression mechanism oracle, not delivery of those
probes, a feedback-induced floor trap, real overuse, product health or decoded media.
The older seven-case harness still supplies the equality/network-upper boundaries.
Neither harness changes any failed streaming result.

### Baseline observer and receiver-cadence diagnostics: passes, not reproductions

`BASELINE_DELAYED_ESTIMATOR_COHORT.md` declared one observer-only run of the original
delayed dynamic fixture, with `experiment:nil`, 50-ms one-way delay, no capacity
serialization and the original pixel/FPS/blackout assertions. The native default
readback verifies an absent burst override; pinned `PacerConfig::kDefaultTimeInterval`
is 40 ms. This is the production-default configuration, distinct from the 20-ms
hold/skip diagnostic cohorts; it is not a logged measurement of packet spacing.
The explicit factor-1 screenshare tuple is configuration-equivalent to the SDK's
empty-group substitution, not byte-identical text or timing equivalence.

`baseline-estimator-native-delayed-1.log` passed with unchanged source
`62abc9b00a2b56041b192655da5cf91ae45d09c0d571848c5e5dc6892268109e` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`.
All observed pixels stayed sharp, final FPS was 51, maximum native RTT 111 ms,
24 advancing post-capture delay events and 15 distinct pacing pairs verified,
and blackout plus balanced teardown passed. Its first two ordinary reports saw
888,571 bps, established by probe 2 before capture, not the earlier failed ordinary
gate's 656,555 bps. Thus this is a non-reproduction, not a root-cause finding or a
replacement green ordinary gate. Before the run, 83 focused tests and 70 fake-runner
scenarios passed; those counts are separate from the native run.

The single `testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic` retains the
20-ms hold/skip second-drop fixture and its unchanged first-sharp two-second window,
eight changed transitions, 500-ms maximum gap and four-second recovery deadline.
It adds bounded, single-flight viewer statistics on existing ordinary sampling
ticks, plus already available RTP timestamp and renderer callback/conversion timing.
None feeds host policy. `recovery-cadence-native-1.log` passed with unchanged source
`cda852c92d3209ce2ea9cad6e97ed1e112e51901be5b99eee06fe97295e11de5` and the same bridge.
The oracle's conservative restore-start boundary is 8,063.404 ms; sharp pixels
arrived at 8,500.000 ms, 436.596 ms later. Setter completion at 8,063.422 ms gives
a separate 436.578-ms interval, not the oracle's primary timing. Its first two-second
window held 11 sharp frames/10 changed
transitions, and all 29 recovered frames before the actual second drop stayed sharp;
their maximum gap was 303.742 ms. Capacity stage 3 really began at 14,121.533 ms
(setter completion 14,121.553 ms), and pixels degraded again. Final FPS was 5.
Active native evidence verified 32
advancing delay events and 40 distinct pacing pairs; blackout and balanced teardown
completed. Receiver collection retained 39/39 records with zero omitted, malformed,
regressing, saturated or retired completions. These aggregate counters do not join
individual capture, encoder, packet and display frames.

This run did not reproduce the 905.473-ms gap; instrumentation can affect timing.
It validates collection in a passing run, not the cause or repair of matrix 2's
failure, and it does not add a case to either original fixed matrix. Its log/receipt
hashes and scope are in `RECOVERY_CADENCE_DIAGNOSTIC.md`. Before the run, 126 focused
tests and 72 fake-runner scenarios passed. Afterwards, independent inbound attribution,
malformed counter, retirement and clock mutants compiled and failed 1/8/3/4 assertions
respectively, with zero unexpected errors; exact restoration passed 27 focused tests
under the same `cda852c9…` source seal. These are receiving-boundary mutations, not
media-failure reproductions. Every earlier red receipt remains unchanged.

### SDK-default-selection cohort: terminal second-pressure failure

`DEFAULT_PACING_ALR_PROBE_CAP_COHORT.md` predeclared a separate three-round,
seven-case comparison: original delayed control/candidate, weak, disabled recovery,
enabled recovery, second drop and ample. It removes the 20-ms override while
preserving exact candidate ALR groups, caps and all pixel/cadence/pressure guards.
The five moving cases add bounded receiver collection and final-request draining;
this is not a timing-identical A/B against historical 20-ms recordings and does
not extend either original five-case matrix.

The new cohort is terminal RED: 19 passes, then round 3 second-drop failure,
20/21 completed with only round 3 ample unrun. `default-pacing-cohort-1.result.json`
is authoritative; all 20 separate receipts agree and preserve source
`c029f1720d7fcde07e60514309707418d99a072264169c20621719a59a5d778c`, bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47` and runner identities.
Every case verifies SDK-default configuration selection, not runtime consumption
of 40 ms: each receipt explicitly records `runtime_window_readback: false`.
The 40-ms value comes only from pinned SDK source. There were no retries or timeouts.

All three delayed controls and candidates passed sharp startup at final
49.5–51 fps, without reproducing the old ordinary blur; weak controls passed at
5 fps, completed ample controls at 13 fps, and disabled cases are characterizations.
Enabled recovery passed in all rounds at 1,475.662/3,561.372/385.440 ms. The first
two second-drop cases passed at 381.263/2,896.687-ms recovery and then degraded again.
These times use the conservative mutation-start boundary, not setter completion.

The failed third second-drop case recovered in 377.358 ms and passed sustained
cadence (28 sharp pre-drop frames, maximum gap 328.103 ms). Its actual second
drop started at 14,005.081 ms, yet all 30 subsequent observations stayed sharp
1080×1920 through 19,889.630 ms, final 5 fps. The sole failed assertion was
`Fresh second pressure must revoke full-pixel recovery`. This is a different
failure from the old 905-ms first-window gap: stage 3 really occurred. It identifies
the failed unchanged oracle, not the cause or whether that renewed limit necessarily
required spatial degradation. Active native evidence verified 37 advancing delay
events/42 distinct pacing pairs; receiver collection completed 39/39 records.
Blackout and balanced teardown completed despite this nonthrowing assertion.
Neither those successes nor later sharp pixels override the cohort's RED result.

Native pressure response was present: delay overuse reduced BWE through
541,325/495,593/482,502 bps at 14,587.683–14,791.157 ms, returning to normal at
14,951.756 ms. Adjacent ordinary queue delay was 6.811/28.842 ms, RTT 6/7 ms.
Sustained overload or incorrect policy is therefore not established solely by
retained sharp pixels. The next step is contract/replay discrimination, not forcing
unnecessary blur to pass the old assertion or silently reclassifying the RED run.

Before the cohort, 563 required deterministic methods and 75 fake-runner scenarios
passed separately; four new final-drain/default-admission/profile/workload mutants
failed 1/8/2/2 assertions with zero unexpected errors, then exact restoration passed
53 focused tests. `RECEIVER_MUTATION_EVIDENCE.md` preserves those receipts and the
different gate-versus-runner source-manifest scopes. The cohort plan pins full
case values and receipt/log hashes. Every historical RED stays RED; no consumed
40-ms, default-on flag, product-fix, promotion or deployment claim follows.

## Safety coverage under construction

Recovery has an exact peer/Show owner, fresh ordinary native-report/packet/RTT
witnesses, a fixed three-second admission deadline, native-apply acknowledgement,
and actual full-size encoded-frame progress before acceptance. Failed attempts
back off for 15/30/60 seconds. Accepted geometry may survive missing telemetry;
fresh pressure and lifecycle uncertainty still revoke it.

The deadline limits policy authority, not how long a blocking native API can take.
A late native result must be reconciled before it is published as accepted.
Unknown apply/rollback outcomes must invalidate the applied-state cache, never be
reported as proof that the previous native geometry was restored.

Late native application, failed compound fallback, stale same-peer cache ownership,
and current-owner cache invalidation now have behavioral tests. The 427-method gate
above passed them; source-wiring checks are supplemental, not a live service proof.

Nineteen deliberate source mutations all failed their intended behavioral assertions
in `spatial-mutations.YPGrIL/results.json`, with per-mutation logs alongside it.
They cover Show ownership, native publication deadlines, stale applied caches,
actual encoded confirmation, no-packet evidence, native fallback and successor
ownership, admission/confirmation queue boundaries, unchanged caps, malformed and
cross-lane packet baselines, preserving independent probes, original sparse deadlines,
successful-backoff reset, ordinary grace, partial-pair rejection and pre-admission hold.
Every final production-file SHA-256 matches its pre-mutation value. The runner's
reverse-context ambiguity was caught, repaired to the exact original hash, and replaced
with unique reverse context plus per-file restoration verification before continuing.
No mutant reached a running app or release artifact.

Remaining work is diagnosis of ordinary startup-detail and recovery-cadence failures,
plus native validation of genuinely sustained second pressure after the deterministic
contract replay below, without weakening or silently reclassifying recorded oracles.
Retained sharp pixels alone do not authorize a forced-revocation product fix.
Corrected native witnesses have run;
matrix 2 still failed its media contract. Matrix 1 left eight cases unrun, matrix 2
left seven, and the separate default-selection cohort left one. None may be
relabeled passes or completed by appending retry-until-green diagnostics.
All earlier weak-link and recovery failures remain retained. The historical restored-source gate
`startup-20260920-52298-43kzn8` passed all 440 deterministic methods and both original
native cases after the mutations. Its source hash exactly matches the failed matrix's
`9292688a06975420a085c385cce45364e8b87a428bf52c5d359e4fc06174eb27`;
this proved restoration at that checkpoint, not a current green gate. It does not
replace the later red ordinary gate or either failed ALR candidate matrix.
Loopback success would still not prove WAN, iPhone presentation, duplex audio,
deployment, or user-visible reliability. The live host has not been restarted.

## Second-pressure replay and probe-duration discriminator

Three new production-policy replays pass under source
`f628958f644f699487fe9a0e22b874a6e7dae0f90abedff045725358ba64ee4b`. The recorded
541,325→482,502-bps transient retains accepted survival pixels during an independently
owned 3.5-second probe. Its unchanged deadline contracts the total cap to 905,041 bps;
the recorded rebound does not mint new geometry or capacity authority. In a separate
counterfactual, two fresh ordinary low-BWE reports after expiry retire geometry into
emergency/cooldown. Fresh queue/RTT/collapse pressure still retires it, while stale or
missing evidence does not. Packet/frame/RTT counters are deterministic witnesses;
these are policy decisions, not new native decoded-media proof.

Four compiled mutants fail 46/3/6/11 assertions for premature collapse, suppressed
persistent downgrade, missing fast-pressure retirement and stale fast timestamps.
Production source is exactly restored. The full gate
`startup-20260920-97276-10o8s41` passes all 566 methods; its manifest identity is
`ea33901ff0c5edf1cf751507d738023cabf5552dea5b0bf15418772ee6089fa2` (different path
scope from the runner identity). All 78 fake-runner scenarios pass, including the
three new required-method omissions. `SECOND_PRESSURE_REPLAY_EVIDENCE.md` in scratch
pins the individual receipts. The historical 800-kbps native second-drop RED remains
unchanged; forcing blur is not justified merely because the link setting changed.

A separate actual-framework controller oracle tests first delivered probe-feedback
susceptibility. Four fresh environments use native returned cluster 2 at 905,041 bps,
247-byte packet records, 50-ms outward/return paths and one complete feedback batch.
Peer maximum, positive video allocation 585,041 and reserve 320,000 bps are fixed.
Only `min_probe_duration:100ms` differs in the long arm; no product trial is enabled.

| Probe duration | Final-packet arrival extension | Native probe/delay/published BWE |
| --- | --- | --- |
| Default 15 ms | 0 | 905,038 bps |
| 100 ms | 0 | 905,038 bps |
| Default 15 ms | 4,055 us | 656,554 bps |
| 100 ms | 4,055 us | 869,165 bps |

All four pass in `probe-duration-feedback-smoke-1.log`, with normal delay state,
balanced records/loggers and no probe failure. Native values, not arithmetic alone,
cross the 670,400-bps threshold. A duration-off mutant compiles and fails both long
cases at actual cluster configuration, with short cases passing. Source, compiler
ABI, framework, binary and log hashes are retained in the separate receipts.

The long probe sends 11,362 versus 1,729 bytes (9,633 extra, about 6.57×), with actual
send spans 98,250 versus 13,100 us. The field trial affects later common probe types,
not only startup. This synthetic mechanism neither proves the historical 656,555-bps
startup cause nor native pacing, complete two-cluster startup, moving-media recovery
or production safety. Smaller duration/capacity discrimination should precede media
wiring; preserve all native REDs and fixed deadlines. No host restart, deployment,
phone/audio operation, commit or push accompanied these checks.

### Baseline-preserving40ms probe-duration discriminator

The later fixed FIFO sweep completed24/24 cases:15/25/40/100ms across8Mbps and
600kbps links, each with0/4055/10000us final-packet extension.40ms was the shortest
tested duration staying above670400bps in all ample cases, at905038/820389/685387bps.
Every constrained case published below600kbps, with real modeled FIFO residence;
none emitted native delay overuse.40ms sent4693bytes versus11362 at100ms and1729
at15ms. This is a bounded candidate choice, not universal optimum or historical
cause proof. See scratch `PROBE_DURATION_FEEDBACK_ORACLE.md` for full results.

The separate Configuration-group variant preserved Behavior=min_packet_size:0
and produced byte-identical24-case output. Compiled duration-off and FIFO-bypass
mutants failed18/12 cases at their configuration/serialization assertions with
all24case results and balanced logger lifetimes. These failures occur before packet
submission in the rejected cases, not at downstream estimator arithmetic.

The new default-off real-media pair adds exact15ms-control and40ms-candidate
selectors without changing prior cohorts. Both hold ALR growth, skip already-low
probes, select SDK-default pacing and retain the original12s delayed-dynamic
cursor-only fixture. The new separately pinned bridge validates the original
environment; the independent Swift witness validates the first two real cluster
requests against IDs1/2,rates900000/905041,5probes and1688/1697 or4500/4525bytes.
This is requested byte-budget consumption, not actual pacer duration or probe
delivery. Old REDs still block promotion, and the initial pair does not substitute
for ordinary native and recovery/pressure acceptance. No production flags changed.

The initial pair is now complete: both strict receipts passed with sealed source
`13569743baafabed8d76bd0febdb9ec4f47bf4926aeb96e93e67d57fd1047f01` and bridge
`a0a59e41c7fc3fcfe2d04fa8ff2751b3847108172d568adedabe1e00a03c44e9` unchanged.
Control/candidate first sharp frames were 257.4205/428.2259 ms; both stayed sharp
and ended at 49.5 fps. The candidate reached full policy tier at 3068.5765 ms
versus 7182.6131 ms, but its initial probe results arrived after capture while
the control's arrived before capture. This mixed single pair does not establish
a robust improvement or reproduce the historical low startup estimate. All
native witnesses, blackout and balanced logger teardown passed. The restored
gate passed 583 methods, 96 fake scenarios passed separately, and four compiled
byte/selection/loader/native-fence mutants failed 6/52/7/23 assertions with no
unexpected errors. See scratch `PROBE_DURATION_MEDIA_PAIR_1.md` for exact
receipts and the next, not-yet-run moving-weak falsifier. No deployment occurred.

### Moving weak and recovery duration pairs: no demonstrated net improvement

The later moving-weak pair ran once per arm and both strict receipts passed.
Control15/candidate40 each decoded 49 sharp 1080×1920 frames and ended at 5 fps.
First sharp was 367.675/374.409 ms; both retained roughly 0.84/0.90-second early
gaps despite about 200 ms source submissions, with `framesEncoded` already
plateauing at two. The candidate used slightly more measured relay traffic.
See scratch `PROBE_DURATION_MOVING_WEAK_PAIR_1.md`; it is not a recovery result.

The separately declared 16-second 8→0.8→8 Mbps moving-recovery pair also passed
both strict receipts, without retries or source changes between arms. Sealed
Swift/package identity was
`80f3f2183a9c777fd3b3a6cba96666e17ed6626f54532067833e130f04e2ab1f`, with the same
`a0a59e41c7fc3fcfe2d04fa8ff2751b3847108172d568adedabe1e00a03c44e9` bridge.
Control15/candidate40 first sharp was 373.148/283.916 ms, but first changing sharp
content was 2366.376/2862.350 ms. Recovery was 2436.812/3467.713 ms after each
actual conservative restore boundary: 40 ms was 1030.901 ms slower in this pair.
Both fixed recovered windows held 18 sharp frames/17 changing transitions, with
maximum recovered gaps 202.345/188.594 ms and no subsequent blur. Final FPS was
12.5/13. Native witnesses, blackout and balanced teardown passed independently.

Maximum modeled relay serialization was 218.779/939.064 ms. The candidate's
later first blur partly reflected old sharp frames draining that backlog, not
lower latency; callback lateness during buildup was at most 2.331 ms. Native
overuse counts were 4/11, while both receiver collectors reported zero loss,
drops, NACKs or PLIs. Counts of requested probes do not establish transmitted
probe bytes or isolate the backlog's cause. Keep the common-duration candidate
default-off; mixed single-pair results are not a robust improvement.

The restored 58-test safety selection and 110 fake-runner scenarios passed.
Boolean/capacity/selector mutations compiled and failed 2/4/2 assertions with
zero unexpected errors. Two preceding selector attempts timed out before any
tests, one during linking and one in a target-information compiler utility;
retain them as infrastructure failures, not mutation evidence. After exact
restoration/rebuild, gate `startup-20260920-35407-7bfyw9` passed 595 required
methods with no skips; all 342 covered files rehashed unchanged after the pair.
Exact logs, hashes, qualifications and the next encoder-boundary diagnostic are
in scratch `PROBE_DURATION_MOVING_RECOVERY_PAIR_1.md`. That diagnostic is not yet
implemented or run. All historical REDs retain their status; no production flag,
installed host, phone, audio route, network setting, Git push or deployment changed.

### Outer encoder-boundary diagnostic (2026-09-20)

After 612 deterministic checks, 127 fake gate scenarios and compiled rejection
mutations, one control15 moving-recovery diagnostic ran with a six-second
test-only scalar trace. Overall **RED**: one stale callback made the trace
invalid; original pixel/recovery/blackout/native-witness/teardown assertions passed.
No retry, deployment or policy promotion followed.

Retained early observations locate a useful boundary: all ten source submissions
in 0–2 seconds reached the encoder and returned zero, but only three produced
matched outputs (162.6, 815.0 and 1615.0 ms). Those output callbacks were prompt
after their own inputs, and the first release was at 4752 ms. This is evidence
of sparse output after outer encode entry, not a verified whole trace or a named
VideoToolbox failure. The next diagnostic is bounded native H264 drop/error logs
plus timestamped rejection reasons; do not raise bitrate/QP/caps from this alone.
Full identities and the preserved failure are in the scratch
`ENCODER_BOUNDARY_DIAGNOSTIC_1.md` and its log/receipt.

The separately instrumented native-log diagnostic2 then passed its unchanged
acceptance checks: 55 encoder inputs,45 outputs, and ten native H264 frame-drop
notices. In0–2s all ten inputs arrived but only three outputs were delivered;
seven drop notices align temporally with the gap. This confirms native frame
suppression in the synthetic encoder path, not a source-capture gap. Scalar logs
remain process-scoped. Diagnostic1's earlier stale-callback RED is not erased.
The next narrow target is the encoder's screensharing MaxAllowedFrameQP=39
constraint (the local Apple SDK documents its potential to drop frames), plus
actual hardware-status readback. Neither cause is proven yet; do not weaken
sharpness/congestion/continuity checks or change network policy from this alone.
Evidence is in `ENCODER_NATIVE_LOG_DIAGNOSTIC_2.md`; 626 deterministic and141 fake
gate checks passed. No production behavior or deployment changed.

### Isolated VideoToolbox QP comparison (2026-09-20)

A predeclared fresh-process ABBA comparison (QP39/unset/unset/QP39) completed
four characterization tests, keeping the dense/moving pixels, signed-contrast
oracle,5fps cadence and initial bitrate ramp fixed. Both QP39 arms delivered3/12
frames, all with phase0; both unset arms delivered8/12, first changing phase at
input6 (1.2s). Minimum stripe contrast stayed above0.985 in both arms. However,
unset sent178871 bytes versus17107, so this is NOT bandwidth-safe release proof.
The direct-VT QP readbacks were39/-1 with status0. Hardware status was unsupported
(-12900), not a false boolean; software encoding is not established.

One prior attempt stopped before encoding because the optional speed-priority
hint was unsupported. Its RED is preserved; the complete comparison matches the
pinned SDK's nonfatal handling of that exact hint. The actual WebRTC session's
QP status/negotiated level were not retained in diagnostic2, and this isolated
test omits that path's initial pixel-format reset/network/adaptation. No policy
or SDK binary changed. Do not promote without actual per-encoder configuration
evidence and unchanged weak-network/continuity acceptance. The test is explicitly
opt-in and does not replace ordinary native gates. Full evidence is in scratch
`VT_QP_ABBA_2.md`, with source seal
`2a8f1649610a5d6c61a9c671ff4be3c9e6a74d34efdd08606cb88f07691e11f6`.

The subsequent actual-WebRTC property comparison used a sealed test-only public
VT hook with exact owner/generation/session eligibility. Six admission tests,
an assertion-failing eligibility mutation, seven native isolation cases and13
numeric receipt rejection cases precede it. ControlPASS verified16 actual QP39
assignments/readbacks. Unset verified6 omissions/default-1 readbacks, but remains
**RED** because the outer trace rejected one owned-input callback during release
at5061.151ms. All original pixel/network/recovery/blackout/teardown assertions
passed; the trace assertion is not waived. First changing decoded content was
1128.371ms earlier, while first sharp frame latency was unchanged (~314ms) and
final FPS was lower (8 versus12.5). This is not a uniform improvement or release
proof. Investigate the exact legal drain boundary with regression tests before
another candidate run. Source seal
`d229faae00588e700ed2f16945b80ff61b198a6fcde80f1d7c8bf51f21f62a26`;
full logs, initial hook-recursion failure, guard receipts and qualifications are
in scratch `QP_OWNER_NATIVE_PAIR_1.md`. No production behavior or deployment changed.

### Narrow drain ownership and fresh QP pair

The pinned encoder retains its callback until synchronous invalidation returns.
Schema 3 now admits only exact, successful, unconsumed pending inputs during that
single release lease. Both output and callback-return retain old identity and an
explicit retirement fence; all lifecycle changes and release return revoke it.
Late, duplicated, unknown, wrong-registration and cross-encoder observations still
fail. Native forwarding is unchanged. 28 focused tests, five compiled faults
(8/9/9/10/21 assertion failures, zero unexpected), 32 independent Ruby replay tests,
154 fake runner scenarios and the restored 639-method contributor gate passed.
An initial history-mutant compiler failure is retained, not counted as guard proof.

The separately predeclared native control/unset pair then passed both arms with
unchanged media/native/blackout/teardown requirements and sealed source
`b03f31b40c0f56a4cfd9bf8637adc301091c302ffbb74548f14e42431fe872cb`.
The candidate recorded an actual correctly owned release-drain output/return and
zero stale callbacks. First changing pixels arrived at 1222.512 vs 2365.443 ms
(1142.932 ms earlier); first-sharp frames were 323.543 vs 357.786 ms. Recovery was
2473.647 vs 1965.586 ms, **508.061 ms slower**, while both ended at 12.5 fps.
This supports earlier startup motion, not a general recovery gain or deployment.
Consider a separately bounded startup-only treatment before changing global QP
policy. All prior REDs remain as-run. Full receipts and interpretation are in
scratch `QP_OWNER_NATIVE_DRAIN_PAIR_2.md`. No app, SDK or production setting changed.
