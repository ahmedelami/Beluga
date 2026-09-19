# Local LiveKitWebRTC build provenance

## Final app integration checkpoint

The signed iOS Simulator suite passed 643 tests with two environment-specific skips and zero
failures against this exact local ZIP (`app-integration.FgCAnN/test-6-full.log` and
`result-6-full.xcresult`, 2026-09-05 22:34 EDT). The dynamic-framework smoke test executes the
real factory/delegate retry, rejects an initial native failure, then proves start and healthy
idempotence without audio hardware. `dladdr` binds the retry to the factory's actual loaded
framework, and SHA-256 binds that image to the exact Simulator binary below. Pinned Xcode
injects its unmodified build-products framework during hosted tests; the app's separately
signed embedded copy retains the same recorded Mach-O UUID.

The exact native-recovery integration also holds media counters frozen after native acceptance
and requires playback to remain unproved until the explicit fixture counters advance. A
separate exact failed-receipt test proves diagnostics exist at first failure publication and
cannot be replaced by a retired duplicate. These fixture counters are not physical media proof.

An existing full-suite fixture ended before asynchronous disconnect completed, making the next
keyboard test encounter a correctly enforced retiring-device guard. The keyboard case passed
alone; awaiting the existing exact retirement-admission barrier in the preceding fixture made
the full suite pass. No production retirement guard was changed. Four stale generated PCM
module files from the old SDK were moved aside in this task's DerivedData; shared caches and
other build products were retained.

Product identity, zsh syntax, and the complete behavior-only release-guard regression suite
passed with the final build-65 and ZIP pins. TestFlight archive/export/upload and physical
remote-iPhone verification remain pending at source freeze.

Source snapshot: 2026-09-06 01:58 UTC; subsequent build/package findings are recorded below.
This records source, completed wrapper tests and the verified packaged artifact. App integration,
TestFlight upload and physical audio verification remain pending.

## Pinned inputs and complete source patch

| Input | Exact revision or SHA-256 |
| --- | --- |
| `https://github.com/webrtc-sdk/webrtc.git` | `39d2180660d43d2e1630e564e3afe1c1fb72746e` |
| `https://github.com/webrtc-sdk/webrtc-build.git` | `440d978c6f8f6a89d53c6f8ac0d096a7b44f73e5` |
| depot_tools | `ec7d8f539cb439ce9ca7750ff0d8942e68325090` |
| Chromium build dependency | `be1a8f6dcd7df7e46320192c5e2f364e50d79bbf` |
| Chromium third_party dependency | `a3b630c291f1cf3b711687b1c4be322d3015512e` |
| buildtools dependency | `aec4f3c79e5af648386819cbe7f6e67206385ece` |
| Source `DEPS` SHA-256 | `8f7895f3614c31e317e3298f040d7217220fc711655f3fbb0f5379333da08e3f` |
| Recipe `build/patches/apple_prefix.patch` SHA-256 | `649ca0ac6de2386261f978ddd03840855e851a14545840f975edce703e9b48ad` |
| Combined local source patch SHA-256 | `9298b17853f6bf61a557001a2165d17df106cc01cc30288aef693eaba6448d50` |

`opensteamer-livekit-audio-retry.patch` is a full-index diff against the pristine WebRTC revision
above: 10 modified tracked files plus all three previously untracked dedicated-test files. It
includes the recipe's LiveKit framework/Objective-C prefix changes, the optional delegate retry
API, actual ADM initialization/start and buffer rollback, exact owner/thread checks, and the GN
test target plus its plist/main/XCTest source. Apply this combined patch **once** to that pristine
revision; do not apply the prefix patch separately first. `git apply --reverse --check` succeeded
against the restored live source tree. No vendor index was staged or committed during capture.

```sh
# In a clean checkout at the pinned WebRTC revision; these commands apply the captured patch.
git apply --check /absolute/opensteamer-livekit-audio-retry.patch
git apply /absolute/opensteamer-livekit-audio-retry.patch
```

The captured `objc_audio_device.mm` SHA-256 is
`3cbe46914707692764ff85572128f531c9f80866f9c32a1030109d7300fcf903`; no `MUTANT` marker remains.
The recipe's historical M92 `webrtc_version.yaml` is not the source-version authority.

## Dependency, compiler and build configuration

Original evidence root: `/Volumes/t7/opensteamer-webrtc-retry-vendor.U62v4y`.
Its `.gclient` uses `src`, the pinned WebRTC URL, `deps_file=DEPS`, `managed=False`, empty
`custom_deps`, and `target_os=['ios']`. Executed sync, from its `webrtc` directory:

```sh
gclient sync --nohooks --noprehooks --no-history --shallow --jobs=2 \
  -r src@39d2180660d43d2e1630e564e3afe1c1fb72746e
```

`sync.json` records 159 entries (69 processed, 159 marked synced), including source and CIPD
dependency identities; SHA-256 `9409ab293c5184cebe488f100056cf0906c26d464a295dc2b84b8a527804fccc`.
`sync.log` SHA-256 is `846ae1d96e9725eb7ebefe2f83f996087d59b46729a76a423c7f78ce3f8ce06a`.
These local evidence files must be retained with the final build receipt.

From `webrtc/src`, `build/util/lastchange.py --filter=. -o build/util/LASTCHANGE` was executed.
Without a source-dir override its default is the **build dependency**, not WebRTC. Result:
`LASTCHANGE=be1a8f6dcd7df7e46320192c5e2f364e50d79bbf`, `LASTCHANGE_YEAR=2026`; file SHA-256
`12d6fc41625ceacaa7f2245b00ac74b2a7363efea03d0c62b4404fa1ad8935a5`. The explicit filter avoids
the default `^Change-Id:` historical search on the shallow checkout; this is not evidence that
default shallow-checkout metadata generation is reproducible.

The vendor environment sets `DEPOT_TOOLS_UPDATE=0`, `DEPOT_TOOLS_METRICS=0`, isolated TMP/CIPD/
vpython cache directories, and the pinned Xcode 26.6 (`17F113`) developer directory:
`/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer`.
No whole-Xcode hash was repeated for this record. Compilation uses Chromium's downloaded Clang,
not Apple's Clang: `22.0.0git`, reported LLVM revision `efe9a8c95451c9dadb5dd522802b05afd8b52d1b`,
package label `llvmorg-22-init-14273-gea10026b-2`; executable SHA-256
`dcb3f69bf81758b9d7a1d5c620638f3634eaaa5e2c923f77a9e8668f853be2f4`.
GN reports `2301 (4619125bd337)`; Ninja reports `1.12.1`.
Generated Simulator compile flags explicitly select the pinned Xcode's `iPhoneSimulator26.5.sdk`.
The initial unused `use_system_xcode=true` GN argument was removed; it is not a toolchain proof.

Both configurations use `target_os="ios"`, `target_cpu="arm64"`, `ios_deployment_target="13.0"`:

```gn
enable_dsyms = false
enable_libaom = true
enable_stripping = true
ios_enable_code_signing = false
is_component_build = false
is_debug = false
rtc_build_examples = false
rtc_enable_protobuf = false
rtc_enable_symbol_export = true
rtc_include_dav1d_in_internal_decoder_factory = true
rtc_libvpx_build_vp9 = true
rtc_use_h264 = false
treat_warnings_as_errors = true
use_rtti = true
use_remoteexec = false
use_siso = false
```

Simulator additionally uses `target_environment="simulator"`, `rtc_include_tests=true`, and
`enable_run_ios_unittests_with_xctest=true`; its `args.gn` SHA-256 is
`0fcbc44b7b8b4da8d9cc8ef87ee453e1f89e9f555ded99ef16da924327473b98`. Device uses
`target_environment="device"`, `rtc_include_tests=false`; its `args.gn` SHA-256 is
`c6b8e063c223601a48ce0824a1555844ab7f77ef8c099d3a5829ced1ebbfa290`.
All Ninja work is limited to `-j2`. From `webrtc/src`, using the recorded vendor environment:

```sh
buildtools/mac/gn gen out/opensteamer-ios-arm64-simulator
third_party/ninja/ninja -C out/opensteamer-ios-arm64-simulator \
  custom_audio_device_retry_unittests ios_framework_bundle -j2
buildtools/mac/gn gen out/opensteamer-ios-arm64-device
third_party/ninja/ninja -C out/opensteamer-ios-arm64-device ios_framework_bundle -j2
```

## Test and license evidence

The real custom ADM wrapper/AudioDeviceBuffer suite uses a synthetic device and transport, not
live audio I/O. `wrapper-tests-2.log`: 10 tests, zero failures. Mutation A (`mutant-noop.log`)
caused 32 assertion failures across the ten-test run; mutation B (`mutant-buffer.log`) caused two.
Both mutations were restored. Final restored Simulator relink completed successfully; the
`wrapper-tests-restored.log`/`.xcresult` run passed 10/10 at 2026-09-05 21:57:11 EDT. It used
Simulator `C798378E-0506-4E19-BD5F-DE7D8B6A4B7B`, `test-without-building`, diagnostics disabled,
parallel testing disabled, and 30-second per-test limits. This is wrapper proof, not physical
phone playback, native iOS recovery integration, or deployment proof.

| Completed evidence file | SHA-256 |
| --- | --- |
| `wrapper-tests-2.log` | `b0aa33c30118ce856231b501b0692c06fc15bb634d8f43741faef02d801156b3` |
| `mutant-noop.log` | `6f6a04664d2ad1d3494e3f468a058c0c829b55a6e244ab34b6f4e59975e5d33b` |
| `mutant-buffer.log` | `cf22dfc137906653a38e7152abc576aca6357816d57be99bc05e2758280a0f41` |
| `wrapper-tests-restored.log` | `6a4eb6aa999e3245654742b82411d79fa15e98654f56d9f20be39177556c3264` |
| `licenses-union-2.log` | `abc3a362275908e3e615f75076290e660ef419dcd0897addf7ec58c12b5a5295` |

`tools_webrtc/libs/generate_licenses.py --target //sdk:ios_framework_bundle` was run over both
generated Simulator and device build graphs. `licenses-union/LICENSE.md` matches the original
Simulator notices and the committed `LICENSE.md` byte-for-byte: 110690 bytes, SHA-256
`194386ab7947314fb36ecd963ff6d708f48f84135b5a549a00d0bd3e48bf3c38`. The first union attempt
failed only because its output directory was absent; creating it and rerunning produced the
successful `licenses-union-2.log`. The full notice text is embedded in the existing app resource.

## Frozen Mac slice and completed artifact

The Mac slice remains the exact official `144.7559.11` artifact. Its canonical 122-entry,
five-symlink framework manifest SHA-256 is
`ed48b96a26ff499911c4a9a5ac700a26c32c845ad82351d5b74054705302ef15`; see README for its exact
source path. No Mac framework was rebuilt or signed. The verified ZIP has one root
`LiveKitWebRTC.xcframework` and exactly `ios-arm64`, `ios-arm64-simulator`, and
`macos-arm64_x86_64` slices. Intel Simulator support is intentionally absent.

The device build subsequently completed successfully: 5395 Ninja tasks, 410.6 seconds, exit 0
(`build-device.log`). Both device and Simulator framework builds are complete.

The first real assembly, retained unchanged at `artifact-1`, failed closed because pinned Xcode
emitted Mac `BinaryPath=LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC`; both iOS entries used
`LiveKitWebRTC.framework/LiveKitWebRTC`. That observed plist's SHA-256 is
`b3aa17298d5c128c6621732bab780803e46a51a2de2c2e8f0c840b89bcd34d50`. The packager now admits
only that exact additional versioned path for the Mac slice, or its previously accepted root
link path, and requires the declaration to resolve to the same verified framework executable.
It does not normalize or allow arbitrary paths. Versioned iOS paths, other Mac versions,
normalized aliases, absolute paths and escapes remain rejected. Existing symlink-mode
preservation is unchanged. The expanded tiny fixture suite passed 18/18 (0.393 seconds), without
real packaging or native compilation; log:
`/Volumes/t7/opensteamer-packager-mac-path-validation.yLt7Sf/tests.log`.

The fresh `artifact-2` packaging attempt completed with exit 0. Its ZIP and three receipts were
copied into this vendor directory. The independent source-copy verification also passed
(`source-artifact-verify.log`: `LiveKit artifact verified`). The incomplete first assembly remains
unchanged and was not reused or overwritten. `COMPLETE.json` confirms the exact three slices,
the pinned official Mac manifest above and pinned `xcodebuild` executable SHA-256
`d508f0e1901151843804e4af512d4587ad0e422039e43e14abf22792360ad3d4`.

| Final artifact or receipt | SHA-256 |
| --- | --- |
| `LiveKitWebRTC.xcframework.zip` (24382900 bytes) | `1399ee6f9a34a6926d2abe9196c1361a40a7fbc9551becd5d13b15a73f510cf7` |
| `ARTIFACT_MANIFEST.json` | `5e86a03086dcf31d5499e08d2e122811c17a67949a8358809b9e5d0ecc8c33a5` |
| `SHA256SUMS` | `e52a44509606c8e7a785d5003d17a3e5d8a7ffbb953c992f26f2913de3fd0ff2` |
| `COMPLETE.json` | `9298790b3937931d043f4b8c6dd4f5ee736cd07625c896f1973765e6778b872b` |
| Device arm64 executable | `bc0173ff0e402a44135c23e39f750d05ca2cbb98b7ec3ee14658e1276461e011` |
| Simulator arm64 executable | `89ad833585353cc20f8bad3272170a574c0ae4c7dea433c8abd45ff2b53d2abe` |

Device Mach-O UUID: `4C4C4416-5555-3144-A18C-FA4B2C749144`.
Simulator Mach-O UUID: `4C4C4407-5555-3144-A198-838713A58FEE`.
The guarded release now pins these archive bytes; the current app build number is 65.

Pending: guarded archive/export/upload and physical audio verification. No SDK repository/release
was published, no package cache was
substituted, and this packaging work did not change an installed app.
