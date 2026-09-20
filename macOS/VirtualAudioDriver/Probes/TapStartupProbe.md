# Opt-in process-tap / virtual-input startup diagnostic

This is a standalone diagnostic, not production code or a rollout tool. Offline
tests validate its refusal/report contracts, not the reported dictation failure.
Live execution and its limitations must be recorded against the specific report,
runtime pins, and built probe identity; a build/test result is not live evidence.

The task-local `tap-startup-ab-02.json` report (2026-09-19, source task directory
`/Volumes/t7/opensteamer-mic-startup.wGnGFF`) records four cleanly retired arms
with input callback progress for both values. Every arm also observed foreign
output activity, so that report's cold-start verdict is inconclusive. It does
not identify the historical emitting process, establish the Codex dictation
cause, or validate a production change. A later output inspection cannot
retroactively attribute the earlier activity.

## Build and read-only checks

From the repository root, supply a new output path in an existing directory:

```sh
zsh macOS/VirtualAudioDriver/scripts/build-tap-startup-probe.sh /absolute/new/TapStartupProbe.app
ruby macOS/VirtualAudioDriver/tests/TapStartupProbeContractTests.rb
/absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe --permission-check --host-pid 77172
/absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe --host-scan-diagnostic
/absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe --offline-host-classifier-test
/absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe --output-activity-check
/absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe --offline-output-classifier-test
```

The last command is read-only: it does not create a process tap, audio queue,
aggregate, or IOProc, start audio, request permission, change selectors, or
control the host. It reports the microphone authorization enum (authorized = 3),
the diagnostic bundle identity, and the supplied canonical CaptureServer PID's
start seconds/microseconds. The PID is an example, not a current runtime pin.
The host-scan command is also read-only and reports at most eight unresolved
`proc_name` entries plus counts, without emitting their names or paths. Public
typed `KERN_PROC_PID` metadata is used when `proc_name` cannot read an unrelated
process. Empty, truncated, denied, mismatched-PID, or unterminated metadata stays
unknown and fails closed; a host candidate still requires every exact runtime
pin. Named zombies are not silently ignored. The offline classifier command
executes nine pure typed-metadata contracts and calls no process/audio APIs.
The output-activity command reads public Core Audio process metadata only. It
reports currently running output process IDs and bundle IDs, classifying the
inspector, the diagnostic bundle, the canonical host executable path, and other
bundles. It creates no audio objects and starts no audio. Output is bounded to
16 active processes; missing metadata or overflow is explicitly incomplete.
The output classifier's five offline contracts do not call Core Audio APIs.

System-audio capture authorization has no public preflight in the selected
Core Audio tapping headers. The read-only command explicitly reports this gate;
it cannot establish that a new diagnostic identity is already authorized.
Neither the app nor supervisor resets TCC or requests access. A process-tap
creation itself can prompt when authorization is absent, so **do not run the
live command with an unknown/unauthorized capture identity**. Resolve any
permission decision with the user separately. Never impersonate the host's
bundle identity to inherit its permissions.

## Live boundary (requires separate review/approval)

The supervisor requires every pin explicitly. Obtain current values immediately
before the approved idle boundary; examples are deliberately not runnable:

```sh
ruby macOS/VirtualAudioDriver/scripts/run-tap-startup-ab.rb \
  --live-opt-in --audio-capture-permission-confirmed \
  --native /absolute/new/TapStartupProbe.app/Contents/MacOS/TapStartupProbe \
  --native-sha256 LOWERCASE_SHA256 --driver-sha256 LOWERCASE_SHA256 \
  --driver-instance CURRENT_INSTANCE \
  --clock-uid EXACT_REAL_OUTPUT_UID --input-uid EXACT_CURRENT_DEFAULT_INPUT_UID \
  --output-uid EXACT_CURRENT_DEFAULT_OUTPUT_UID \
  --system-output-uid EXACT_CURRENT_DEFAULT_SYSTEM_OUTPUT_UID \
  --host-pid CURRENT_PID --host-start-seconds CURRENT_START_SECONDS \
  --host-start-microseconds CURRENT_START_MICROSECONDS --host-sha256 LOWERCASE_SHA256 \
  --report /absolute/new-metadata-report.json
```

The capture-permission flag means an already-authorized identity has actually
been confirmed; it is not a bypass or a request to grant permission. To require
the host's preexisting absence instead of a pinned quiescent host, replace all
four host-pin arguments with `--host-absent`. The probe never stops the host.

It preserves all three default selector IDs/UIDs and watches their change
notifications. The virtual endpoints are selected only by the exact production
visible-input and hidden-writer UIDs, then validated for model, role, visibility,
clock domain, and 48 kHz mono Float32 format. The aggregate uses the exact pinned
real default output as its clock. It does not select a default device, format,
system volume, or route. The pinned running host must remain the same canonical
PID, start tuple, and binary; any observed active foreign virtual client aborts.

Each arm starts a silent hidden-writer owner and a separate native Audio Queue
reader process. After `tap_start` BEGIN, the supervisor immediately dispatches
the reader, even if the owner's `AudioDeviceStart` is blocked. The private
aggregate differs only in TapAutoStart (plus fresh owned identifiers). The order
is true / false / false / true. Counts distinguish writer callbacks, tap
callbacks, input callbacks, frames, and advancing input timestamps. No audio
bytes are inspected, recorded, logged, or written to disk.

The reader's native-start deadline is 20 seconds; initial-stage deadlines are
5/8 seconds, passive checks 5 seconds, cleanup 3 seconds plus at most 1 second
per owned process to reap. TERM/KILL are only sent to retained child handles.
Only the owner's created tap, aggregate, and IOProcs and reader's own queue are
destroyed. Any killed worker, missing destruction acknowledgement, selector
change, unexpected active client, failed identity check, or failed fresh idle
check terminates the sequence: **no second arm after uncertain teardown**.
The report is created exclusively with mode 0600 and is never overwritten.

## Evidence limits

### Production-aligned comparison

The supervisor's optional `--production-aligned` mode is a separate diagnostic
configuration. It starts the same private real-output-clock tap first, then a
silent hidden-writer AudioQueue, waits for advancing writer callbacks, and only
then starts a fresh AVAudioEngine reader. The tap excludes its owner but includes
the reader, matching the production exclusion boundary more closely. The reader
is explicitly pinned to the visible product input; this still differs from
Codex's default-device discovery and does not reproduce Codex's entire graph.

The supervisor requires native configuration and before/after device readbacks,
disabled voice processing, and strictly ordered tap-start, writer-start,
forwarding-ready, and reader-start timestamps. It retains all existing runtime,
selector, permission, ownership, output-activity and acknowledged-teardown gates.
It stops after the first true arm if the input starts successfully, reporting
`baseline_did_not_reproduce_input_failure`; it also stops on playback contamination
or invalid evidence. The sampler reports owner/peer output separately, and observed
reader output yields `reader_output_observed_inconclusive`; a later input-only
readback cannot erase graph-initialization output. Sampling can still miss brief
activity. Both owned process exit statuses and acknowledged teardown must agree
with the reported startup result. Do not repeat unchanged successful controls as though more
iterations could establish the observed Codex failure. A native start error still
requires correlation with the receiving-boundary logs before identifying it as
the same approximately 14-second timeout.

If an aligned reader has completed setup but its native engine-start call remains
pending for18 seconds, the supervisor requests one prospectively defined
`retire-tap` intervention. It removes only that owner's private tap/aggregate,
without stopping or rebuilding its hidden writer or changing any default device.
The owner must prove the same writer UID/format and advancing callbacks around
retirement. Within a further8 seconds the reader must return and advance callbacks,
and both workers must acknowledge cleanup with matching exit statuses. The report
labels this `input_pending_until_tap_retirement`, separately from an ordinary
startup success. It requires a dormant tap, a native input call pending at least
15 seconds, and return after retirement begins; a late success before intervention,
a stopped writer, stale format, or killed worker is invalid. Counterbalanced
true/false results remain native-boundary evidence, not Codex transcription proof.

Native command waits check cancellation before polling and read bounded command
bytes in100ms slices. The no-audio `--offline-command-cancellation-test` verifies
pre-cancel, guard failure, valid command, partial-command cancellation and EOF.
An earlier killed run remains invalid even if a later runtime audit proves the
OS removed its audio resources; never relabel it as a clean arm.

This mode changes only the standalone diagnostic. The installed host, driver,
pairing, iOS application, and production TapAutoStart policy are untouched.
Live use still requires the separately approved idle boundary described above.

The2026-09-20 task-local `result-tap-isolation.json` report in
`/Volumes/t7/opensteamer-aligned-startup-run.GuHmgA` records a clean
true/false/false/true differential. Both true arms remained pending until the
18-second tap-only intervention and returned about46–49ms afterward while the
same writer continued. Both false arms started in about12ms. All four readers
then advanced20 callbacks/96,000 frames; all eight idle checks and both-worker
teardown/exit proofs passed, with no observed foreign or reader output activity.
This native result supports a narrowly scoped production candidate, but it is
not actual Codex transcription, real phone PCM or fresh paired-reconnect proof.
The earlier format-rejected and killed-reader reports remain invalid and retained.

- Apple documents TapAutoStart=true as making aggregate start wait for the first
  tapped audio. A tap-start timeout without an independent input failure is not
  evidence of a microphone defect.
- The sampler records non-excluded process output activity before/during each
  arm. Any observed activity makes the cold-start comparison inconclusive. It
  never stops existing playback. Sampling is 100 ms, so transient activity can
  be missed and the report states that limit.
- Private taps are visible only to their creator. Empty public tap enumeration
  cannot prove absence of another process's private tap, including a host tap.
  A killed owner cannot prove destruction; public enumeration cannot repair that
  gap. Accordingly the supervisor always aborts after a kill.
- A clean counterbalanced differential is labeled an observed differential,
  **not causal proof**. All-success results only mean no input-start failure was
  observed with this Audio Queue reader; they do not falsify a Codex-only failure.
- Silence is intentionally written. Callback progress is not proof that real
  phone PCM, audible input, dictation, reconnects, or physical routing work.
- The tests include negative mutations for killed workers, missing passive
  proof, cleanup, selector changes, guards, readback, callback errors/progress,
  and playback contamination. Those are offline harness evidence only.
