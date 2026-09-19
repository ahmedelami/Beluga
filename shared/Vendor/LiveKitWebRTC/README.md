# OpenSteamer's pinned LiveKitWebRTC artifact

This directory is the source-controlled home of the app's single `LiveKitWebRTC` binary
module. `Package.swift` references `LiveKitWebRTC.xcframework.zip` directly; no SDK release,
external artifact hosting, mutable package-cache override, or second module provider is used.

## Artifact status

The replacement ZIP and its `ARTIFACT_MANIFEST.json`, `SHA256SUMS` and `COMPLETE.json` receipts
are present. Real packaging and independent verification of the source-tree copy passed.
The 24382900-byte archive SHA-256 is
`1399ee6f9a34a6926d2abe9196c1361a40a7fbc9551becd5d13b15a73f510cf7`, now pinned by the
guarded release. See `BUILD_PROVENANCE.md` for exact receipt and binary identities.
Guarded TestFlight release and physical verification remain pending; packaging and test success
are not deployment or playback proof.

## Source provenance

App integration has passed the full signed Simulator suite: 643 tests, two environment-specific
skips, zero failures. The executed dynamic-framework retry test is bound to the exact Simulator
binary digest. TestFlight deployment and physical remote-iPhone audio remain separate gates.

See `BUILD_PROVENANCE.md` for the captured GN/compiler/dependency identities, mutation-sensitive
wrapper test evidence, license union and remaining release gates. The adjacent
`opensteamer-livekit-audio-retry.patch` includes the complete prefix, production retry and
dedicated-test delta against the pinned pristine WebRTC source, including previously untracked
test files. Apply that combined patch once; do not apply the prefix patch separately first.

- Upstream binary wrapper: `https://github.com/livekit/webrtc-xcframework.git`, version
  `144.7559.11`, commit `46f2af86f06b9a8a9158d37cadda5cb5a214e4c4`.
- Official release archive SHA-256:
  `07c5caf718058af3c528dcabd257298c40e5a8527e4fb9f47c48336ba5899853`.
- WebRTC source: `39d2180660d43d2e1630e564e3afe1c1fb72746e`.
- Reviewed LiveKit build recipe: `440d978c6f8f6a89d53c6f8ac0d096a7b44f73e5`.
- Reviewed depot_tools: `ec7d8f539cb439ce9ca7750ff0d8942e68325090`.

The recipe's historical `webrtc_version.yaml` is not the source-version oracle. Final build
metadata must identify the actual checkout, exact applied patch bytes, dependency/CIPD
revisions, compiler and SDK versions, GN arguments and architecture-specific build commands.
Rebuilding from source and retrieving the same committed artifact are different guarantees:
record any tool-generated nondeterminism rather than claiming unproved bit-for-bit rebuilds.

## Slice and packaging contract

- Patched iOS device: arm64.
- Patched iOS Simulator: arm64 only. Intel Simulator builds are not supported by this artifact;
  do not silently mix an unpatched x86_64 slice with the patched arm64 API.
- macOS: the official arm64/x86_64 framework is copied byte-for-byte, including headers,
  resources, nested privacy-manifest layout and the five versioned-framework symlinks. Do not
  rebuild, re-sign, rewrite or dereference this source slice. Existing host signing still acts
  on its separate build product, never this source artifact.

The archive must contain exactly one root `LiveKitWebRTC.xcframework`, with its plist selecting
those three slices. Preserve framework/module/executable name `LiveKitWebRTC` and framework
bundle identifier `io.livekit.LiveKitWebRTC`. Normalize ZIP entry ordering and metadata while
preserving executable modes and symlink targets; exclude Finder metadata, credentials, caches,
test runners and intermediate build files. Record the final archive SHA-256 and the complete
per-entry content/type/mode/symlink manifest. Compare the extracted Mac subtree to the official
source before and after packaging. A final release must pin the resulting archive bytes.

## Notices and release verification

Retain wrapper MIT and WebRTC BSD notices in the root `THIRD_PARTY_NOTICES.md`, which the app
already bundles. Generate and distribute transitive notices from the actual compiled GN
targets. If build-recipe scripts are included, retain their Apache-2.0 license and `build/NOTICE`;
record local modifications. The upstream two-line version label alone is not a license inventory.

Final integration must test the custom ADM wrapper's real initialization/start retry and exact
native receipts, privacy revocation and drains on the patched Simulator slice, and verify the
same API in the device slice. Archive/export checks retain the exact existing app identity,
one embedded signed LiveKit framework, team and entitlement restrictions. Package input changes
must never rewrite historical encrypted-cache enrollment provenance. An iOS release does not
install or replace the Mac host or its virtual-audio driver.

## Local packager (already-built inputs only)

`package_artifact.py` invokes the pinned `xcodebuild -create-xcframework`; it does not compile,
sign, upload, install, or modify input frameworks. The official Mac manifest is pinned in the
script as `ed48b96a26ff499911c4a9a5ac700a26c32c845ad82351d5b74054705302ef15` (122 entries,
including exactly five symlinks). Its verified source is:

```text
/Volumes/t7/opensteamer-source-packages/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework
```

After both patched iOS frameworks have actually built, supply their canonical absolute paths
and a previously absent output directory whose parent already exists:

```sh
/usr/bin/python3 -B shared/Vendor/LiveKitWebRTC/package_artifact.py package \
  --ios-device /absolute/device/LiveKitWebRTC.framework \
  --ios-simulator /absolute/simulator/LiveKitWebRTC.framework \
  --official-mac /absolute/official/macos-arm64_x86_64/LiveKitWebRTC.framework \
  --output /absolute/new-artifact-directory
```

The new private output contains the assembled XCFramework, deterministic ZIP,
`ARTIFACT_MANIFEST.json` (canonical per-entry path/type/mode/content digest or symlink target),
`SHA256SUMS`, and `COMPLETE.json`, written only after full extraction verification and input
reverification. An existing output is always rejected. Failure retains an incomplete output
without `COMPLETE.json`; use a different new directory rather than overwrite it. The script
requires exactly the three reviewed platform/architecture slices, their real Mach-O platform
and dynamic-library identity, the expected module/plist identity, and the unchanged official
Mac subtree. It refuses unsafe ZIP paths, symlink traversal, special files and extra slices.

For an independent check, run its `verify` subcommand with `--archive`, `--manifest`,
`--official-mac` and the independently pinned `--sha256`; extraction uses a fresh temporary
directory beside the archive. Packaging output is not copied into this source tree automatically.
The device/Simulator generated notice union is verified and embedded in the app's existing
notice resource. Build-source and final artifact receipts remain separate release inputs;
do not add arbitrary files into the exact three-slice XCFramework.

The tiny fixture suite is `/usr/bin/python3 -B -m unittest -v test_package_artifact` from this
directory. It uses synthetic, non-runnable Mach-O headers and a fixture assembler, never Xcode
or real audio. Its result proves packaging properties, not correctness of the patched SDK.
