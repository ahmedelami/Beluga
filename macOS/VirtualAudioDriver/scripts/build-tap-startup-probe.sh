#!/bin/zsh
set -euo pipefail
umask 077
if (( $# != 1 )) || [[ "$1" != /*/TapStartupProbe.app ]]; then
    print -u2 "usage: zsh $0 /absolute/new/output/TapStartupProbe.app"
    exit 64
fi
probe_output="$1"
if [[ -e "$probe_output" || -L "$probe_output" || ! -d "${probe_output:h}" || -L "${probe_output:h}" ]]; then
    print -u2 "refusing existing output or invalid output parent"
    exit 73
fi
probe_root="${0:A:h:h}"
probe_developer="/Applications/Xcode-26.6.0.app/Contents/Developer"
probe_sdk="$(DEVELOPER_DIR="$probe_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
/bin/mkdir -m 0700 "$probe_output"
/bin/mkdir -m 0700 "$probe_output/Contents" "$probe_output/Contents/MacOS"
# Build only this new diagnostic bundle. No production artifact, defaults, TCC, or host control.
DEVELOPER_DIR="$probe_developer" /usr/bin/xcrun --sdk macosx clang \
    -arch arm64 -arch x86_64 -isysroot "$probe_sdk" -mmacosx-version-min=14.2 \
    -std=c17 -fobjc-arc -O2 -Wall -Wextra -Werror \
    -I "$probe_root/include" "$probe_root/Probes/TapStartupProbe.m" \
    -framework Foundation -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
    -o "$probe_output/Contents/MacOS/TapStartupProbe"
/usr/bin/install -m 0600 "$probe_root/Probes/TapStartupProbe-Info.plist" "$probe_output/Contents/Info.plist"
/usr/bin/plutil -lint "$probe_output/Contents/Info.plist"
/usr/bin/codesign --sign - --timestamp=none --identifier com.elamin.opensteamer.TapStartupDiagnostic "$probe_output"
/usr/bin/codesign --verify --strict --all-architectures "$probe_output"
/usr/bin/lipo -archs "$probe_output/Contents/MacOS/TapStartupProbe"
/usr/bin/shasum -a 256 "$probe_output/Contents/MacOS/TapStartupProbe"
print "Built only; not launched. New bundle TCC authorization remains a separate live-run gate."
