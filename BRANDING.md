# Beluga naming and compatibility

The product and repository are **Beluga**. The iPhone display name and app product are
`Beluga` and `Beluga.app`; the newly built Mac host is `Beluga Host.app`. Both apps use the
existing black Beluga logo on white. The original 2048-pixel PNG is
[`branding/BelugaLogo.png`](branding/BelugaLogo.png); app asset sizes are derived from it.

Source directories, Xcode project/target/scheme/module names, scripts, environment variables,
package references, npm packages, Worker names, and deployed service endpoints retain their
existing opensteamer spellings. They are operational identifiers rather than app display names.
The root Swift package is named `Beluga`; its library and executable target names remain stable.

The installed Mac host and LaunchAgent still use their recorded opensteamer paths. Historical
migration/update controllers and evidence remain frozen; a branding build does not authorize
an installed-host migration. Fresh Beluga bundles use their matching bundle verifier.

The protected production iOS bundle identifier remains `com.elamin.AudioStreamer`; builds meant to
update that app must keep its identity, container, and default Keychain access group. The separately
authorized side-by-side TestFlight client uses `com.elamin.opensteamer` and must never be presented
or installed as an update to the protected app.

Some pre-rebrand identifiers are intentionally immutable compatibility data rather than branding:

- The current iOS Keychain service stays `org.example.AudioStreamer`; migration code may read the
  earlier `com.elamin.AudioStreamer` identity and paired-Mac items only as one validated,
  same-namespace fallback pair. The macOS host keeps its shipped
  `com.elamin.AudioStreamer.CaptureServer` bundle/signature identifier,
  `com.elamin.AudioStreamer.CaptureServer.runtime` lock namespace. Those exact deployed identities
  preserve macOS privacy grants and mixed-version exclusion. The protected legacy host retains
  `com.elamin.AudioStreamer.CaptureServer.WorldwidePairing.v1`, while the new host stores only in
  `com.elamin.opensteamer.CaptureServer.WorldwidePairing.v1`; the disjoint services preserve the
  legacy rollback pairing while allowing the side-by-side TestFlight app to pair independently.
- The deployed v1 WebSocket headers/subprotocols, WebRTC data-channel identifiers, invitation
  checksum domain, and cryptographic transcript labels retain their original bytes. These values
  are authenticated protocol ABI. They may change only behind a negotiated new protocol version
  with mixed-version rollout tests.

Do not “clean up” those legacy literals with a global replacement. They are documented next to
their definitions and covered by compatibility tests. New user-facing names must use `Beluga`.
Do not rename deployed identifiers, persisted paths, or frozen release records solely to match
the display name.
