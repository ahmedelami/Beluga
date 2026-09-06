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

`renderingNonzero` means nonzero PCM reached the app's native render boundary.
It does **not** prove output through the later iOS mixer, hardware, speaker or
headphones. Similarly, inbound RTP progress alone does not prove decoded playback.

## Verification boundary

The transport, journal, native failure-context, Mac classifier and private report
writer have deterministic tests. Regression checks cover revoked authority, stale
policy reads, replayed history, missing observations, retained causes after cleanup,
recovery baselines, delayed statistics and blocked optional native reads. Negative
mutations must demonstrate rejection of their target defect before release claims.

Deployment requires both the updated signed Mac host and a matching iPhone build.
TestFlight acceptance is distribution evidence, not physical audio proof. Inspect
fresh correlated telemetry from the intended remote iPhone before attributing its
silence to a specific stage or claiming the playback issue fixed.
