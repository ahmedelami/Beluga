# Remote iPhone audio diagnostics

The optional audio-diagnostics lane reports the paired iPhone's observable playback
pipeline to the Mac automatically. It is independent of showing the screen, successful
playback, Retry, and the remote-input channel. It does not authorize or repair audio.

## Evidence and privacy

- A current offer/answer nonce binds the unordered, zero-retransmission channel to one
  peer negotiation. Revoked readers and delayed packets cannot acquire new authority.
- Each heartbeat includes the app version/build, random session/policy generations,
  retry and authorization outcomes, aggregate connection/call/microphone policy flags,
  inbound counters, native route/session facts and render progress.
- Native failures retain a bounded typed context captured before rollback: stage,
  reason, status, device/system/configuration generations and scalar route facts.
  Historical causes are distinct from the current playback state.
- No audio recordings, spoken content, typed input, contacts, track titles, route/device
  names, pairing credentials, SDP, ICE addresses, or arbitrary error strings are sent.
- The wire limit is 4 KiB, with at most eight recent events and one retained first
  failure. The sender runs at most once per second after a change, then every five
  seconds. Backpressure drops telemetry; it never queues media-control work.
- Native sampling is single-flight and separate from the ordered peer-event consumer.
  Cached native and inbound samples retain their observation ages; receiving a new
  heartbeat does not make an old sample fresh.

## Mac evidence

The host writes one bounded, atomically replaced report:

`~/Library/Application Support/opensteamer/diagnostics/audio-client-v1.json`

The report is at most 32 KiB. The diagnostics directory is owner-only and the file
mode is 0600; unexpected owners, links, permissive modes or ACL grants fail closed.
The writer coalesces pending reports and normally writes no more than every five
seconds. Terminal transport/session changes wake a delayed write. It does not
truncate or replace the existing host log.

Interpret the report's host/peer/negotiation identity, receipt and expiry together.
An expired report left by a crash is not current evidence. A non-negotiating older
iPhone build is reported as unavailable, not as silent or healthy. Current native
evidence expires independently of the heartbeat. Progress comparisons require
advancing observation times within the same policy/native generation.

In the v1 retained native cause, `inputRequired` is the native recording request
(`_wantsRecording`), not permission or effective input authorization. WebRTC can
request recording while the microphone is unauthorized; use the separate current
permission, input-bus and route-proof fields to assess admission. Likewise,
`routeSharingPolicyIsDefault == false` does not identify which non-default policy
iOS reports. The retained cause has no raw sharing-policy enum, so do not infer
long-form routing from that boolean alone. From iPhone build68, a failed native
output-policy target check additionally publishes its pre-rollback rejection in
the existing numeric `authorityFailureCode` field on historical failure evidence.
This is a native target-proof receipt, not a new reducer authorization decision.
The current controller code (including failed-closed201) stays unchanged.

The bounded codebook is `1024 + outcome * 8 + observedPolicy`: observedPolicy is
default0, longFormAudio1, independent2, longFormVideo3, or unknown4. Unknown raw
system values map to unknown, never arbitrary wire values. Outcomes1...6 mean
invalid arguments, prior failed repair, pre-effect drain rejection, post-effect
drain rejection, setter rejection, and persistent sharing mismatch. Outcomes7...55
name the first failed transaction/ownership/privacy/route predicate, in exact
production evaluation order; adding64 identifies the same predicate after the
setter. Outcome56 means the one permitted attempt was already spent. Reserved
outcomes and policy values are rejected by the local typed mapper. The canonical
names are `WebRTCAudioClientNativeTargetPolicyRejection` in
`shared/Sources/WebRTCTransport/WebRTCAudioClientFailureContext.swift`.
For example1073 means persistent sharing mismatch with observed longFormAudio;
it is evidence about that rejected native check only, not the current route.

The receipt keeps the original native device/event/system/configuration/operation
identity. Since native evidence cannot establish a Swift policy UUID, new detail
events use a nil policy and attempt0. The first concrete native cause supersedes
an uncorrelated controller-only retained placeholder; it never overwrites an
already-concrete native cause. Enrichment of a retained native cause requires an
exact five-part identity match established before the new read. A distinct later
failure lives only in the bounded event history. Deduplication rejects retired
devices and replayed events. Event trimming cannot evict the retained first cause.
No new wire fields, enum cases, private route identifiers or success receipts are
introduced; installed hostv48 can retain these numeric codes without redeployment.

`renderingNonzero` means nonzero PCM reached the app's native render boundary.
It does **not** prove output through the later iOS mixer, hardware, speaker or
headphones. Similarly, inbound RTP progress alone does not prove decoded playback.

## Verification boundary

The transport, journal, native failure-context, Mac classifier and private report
writer have deterministic tests. Regression checks cover revoked authority, stale
policy reads, replayed history, missing observations, retained causes after cleanup,
recovery baselines, delayed statistics and blocked optional native reads. Negative
mutations must demonstrate rejection of their target defect before release claims.

The initial diagnostics lane requires the updated signed Mac host and a supporting
iPhone build. Build68's rejection detail is compatible with the already-deployed
v48 host; it does not require another Mac deployment or relax any audio policy.
TestFlight acceptance is distribution evidence, not physical audio proof. Inspect
fresh correlated telemetry from the intended remote iPhone before attributing its
silence to a specific stage or claiming the playback issue fixed.
