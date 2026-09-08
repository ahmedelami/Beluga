# opensteamer Mac media integration

The Mac host now uses native Apple Events for ordinary YouTube watch tabs in Chrome
and for Music. No Chrome extension is required. An inactive tab is still an ordinary
background Chrome tab; discovery does not select it, bring Chrome forward, or start
playback. Next/Previous are offered only when the selected player has those controls.
Multiple ambiguous players clear selection rather than choosing an arbitrary target.

Enable Automation through the installed signed host (Chrome or Music must already
be running):

```sh
"/Applications/opensteamer Host.app/Contents/MacOS/OpensteamerMediaBridge" --authorize-chrome
"/Applications/opensteamer Host.app/Contents/MacOS/OpensteamerMediaBridge" --authorize-music
```

The helper asks the running host to request macOS consent; it does not impersonate
the host or launch another host. No iPhone connection is needed for permission setup.
Chrome additionally requires its **Allow JavaScript from Apple Events** setting.
Ordinary discovery never requests consent or changes that setting. Denied permission,
disabled JavaScript, stale reads, or ambiguous state revoke controls; diagnostics
report the capability state. The host cannot prove a safe Chrome/Music selection when
a running Chrome instance is unreadable, so controls remain unavailable in that case.

Native requests bind the Chrome PID/launch, stable window/tab IDs, exact URL, and
document/player/item generation. The production script runs in the page context,
not an isolated extension world: page state and returned metadata are untrusted.
Bounded values, exact source checks, original deadlines, and non-replayed relative
commands protect command routing; they are not a security boundary against a
compromised page or another process running as the same macOS user.

Run the exact production native-script behavior and mutation tests:

```sh
node --test browser/opensteamer-media/tests/native-apple-events.test.cjs
```

Native Swift tests cover final dispatch authorization, deadlines, source replacement,
overlapping polls/commands, and permission-only IPC. These tests do not prove macOS
consent, live player behavior, or the iPhone's system Now Playing UI. Those remain
separate installed-host and physical-device release checks in `TESTING_ORACLES.md`.

## Retained optional extension implementation

The extension implementation below remains available for development and compatibility
testing; the default host source runtime uses native Apple Events instead. Loading the
extension alone does not switch that runtime, and the permission-only host endpoint
rejects extension media-state injection. Do not install it as a native-integration step.

This local Manifest V3 extension supplies current YouTube metadata and Play, Pause,
Next, and Previous commands to the opensteamer native media helper. Its fixed ID is
`dhmdpbpcldmnkjfibepklolofapiceab`; the manifest contains a public key only. The native
messaging registration must use `org.example.opensteamer.media` and allow only
`chrome-extension://dhmdpbpcldmnkjfibepklolofapiceab/`.

The extension uses `nativeMessaging`, `scripting`, and exact
`https://www.youtube.com/*` host access, plus two static scripts in the top frame.
It does not request the general tabs permission, browsing history, all-sites access,
or remote executable code. `scripting` is used only once per install/update to attach
the bundled adapter and bridge to existing YouTube documents without reloading them.
This bootstrap queries only the granted host, checks its exact current URL twice,
and targets Chrome's returned document ID for both worlds. A retired document has
no fallback to its replacement. Idempotent guards prevent duplicate static/bootstrap
listeners. The extension does not change tab focus, navigation, typing, playback,
or player selection to discover media. A Next or
Previous command clicks only an available control on the exact current YouTube
player; it does not invent playlist navigation or a keyboard fallback.

`adapter.js` runs in MAIN to read untrusted `navigator.mediaSession.metadata` along
with the real video element. Its metadata is treated as untrusted text, stripped of
control characters, and clipped by UTF-8 byte length. Blank artists are omitted;
missing titles use `YouTube` only when a valid media item exists. Playback state and
time come from the video, with unavailable/nonfinite or over-one-year times omitted. The page can
observe and forge MAIN-world messages; the isolated bridge and worker therefore
admit only bounded media state and responses for already-pending commands. MAIN
messages cannot trigger native Music authorization. Only a message from the exact
extension popup, with no tab sender, can request that permission. The popup's
**Enable Music controls** button is the explicit user gesture for the native
helper's macOS Automation prompt. The extension persists no metadata or commands.

The local bridge trusts processes running as the same macOS user. Socket ownership
and helper signature checks identify the local account and helper binary; the
extension-origin argument does not prove that Chrome launched the helper or that a
person clicked the popup. A malicious process already running as that user can
invoke the signed helper with that argument. This integration does not establish a
security boundary against such same-user processes.

The worker binds a source to the exact sender tab, document, and connection epoch.
It selects the source that most recently started playing or changed its playing
item. Ordinary heartbeats do not change selection between two playing tabs. It
retains the selected fresh paused source when none is playing. State expires after
three seconds without a source update. Metadata and
playback changes publish immediately at observed events, with a 250 ms fallback
sample and at least one source heartbeat per second while the page runs. Native
state heartbeats occur once per second. Chrome may throttle background timers;
missed freshness deadlines clear the source rather than claiming it is still fresh.
Player, video, item, navigation, document, or native connection replacement revokes
the relevant context. Returning after navigation or reconnection requires a fresh
context before controls are admitted.

Every native JSON message is at most 4096 UTF-8 bytes. Commands carry the original
issued timestamp, a UUID, and the selected context UUID. Future commands and commands
at least 1000 ms old are rejected at native arrival. The remaining deadline is
passed unchanged through the worker, isolated bridge, and MAIN adapter using
`performance.timeOrigin + performance.now()`. Immediately before the actual action,
MAIN rechecks the original wall deadline, monotonic deadline, document/player/video/
item identity, and available control in the same JavaScript turn. Pending commands
are capped at 32, replay IDs at 2048 for 60 seconds, and source ports at 32. A full
replay table rejects new commands instead of evicting live IDs. Relative commands
are never retransmitted after timeout or disconnection.

Run deterministic tests from the repository root:

```sh
node --test browser/opensteamer-media/tests/media.test.cjs
```

The suite runs the actual production worker, bridge, and adapter source in Node VM
contexts with fake Chrome and DOM boundaries. It observes target play/pause/click
effects, tests malformed input, expiry, replacement, recovery, deduplication,
pending limits, popup-only authorization, existing-document install, URL replacement,
and duplicate injection, and requires behavioral oracles to
reject mutated production source. Mutants run in disposable VM contexts; source
files are verified unchanged afterward. These tests do not establish real Chrome
behavior, Music Automation permission, native iOS metadata presentation, or physical
media-control success. Those require the installed extension/helper/host and the
intended iPhone build, following the repository's Now Playing release oracle.

For an authorized local installation, register the signed native helper first,
then open Chrome's Extensions page, enable Developer mode, and use **Load unpacked**
on this directory. Confirm the displayed extension ID above. Existing YouTube tabs
receive a bounded one-time bootstrap without a reload; newly navigated documents
receive the normal static scripts. Open the extension's
popup to inspect helper availability and explicitly enable Music controls.
