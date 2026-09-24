#!/bin/zsh
# Bind a live Mac host process to release-sealed executable and media-framework identity.
set -euo pipefail
umask 077

readonly SCRIPT_DIR=${0:A:h}
readonly LIVE_PROCESS_VERIFIER="${SCRIPT_DIR}/verify-live-mac-host-process.sh"
readonly BUNDLE_VERIFIER="${SCRIPT_DIR}/verify-mac-host-bundle.sh"
readonly EXPECTED_TEAM_ID='MSMG8CJLB3'
readonly EXPECTED_EXECUTABLE_IDENTIFIER='com.elamin.AudioStreamer.CaptureServer'
readonly EXPECTED_FRAMEWORK_IDENTIFIER='io.livekit.LiveKitWebRTC'

fail() {
    print -u2 -- "verify-sealed-live-mac-host-identity: $*"
    exit 1
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '
        {
            candidate=substr($0, 1, 64)
            separator=substr($0, 65, 2)
            if (length(candidate) == 64 && candidate ~ /^[0-9a-f]+$/ &&
                separator ~ /^[[:space:]][ *]$/) {
                value=candidate
                count++
            }
        }
        END { if (count != 1) exit 1; print value }
    '
}

unique_code_field() {
    local metadata=$1
    local field=$2
    print -r -- "$metadata" | /usr/bin/awk -F= -v field="$field" '
        $1 == field {
            value=substr($0, index($0, "=") + 1)
            count++
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    '
}

static_code_identity() {
    local executable=$1
    local expected_cdhash=$2
    local expected_identifier=$3
    local expected_team=$4
    local label=$5
    local metadata cdhash identifier team

    /usr/bin/codesign --verify --strict --all-architectures "$executable" \
        >/dev/null 2>&1 || fail "$label failed static code-signature validation"
    metadata=$(/usr/bin/codesign --display --verbose=4 "$executable" 2>&1) \
        || fail "$label code-signature metadata is unavailable"
    cdhash=$(unique_code_field "$metadata" CDHash) \
        || fail "$label CDHash is missing or duplicated"
    identifier=$(unique_code_field "$metadata" Identifier) \
        || fail "$label code identifier is missing or duplicated"
    team=$(unique_code_field "$metadata" TeamIdentifier) \
        || fail "$label TeamIdentifier is missing or duplicated"
    [[ "${cdhash:l}" == "$expected_cdhash" ]] \
        || fail "$label CDHash does not match the sealed identity"
    [[ "$identifier" == "$expected_identifier" ]] \
        || fail "$label code identifier does not match the sealed identity"
    [[ "$team" == "$expected_team" ]] \
        || fail "$label TeamIdentifier does not match the sealed identity"
}

live_executable_vnode() {
    local pid=$1
    local expected=$2
    local capture=$3
    local error=$4
    local expected_device_decimal expected_device expected_inode expected_identity
    local identities

    expected_device_decimal=$(/usr/bin/stat -f '%d' "$expected") \
        || fail "could not inspect expected executable device"
    expected_device=$(/usr/bin/printf '0x%x' "$expected_device_decimal")
    expected_inode=$(/usr/bin/stat -f '%i' "$expected") \
        || fail "could not inspect expected executable inode"
    expected_identity="${expected_device:l}:${expected_inode}"
    if ! /usr/sbin/lsof -a -p "$pid" -d txt -FDin >"$capture" 2>"$error"; then
        fail "lsof could not inspect the live executable vnode"
    fi
    identities=$(/usr/bin/awk -v expected="$expected" '
        /^f/ { device=""; inode="" }
        /^D/ { device=tolower(substr($0,2)) }
        /^i/ { inode=substr($0,2) }
        /^n/ {
            path=substr($0,2)
            if (path == expected || path == expected " (deleted)") {
                print device ":" inode
            }
        }
    ' "$capture" | LC_ALL=C /usr/bin/sort -u)
    [[ "$(print -r -- "$identities" | /usr/bin/sed '/^$/d' \
        | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')" == 1 \
        && "$identities" == "$expected_identity" ]] \
        || fail "live executable vnode does not match the sealed on-disk executable"
    print -r -- "$expected_identity"
}

if (( $# != 7 )); then
    print -u2 -- \
        "usage: $0 <sealed-manifest> <sealed-manifest-sha256-sidecar> <externally-transported-manifest-sha256> <pid> <required-executable> <required-media-framework-executable> <installed-app-or-dash>"
    exit 64
fi

readonly MANIFEST_INPUT=${1%/}
readonly MANIFEST_SHA256_INPUT=${2%/}
readonly EXPECTED_MANIFEST_SHA256=$3
readonly PID=$4
readonly REQUIRED_EXECUTABLE=${5%/}
readonly REQUIRED_FRAMEWORK_EXECUTABLE=${6%/}
readonly INSTALLED_APP=${7%/}

[[ "$EXPECTED_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "expected manifest SHA-256 must be 64 lowercase hexadecimal characters"
[[ "$PID" =~ ^[1-9][0-9]*$ ]] || fail "PID must be a positive integer"
[[ -n "$MANIFEST_INPUT" && "$MANIFEST_INPUT" == /* \
    && "${MANIFEST_INPUT:a}" == "$MANIFEST_INPUT" \
    && "${MANIFEST_INPUT:A}" == "$MANIFEST_INPUT" \
    && -f "$MANIFEST_INPUT" && ! -L "$MANIFEST_INPUT" ]] \
    || fail \
        "sealed manifest must be an existing absolute physically canonical regular file with no symlinked ancestors"
[[ -n "$MANIFEST_SHA256_INPUT" && "$MANIFEST_SHA256_INPUT" == /* \
    && "${MANIFEST_SHA256_INPUT:a}" == "$MANIFEST_SHA256_INPUT" \
    && "${MANIFEST_SHA256_INPUT:A}" == "$MANIFEST_SHA256_INPUT" \
    && -f "$MANIFEST_SHA256_INPUT" && ! -L "$MANIFEST_SHA256_INPUT" ]] \
    || fail \
        "sealed manifest SHA-256 sidecar must be an existing absolute physically canonical regular file with no symlinked ancestors"
[[ "$MANIFEST_SHA256_INPUT" == "${MANIFEST_INPUT}.sha256" ]] \
    || fail "sealed manifest SHA-256 sidecar must be the adjacent commit marker"
[[ "$(/usr/bin/stat -f '%u' "$MANIFEST_INPUT")" == "$EUID" \
    && "$(/usr/bin/stat -f '%Lp' "$MANIFEST_INPUT")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$MANIFEST_INPUT")" == 1 ]] \
    || fail "sealed manifest must be owner-owned mode 0600 with one hard link"
[[ "$(/usr/bin/stat -f '%u' "$MANIFEST_SHA256_INPUT")" == "$EUID" \
    && "$(/usr/bin/stat -f '%Lp' "$MANIFEST_SHA256_INPUT")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$MANIFEST_SHA256_INPUT")" == 1 ]] \
    || fail "sealed manifest SHA-256 sidecar must be owner-owned mode 0600 with one hard link"
manifest_size=$(/usr/bin/stat -f '%z' "$MANIFEST_INPUT") \
    || fail "sealed manifest size is unavailable"
[[ "$manifest_size" =~ ^[0-9]+$ ]] && (( manifest_size >= 256 && manifest_size <= 8192 )) \
    || fail "sealed manifest size is outside the reviewed bounds"
[[ "$(/usr/bin/stat -f '%z' "$MANIFEST_SHA256_INPUT")" == 65 ]] \
    || fail "sealed manifest SHA-256 sidecar must contain exactly 65 bytes"

readonly TEMP_ROOT=$(/usr/bin/mktemp -d /private/var/tmp/opensteamer-sealed-live-host.XXXXXX) \
    || fail "could not create private verifier state"
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT
[[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" \
    && "${TEMP_ROOT:a}" == "$TEMP_ROOT" && "${TEMP_ROOT:A}" == "$TEMP_ROOT" \
    && "$(/usr/bin/stat -f '%u:%Lp' "$TEMP_ROOT")" == "$EUID:700" ]] \
    || fail "private verifier state is unsafe"
readonly MANIFEST_SNAPSHOT="${TEMP_ROOT}/sealed-manifest.json"
readonly SIDECAR_SNAPSHOT="${TEMP_ROOT}/sealed-manifest.json.sha256"
readonly MANIFEST_SOURCE_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
    "$MANIFEST_INPUT") || fail "sealed manifest source identity is unavailable"
readonly SIDECAR_SOURCE_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
    "$MANIFEST_SHA256_INPUT") || fail "sealed manifest sidecar source identity is unavailable"

# Copy each externally supplied source exactly once into private verifier-owned storage. Every
# parser below reads only these pinned snapshots. Source identities are bracketed here and then
# identities plus hashes are rechecked after all live-host verification completes.
/bin/cat "$MANIFEST_SHA256_INPUT" >"$SIDECAR_SNAPSHOT" \
    || fail "could not pin the sealed manifest SHA-256 sidecar"
/bin/cat "$MANIFEST_INPUT" >"$MANIFEST_SNAPSHOT" \
    || fail "could not pin the sealed manifest"
[[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' "$MANIFEST_INPUT")" \
        == "$MANIFEST_SOURCE_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' "$MANIFEST_SHA256_INPUT")" \
        == "$SIDECAR_SOURCE_IDENTITY_BEFORE" ]] \
    || fail "sealed manifest publication changed while it was being pinned"
[[ -f "$MANIFEST_SNAPSHOT" && ! -L "$MANIFEST_SNAPSHOT" \
    && "$(/usr/bin/stat -f '%u:%Lp:%l:%z' "$MANIFEST_SNAPSHOT")" \
        == "$EUID:600:1:$manifest_size" \
    && -f "$SIDECAR_SNAPSHOT" && ! -L "$SIDECAR_SNAPSHOT" \
    && "$(/usr/bin/stat -f '%u:%Lp:%l:%z' "$SIDECAR_SNAPSHOT")" \
        == "$EUID:600:1:65" ]] \
    || fail "private sealed-manifest snapshots are unsafe"
/usr/bin/printf '%s\n' "$EXPECTED_MANIFEST_SHA256" \
    | /usr/bin/cmp -s - "$SIDECAR_SNAPSHOT" \
    || fail "sealed manifest SHA-256 sidecar does not match the externally supplied digest"
readonly MANIFEST_SHA256_BEFORE=$(sha256_file "$MANIFEST_SNAPSHOT") \
    || fail "sealed manifest snapshot SHA-256 is unavailable"
readonly SIDECAR_SHA256_BEFORE=$(sha256_file "$SIDECAR_SNAPSHOT") \
    || fail "sealed manifest sidecar snapshot SHA-256 is unavailable"
[[ "$MANIFEST_SHA256_BEFORE" == "$EXPECTED_MANIFEST_SHA256" ]] \
    || fail "sealed manifest SHA-256 does not match the externally supplied digest"

# Streaming validation rejects duplicate fields before ordinary jq object access could collapse
# them. The manifest digest is supplied independently by the release-candidate workflow; this
# verifier never derives expected identity from the installed host it is examining.
/usr/bin/jq --stream -c . "$MANIFEST_SNAPSHOT" | /usr/bin/jq -e -s '
    [ .[] | select(length == 2) | .[0] ] as $paths
    | ($paths | length) == 11
      and ($paths | all(length == 1))
      and (($paths | map(.[0]) | sort) == [
        "executableCDHash", "executableIdentifier", "executablePath",
        "executableSHA256", "executableTeamIdentifier",
        "mediaFrameworkExecutableCDHash", "mediaFrameworkExecutableIdentifier",
        "mediaFrameworkExecutablePath", "mediaFrameworkExecutableSHA256",
        "mediaFrameworkExecutableTeamIdentifier", "schema"
      ])
' >/dev/null \
    || fail "sealed manifest contains duplicate, nested, missing, or unknown fields"
jq -e '
    type == "object" and
    (keys == [
      "executableCDHash", "executableIdentifier", "executablePath",
      "executableSHA256", "executableTeamIdentifier",
      "mediaFrameworkExecutableCDHash", "mediaFrameworkExecutableIdentifier",
      "mediaFrameworkExecutablePath", "mediaFrameworkExecutableSHA256",
      "mediaFrameworkExecutableTeamIdentifier", "schema"
    ]) and
    .schema == "opensteamer.sealed-live-mac-host-identity.v1" and
    all(.[]; type == "string")
' "$MANIFEST_SNAPSHOT" >/dev/null \
    || fail "sealed manifest schema is invalid"

readonly EXECUTABLE_PATH=$(/usr/bin/jq -er '.executablePath' "$MANIFEST_SNAPSHOT")
readonly EXECUTABLE_SHA256=$(/usr/bin/jq -er '.executableSHA256' "$MANIFEST_SNAPSHOT")
readonly EXECUTABLE_CDHASH=$(/usr/bin/jq -er '.executableCDHash' "$MANIFEST_SNAPSHOT")
readonly EXECUTABLE_IDENTIFIER=$(/usr/bin/jq -er '.executableIdentifier' "$MANIFEST_SNAPSHOT")
readonly EXECUTABLE_TEAM=$(/usr/bin/jq -er '.executableTeamIdentifier' "$MANIFEST_SNAPSHOT")
readonly FRAMEWORK_PATH=$(/usr/bin/jq -er '.mediaFrameworkExecutablePath' "$MANIFEST_SNAPSHOT")
readonly FRAMEWORK_SHA256=$(/usr/bin/jq -er '.mediaFrameworkExecutableSHA256' "$MANIFEST_SNAPSHOT")
readonly FRAMEWORK_CDHASH=$(/usr/bin/jq -er '.mediaFrameworkExecutableCDHash' "$MANIFEST_SNAPSHOT")
readonly FRAMEWORK_IDENTIFIER=$(/usr/bin/jq -er '.mediaFrameworkExecutableIdentifier' "$MANIFEST_SNAPSHOT")
readonly FRAMEWORK_TEAM=$(/usr/bin/jq -er '.mediaFrameworkExecutableTeamIdentifier' "$MANIFEST_SNAPSHOT")

[[ "$EXECUTABLE_PATH" == "$REQUIRED_EXECUTABLE" \
    && "$FRAMEWORK_PATH" == "$REQUIRED_FRAMEWORK_EXECUTABLE" ]] \
    || fail "sealed manifest paths do not match the runner's fixed host paths"
[[ "$EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ \
    && "$FRAMEWORK_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "sealed executable SHA-256 values are malformed"
[[ "$EXECUTABLE_CDHASH" =~ ^[0-9a-f]{40}$ \
    && "$FRAMEWORK_CDHASH" =~ ^[0-9a-f]{40}$ ]] \
    || fail "sealed CDHash values are malformed"
[[ "$EXECUTABLE_IDENTIFIER" == "$EXPECTED_EXECUTABLE_IDENTIFIER" \
    && "$FRAMEWORK_IDENTIFIER" == "$EXPECTED_FRAMEWORK_IDENTIFIER" ]] \
    || fail "sealed code identifiers do not match the fixed production identities"
[[ "$EXECUTABLE_TEAM" == "$EXPECTED_TEAM_ID" \
    && "$FRAMEWORK_TEAM" == "$EXPECTED_TEAM_ID" ]] \
    || fail "sealed TeamIdentifier values do not match the fixed production team"

[[ -f "$EXECUTABLE_PATH" && ! -L "$EXECUTABLE_PATH" \
    && -x "$EXECUTABLE_PATH" ]] \
    || fail "sealed host executable path is unavailable"
if [[ -L "$FRAMEWORK_PATH" ]]; then
    [[ "$FRAMEWORK_PATH" == */LiveKitWebRTC.framework/LiveKitWebRTC ]] \
        || fail "only the reviewed media-framework executable alias may be a symlink"
fi
readonly FRAMEWORK_RESOLVED=${FRAMEWORK_PATH:A}
[[ -f "$FRAMEWORK_RESOLVED" && ! -L "$FRAMEWORK_RESOLVED" \
    && -x "$FRAMEWORK_RESOLVED" ]] \
    || fail "sealed media-framework executable path is unavailable"

readonly EXECUTABLE_FILE_IDENTITY_BEFORE="$(/usr/bin/stat -f '%d:%i' "$EXECUTABLE_PATH")"
readonly FRAMEWORK_FILE_IDENTITY_BEFORE="$(/usr/bin/stat -f '%d:%i' "$FRAMEWORK_RESOLVED")"
readonly EXECUTABLE_ACTUAL_SHA256=$(sha256_file "$EXECUTABLE_PATH") \
    || fail "host executable SHA-256 is unavailable"
readonly FRAMEWORK_ACTUAL_SHA256=$(sha256_file "$FRAMEWORK_RESOLVED") \
    || fail "media-framework executable SHA-256 is unavailable"
[[ "$EXECUTABLE_ACTUAL_SHA256" == "$EXECUTABLE_SHA256" ]] \
    || fail "host executable SHA-256 does not match the sealed identity"
[[ "$FRAMEWORK_ACTUAL_SHA256" == "$FRAMEWORK_SHA256" ]] \
    || fail "media-framework executable SHA-256 does not match the sealed identity"
static_code_identity "$EXECUTABLE_PATH" "$EXECUTABLE_CDHASH" \
    "$EXPECTED_EXECUTABLE_IDENTIFIER" "$EXPECTED_TEAM_ID" "host executable"
static_code_identity "$FRAMEWORK_RESOLVED" "$FRAMEWORK_CDHASH" \
    "$EXPECTED_FRAMEWORK_IDENTIFIER" "$EXPECTED_TEAM_ID" "media-framework executable"

readonly BUNDLE_OUTPUT="${TEMP_ROOT}/bundle.stdout"
readonly BUNDLE_ERROR="${TEMP_ROOT}/bundle.stderr"
readonly LIVE_OUTPUT="${TEMP_ROOT}/live.stdout"
readonly LIVE_ERROR="${TEMP_ROOT}/live.stderr"
readonly VNODE_CAPTURE="${TEMP_ROOT}/vnode.stdout"
readonly VNODE_ERROR="${TEMP_ROOT}/vnode.stderr"

bundle_verified=false
if [[ "$INSTALLED_APP" != - ]]; then
    [[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] \
        || fail "installed host app is unavailable"
    [[ -f "$BUNDLE_VERIFIER" && ! -L "$BUNDLE_VERIFIER" ]] \
        || fail "reviewed host-bundle verifier is unavailable"
    if ! /bin/zsh "$BUNDLE_VERIFIER" --installed-runtime \
        "$INSTALLED_APP" "$EXPECTED_TEAM_ID" >"$BUNDLE_OUTPUT" 2>"$BUNDLE_ERROR"; then
        fail "reviewed installed host-bundle verification failed"
    fi
    bundle_verified=true
fi

[[ -f "$LIVE_PROCESS_VERIFIER" && ! -L "$LIVE_PROCESS_VERIFIER" ]] \
    || fail "reviewed live-process verifier is unavailable"
readonly LIVE_EXECUTABLE_VNODE_BEFORE=$(live_executable_vnode \
    "$PID" "$EXECUTABLE_PATH" "$VNODE_CAPTURE" "$VNODE_ERROR")
if ! /bin/zsh "$LIVE_PROCESS_VERIFIER" "$PID" "$EXECUTABLE_PATH" \
    "$EXECUTABLE_CDHASH" "$EXPECTED_EXECUTABLE_IDENTIFIER" "$EXPECTED_TEAM_ID" \
    "$FRAMEWORK_PATH" >"$LIVE_OUTPUT" 2>"$LIVE_ERROR"; then
    fail "reviewed live-process verification rejected the sealed host identity"
fi
readonly LIVE_EXECUTABLE_VNODE_AFTER=$(live_executable_vnode \
    "$PID" "$EXECUTABLE_PATH" "$VNODE_CAPTURE" "$VNODE_ERROR")
[[ "$LIVE_EXECUTABLE_VNODE_AFTER" == "$LIVE_EXECUTABLE_VNODE_BEFORE" ]] \
    || fail "live executable vnode changed during verification"

readonly MANIFEST_SOURCE_SHA256_AFTER=$(sha256_file "$MANIFEST_INPUT") \
    || fail "sealed manifest source SHA-256 disappeared during verification"
readonly SIDECAR_SOURCE_SHA256_AFTER=$(sha256_file "$MANIFEST_SHA256_INPUT") \
    || fail "sealed manifest sidecar source SHA-256 disappeared during verification"
readonly MANIFEST_SNAPSHOT_SHA256_AFTER=$(sha256_file "$MANIFEST_SNAPSHOT") \
    || fail "sealed manifest snapshot SHA-256 disappeared during verification"
readonly SIDECAR_SNAPSHOT_SHA256_AFTER=$(sha256_file "$SIDECAR_SNAPSHOT") \
    || fail "sealed manifest sidecar snapshot SHA-256 disappeared during verification"
readonly EXECUTABLE_SHA256_AFTER=$(sha256_file "$EXECUTABLE_PATH") \
    || fail "host executable SHA-256 disappeared during verification"
readonly FRAMEWORK_SHA256_AFTER=$(sha256_file "$FRAMEWORK_RESOLVED") \
    || fail "media-framework executable SHA-256 disappeared during verification"
[[ "$MANIFEST_SOURCE_SHA256_AFTER" == "$MANIFEST_SHA256_BEFORE" \
    && "$SIDECAR_SOURCE_SHA256_AFTER" == "$SIDECAR_SHA256_BEFORE" \
    && "$MANIFEST_SNAPSHOT_SHA256_AFTER" == "$MANIFEST_SHA256_BEFORE" \
    && "$SIDECAR_SNAPSHOT_SHA256_AFTER" == "$SIDECAR_SHA256_BEFORE" \
    && -f "$MANIFEST_INPUT" && ! -L "$MANIFEST_INPUT" \
    && "${MANIFEST_INPUT:a}" == "$MANIFEST_INPUT" \
    && "${MANIFEST_INPUT:A}" == "$MANIFEST_INPUT" \
    && -f "$MANIFEST_SHA256_INPUT" && ! -L "$MANIFEST_SHA256_INPUT" \
    && "${MANIFEST_SHA256_INPUT:a}" == "$MANIFEST_SHA256_INPUT" \
    && "${MANIFEST_SHA256_INPUT:A}" == "$MANIFEST_SHA256_INPUT" \
    && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' "$MANIFEST_INPUT")" \
        == "$MANIFEST_SOURCE_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' "$MANIFEST_SHA256_INPUT")" \
        == "$SIDECAR_SOURCE_IDENTITY_BEFORE" \
    && "$EXECUTABLE_SHA256_AFTER" == "$EXECUTABLE_SHA256" \
    && "$FRAMEWORK_SHA256_AFTER" == "$FRAMEWORK_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i' "$EXECUTABLE_PATH")" \
        == "$EXECUTABLE_FILE_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i' "$FRAMEWORK_RESOLVED")" \
        == "$FRAMEWORK_FILE_IDENTITY_BEFORE" \
    && "${FRAMEWORK_PATH:A}" == "$FRAMEWORK_RESOLVED" ]] \
    || fail "sealed host artifacts changed during verification"

print -r -- "manifest_sha256=$MANIFEST_SHA256_BEFORE"
print -r -- "executable_sha256=$EXECUTABLE_SHA256"
print -r -- "executable_cdhash=$EXECUTABLE_CDHASH"
print -r -- "live_executable_vnode=$LIVE_EXECUTABLE_VNODE_AFTER"
print -r -- "media_framework_sha256=$FRAMEWORK_SHA256"
print -r -- "media_framework_cdhash=$FRAMEWORK_CDHASH"
print -r -- "installed_bundle_verified=$bundle_verified"
/bin/cat "$LIVE_OUTPUT"
