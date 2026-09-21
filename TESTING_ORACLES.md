# Beluga Release Oracles

Passing code-path assertions is not release evidence. Each production claim needs an
independent observable outcome from the artifact that actually ran, plus a negative mutation
that demonstrates the oracle fails when that outcome is broken. This document distinguishes
implemented gates from the remaining release boundaries; it is not a feature-completeness claim.

## Critical Guarantees

| Guarantee | Implemented primary oracle | Representative mutation that fails |
| --- | --- | --- |
| Exact product identity | `check-product-identity.sh` parses the Swift package, XcodeGen source, generated project and schemes, iOS/macOS plists, preserved bundle IDs, LaunchAgent paths and logs, npm manifests/lockfiles, and Worker configuration. It resolves PBX target, product-file, build-configuration, and scheme blueprint object IDs instead of trusting display comments. A hosted iOS test also inspects the built app bundle. The public-release gate runs these checks alongside the path-specific former-brand audit. | Change Beluga display casing, rename one project/target, redirect a target or scheme to the wrong PBX object, alter the real product path or configuration name, change a preserved upgrade bundle ID, drift the host/LaunchAgent path, or change one npm/Worker name. Each mutation is exercised independently. |
| Correct Mac host | Freshly build the signed app, verify its actual plist and designated requirements, then require the installed app and live launchd PID to use the same executable and CDHashes. The live process must map the verified installed LiveKitWebRTC framework vnode, and the loaded launchd job must match the checked-in program arguments, environment, `RunAtLoad`, and `KeepAlive` policy. | Run a legacy app, naked SwiftPM binary, wrong Team ID, renamed bundle, symlink, stale installed build or mapped framework, changed launch arguments, or endpoint/auth/DYLD environment override. |
| Durable paired reconnect | The physical driver keeps one non-secret pair fingerprint across three distinct host PIDs and an iPhone cold launch, while requiring a freshly authenticated live media route after every reconnect. | Retain the UI label but delete the Keychain record, reuse a reconnect sequence, or reconnect signaling without advancing inbound/native media. |
| Full-quality audio through the app-observable boundary | The deterministic native loopback evaluates the full aligned 800 ms decoded stereo waveform—including independent 4–15 kHz pilots—for completeness, silence runs, clipping, gain, channel separation, correlation, bandwidth, and both edges. Separate conversion tests exercise source formats. On iPhone, the physical gate drives a coded 500 ms challenge alternating 997/1499 Hz at high level with 8003/11003 Hz at low level. It requires inbound RTP energy plus output-only RemoteIO render-input PCM/callback/frame density, per-channel high/low-band zero-crossing rates, bounded envelope and cumulative per-callback waveform-shape rates, cumulative cross-callback continuity, no near-silence, no recovery rebuild, no callback gap over 25 ms, and the playback/default 48 kHz stereo route. This is pre-system-output evidence, not proof of the later iOS mixer, route processing, DAC, speaker, or acoustic result. | Telephone-band low-pass, first/last or periodic silence, dropped/repeated samples, frozen callbacks, repeated phase-reset 10 ms blocks, rapid 10 ms gain pumping, clipped or flattened/square PCM followed by one healthy callback, mono folding, half-stereo delivery, swapped or impossible band rates, VoiceProcessingIO, callbacks that consume no PCM, recurring 30/40 ms native callback gaps, a late one-shot increment, or counters too sparse for elapsed time. |
| iPhone microphone forwarding into the product virtual microphone | A connection-level lease registers the exact default-input listener before writing, saves and freshly resolves the prior UID, requires bounded listener/readback proof, is fenced by the atomic product endpoint pair plus peer/connection generations, and conditionally restores only while it still owns the visible input-only endpoint. Session-lifetime output/system-output listeners synchronously close the writer gate; all current and retired virtual-microphone UIDs are forbidden output defaults and process-tap clocks. The forwarding AudioQueue targets only the hidden output-only UID, proves the exact UID and AudioDeviceID before and after start, consumes native mono playout, and requires one successful post-start pull plus two advancing progress snapshots. Physical evidence binds the visible selection and hidden-writer marker to the same PID/peer/pair generation and restores the original input. | Conflate the visible and hidden UIDs, omit either queue/ID readback, accept a partial/wrong-role/stale pair, delay selection until track or PCM, restore the wrong or hidden UID, overwrite a newer external input choice, permit any product/retired endpoint as output/system output or aggregate clock, remove listeners after one poll, reopen from a stale sequence, pull/enqueue after gate close, count priming as progress, or replace UID-pinned capture with forwarding counters. |
| Product virtual-microphone compatibility | The production writer keeps PCM admission closed through silent priming and startup until exact 48 kHz packed Int16 mono queue/device/converter readbacks and two advancing device sample/host observations pass. It preserves at least 60 seconds beneath the observed FaceTime signed-32 projection and closes both PCM and route gates before reporting runtime clock failure. The installed no-call oracle must open the exact hidden 0-in/1-out writer and visible 1-in/0-out input, bit-compare a mono nonce, require exact packed Float32 mono native formats, exact model/clock domain, unity/unmuted controls, both complete start orders, unchanged defaults, and drained teardown. A separate bounded public VoiceProcessingIO probe must prove actual 48 kHz mono processed-microphone capture, exact 48 kHz stereo playout-client readback with a bounded two-buffer silence callback, advancing timestamps/callbacks, zero render error, and strong nonce correlation. | Negotiate 44.1 kHz, stereo processed-microphone capture, mono or malformed VPIO playout, wrong role topology, wrong clock domain, extra ASBD flags, converter error, non-unity gain/mute, frozen/regressed/aged device time, insufficient signed-32 reserve, altered/dropped/duplicated PCM, one-order-only lifecycle, default mutation, silence/noise-only capture, or leaked queue/listener/callback/endpoint. |
| Replacement virtual-driver timeline | The clean-room C17 core and direct production-wrapper tests increment a nonzero zero-timestamp seed only when the shared clock moves from zero clients to its first client, preserve it when the sibling endpoint joins, bind ring frames to exact epoch/session/absolute-frame tags, and repeat both start orders and 1,000 complete restarts without stale PCM. Concurrent lifecycle/I/O/timestamp tests run under ThreadSanitizer; ASan/UBSan, malformed-bundle mutations, two byte-identical universal builds, and loading the actual built bundle cover the artifact seam. The user reports the current side-by-side product path works bidirectionally; provenance-bound installed public-API validation remains required for independent artifact proof. | Keep a constant seed across reset, change it on a join, publish a new seed with an old anchor, retain stale ring state, expose lifecycle retry as a callback error, omit a loadable Mach-O UUID, test only one order, or infer the seed from public AudioQueue time. |
| Active iPhone call isolation | A signed lifecycle suite samples aggregate CallKit state before ordinary activation. Ringing-only startup keeps ordinary best-effort playout while microphone ownership stays closed. Connected-call startup remains globally closed until an exact startup-origin authorization is bound to the first healthy peer, synchronously armed by the quiescent native ADM with zero session side effects, and then proved by fresh inbound/native evidence. A later bare CallKit transition closes only microphone ownership; a genuine interruption replaces any startup authorization with a fresh interruption-origin authorization. Call end revokes hosted ownership and requires a fresh ordinary rebuild plus a newly advancing proof window. | Activate before the startup call sample, open the manual gate before native startup arm, accept an unspecified or wrong origin, bind a startup authorization to a replacement peer, let foreground/route callbacks rebuild after hosted failure, retain startup ownership across a real interruption or call end, accept a suspended pre-call stats read, disconnect the peer, or report Playing before fresh callbacks and frames advance. |
| Background audio | The built-app test inspects `UIBackgroundModes=audio`. The physical gate presses Home for 35 seconds, returns to the app, and requires the original session generation to have accumulated real-time inbound duration/energy and output-only RemoteIO render-input PCM with the coded high/low-band and envelope signatures over the entire interval, without a callback gap, near-silence callback, or audio-unit rebuild. | Remove the capability, stop or mute the track on Home, freeze/replay one callback, suspend RemoteIO, stall for most of the interval, catch counters up only after foregrounding, or reconnect on foreground. |
| Screen Show/Hide | The driver places a nonsecret changing pattern on every Mac display. The physical gate binds an authenticated Show/Active acknowledgement to a stable sequence of at least 12 decoded frames/sec whose independently sampled salted pixel digest changes at least 3 times/sec, then requires a newer authenticated Hide/Inactive acknowledgement and proves audio continues in the same media session. | Acknowledge Show without advancing decoded frames, reuse a stale acknowledgement/renderer, emit one late frame, report 60 fps while pixels change only 1–2 times/sec, advance timestamps over frozen pixels, stop the deterministic visual challenge, or Hide by reconnecting the media session. |

The current Screen gate proves that decoded pixel changes overlap a live deterministic host
challenge at the production renderer boundary, but the decoded pixels do not yet carry a
cryptographic nonce that identifies that exact challenge. It therefore does **not** independently
prove source identity, GPU presentation, or host capture-process quiescence after Hide. The
current remote-input check proves only that a fresh authenticated capability is present;
it does **not** yet drive a disposable Mac target and observe real AX/model mutations. Those claims
remain release-incomplete and must not be inferred from acknowledgements or screenshots.

The retained historical BlackHole 2ch v0.7.1 is release-incompatible for worldwide routing. Its local
timeline counter resets without a new zero-timestamp seed, and a no-call run still
observed public device time whose 24 kHz projection exceeded the signed-32 FaceTime
boundary after both endpoints had been stopped. The same run did not prove exact
hidden-to-visible PCM. Production code must therefore fail closed on this generation;
stopping the endpoints is not reset or recovery evidence.

As of August 23, 2026, the user reports that the current side-by-side opensteamer
deployment works with simultaneous iPhone-microphone uplink and Mac-audio downlink.
That observation applies to the installed pre-cleanup build; it is not provenance-bound
driver evidence and does not certify a later build from this source cleanup.

## Gate Rules

- Prove provenance first: device, app build, code identity, executable path, PID, and fresh
  artifact directory.
- Prefer counters, decoded content, native target state, and exact before/after deltas over labels
  that merely restate internal state.
- Cross-check at least two independent layers for physical media tests, such as host source/RTP
  evidence and iPhone decoded/native-render evidence.
- Require a positive baseline and one-field-at-a-time negative mutants. A test that has never
  been seen rejecting its target defect is not a regression guard yet.
- Never reuse an existing `.xcresult`, log suffix, screenshot, or summary. Bind evidence to the
  current device, PID, build, and run.
- Use bounded ratios for network loss, concealment, and jitter. Reserve exact zero assertions for
  deterministic in-process tests where zero is truly invariant.
- Keep manual sensory checks as exploratory evidence. They do not replace a repeatable waveform,
  pixel/nonce, counter, or target-state oracle.
- RemoteIO callback PCM is before iOS's final system mixer and hardware output. A claim that the
  speaker or headphones sound crisp requires a separate wired or external recording with a
  source-correlated waveform oracle; app-internal counters alone cannot make that claim.
- AudioQueue priming, queue-running state, callback clocks, hidden-writer selection, and forwarding-readiness counters do
  not prove that another Mac application can consume the visible product input. The physical oracle must
  independently open the visible device by stable UID and recognize a source-correlated remote
  microphone challenge. Hidden-writer selection is nevertheless a required semantic gate: bind
  its pre/post-start UID readback marker to the current host PID, peer generation, and atomic pair
  generation before arming that capture.
- Run the no-call hidden-output-to-visible-input oracle against the freshly resolved
  installed endpoint pair before another FaceTime trial. It must pass exact PCM, format,
  clock/headroom, unchanged-default, and teardown checks. A passing no-call result
  removes those deterministic blockers but does not prove FaceTime adopted or sent the
  input, nor that its private downlink is intelligible; one final bidirectional FaceTime
  acceptance call remains necessary. Bind any claim
  about an exact driver build to separate signed-bundle provenance until the oracle
  itself records that provenance. The historical public probe is
  decisive blocking evidence for the aged installed BlackHole pair, but it is not a
  substitute for the implemented direct seed/restart and both-order tests or the still-
  required installed validation of the repo-owned replacement driver.
- For worldwide-only microphone forwarding, capture the original input plus the
  output and system-output UIDs before connection. Require the visible product endpoint as the input at
  the authenticated peer/ICE/control boundary before remote-track or PCM proof,
  exact output and system-output equality throughout, prove the hidden endpoint never becomes
  a default, and require restoration of the
  original input after disconnect. Input notifications caused by the expected
  selection and restoration are allowed and should corroborate ordering; any output
  or system-output notification is a failure.
- Graceful teardown can prove conditional restoration. An in-memory lease cannot
  prove restoration after `SIGKILL`, process crash, kernel failure, or power loss;
  release claims must state that limitation rather than inferring crash recovery.

## Ordinary microphone effective-sharing profile

The 2026-09-19 user-approved revision preserves the requested `.default` setter
policy and the actual observed getter separately. Only ordinary raw microphone
duplex with exact `.playAndRecord` / `.default` / options40 accepts effective
`.default` or `.longFormAudio`. It does not identify the source of a notification,
authorize capture, permit a different input route, or apply to hosted-call playback.
Output-only playback remains effective long-form; hosted-call playback remains
effective default. Native, Swift, and Rust must agree on this profile without
normalizing observed values or changing the factual `isDefault` diagnostic bit.

Require both effective values through current-operation observation, native
configuration, sender admission/statistics, and physical PCM proof. A later 0/1
observation is benign only with the same immutable transaction provenance and a
newer sequence/time. A changed value under the same sequence remains conflicting.
Reject independent, long-form-video, negative/unknown values, inconsistent diagnostic
bits, wrong mode/options/category, stale operation/device/generation evidence, and
missing native or capture authorization. Prove a strict-default mutation breaks the
positive long-form case and a broad-acceptance mutation breaks the negative cases.

The spare-phone AVAudioEngine test proved built-in raw RemoteIO capture under
effective long-form in two fresh processes, with two advancing 500ms PCM windows
per process and balanced teardown. That is platform evidence only: it does not
replace sole-production-device capture, WebRTC sender, Mac consumer, reconnect,
call-privacy, or physical media-button validation from the changed artifact.

Pending route convergence must also handle a category observation that carries a
real, chained route change. It may advance only the current Pending transaction's
route cursor with exact profile, sequence/deadline/configuration/system provenance,
unchanged pinned output and admissible ownership. It is not reason-8 evidence, a
native-start settlement, a capture grant, or proof of notification origin. Require
the production handler to update that cursor while preserving the category receipt;
reject broken chains and wrong outputs, ownership, policies or generations, and
keep Prepared/Starting/Consumed behavior unchanged. Removing the cursor update must
fail the handler test. Physical proof must still exercise output-only to microphone
and back, not merely cold microphone activation. Capture failure diagnostics before
rollback, since deactivation removes input routes and can obscure the first cause.

An SDK `stopRecording` callback is a synchronous capture-privacy boundary, not an
application policy transaction. Require authorization revocation, drained capture,
cleared recording generations and rejected bare restart, with no category, configuration
or system-generation mutation. Preserve a pending exact output-only operation and the
truthful configured input-bus flag until that operation disposes/rebuilds the unit.
Exercise absent, output-only and microphone pending carriers; reject cross-carrier
borrowing and competing enables. Restoring the untagged stop-time rebuild must fail
the production-stop regression. Swift tests must prove privacy is already closed while
the output-policy owner is suspended and before successful or failed native attempts.
Physical repeated A/C cycles must show advancing native capture and sender energy,
frozen capture after each disable, correlated category receipts, and real tag drains.
The sole-viewer physical test keeps a real MediaPlayer command registered, negotiates
normal local WebRTC with a no-hardware host, and runs three complete cycles on one
production RemoteIO device. It consumes actual category/drain events through the Rust
authority and stores scalar measurements only. Two fresh launches passed on the spare
iPhone15 with effective long-form sharing. This does not exercise the production view
model, a Mac consumer, worldwide traversal, actual remote-command delivery or TestFlight.

## Wired iPhone audio boundary

Exercise the production native input selector and route-transaction matcher for
HeadsetMic/Headphones and USBAudio/USBAudio, built-in with speakers/A2DP/headphones
without input, absent/ambiguous inputs, wrong output, and unknown/HFP ports. Require
exact type and UID through convergence and capture publication, exclusive factual
built-in/wired bits and a fresh proof generation. Replacing a type while reusing a
UID must fail; an input appearing in the inventory is not a selected-route proof.
Independently restore built-in-only admission and remove type/UID fencing and require
the respective behavioral assertions to fail. Swift sender statistics and lifecycle
proof must accept wired only with unchanged privacy, transport, raw processing and
generation guards. Rust's category/sharing target contract is unchanged by port kind.
Do not modify v1 wire keys without negotiation with deployed hosts. A Simulator pass
does not prove adapter capabilities or acoustic output: require the matching iPhone
artifact with a real headset for cold connect, mic on/off, unplug/replug and reconnect.

## Native media controls release boundary

Headset Play/Pause must register `togglePlayPauseCommand` alongside the explicit
commands. Resolve its direction under the dispatch gate's lock from the same
authorized Mac item: playing means Pause; paused/stopped means Play. Require that
direction's capability, not either capability, and preserve the resulting absolute
command through delayed actor/network work. Never infer direction from local playout,
optimistically flip metadata, add a wire toggle, or change microphone/audio routing.
Cover background-thread dispatch, native target registration and availability, all
playback/capability combinations, and owner/item/negotiation/transport replacement.
Registration-removal and reversed-direction mutations must fail their respective
behavioral tests. Actual wired and wireless accessory delivery still requires the
matching iPhone build and real button presses; simulated gate dispatch is not that proof.

Thumbnail decoration must remain independent of command delivery. Cover legacy/malformed
optional artwork decoding, current-source reference binding, immediate metadata/controls while
loading stalls, and owner/context/negotiation replacement rejecting late results. The actual
network loader must reject a streamed oversized body before EOF and cancel superseded requests;
a post-download size assertion alone is insufficient. Reject untrusted redirects and oversized
decoded dimensions. A matching iPhone build must separately prove native artwork presentation;
unit dictionaries and a successful image fetch are not Lock Screen evidence.

Native artwork must also be requested from a non-main executor through the actual
published MPMediaItemArtwork, without a prior main-thread image request. Require
returned dimensions and pixels plus unchanged metadata/controls. Artwork and native
command handlers must remain explicitly Sendable: Objective-C may invoke them outside
the main actor. Restoring the inferred MainActor artwork callback must fail this
background test with the executor assertion, not merely a missing-image assertion.
Run `ruby scripts/test-native-media-callback-isolation.rb EMPTY_PRIVATE_OUTPUT_DIRECTORY
DEVELOPER_DIRECTORY` with the selected canonical Xcode developer directory. This bounded
compiler oracle extracts both production callbacks and checks their isolation in SILGen
and optimized Swift 6, with independent annotation-removal mutants. It complements the
signed artwork runtime test; it does not execute a native remote command or prove a
physical iPhone crash has the same cause.

Before shipping a change to Now Playing controls, require deterministic coverage of
negotiation with legacy peers, the 4 KiB wire bound, exact current-source command
admission, at-most-once Next/Previous execution, and fresh state after startup and
same-peer ICE recovery. Queue-delay mutations must demonstrate that a command or
acknowledgement admitted before recovery cannot acquire a new generation's authority.
Backpressure must not replay a relative command or permanently disable controls for an
unchanged paused item. Native metadata tests must cover owner replacement, source clear,
unsupported controls, and preservation of local interruption/headphone privacy policy.

Native Chrome integration additionally requires exact-production-script behavior
tests for document/item identity in Chrome's page execution context, video replacement, navigation
unavailability, same-URL ABA/reload/BFCache, bounded metadata and command ledgers,
renderer-side deadlines, duplicate relative commands, and late promise completion.
Native Apple Event tests must bind PID/launch identity and stable window/tab IDs,
reject changed targets, enforce final host authorization/deadlines, verify actual
command readback, and fail closed on ambiguous or indeterminate player discovery.
Mutation oracles must reject removal of final renderer/native admission and expiry
checks and relative-command duplicate interception. Permission-only helper IPC must
work without an extension or connected peer, reject media-state injection, tolerate
ordinary consent latency, recover from a transient listener failure, and retire on
stop/disconnect. Ordinary polling must never prompt or activate Chrome.

The retained optional extension path additionally requires the production browser worker,
isolated bridge, and MAIN adapter behavior tests; native framed-socket tests; Music
Apple Event identity/readback tests; and composite source/item ABA revocation tests.
Exercise expired queued commands, wrong peers, malformed/replayed revisions,
disconnect during permission requests, source replacement, and indeterminate reads.
Mutation oracles must reject removal of final command authorization and deadline
checks, not merely match source text. Verify the signed helper, exact native origin,
host Automation entitlement and old-bundle rollback compatibility independently.
Normal signed-host Automation consent and real native Chrome/Music operations remain
live integration gates; fake descriptors and VM DOM tests do not prove them. A real
installed extension is required only for claims about the optional extension path,
not for the native Apple Events path. Preserve the old signed bundle's rollback
verifier separately when changing the reviewed Automation usage description.

A physical release claim additionally requires the deployed host and intended iPhone
build: observe the system Lock Screen/Control Center metadata, change between two real
Mac media sources, and verify Play/Pause/Next/Previous affect only the active source.
Repeat while paused, through a connection recovery, and with local audio muted by its
privacy policy. A successful command acknowledgement or metadata dictionary alone does
not prove native iOS presentation or the Mac player's observable response. Keep this
physical evidence separate from compile, simulator, upload, and deployment results.

## Focused-window resize boundary

Exercise the actual controller against position-dependent size clamping and rejection,
including right-flush left expansion, partial room, negative display origins, all four
corners, mixed-axis directions, and application minimum/maximum constraints. Observe
actual intermediate and final mock window frames, bounded writes, opposite-corner
anchoring, and successor authority; accepting an unchanged frame is not resize success.
Independently remove prepositioning and the no-op rejection to prove those regressions
fail. Preserve exact editable/secure focus and existing stale-target/session tests.

Each forward and rollback write must recheck authorization, window eligibility, focus,
geometry, and the previously observed owned frame. Test failures between phases and
external frame drift after readback. Unknown readback or lost authority must not cause
blind rollback or replay. These deterministic fixtures model synchronous AX behavior;
they do not establish how a real application settles delayed Accessibility changes.
A physical resize claim still requires the matching installed host and a disposable
real window, with before/after AX bounds and pixels plus uninterrupted keyboard focus.

## Focused-window move boundary

Move requires a distinct advertised capability, mode-bound target generation and feedback.
Exercise an explicit safe selection, hold-and-drag originating outside the selected window,
exactly one commit, no normal click/scroll/primary-drag leakage, and pending/cancelled gestures.
Exercise the separately advertised Move and Resize scale-rebinding capabilities. A decoded-size
change must block input until the exact typed generation reaches Metal, then preserve the same
target generation only for exact integer aspect equality while the host capture transform is
unchanged. Move may preserve an idle selected target; Resize may also preserve its initial
non-mutating target request. Prove exact-aspect decoded rebinding succeeds without a host-geometry
update, while rounded aspect, any host capture/framebuffer transition, pending selection or commit,
and peers missing the matching mode capability remain fail-closed. Mutants that remove either
capability gate, use tolerant floating-point aspect matching, accept a changed host transform, or
retire safe state during the bounded client presentation gap must fail.
The production controller must write only position, preserve size and exact secure/editable
focus, observe actual readback, and issue a fresh successor. Legacy Move remains fully display
contained. Recoverable offscreen Move requires a separate advertised capability and an explicit
viewer commit opt-in; retain a visible top/title-bar band and horizontal grip, and return both a
legacy unit-contained visible intersection and the bounded full frame. Prove an already-recoverable
partial target can move inward, while Resize, an old viewer, and an old host keep strict containment.
Both Move feedback rectangles are normalized to the encoded frame. A capture-content inset beyond
the half-pixel framework-rounding allowance must suppress both until format renegotiation completes;
the wire does not carry enough transform metadata to interpret meaningful letterboxing safely.
Cover wrong-mode/stale target, changed frame/focus/geometry/permission, constrained or failed
position writes, and lost authorization. Accept same-size application-constrained readback only
when it progresses monotonically toward the requested origin without overshoot, opposite motion,
or untouched-axis drift and remains recoverable. Unknown state must not authorize blind rollback.
An outward drag already clamped at its negotiated edge is a no-op: perform no AX writes,
revalidate ownership and issue a fresh target so the next inward drag remains usable. Do not
confuse that with a setter ignoring a genuinely changed proposal, which must fail. Mutants that
remove the opt-in gate, reuse the clipped frame as the next preview origin, accept a lost grip/top
band, or relax generic normalized rectangles and Resize must fail.
Behavioral mutations must reject a forbidden size write and acceptance of stale authority.
Signed iOS lifecycle tests must retire selection/commit feedback across mode, scene, track,
frame, Show and input-session replacement without dismissing preserved keyboard focus.
These deterministic proofs are not a physical move claim: that still requires the matching
deployed host and iPhone build, a disposable real window, before/after bounds and pixels,
and uninterrupted typing.

## Screen startup quality boundary

Use the fail-closed contributor gate and invariant-to-test map in
`SCREEN_STARTUP_REGRESSION_GUARDRAILS.md`. A selected-but-skipped native fixture is not
evidence. Preserve assertion-failing negative mutations when changing these boundaries.

Cold Show spatial-first startup must keep the existing video/peer-wide ceilings and start at
most 5 fps while preserving full pixels through healthy intermediate promotions. Qualified
intermediate tiers may increase FPS within their ordinary approximate pixel-rate budget
(13 fps balanced, 28 fps high with a 60-fps source), never above configured source FPS.
Exercise stable 3/6/9 Mbps paths, unchanged caps, and missing/negative evidence after promotion. Only
fresh affirmative congestion or lifecycle replacement retires the exact-Show mode;
cached/missing reports and probe expiry must not manufacture a clear-to-blurry transition.
Keep the original native snapshot separate from cached diagnostic route enrichment. An absent
selected pair must not turn optional delegate-versus-native candidate metadata into a route
replacement. Copies must preserve native evidence and identity; the service must consume it.
A whole-pair telemetry gap may hold an already accepted discovery budget only under the
same Show/probe deadline. A later fresh fast ping must await ordinary requalification,
without renewing primary RTT/queue leases or increasing any cap. Preserve sender counters
only for queue deltas, not capacity. Malformed/partial data cannot acquire the gap marker;
real route/BWE/queue negatives and both the primary lease and absolute deadline still win.
For native delayed-network coverage, keep impairment per-fixture: require initial blackout
to prevent connection and post-start blackout to stop decoded frames after drain. A passing
healthy case must retain decoded fine detail and advance decoded FPS, not only set a parameter.
Retain only terminal same-Show disproof after a rejected native apply, never positive
geometry/FPS permission or successor ownership. Exercise real decoded fine-detail pixels
in fresh-process opt-in native loopbacks, including the actual adaptation reducer. Static
sender profiles alone do not prove that the live reducer preserves startup clarity.
The fixed-5-fps loopback does not prove full-FPS load, Internet congestion, or iPhone
presentation timing; these remain separate deployment/physical evidence boundaries.

Replay promotion-cap contraction and the recorded adverse queue, RTT, and bandwidth
samples independently. A temporary promotion ceiling must use fresh measured capacity,
never exceed the active probe/configured ceiling, expire without statistics, and be
revoked by stale ownership or genuine congestion. Mutants must reject removing this
continuity or substituting the doubled probe budget for measured capacity.

Parse native probe diagnostics from the actual pinned SDK, not only synthetic log
fixtures; retain only bounded numeric/enum events. Native callbacks are process-scoped
and must not acquire a current peer's identity merely because that peer drains them.
A cluster-created event or accepted sender parameter is not probe-feedback or frame
presentation evidence. Bind live timing to the installed host and one acknowledged
Show request, distinguish host-receipt timing from actual display timing, and retain
intermediate reversals. Full-resolution reports do not alone prove perceived clarity.

Retain native estimator send/receive intervals as checked signed microseconds or
explicit positive/negative infinity, never coerced zero or unbounded native text.
Exercise unit conversion, zero/negative values, the one-second boundary, overflow,
malformed inputs, and both collector-copy fields. An actual pinned-SDK callback
must preserve successful finite intervals in a fresh native process. Keep legacy
observer compatibility while accepting the complete new field pair; partial,
duplicate or unknown fields must fail closed. A missing-field-copy mutation must
fail the behavioral collector/native oracle. These process-scoped intervals explain
native feedback rejection; they do not identify a peer or prove receiver display time.

Mac native probing must not wait indefinitely for a large media packet when a
low-detail screencast produces only small RTP packets. Exercise the actual
production peer initializer in a fresh process, with continuous tiny frames,
unchanged encoded geometry and a bounded total-cap increase. Require native
feedback, advancing sender-scoped measured BWE, and receiver frame progress
before the original deadline; a created cluster or accepted cap is insufficient.
Removing the startup configuration must make the recovery oracle fail. A
factory field trial is process-wide configuration, not a per-Show permission;
never toggle it during capture or reconnect. Preserve PCM/device policy and
verify same-peer Show/Hide/Show with decoded-frame cessation after drain and
continued independent audio. Padding packets while hidden are not new screen
frames, and a configured probe target is not a hard instantaneous wire-rate cap.
Synthetic local recovery remains separate from installed-host and real-iPhone
clarity timing.

During active startup discovery, successively improving ordinary reports must expose
the best tier qualified by both reports, without treating the latest higher tier as
confirmed or ending discovery merely to show the intermediate picture. Native
qualification requires advancing report identity, measured low packet delay, healthy
RTT evidence, and 500–1500 ms separation. A fresh no-packet report may hold the original
witness only while its tier remains supported and its original lease is valid; it
must not increment the count or renew any timestamp. Missing/reset queue, invalid
identity, unsupported capacity, or unhealthy RTT breaks pending qualification.
Geometry changes reset queue permission, so fast growth waits for a new ordinary
low-queue measurement. Preserve the original probe origin, deadline, accepted budget
and bandwidth high-water mark across intermediate geometry. Silence or expiry removes
speculative capacity without erasing previously applied quality; fresh adverse
capacity must protect that quality's sustainable requirement in both statistics lanes.
Hide/Show and route boundaries retire pending and confirmed discovery state. Rejected
native application must never copy positive geometry confirmation. Exercise rising
capacity, plateau completion, no-packet cadence, expiry, adverse capacity, ownership
and failed-apply outcomes; mutations must reject disabled intermediate presentation,
selection of the better single-witness tier, and removal of freshness/lease guards.
This policy improvement does not establish recovery from invalid native feedback;
installed-host and real-iPhone startup timing remain separate requirements.

Selected ICE-pair RTT is cached between native ping responses. A new statistics request
or collection sequence is not a new RTT measurement. Consume a privacy-reduced pair
identity plus advancing cumulative total RTT/response counters once for RTT-only
pressure and baseline learning; piggyback acknowledgements may advance only the total.
Reject missing/malformed native metadata and reordered reports. Keep retained unhealthy
or expired evidence from authorizing upgrades, while preserving independent fresh
queue/bandwidth protection and clock-bounded probe expiry. Cover pair ABA/reset,
Hide/route/lane changes, legacy snapshot decoding, and both native snapshot-copy paths.
Mutants must fail when duplicate watermarks regain pressure, unknown RTT becomes healthy,
the sequence fence disappears, or either copy drops the observation. A provisional
initial reference must not add two native ping intervals to cold startup; document
that it has less initial outlier filtering than a three-distinct-measurement baseline.

Intermediate startup-capacity observations must use the same single-flight collector,
retain 500 ms quality/pressure windows, and leave the original probe deadline intact.
Require advancing native report identity and increasing measured BWE before raising
the bounded ceiling. A native UTC timestamp is identity, not an elapsed-time clock.
Cached requests cannot compound capacity or renew primary RTT/queue leases. Preserve
negative RTT identity across fast/ordinary lanes, including pair ABA and malformed
metadata followed by a repaired cached tuple. Neutral queue bursts and small bandwidth
declines withhold growth rather than becoming extra congestion samples. Keep a
cap-dependent feedback oracle for first-full timing, plus disabled-growth, cached-report,
deadline, cadence, and negative-invalidation mutants. Fence requests to their original
Show/capture before interpreting callbacks. Full host compilation and new installed-host
and iPhone evidence remain required; synthetic feedback timing is not a network prediction.

Probe-collapse thresholds must use calibrated codec demand, not the configured sender
ceiling. Exercise high and balanced origins at 50 Mbps in both ordinary and capacity-only
lanes, stable/rising estimates below the full probe ceiling, calibrated collapse boundaries,
and genuine 200 ms queue pressure. Independently restore the configured-ceiling comparison
in each lane and require its recovery tests to fail. Fast decision diagnostics must report
their own packet/delay delta, not the ordinary queue window; keep proposed budgets separate
from native apply results. Numeric/enum diagnostics must reject malformed values without
logging media, peer addresses, or raw connection identities, and must not change policy state.

Below-reserve floor recovery must require two advancing native ordinary reports with
measured low packet delay, healthy RTT, capacity at least the first witness's value,
and at least 500 ms separation
within a 1.5 s evidence lease. Fast/no-packet/cached reports must not supply admission
witnesses. Keep the visible floor unchanged while testing bounded capacity, use the
trial's seed-relative collapse threshold, preserve real congestion and the original
hard deadline, and consume at most one attempt per acknowledged Show. Reserve ownership
before asynchronous Show work and activate only for its exact successful capture/ACK;
failed or superseded native application cannot refund the allowance or transfer positive
health to another Show. Cover expiry, disproof, cooldown, stale identities, and seed
retirement. Independently disable admission, restore the ordinary collapse threshold,
and remove failed-apply attempt consumption; their behavioral regressions must fail.
Cold-first-Show fixtures must also admit a constant below-reserve estimate without
fabricated prior congestion or per-poll RTT advancement. An intervening estimate below
the first witness invalidates that pending window, including early/no-packet reports.
Equality permits initial bounded discovery only, never repeated capacity growth or
visible promotion. Retain exact-value trend and admission-reason diagnostics as
proposal evidence separate from native acceptance and client presentation.

### Post-congestion full-pixel recovery

`WorldwideScreenSpatialRecoveryTests`, `WorldwideScreenSpatialRecoveryPolicyTests` and
`WorldwideScreenSpatialRecoveryIntegrationTests` must preserve a separate exact-peer/Show
recovery after startup disproof. Survival-or-better capacity may qualify low-FPS full pixels
without reviving startup or raising bitrate ceilings. Require fresh post-adverse RTT,
advancing native identity, measured packet progress and two separated ordinary witnesses.
Admission queue delay is at most 20 ms. After native application only, actual advancing
full-source encoded frames may confirm geometry with delay at most 100 ms; this is not
capacity permission. Genuine pressure, route replacement and source-size changes still win.
Typed unchanged-frame/no-packet evidence must never manufacture a witness or renew its clock;
missing, malformed, reset and reordered counters cannot supply positive proof.

Keep the absolute 3-second trial deadline through native suspension and service-actor resume,
and preserve 15/30/60-second capped retry backoff with fresh qualification. Existing ordinary
capacity probes keep their independently authorized caps and original deadlines; the spatial
trial cannot create another probe. Recheck an earlier capacity-probe expiry before publishing
an otherwise valid spatial proposal. The deadline bounds accepted publication, not the
duration of an uninterruptible native call. `WorldwideScreenBoundedNativeApplicationTests`
must cover late application and unproven rollback. `WorldwideScreenNativeApplicationCacheTests`
must preserve successor state across suspended stale same-peer failures and still invalidate
current-owner failures. `WebRTCScreenVideoEncodingReplacementTests` must prove compound fallback
is conditional on the exact current native update. Service source-wiring checks supplement,
not replace, these behavioral boundaries.

Before or after geometry admission, an exact whole selected-pair gap in recovery-enabled
discovery may preserve an independently owned probe, never supply capacity or geometry evidence.
Bind this hold to peer, Show, recovery attempt, probe origin and original deadline, and
require the previous ordinary RTT lease plus independently observable sender counters.
Fresh fast health cannot renew that lease or grow the cap before ordinary requalification.
Malformed/partial/cached reports, expired leases/deadlines, real route/BWE/queue pressure
and lifecycle replacement must still reject or retire the hold. Startup disproof remains
terminal and separate. Exercise both ordinary and fast gap entry and their handoff,
including discovery while recovery is still observing and has not acquired geometry authority.

Run `scripts/validate-screen-startup.sh --scratch-path /absolute/dedicated/cache
--spatial-recovery-experiment` with the reviewed `DEVELOPER_DIR`. In three fresh-process rounds,
`WebRTCStartupClarityExperimentTests` compares recovery disabled/enabled on moving 8→0.8→8 Mbps
transport, then adds enabled second-drop and steady ample/weak controls. Enabled recovery must
first show actual degraded decoded pixels, then full 1080×1920 and all contrast scores >0.9
within 4 seconds of the actual restore. Require at least 2 seconds with eight changed-content
observations and no later blurry frame through the next actual drop or observation end.
Second pressure must cause appropriate degradation without capture blackout. Preserve source
submission bounds, phase-marker plus dense pixel-change evidence, relay integrity and the
original native exact-pixel/blackout oracles. Disabled recovery is characterization, not a
required recovery success. Never widen deadlines or ignore a later relapse to bless a candidate.
Mutation evidence must separately reject renewed deadlines, fake/neutral frame confirmation,
relaxed admission, inherited probe authority and stale cache/fallback ownership. The test map
and commands are requirements, not claims of a passing gate, release readiness or deployment.

### Isolated probe-duration comparison

The separate native-controller FIFO sweep compares 15/25/40/100 ms at 8 Mbps and
600 kbps with three fixed tail distortions. Its 24 passing cases and matching
baseline-preserving Configuration-group variant show controller sensitivity and
consumption, not real pacer transmission or a historical startup cause. The
duration-off and FIFO-bypass mutants fail the native-request/serialization guards
before transmitting the rejected cases. Do not call that overuse-detector coverage.

The separate 15 ms control / 40 ms candidate media pair must retain the original
50 ms delayed, dynamic-FPS, cursor-only workload, with SDK-default pacing, ALR hold
and probe skip in both arms. Exact fresh-process selectors and a distinct pinned
observer owner keep it default-off. `StartupVideoProbeDurationWitnessTests` requires
valid host/time/native-error evidence and the first two actual created requests:
IDs 1/2, rates 900000/905041, five probes, and byte minima 1688/1697 or 4500/4525.
Never search later matching requests or infer sent bytes from these minima.
Admission, loader and workload tests plus all eight witness methods are pinned in
the contributor gate. Preserve exact selector, byte comparison, accepted-duration
and native-evidence mutation oracles. Run the predeclared pair once, stop on failure
and retain its results separately from every previous RED and required native gate.
Even a passing initial pair is not pressure/recovery, physical or release acceptance.

The following moving-weak duration pair uses its own exact selectors and strict
800 kbps / 2 ms / twelve-second moving profile. Its independent validator tests
reject every Boolean and numeric workload substitution; admission tests reject
crossed duration arms, missing authority and borrowed cohort selectors. Keep
assertion-failing motion, capacity and selector mutations. The strict runner
requires both native-budget and capacity projections, actual sharp decoded
frames, final FPS >=4, at least twenty source submissions and the fixture's
existing continuity/blackout/native-lifetime assertions. A pass remains a weak
steady-link result, not recovered-motion, genuine-overuse or deployment proof.

The separate moving-recovery pair selects
`testNativeEstimatorALRProbeDuration15MovingRecoveryControl` and
`testNativeEstimatorALRProbeDuration40MovingRecoveryCandidate`. Both require
recovery in the same sixteen-second, dynamic-FPS moving workload: 8 → 0.8 → 8 Mbps
outbound / 8 Mbps return, 2 ms one-way, scheduled drop at 4 seconds and restore
at 8 seconds. Keep SDK-default pacing, factor 1, held ALR growth, probe skip,
zero warmup, no initial shaping, no second drop and both timing collectors.

Pin all three `StartupVideoProbeDurationMovingRecoveryProfileTests` methods:
`testBothDurationArmsAcceptOnlyTheFixedMovingRecoveryProfile`,
`testEveryBooleanProfileDriftIsRejectedIndependently` and
`testNumericAndOptionalProfileDriftIsRejectedIndependently`; also pin the three
`WebRTCStartupPacingAdmissionTests` methods
`testProbeDurationMovingRecoverySelectionsRequireMatchingArm`,
`testProbeDurationMovingRecoverySelectionsRejectLegacyAndMultipleSelections` and
`testProbeDurationMovingRecoverySelectionsRequireCompleteFlagsAndOwnCohort`.
Keep all seven class/method omission cases and require assertion failures from
selector, Boolean-profile and numeric-profile mutations, not compile failures.

Require actual degraded decoded pixels between applied drop and restore, then
full-pixel sharp recovery within four seconds of actual restore. Starting at the
first sharp frame—not a later convenient frame—the fixed two-second window must
contain eight genuine content changes, gaps at most 500 ms and a boundary frame
within 500 ms of its end, with no subsequent blur. Preserve native request-budget,
host/time/error, source/decoder continuity, blackout, receiver-drain and balanced
lifetime oracles. Missing degradation leaves recovery unexercised and cannot
qualify the pair; it is not by itself a product regression or permission to force
blur. This pair is separate from the ordinary native gate and the historical
second-drop test, and supplies no promotion or deployment proof on its own.

`testNativeEncoderBoundaryMovingRecoveryDiagnostic` is a separate test-only
control15 observation, not an additional ordinary native-gate method. Its own
default-off flag requires the exact selector, factor 1, estimator observer,
ALR hold+skip and no default-pacing cohort. Its profile delegates unchanged to the
moving-recovery workload and rejects every other duration. A fixed six-second
capture-relative trace records bounded encoder-boundary scalars without retaining
raw frames or encoded payloads; it does not change the sixteen-second workload.
Pin all eleven `StartupVideoEncoderBoundaryTraceTests`, three
`StartupVideoEncoderBoundaryProfileTests` and three encoder-diagnostic admission
methods, with seventeen independent missing-method scenarios. Preserve assertion
mutations for fixed-window admission, native return forwarding, callback generation
and exact selection. A structurally valid empty trace is not positive flow evidence:
require actual input/output events for such claims, and never infer decoder delivery
or sharp cadence from encoder completion. Existing actual-pixel, recovery-window,
blackout, receiver-drain and native-lifetime oracles remain independently required.

The process-owned native encoder log projection adds no frame or peer attribution.
Require its ten exact-format, width, window, overflow, clock, scope and retirement
tests, plus the four callback-rejection tests preserving original input identity
and old/current generations through release or invalidation. Their fourteen new
missing-method cases must remain fail-closed. The log allowlist retains only numeric
and enum payloads from the pinned H.264 source, distinguishing submission failures,
completion failures, drops and property outcomes. It stores at most 512 events,
with pre-arm configuration and a fixed six-second capture window; retirement must
not unregister the process-lifetime SDK sink or append late events. Native errors
do not invalidate structural collection, and structural validity/absent messages
do not prove positive encoder flow. Bound pre-arm metadata independently against
the first actual encode input before correlation. No raw SDK text, media buffers
or inferred per-frame identity may enter this projection. Preserve diagnostic 1's
RED outcome and all independent pixel/cadence/blackout/lifetime requirements.

## Execution and Claim Boundary

The opt-in native pacing bridge is an isolated debugging artifact, not a production
dependency. Require exact loaded-framework path/hash/UUID and bridge hash before
private access. Observe the actual new peer's GetConfiguration, require a contradictory
expectation to fail, and recheck ordinary configuration afterward. Admission tests reject
audio/viewer topology before factory work; lifecycle tests retain the rejected native
peer and observe it closed, then verify ordinary construction after success and failure.
Artifact mismatch must produce the identity error before dynamic loading. Deliberately
removing close/hash/readback checks must fail those receiving-boundary oracles. These
checks do not establish scheduling improvement, ABI compatibility with other artifacts,
duplex audio safety or release readiness. Failed actual-pixel trials cannot be replaced
by configuration readbacks or lower RTT alone.

Fixed pacing-factor trials must freeze the entire existing field-trial baseline before
the first factory in a fresh, exactly selected, audio-free process. Admission binds one
host and viewer to a TaskLocal token and never reopens after retirement. Require native
worker IDs independently read from those actual factories, post-binding/capture numeric
BWE-to-pacer pairs on the host worker, the complete unchanged ALR tuple, and received
rates matching the factor against the logged pre-pushback estimate. Configuration text
and process-scoped ALR logs alone do not prove consumption. Unknown worker identity,
contradictory factors, ambiguous timestamps/pairing, malformed data or overflow cannot
yield success. Mutation tests must reject audio admission, altered XCTest selection,
unknown host attribution and intent substituted for a numeric rate match. Each factor
trial still needs its own actual decoded-pixel oracle; safety gates and lower RTT do not
override a failed clarity run.

Native estimator observation is a separate control-factor diagnostic with both opt-ins,
one exact observer XCTest selection and a fresh audio-free process. The pinned bridge
must intercept the real host initializer, retain the ordinary controller delegate and
bind events to the actual host worker and environment. Construction without a controller
or events proves only construction. Hook tests must independently exercise synchronous
reentry and delayed TaskLocal child reuse after success and throw, reject wrong topology
before factory work, and preserve ordinary construction outside the scope. Keep the
observer owner alive through native close and verify balanced logger destruction after
the final callbacks.

`StartupVideoNativeEstimatorSnapshotTests` requires schema 2 and rejects schema 1,
JSON over 1 MiB,
more than 2048 events, missing or nonunit factory/controller counts, invalid lifetimes,
fields or sequence, wrong worker/environment, clock regression and native error counters.
Exactly two advancing post-capture delay events remain insufficient; require three, with
ties excluded from distinct proof. Validate pre-capture events but exclude them from the
witness. Unknown event payloads are counted and discarded; no raw SDK text is retained.
Report first post-capture delay overuse separately and do not require overuse to verify
observability. A loss-named update carrying cached Q8 fraction loss or a reset packet
accumulator does not prove absence of network loss or an independent loss-driven change.

The shared event sequence also accepts `probeCreated`, `probeSuccess`, `probeFailure`
and `alrState` under the same worker, clock and capacity checks. Creation/success require
positive Int32 bitrate and cluster ID; failure requires an ID and reason 0 through 2
with no bitrate. Only creation permits positive UInt32 minimum-probe and byte counts.
ALR requires Boolean `inAlr`, no bitrate and no other payload fields; every other kind
forbids that Boolean. Opposite fields and values outside these widths fail closed.
Probe/ALR counters never satisfy delay-event proof. A created request is not delivery
proof, repeated successes for one ID are distinct result observations rather than
distinct clusters, and matching results/requests are not required. Native ALR entry/exit
must be read from its event, not inferred from send rate. Retain pre-capture validation
without borrowing its events as post-capture evidence.

The source-bound `estimator-native-weak-1.log` diagnostic verifies 116 advancing delay
events, 40 post-capture loss-named events and 44 pacing matches. Delay overuse precedes
policy disproof, but the unchanged pixel/FPS oracle fails with seven blurred frames and
3.5 final fps. Clean native teardown is separate evidence: zero live loggers, one created,
one destroyed and zero lifetime failures. Thirty-three focused admission/hook/model
tests and 61 fake-runner scenarios pass at this checkpoint. Four separately compiled
mutants fail assertions for a two-sample witness, missing controller creation, wrong host
attribution and synchronous hook reuse; both changed source files are restored to their
exact prior hashes. The restored `startup-20260920-17612-rgewp4` gate passes 512
deterministic methods and both original native cases without skips; all 333 covered
source-file hashes remain unchanged. This does not replace the failed recovery matrix.
See `SPATIAL_RECOVERY_EXPERIMENT.md` for exact artifact identities
and timing. Neither temporal order nor this failed run establishes burst causality,
authorizes a weaker guard, or proves a deployed improvement.

The richer schema-2 cohort uses one unchanged source and bridge for three fixed controls
under `pacer-bridge.xjZwtL/PROBE_OBSERVATION_COHORT.md`. Native observation verifies in all
three, with zero unknown/invalid/dropped events or lifetime errors and clean balanced
teardown. Actual-pixel outcomes remain separate: run 1 passes with zero blurred frames
and 5 fps; run 2 fails with nine blurred frames and 3.5 fps; run 3 fails with twelve
blurred frames despite 4.5 fps. In both failed runs, delay overuse precedes the next
observed probe request and follows the preceding result by 3,878.838 and 2,809.285 ms.
This does not establish a periodic-probe burst cause or justify the proposed 60-second
ALR-interval trial. At that cohort checkpoint, 45 focused safety tests and 63 fake-runner
scenarios passed. The later receiving-model mutations for borrowed delay proof, missing
ALR membership and failure-event bitrate produced four, one and four assertion failures
and exact source restoration, as recorded in `ALR_GROWTH_HOLD_TRIAL.md`. They do not
constitute native-producer mutation coverage. Preserve every cohort outcome and earlier
failure; no production behavior, cap or guard was relaxed.

The bounded ALR-growth-hold candidate adds exactly
`WebRTC-DontIncreaseDelayBasedBweInAlr/Enabled/` to the DEBUG/macOS frozen control-factor
configuration. Require an estimator observer and its own exact, explicitly opted-in
fresh-process XCTest selection; neither ordinary pacing nor baseline observer methods
may lend their admission. A distinct retained native owner requires the exact flag at
actual controller creation, while the baseline owner requires it absent. Preserve SDK
delegation, environment identity, schema-2 clocks/host attribution, three advancing delay
samples and balanced logger lifetime. No live reconfiguration or native global setter
is allowed. Probe updates and genuine overuse decreases remain separate observations.

The initial `alr-growth-hold-native-weak-1.log` and `.log.result.json` record an unchanged
source-bound pass: first frame 356.919 ms, 49/49 sharp frames, zero blur, final 5 fps,
eight advancing delay events, verified pacing and balanced teardown. Source is
`79c337f9689fe1d6482ea0467172a74c71bcd7e72e4797c5c26ce9f837576f19`; bridge is
`7abb982c86cf24bced2bd0b65b1e9a6dd9eced114a928327d318e66d23cf5b3c`.
A 4,872.181-ms interval held sender BWE at 758,659 bps with 24 sharp changed frames,
20 encoded-frame increments, 244 packets and 287,025 forwarded relay bytes advancing;
probe 7 later raised the estimate while still in ALR. This is behavior consistent with
the hold, not direct native branch-hit proof. The absence of overuse means this run
does not prove the response to real pressure, broad recovery or a production fix.

Before matrix additions, 54 focused tests and 65 fake-runner scenarios passed. Two
additional admission mutants compiled: borrowed selection caused two assertion failures,
and missing observer admission caused three assertion failures plus one unexpected
error. The field-trial source was restored to its prior SHA-256 prefix `a98884cf`;
count only the assertion failures as mutation evidence. The hold's predeclared matrix
was three fresh-process rounds of disabled recovery, enabled recovery, second drop,
ample and weak, in that order. It is terminal and failed: 11 passes then round 3 enabled
recovery failed, completing 12/15 cases; round 3 second drop, ample and weak did not run.
All twelve receipts preserve source
`2dae8d4953d050cc62e82217b3cf90b780af4c7de87b74c9a401d3f2b3f783b4` and unchanged bridge
`7abb982c86cf24bced2bd0b65b1e9a6dd9eced114a928327d318e66d23cf5b3c`, with unchanged
source. Retain `alr-growth-hold-matrix-1.result.json` and every case log/receipt; no
partial-matrix pass, rerun-until-green or substitution of the initial pass is acceptable.

Rounds 1 and 2 recovered sharp pixels in 437.546/1,840.457 ms for enabled recovery and
389.990/2,304.937 ms for second drop, with no recovered-interval relapse and actual
second-drop degradation. Both ample controls were all sharp at 13 fps; both weak
controls were all sharp at 5 fps. Disabled cases passed characterization, not recovery.
Round 3 enabled recovery had nil actual shadow divergence and no recovered sharp frame,
ending at 1 fps despite verified current native estimator/pacing snapshots; nine
post-restoration 90×160 motion frames confirm delivery without detail recovery. Its throwing
recovered-frame assertion runs close in the catch but skips the relay-blackout check and
final native teardown snapshot/marker. No marker exists: neither balanced teardown nor
blackout proof may be borrowed from earlier cases or inferred from close execution.

The failed trace stalls at BWE 192,627 then 181,925 bps while floor total/video caps remain
486,001/99,360 bps; periodic requests are 198,720 bps, twice the video cap. Even twice
those BWE values or the requested probe rate cannot reach the total-cap recovery
qualification. Pinned `probe_controller.cc:552–561,597–600` limits requests to the lesser of the
maximum rate and twice total allocation, disabling further probing at that cap. The
matching measured requests support this mechanism as a source-backed inference, not a
logged native allocated-rate value. The observed stall rejects promotion, without
permission to weaken guards or raise ceilings. All processes are terminal; no further
trial or fix is claimed.

The separate ordinary gate `startup-20260920-33592-js07xn` passed 531 deterministic
methods and native case 1, but native case 2 failed one startup-detail assertion without
the hold flag selected: width 1080 fell to 134 at 1,152.93 ms, then 270, before recovering
to 1080 at 3,494.21 ms. Final 51.5 fps cannot erase intermediate blur. All 333 covered
files were independently rehashed with no changes, preserving gate source identity
`2e38959358038ee949b4ccb27f2d40e9a5ee2a927632526cc793d0c843e368d3`; its 65 fake-runner
scenarios passed separately. This is a failed full native gate and a release blocker,
not a restored-gate pass. The failed hold matrix is a separate blocker. Historical
green gates do not supersede this result; no deployment, commit or push was performed.

The subsequent probe-cap candidate adds only the exact
`WebRTC-Bwe-ProbingConfiguration/skip_if_est_larger_than_fraction_of_max:1.0,skip_max_allocated_scale:2.0/`
group to the held control observer configuration. Default-off admission requires its
original five exact `testNativeEstimatorALRProbeCap` matrix methods, plus the separate
`testNativeEstimatorALRProbeCapRecoveryCadenceDiagnostic` selection, both opt-ins, a fresh video-only
process and the distinct native owner. The receiver diagnostic is not a sixth matrix
case. Reject preexisting groups and borrowed hold-only
selections. Preserve all native evidence, pressure, reserve, cap, Show, deadline and
pixel/FPS assertions. SDK behavior is a strict comparison of `min(BWE, network upper)`
against `min(peer maximum, 2 * positive allocation)`; zero allocation uses peer maximum.
Equality and a low network upper estimate do not skip. A skipped `RequestProbe` still
consumes the five-second recovery-request cooldown. Configuration or absent events alone
cannot prove that the periodic ALR predicate executed.

`ALR_PROBE_CAP_TRIAL.md`, initial log/receipt
`alr-probe-cap-native-enabled-recovery-1.log`, matrix receipt
`alr-probe-cap-matrix-1.result.json` and corrected summary
`alr-probe-cap-matrix-1.summary-2.json` are retained in the same scratch directory.
Initial sharp recovery passed after 352.771 ms (first frame 341.715 ms), without the exact
earlier floor-cap opportunity. Initial and matrix receipts preserve unchanged source
`81dd4fcac0e66420bfea0b321558b6333f8bb5d2f6c2baec27d3eb7ea3fdfe65` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`.

The fixed matrix stopped after six passes and round 2 enabled-recovery failure: 7/15
completed, eight unrun. Its sole failed assertion was the pacing witness, whose reason
was `outOfOrderHostEvidence` with seven events. Actual pixels recovered after 2,924.163 ms,
with 66 changed observations, no recovered-interval relapse and final 12.5 fps. Native
estimator verification, blackout and balanced logger teardown completed. Record each
of those boundaries separately: pixel recovery does not excuse a failed native witness.
The matrix remains red and cannot be promoted, partially certified or retried until green;
its as-run witness failure and the independent ordinary-gate failure remain recorded.
All seven rejected events were native millisecond timestamp equalities, not decreases,
with strictly advancing callbacks; the SDK can publish changed pushback with unchanged
estimate in one millisecond. The corrected receiving model now checks sequential tied
pairs numerically and counts them only as `tiedPairs`, never additional independent
matches. It retains three distinct advancing native timestamps, strictly advancing
callbacks and all provenance guards. At that checkpoint no fresh full native matrix
with the corrected witness had run; the original matrix stays red. This failed case entered the exact floor but exited
by 8,588.312 ms before its nominal next periodic opportunity at 9,756.193 ms; the earlier
hold-only failure had that opportunity inside its floor interval. Neither this timing
confound nor the initial no-floor pass proves a live skip-branch hit.

Before the correction, 61 focused tests (20 admission, eight hook, four bridge, 29 model) and 67 fake-runner
scenarios passed. The candidate-selection and missing-hold Swift mutants each compiled
and produced five assertion failures, zero unexpected errors, followed by exact restoration
of field-trial SHA-256 `403c3b99228620133bec26853ee95cb8e288fea2b1c7c9b84a8ec68218d4b12b`.
The corrected checkpoint passed 82 focused tests (the prior 61 plus 21 pacing-witness
tests) and 69 fake scenarios in `alr-probe-cap-tied-witness-focused-1.log` and
`alr-probe-cap-tied-witness-gate-selftest-1.log`. Independent compiled strict-ms,
allowed-regression, counted-ties and duplicate-callback mutants produced respectively
9/3/4/8 assertion failures across 2/1/1/1 tests, all with zero unexpected errors. Their
`pacing-tied-witness-mutation-*-1.log` files and exact restored identities are retained:
witness `72b6bdd74b3bbc94537d00ff684342d2be730dda5a2c01a1fb51e03668b8f354`, tests
`17e486589bf1890bc630067bf98132fb7da2f8792617fcdfadd550e9f47ebdf5`.
This validates receiving behavior, not by itself a fresh native matrix, the ordinary
startup gate or execution of the periodic floor-trap predicate.
The separate actual-framework `ProbeCapControllerSmoke.mm` passed all seven predicate
cases; forcing configuration off compiled and failed its expected probe-count assertion
in case 2. Its unchanged framework identity is independently checked by the harness.
Source/binary/mutant identities are respectively
`bae0f689f971427f63fd4cfd6803ff960c1d5dcb4aa136936f3583f720ccb9ad`,
`0f8d144ec0169606c00c5f2861f0ceaffa91a5681077326e951dce78d771500e`, and
`6179fd48d2388150e86b7c89f3210c4411b39cae9e99f9e4fbc4e7f60cb701d1`.
Compile log 1's missing-field warnings-as-errors failure was corrected with a named
`ProcessInterval`; normal compile log 2 and mutant compile log 1 succeeded. Only the
runtime assertion failure is mutation evidence. These controller cases verify the common
predicate and equality/network-upper boundaries, not a periodic ALR episode, transport,
decoded pixels or preserved overuse behavior. No production rollout, commit or push is
claimed; all earlier red results remain release blockers.

The separately predeclared corrected-witness cohort is now terminal. Its initial
enabled-recovery trial passed with 3,080.764-ms sharp recovery and final 13 fps. Matrix 2
then passed seven cases and failed round 2 second drop: 8/15 completed, seven unrun.
`alr-probe-cap-matrix-2.result.json` remains authoritative; the new
`alr-probe-cap-matrix-2.summary-1.json` is only its descriptive derived projection.
Initial and completed matrix receipts preserve unchanged source
`edcaba4212ee66e20821c044a5088c63fb1709e8028e29f22908356c273ad3ce` and bridge
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`.

The failed second-drop case first recovered sharp pixels at 8,785.787 ms, 719.290 ms
after actual restoration. The next sharp frame at 9,691.261 ms left a 905.473-ms gap,
violating the 500-ms sustained-cadence limit. The fixed first-sharp two-second window
held eight sharp frames but only seven changed transitions, below the required eight;
its timely boundary does not cure either defect. All 56 recovered frames remained
sharp with 55 changes overall and final 5 fps, but a later healthy span cannot replace
the first window. Source submissions around the gap continued at roughly 200 ms;
individual-frame pipeline attribution remains unavailable in this projection.

Because the same fixed-window predicate never qualified, no actual second capacity
drop occurred. The sustained assertion failed and the absent second-drop unwrap threw.
Active native estimator/pacing witnesses verified (27 advancing delay events, 55
independent pacing matches, 24 tied pairs), but the throw bypassed relay blackout and
the final post-close logger snapshot/marker. Catch-path close is not balanced-teardown
proof. The first seven cases' successful later checks cannot be borrowed by this case.

Round 1 enabled recovery did provide the requested timing opportunity: ALR true and
the exact 486,001/99,360-bps floor still present at 7,580.047 and 8,081.763 ms, after
the preceding probe's nominal 7,525.961-ms periodic deadline, with advancing traffic.
That is not direct internal allocation/network-upper/controller-state or branch-hit
proof. Preserve that useful observation, the failed cadence contract, every previous
red receipt and the independently red ordinary gate. No passed-matrix, promotion,
deployment or relaxed-oracle claim follows. See the corrected cohort plan and
`SPATIAL_RECOVERY_EXPERIMENT.md` for the complete fixed-case accounting.

The later actual-framework periodic oracle is separate from those media receipts.
`ProbeCapPeriodicALRFeedbackSmoke.mm` exercises the real GoogCC controller, actual
ALR detector and periodic process path, not a copied skip predicate. Keep immutable
paired hold-only/hold-plus-skip trials, peer 486,001 bps, reserve 320,000 bps and
allocation 166,001 → 99,360 → 166,001. Genuinely submitted synthetic ordinary packets
receive fixed send+25-ms receipts and send+50-ms feedback, with no forced BWE/RTT or
fabricated probe results. Both cases enter ALR at 425 ms with native BWE 308,030 bps.
At 5,425 ms hold-only requests 198,720 bps and candidate requests none; at 5,450 ms
the restored allocation permits a useful 332,002-bps candidate request. Both complete
104 sent/received/feedback records and balanced logger lifetimes. A separately compiled
config-off mutant fails the candidate's exact periodic probe-count assertion while
the control passes and native ALR/feedback are present. The normal source and binary
remain unchanged. Preserve the first no-feedback revision's failed estimate assertion;
it was rejected before periodic eligibility, not silently made green.
`PERIODIC_ALR_FEEDBACK_ORACLE.md` pins all source/binary/log identities and the bounded
20-second wall/10-second CPU execution. This verifies requests, not probe delivery,
feedback-induced floor collapse, real overuse, media or product health. The original
seven-case actual-controller harness still supplies equality/network-upper coverage.

Keep SDK-default production pacing (40 ms with no configuration override) separate
from the diagnostic 20-ms hold/skip media and periodic fixtures. The observer-only
`baseline-estimator-native-delayed-1.log` uses the original delayed dynamic fixture
without a capacity experiment and passes sharp pixels, 51 fps, 24 advancing native
delay events, 15 pacing pairs, blackout and balanced teardown. Its unchanged source
is `62abc9b00a2b56041b192655da5cf91ae45d09c0d571848c5e5dc6892268109e`; bridge remains
`91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`.
Its first two ordinary estimates of 888,571 bps do not reproduce the red ordinary
gate's 656,555-bps startup. The explicit control trial is configuration-equivalent
to SDK defaults, not timing-equivalent or byte-identical. This diagnostic pass, and
its preceding 83 focused tests/70 fake scenarios, do not certify the ordinary gate.

Receiver cadence diagnostics must retain bounded video-only inbound counters and
monotonic request/completion clocks, without adding timers, blocking host sampling or
feeding policy. Reject malformed values, outbound attribution, saturation and late
retired completions; do not coerce missing values to zero. Preserve the original
renderer received-time and pixel oracle while separately recording callback entry,
conversion duration and RTP timestamp. Aggregate receive/decode progression is not a
per-frame encoder/packet/display join. The single separately selected
`recovery-cadence-native-1.log` passed under source
`cda852c92d3209ce2ea9cad6e97ed1e112e51901be5b99eee06fe97295e11de5` and the same bridge:
436.596-ms sharp recovery from the conservative restore-start boundary,
11 sharp first-window frames/10 changes, 303.742-ms maximum
recovered gap, actual second-drop degradation, final 5 fps, 39 retained receiver
records and verified native/blackout/balanced-teardown evidence. It did not reproduce
the old 905.473-ms gap; added collection can perturb timing. This is a passing
collection diagnostic, not a media fix or a new matrix case. The preceding 126 focused
tests/72 fake scenarios, compiled receiver mutants with 1/8/3/4 assertion failures
and restored 27-test pass are separately pinned in `RECOVERY_CADENCE_DIAGNOSTIC.md`.
Every earlier red receipt and every unrun matrix case keeps its original status.

The separately declared SDK-default-selection cohort compares seven exact cases in
each of three rounds: paired original delayed control/candidate, weak, disabled
recovery, enabled recovery, second drop and ample. It leaves the burst override
absent and preserves the exact ALR candidate groups and all product guards. Moving
cases add receiver collection with retire/drain before final viewer statistics;
they are not a timing-identical comparison to the old 20-ms recordings. Native
default-selection and numeric factor/estimator verification are not consumed-40-ms
proof. The 40-ms value is source-derived and all 20 completed receipts explicitly
record `runtime_window_readback: false`.

`default-pacing-cohort-1.result.json` is terminal RED: 19 passes, then round 3
second-drop failure, leaving round 3 ample unrun (20/21 complete). All receipts
preserve source `c029f1720d7fcde07e60514309707418d99a072264169c20621719a59a5d778c` and
bridge `91c9c4c698f3859bebb09c280f89e6043481efbe76d25c6da9fe259a0f50bb47`; no timeout
or retry occurred. All delayed controls/candidates passed without reproducing old
startup blur. The failed case recovered sharp pixels in conservative 377.358 ms,
passed sustained cadence, and actually began its second drop at 14,005.081 ms.
All 30 later decoded frames remained full size through 19,889.630 ms, failing the
unchanged second-pressure degradation assertion. This is not the prior 905-ms
first-window failure. Active estimator/pacing, receiver collection, blackout and
balanced teardown verified independently; they cannot waive that assertion or
identify the cause of the missing spatial decrease.
Native overuse reduced BWE to 482,502 bps then returned to normal with low adjacent
ordinary queue/RTT samples. This does not establish sustained overload or a policy
defect requiring forced blur. Preserve the RED receipt while distinguishing the
second-pressure contract through bounded replay and independent evidence.

Before the cohort, the contributor gate passed 563 required deterministic methods
and the fake runner passed 75 scenarios. Separately compiled final-drain,
default-admission, default-profile and delayed-workload mutants failed 1/8/2/2
assertions, with zero unexpected errors; exact restoration passed 53 focused tests.
`RECEIVER_MUTATION_EVIDENCE.md` distinguishes gate-manifest identity from the runner's
different path-set hash. `DEFAULT_PACING_ALR_PROBE_CAP_COHORT.md` records case values
and receipt/log hashes. Preserve this RED and every historical RED. None proves
runtime 40-ms consumption, default-on flags, a product fix, promotion or deployment.

Subsequent deterministic second-pressure replays pass for transient retention,
persistent post-expiry downgrade and independent fresh-pressure retirement. Their
46/3/6/11-assertion mutants are restored; gate `startup-20260920-97276-10o8s41` passes
566 required methods and the fake runner passes 78 scenarios. The native RED is
not amended by those policy-only witnesses. Scratch `SECOND_PRESSURE_REPLAY_EVIDENCE.md`
records source identities and the limits of the synthetic cumulative counters.

Scratch `PROBE_DURATION_FEEDBACK_ORACLE.md` records four actual-framework cases:
15/100-ms common duration, each with zero or 4,055-us final-arrival extension.
Native probe success, normal delay estimate and returned target agree at
905,038/905,038/656,554/869,165 bps. All records and logger lifetimes balance; a
duration-off mutant fails both long cases. Traffic rises from 1,729 to 11,362 bytes.
This proves first-delivered-probe susceptibility only. It does not establish the
cause of a historical startup sample, actual pacer consumption, full two-cluster
startup, a startup-only flag, real congestion behavior or a deployable fix.

- `swift test` covers the deterministic protocol, security, transport waveform, mutation, Mac
  artifact, and validation-driver contracts.
- A **signed** Simulator `xcodebuild test` run covers iOS lifecycle, Keychain, accessibility
  serialization, native PCM publication, and evaluator mutations. An unsigned run is not a
  substitute because it cannot exercise the production Keychain access group.
- A generic-device UI `build-for-testing` proves the physical test source compiles; it does not
  execute a physical oracle.
- Injected CallKit tests prove fail-closed microphone policy, explicit hosted-origin ownership,
  and asynchronous race fencing, not that a real device reports every transition. A signed
  physical-device pass must cold-launch during a real connected iPhone call, prove
  `origin=startup-connected-call`, keep microphone input closed while fresh decoded/native playout
  evidence advances, replace that ownership with `origin=interruption` after a genuine interruption,
  begin that interruption-origin window only after interruption-ended supplies a resume hint, then
  end the final call and require a fresh ordinary audio-policy generation plus new advancing
  render evidence before claiming recovery.
- The production-bundle physical driver binds evidence to a fresh artifact directory, physical
  device identity, installed bundle/build number, signed Mac host, changing host PIDs, session
  identity, and current `.xcresult`. `devicectl` cannot independently prove that the installed
  bytes arrived through TestFlight, so App Store Connect/TestFlight remains the authority for that
  distribution fact.
- The driver binds every retained attachment's name and metadata to its exact XCTActivity. Current
  `xcresulttool` activity JSON does not expose attachment bytes, so attachment contents are
  supplemental audit material; the executing XCTest assertions and pass/fail result—not the
  attachment name—remain the release oracle.
- The waveform gate uses the production Opus/WebRTC path at its 48 kHz stereo target format. It
  does not by itself prove ScreenCaptureKit's source-format conversion; those conversion cases are
  covered separately.
- A newly instrumented physical claim is release-complete only after the matching app build runs
  the non-skipping physical gate and produces a fresh passing result. Build-only evidence, an older
  TestFlight build, a screenshot, or a prior manual pass must not be reported as that result.
