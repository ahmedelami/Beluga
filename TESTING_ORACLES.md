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
| Screen Show/Hide | The lifecycle driver retains its decoded-frame, decoded-pixel, Hide acknowledgement, and audio-continuity gates. A separate guarded visual driver pins the exact production iPhone 17 Pro (CoreDevice `7694F11E-D66D-5632-9A0D-462C980130A5`, hardware UDID `00008150-0002581C3E3A401C`) and installed production-bundle build, prepares and seals its signed test products while the phone may remain locked, then arms one observer for the next natural interval in which the already-authenticated viewer has its screen visible. It refuses to unlock, launch, activate, background, tap, hide, replace, or disconnect that production app/session. It continuously listens for all three Mac default-audio selectors, treats even a transient notification as a sticky violation, retains point-in-time UID readbacks, and draws four ordered high-contrast symbols whose 12-bit spatial payload is bound to a fresh 128-bit run nonce. Its UI test aspect-fits the decoded video inside `worldwideMacScreenVideo`, crops that region from repeated final-composite iPhone screenshots for the full observation interval, requires a complete cycle plus a fifth ordered run while the exact Show acknowledgement and renderer remain unchanged, bounds undecodable gaps and same-symbol hold time, and requires fresh final evidence before passing. CoreDevice metadata must report the exact `iPhone 17 Pro` marketing name at every checkpoint, and the `.xcresult` must bind its sole passing configuration to that hardware UDID and model. Device metadata does not prove TestFlight receipt provenance; that remains a separate App Store Connect fact. | Create or replace the viewer, change production-app lifecycle/UI, mutate a default audio route even if it later restores, acknowledge Show without advancing decoded frames, reuse a stale acknowledgement/renderer, report healthy counters under a black or obscured final surface, show unrelated vivid animation, replay a prior run's symbols, freeze after one complete cycle, skip/reverse a symbol, begin clear and remain black, sample letterboxing instead of the decoded content, use the wrong orientation/crop/build/device, mutate the sealed test products, or replace the installed production app during test setup. |

The lifecycle Screen gate still checks decoded pixel changes and a small final-composite screenshot
region under its changing challenge. The dedicated observe-only screen source closes that gate's source-
identity ambiguity with a fresh nonce-derived spatial sequence and observes long enough to reject
the reported clear-then-black failure. Its source, unit mutations, build, or an older screenshot are
not release proof: the intended installed production-bundle build must run the non-skipping physical test
and produce a fresh passing result. `arm-testflight-screen-visual-oracle.sh` performs compilation,
signing, product sealing, and identity checks while the phone may remain locked, then leaves exactly
one local observer waiting for up to a week. It automatically uses the next natural foreground Mac-
screen interval and rearms if that interval closes before device/session binding, so the user does not
need to hold the phone open while preparation or polling occurs. One uninterrupted foreground interval
is still logically required for the changing final-composite screenshot sequence; the observer will not
unlock or perturb iPhone microphone/audio ownership or production-app lifecycle merely to create that
fixture, and it leaves that screen presentation in place. Sampled screenshots do not prove every
intervening frame or host
capture-process quiescence after Hide. The current remote-input check proves only that a fresh
authenticated capability is present; it does **not** yet drive a disposable Mac target and observe
real AX/model mutations. Those claims remain release-incomplete and must not be inferred from
acknowledgements or screenshots.

Both runners stage a candidate summary privately, atomically commit the terminal run status first,
and only then publish a `passed` summary and success line. Failure of that final status commit instead
publishes only failed evidence; an uncommitted staged file is never release proof.

Both physical screen runners now require an external release seal for the Mac host before they can
start the visual challenge. Set `OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST` to a canonical,
owner-owned mode-0600 manifest,
`OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH` to its exact adjacent committed
mode-0600 one-link `.sha256` sidecar, and
`OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256` to the independently transported SHA-256
of those exact manifest bytes. The production armer forwards all three values through the environment;
none is placed in the runner command line. The manifest schema is
`opensteamer.sealed-live-mac-host-identity.v1` and contains exactly the installed executable path,
SHA-256, CDHash, signing identifier, and TeamIdentifier plus the corresponding path, SHA-256,
CDHash, signing identifier, and TeamIdentifier for the LiveKitWebRTC executable. The verifier first
runs the reviewed installed-bundle verifier, then binds the launchd PID's executable vnode and
dynamic signature to those sealed bytes and binds its loaded LiveKitWebRTC vnode to the sealed
framework bytes. Both runners retain that exact snapshot immediately before challenge launch and
require a byte-identical snapshot after the physical observation. The development runner establishes
the same sealed baseline before its first secondary-manager probe and re-verifies it immediately
around every probe, invitation mint, and exact-generation stop, including finalizer cleanup.

The production V90 packaging hook is
`macOS/scripts/prepare-v90-sealed-host-oracle-handoff.sh prepare`. It accepts only an owner-owned,
mode-0600, one-link metadata file in a fresh owner-owned mode-0700 V90 capsule plus that metadata's
independently retained lowercase SHA-256. That capsule must be outside the user-protected
`~/Library/Application Support/opensteamer` runtime/evidence root. The exact
`opensteamer.v90-host-oracle-capsule-metadata.v1` fields are `schema`,
`candidateAppRelativePath`, `candidateExecutableSHA256`,
`candidateMediaFrameworkExecutableSHA256`,
`designatedRequirementReferenceRelativePath`, and
`designatedRequirementReferenceSHA256`. Both relative paths must resolve canonically inside that
new capsule. The reference must be a separate owner-owned, xattr-free, mode-0755, one-link code
object whose digest came from the approved pinned predecessor metadata; the capsule builder must
never fill that digest by hashing the V90 candidate, reading either installed `/Applications`
bundle, or reopening any retained/consumed migration or update capsule. The candidate and reference
digests must differ. If a separately authorized capsule assembler cannot supply those already
reviewed inputs, preparation stops instead of borrowing historical live or retained state.

The approved predecessor input is the preserved-input V86 re-sign whose executable SHA-256 is
`553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66`. Before copying it, the
assembler requires that executable to remain at `Contents/MacOS/CaptureServer` inside its complete
canonical app and verifies both the code object and the full app with strict resource validation.
It then fingerprints the original and independent capsule copy by exact size (`11442304`),
`LC_CODE_SIGNATURE` extent (`dataoff=11401072`, `datasize=41232`), unsigned-prefix SHA-256
`a7885a8d1ffef70f5a747eaed984a6cb70fe382491fcc6fbf8505aa0ad47ff5b`, CDHash
`e41c23322912104a648e791bfb0d3a5714323b26`, full CodeDirectory SHA-256
`e41c23322912104a648e791bfb0d3a5714323b26b1b299ae5f0cfa225f68aba0`, TeamIdentifier
`MSMG8CJLB3`, identifier `com.elamin.AudioStreamer.CaptureServer`, and designated requirement
`identifier "com.elamin.AudioStreamer.CaptureServer" and anchor apple generic and certificate
leaf[subject.CN] = "Apple Development: Ahmed Elamin (92LVX32M8K)" and certificate
1[field.1.2.840.113635.100.6.2.1] /* exists */`. The standalone copy is code-identity
evidence, not full-bundle resource proof: the controller replays those compiled byte, Mach-O,
CodeDirectory, identity, and requirement pins without pretending the separated executable still
contains its original Info.plist or sealed resources.

Preparation creates the fixed, previously absent `v90-screen-oracle-handoff` directory once, calls
`create-sealed-mac-host-identity-manifest.sh` with the metadata-pinned reference digest, and verifies
that the generated manifest describes the exact metadata-pinned candidate and fixed production team
`MSMG8CJLB3`. The generator publishes `sealed-live-mac-host-identity.json` followed by
`sealed-live-mac-host-identity.json.sha256`; the wrapper then publishes
`v90-screen-oracle-host-identity-handoff.json` followed by its own `.sha256` overall commit marker.
The handoff schema records the trusted metadata digest, both candidate digests, the designated-
reference digest, fixed team, and fixed manifest basenames. Any missing sidecar is an uncommitted
capsule, and a failed output directory is never reused. Carry the complete four-file handoff
directory plus the independently retained handoff SHA-256 into the post-deploy step.

Only after a separately authorized deployment may
`prepare-v90-sealed-host-oracle-handoff.sh arm <handoff> <external-handoff-sha256> <coredevice-id>
<hardware-udid> <build>` consume it. `arm` revalidates both commit markers, both JSON field sets,
the fixed team, and the candidate hashes, then supplies only the committed manifest path, sidecar
path, and external digest through the existing production armer environment contract. Until that
complete candidate-specific handoff exists, both physical runners intentionally fail before
challenge launch. The artifacts
contain identity metadata only; invitations, rendezvous capabilities, unlock material, and other
secrets remain out of arguments, logs, and the manifests.

### V90 sealed build, cutover, and physical promotion sequence

The immutable V90 release source (commit A) is commit
`92d08a1c434eefef40901333f6d924dc8851a162`, tree
`00ace7a5f69afffdbe7abfdc5c27b1708ab0908c`. It is exported and built only from a
separate clean checkout at that exact identity. The assembler and cutover tooling belong to a
later reviewed tooling identity (commit B): its local HEAD, upstream, and fresh single-record
remote branch readback must agree, its running tracked blobs must equal commit B, and commit A
must be its ancestor. Commit A identifies the product source bytes; commit B identifies the
mechanism that assembled them. Deployment may use a later reviewed descendant of B;
it records its own current commit, tree, and tracked observer blobs. The build's
historical commit/tree/assembler blob must remain exact and ancestral, but need not
equal the deployment-tool commit. Neither identity substitutes for the other.

`macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh` is offline with respect to the
installed host and every running service. It accepts only nonoverlapping clean source/tooling
locations, a fresh private capsule root, and an independent predecessor-reference code object
whose externally supplied SHA-256 equals the explicitly approved compiled pin. A malformed
compiled pin or digest mismatch fails before capsule construction; deployment authorization alone
does not approve a byte- or CDHash-different predecessor reconstruction. The assembler exports
commit A, builds and signs the candidate, copies the exact source launch plist, removes build
scratch, and commits strong source/candidate manifests, a copy-stable candidate manifest, the
host-identity handoff, and
`v90-deployment-payload-manifest.json` plus its sidecar. Payload schema
`opensteamer.v90-deployment-payload-manifest.v2` records all nine additional predecessor fingerprint
fields so the controller can require the capsule record, compiled pins, copied bytes, and copied
signature metadata to agree. Capsule assembly is sealed build evidence, not deployment evidence.

Live use goes only through `macOS/scripts/run-opensteamer-host-v90-cutover.sh` and
`macOS/scripts/opensteamer-host-v90-cutover-controller.rb` with the sealed capsule and independently
retained handoff and payload digests. The launcher re-proves clean remote tooling and pinned
controller, route-monitor, Ruby, Swift compiler, and SDK identities. Preflight performs two
mutation-free observations; execution replays the full capsule and live V86 fences immediately
before durable `STOP_INTENT`. The controller holds same-filesystem exact-V86 app/plist rollback
copies, keeps the sticky CoreAudio monitor armed with zero notifications, and requires at least
31 monotonic elapsed seconds of stable V90 PID, generation, bytes, display, session, routes, and
secondary-viewer readiness. Full samples run once per second when fast; slow samples count toward
elapsed time, and the window ends only after a complete successful sample reaches its deadline.
The full final pre-irreversible safety replay remains mandatory. Any
failure after `STOP_INTENT` but before durable `V90_COMMIT_IRREVERSIBLE` must traverse the journaled
rollback to terminal `ROLLED_BACK_EXACT_V86`. The sticky monitor remains live through that point of
no return. A later failure must leave V90 live, publish committed-but-unverified evidence, exit
nonzero, and never attempt an unmonitored rollback. Only clean zero-notification monitor teardown,
the post-commit safety proof, final route readback, and terminal `COMMITTED_V90` form a successful
host-deployment result; neither an intermediate state nor a pending result/pointer is such a claim.

The signed capsule is a reusable artifact, not a deployment-attempt identifier. Each
execution allocates a new private transaction and captures the verified predecessor's
PID/start/nonce, lock identity, and app/plist identities. Any change before stop fails
the attempt. Rollback restores those exact held filesystem objects and proves the new
process generation against the same trusted predecessor bytes. Completed rollback
transactions and their failed archives remain immutable history; a durable terminal
receipt permits a subsequent fresh attempt with the same artifact. Missing or corrupt
receipts, unfinished transactions, active pointers, and unknown staging residue block
automatic retry. Existing pre-receipt history is admitted only by its reviewed legacy
baseline. The controller never deletes history to make a retry pass.

Offline regression coverage must exercise two completed rollback attempts with the
same artifact, acceptance of a fresh verified predecessor generation, rejection of
within-attempt identity drift, and rejection of incomplete or altered history. The
readiness observer must be bound to current deployment tooling, not the capsule's old
source export. These are tooling proofs, not installed-host or final-pixel proof.
Readiness failures retain the client exit status, a possible signal number, and a
bounded allowlisted error classification; they must not collapse every rejection
into a timeout or print arbitrary client output. The exact sealed client can be
exercised against an isolated local control-server fixture before another cutover.
That fixture must bind a real socket inside a fresh private directory under
`/private/tmp`, not merely put its output there. Foundation's `standardizedFileURL`
can rewrite an existing `/private/tmp/...` path to `/tmp/...` while leaving the
same nonexistent path unchanged. Path syntax validation must not depend on whether
the socket, invitation, or cleanup receipt already exists. Preserve the separate
owner/mode, no-follow, descriptor, inode, and parent-symlink checks; accepting a
valid spelling is not permission to trust the object at that path. Require the
exact signed candidate to pass this isolated socket fixture before switching the
installed host, so this class of client-side rejection is caught offline.

After a terminal `COMMITTED_V90` host result and fresh sealed-host readback, run
`validate-iphone15-dev-screen-visual-oracle.sh` on the paired iPhone 15. That pass is development
diagnosis only. Only after it passes may the production iOS candidate proceed through the
separately evidenced TestFlight build/upload, App Store Connect availability, and exact-build
installation steps. Release completion then requires a fresh non-skipping
`validate-testflight-screen-visual-oracle.sh` pass on the pinned personal iPhone 17 Pro, with the
nonce-bound final pixels, sole XCTest pass, unchanged app/build/host/peer/screen-session identities,
and clean zero-notification route-monitor teardown. Source tests, capsule sealing, host cutover,
iPhone 15 diagnosis, TestFlight availability, installation, and the iPhone 17 Pro physical result
are distinct evidence boundaries; no earlier stage implies a later one.

Development diagnosis uses the separately signed `org.example.AudioStreamer.dev` bundle on the
paired iPhone 15; it never operates the personal production iPhone. The guarded development runner
also admits a never-connected primary only when the complete current-generation
startup/waiting/online boundary, exact PID/nonce, secondary-manager idle proof, and
absence of subsequent primary activity agree. This branch records no primary
session, build, audio, or microphone proof; the existing no-reactivation and exact
secondary-session cleanup fences still apply. A fresh host therefore does not need
the personal phone connected merely to enable development validation. The runner
builds the current checkout with a generic-iOS `build-for-testing`, performs at most one bounded
Xcode-owned clean/rebuild for an invalid incremental runner signature, and seals those products
before it needs the phone. It then publishes a private, 30-minute, run-nonce-bound unlock request and
parks while refreshing an owner-only status heartbeat. The exact-device unlocked-state
acknowledgement helper binds the runner's process-start identity, verifies that its exact run lock is
still held, observes the pinned iPhone 15 unlocked, verifies that no matching credential-holding
controller is currently running, and rejects a stale or replaced request and a competing writer. It
does not attest screenshot history or prove that an unlock controller previously ran and exited. A
local heartbeat/agent must still use the
`iphone-usb-unlock` workflow against the exact saved-code
Keychain account: inspect fresh before/after screenshots, make at most one complete entry, prove the
phone unlocked, send `exit` to the credential-holding controller, and only then run
`ack-iphone15-dev-screen-visual-oracle-unlock.sh`. The acknowledgement contains no credential and is
only a wake signal; the runner independently rechecks the exact CoreDevice identity, hardware UDID,
and unlocked state and has no manual-success or skip switch. Offline acknowledgement tests execute
the actual helper serializer and runner validator together, including exact keys, identity, digest,
request mutation, and observation-age rejection; matching source strings are not a handoff proof.
During the live step a separate
credential-free exact-UDID `PreventUserIdleSystemSleep` lease emits a private heartbeat. Its Python
runtime is launched with `-I -S -B` and an empty environment, before any virtualenv `site` or `.pth`
startup hook can execute. It pins the exact interpreter and a deterministic digest of every
non-cache file in the complete third-party runtime, rejects symlinked runtime paths, installs a
source/native-extension-only loader so excluded bytecode cannot execute, and re-hashes after import.
It then uses an existing-pairing-only native tunnel path that never issues a pairing command. Each
renewal acquires a replacement lease on a fresh assertion-service connection before closing the old
connection: the physical device resets a second create command on a reused connection. Behavioral
tests must model that one-command connection and exercise multiple renewals and failure cleanup.
Tunnel, service, and lease acquisition are bounded. The runner supervises the background `xcodebuild`
process against that heartbeat and terminates/reaps it before trap cleanup if the lease fails. The
lease stays owned through nonce-bound device secret cleanup (including trap cleanup), explicitly
closes its remaining service and tunnel after cleanup proof, and the runner waits out the final device
lease's at-most-45-second residual because the assertion protocol has no release acknowledgement.
Thus the unlock controller itself is never retained as a keepalive. The runner
mints a one-use secondary invitation only after rechecking the installed `.dev` build, host
generation, primary peer/screen lifecycle, and Mac default routes. A fresh owner-only status probe
must bind the same host PID/generation to an idle secondary manager before baseline and again after
the final continuity interval without advancing its generation. One final peer/screen-lifecycle
fence follows that probe immediately before mint. The minted receipt must be the single successor
of that baseline generation; after exact stop, a third idle probe must equal the receipt generation.

The development runner has two explicit primary baselines. In `activePrimary`, primary audio must
provide a fresh `renderingNonzero` checkpoint with bounded native/inbound evidence age and sequential
counter progress at each fresh, non-overlapping before/mint/after window. Primary microphone
forwarding may either stay healthy and advance, or begin with at least two consecutive exact
app-inactive `sourceMediaStalled` all-zero samples and remain in that same phase and zero-state.
Both modes require the forwarding snapshot's privacy-safe monitor, device, peer,
transport-authorization, and track generations to match its last attempted key, plus a nonzero
attempt generation that stays unchanged. An older host that does not emit the complete key fails
closed. Every new forwarding sample must advance its media-sample sequence, and any partial
writer/decoder state, mode transition, identity change, or new hidden-writer selection fails closed.
Intermediate audio counters are accepted only as decimal unsigned integers before arithmetic, so a
log value cannot be interpreted as a shell expression. Stale top-level audio status cannot borrow
otherwise healthy-looking retained fields.

In development-only `inactivePrimary`, the personal production iPhone may remain asleep. The runner
requires the ordered terminal primary lifecycle `viewer disconnected` -> exact expected-build
`unavailable.stopped` with `appActive=false` -> `media ended`, then proves the live secondary manager
is idle. It labels this `inactivePrimaryNoAudioProof`; stopped audio is never reported as healthy.
Fresh append windows must contain no primary audio, microphone forwarding/selection, virtual-mic
route selection, or primary media-end activity. Before mint, any peer or capture transition fails.
After the test, only the separately verified ordered secondary connect -> capture start -> viewer
disconnect -> capture stop lifecycle is allowed. The final primary continuity interval is consumed
first, then the receipt-bound manager must be idle again, and a final lifecycle fence must still
prove that exact closed sequence. The sticky CoreAudio monitor must still report zero notifications.
Completed historical secondary cycles may remain in the bounded
baseline only when their latest capture is stopped and their later peer history has a later viewer
disconnect; a stale connected peer or unmatched capture start fails closed. This mode supplies no
primary audio or microphone continuity claim. The DEBUG app imports that
invitation only in memory, removes the copied seed and worldwide Keychain item before constructing
normal runtime owners, and emits a nonce-bound nonsecret cleanup receipt. Every post-copy exit
repeats that cleanup, and the host tears down only the receipt-bound secondary generation. A passing
iPhone 15 run is diagnostic behavior evidence; it can neither replace nor complete the final
TestFlight oracle on the exact production iPhone/build.

The development UI step observes an `Inactive` audio label and disabled microphone affordance; those
are presentation/topology evidence, not an independent native `AVAudioSession`, audio-unit, or hidden
ownership measurement. Separate native `videoControlOnly` tests require no custom iOS audio
transaction device, no local microphone track, and no audio SDP section. Keep those source/native
tests distinct from the physical pixel result and do not infer an unobserved ownership claim from the
UI labels alone.

Healthy and quiescent forwarding are both labeled `exactAttemptBound`. Pre-attempt-generation hosts
cannot prove same-attempt continuity and therefore fail closed instead of receiving a sampled-health
fallback.

The initial host-log checkpoint records the exact append cursor and inode while retaining only a
bounded 16 MiB complete-line tail. It never copies or repeatedly rescans the full long-lived host
log; every later checkpoint consumes a fresh, non-overlapping byte interval from that cursor.

The local integrity boundary trusts the current macOS user, authoritative worktree, and pinned UV
CPython/standard-library tree. The sealing above prevents ambient environment/`.pth` execution,
bytecode shadowing, and at-rest third-party drift; it does not claim resistance to a malicious
concurrent process running as that same user, which could also rewrite the runner itself. Closing
that different threat model requires an administrator-owned or OS-immutable Python and dependency
runtime.

For V90, `--probe-secondary-test-viewer-status <new-absolute-output-file>` is a strictly
non-minting endpoint-idle observation only. The verifier requires the exact expected lowercase
SHA-256 of an owner-matching, single-link `0755` CaptureServer candidate, validates its strict code
signature and preserved `com.elamin.AudioStreamer.CaptureServer` identifier, then accepts only a
fresh nonce-bound `observed` record with `managerPhase=idle`, `managerIsIdle=true`, no invitation or
generation receipt, and an unchanged manager generation. Fence every probe to the same control-
socket device/inode, owner UID and exact `0600` mode across connect, the current owner-only host-lock
PID/generation, and the server peer PID. This observation does not inspect or certify screen-
inactive, viewer-released, or stable-route safe-idle gates; revalidate those gates separately and
immediately before any authorized mint. The probe replay table accepts at most 256 unique probes per
host generation; the 257th fails closed, and even a clean bounded run is race sampling, not readiness,
mint authority, or a continuous watchdog.
V90 remains ineligible until rebuilt and sealed from a clean checkout whose exact HEAD equals a
fresh upstream branch readback, with an immutable V89 committed-rollback-to-exact-V86 origin record
pinned and validated from the actual success result, terminal journal state, and active V86 readback;
the stale offline/unsealed V89 draft README is not origin evidence. After any pass, obtain fresh
explicit per-run authorization and revalidate every fence immediately before a separate invitation-
minting action.

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

## Execution and Claim Boundary

- `swift test` covers the deterministic protocol, security, transport waveform, mutation, Mac
  artifact, and validation-driver contracts.
- A **signed** Simulator `xcodebuild test` run covers iOS lifecycle, Keychain, accessibility
  serialization, native PCM publication, and evaluator mutations. An unsigned run is not a
  substitute because it cannot exercise the production Keychain access group.
- A generic-device UI `build-for-testing` proves the physical test source compiles; it does not
  execute a physical oracle.
- An offline V90 capsule with valid manifests proves a pinned source build and sealed handoff; it
  does not prove that `/Applications`, launchd, the live PID, or any audio route changed.
- Only terminal `COMMITTED_V90` plus its fresh installed/live readbacks is V90 host-deployment
  evidence. `V90_COMMIT_IRREVERSIBLE` or committed-but-unverified evidence means the host must remain
  on V90 pending safety review, not that deployment passed; a rollback terminal proves restoration
  to exact V86, not a successful V90 deployment.
- An iPhone 15 `.dev` pass is diagnostic, TestFlight availability is distribution evidence, and
  exact-build installation is device-state evidence. Only the fresh iPhone 17 Pro
  production-bundle oracle is final user-device visual evidence.
- Injected CallKit tests prove fail-closed microphone policy, explicit hosted-origin ownership,
  and asynchronous race fencing, not that a real device reports every transition. A signed
  physical-device pass must cold-launch during a real connected iPhone call, prove
  `origin=startup-connected-call`, keep microphone input closed while fresh decoded/native playout
  evidence advances, replace that ownership with `origin=interruption` after a genuine interruption,
  begin that interruption-origin window only after interruption-ended supplies a resume hint, then
  end the final call and require a fresh ordinary audio-policy generation plus new advancing
  render evidence before claiming recovery.
- The production-bundle physical driver binds evidence to a fresh artifact directory, the exact
  pinned iPhone 17 Pro CoreDevice/hardware-UDID/marketing-name identity, installed bundle/build
  number, externally release-sealed Mac host executable and
  loaded media framework, unchanged live PID/vnodes/signing identities before and after the
  challenge, session identity, and current `.xcresult`. `devicectl` cannot independently prove that the installed
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
