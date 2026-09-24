#!/bin/zsh
# Publish the release-sealed identity that later binds a visual oracle to the installed Mac host.
set -euo pipefail
umask 077

readonly SCRIPT_DIR=${0:A:h}
readonly BUNDLE_VERIFIER="${SCRIPT_DIR}/verify-mac-host-bundle.sh"
readonly EXPECTED_TEAM_ID='MSMG8CJLB3'
readonly INSTALLED_EXECUTABLE_PATH='/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer'
readonly INSTALLED_FRAMEWORK_EXECUTABLE_PATH='/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC'
readonly MANIFEST_BASENAME='sealed-live-mac-host-identity.json'
readonly SIDECAR_BASENAME='sealed-live-mac-host-identity.json.sha256'

fail() {
    print -u2 -- "create-sealed-mac-host-identity-manifest: $*"
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

read_static_code_identity() {
    local target=$1
    local label=$2
    local metadata

    /usr/bin/codesign --verify --strict --all-architectures "$target" \
        >/dev/null 2>&1 || fail "$label failed strict code-signature validation"
    metadata=$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1) \
        || fail "$label code-signature metadata is unavailable"
    CODE_CDHASH=$(unique_code_field "$metadata" CDHash) \
        || fail "$label CDHash is missing or duplicated"
    CODE_IDENTIFIER=$(unique_code_field "$metadata" Identifier) \
        || fail "$label identifier is missing or duplicated"
    CODE_TEAM=$(unique_code_field "$metadata" TeamIdentifier) \
        || fail "$label TeamIdentifier is missing or duplicated"
    CODE_CDHASH=${CODE_CDHASH:l}
    [[ "$CODE_CDHASH" =~ ^[0-9a-f]{40}$ ]] \
        || fail "$label CDHash is malformed"
    [[ "$CODE_IDENTIFIER" =~ ^[A-Za-z0-9.-]+$ ]] \
        || fail "$label identifier is malformed"
    [[ "$CODE_TEAM" == 'not set' || "$CODE_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "$label TeamIdentifier is malformed"
}

assert_private_regular_file() {
    local target=$1
    local label=$2
    [[ -f "$target" && ! -L "$target" \
        && "${target:a}" == "$target" && "${target:A}" == "$target" ]] \
        || fail "$label is not a canonical regular file"
    [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$target")" == "$EUID:600:1" ]] \
        || fail "$label must be owner-owned mode 0600 with one hard link"
    [[ -z "$(/usr/bin/xattr "$target" 2>/dev/null)" ]] \
        || fail "$label contains extended attributes"
}

publish_exclusive() {
    local staged=$1
    local destination=$2
    local label=$3
    local staged_identity

    assert_private_regular_file "$staged" "staged $label"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || fail "$label destination already exists"
    staged_identity=$(/usr/bin/stat -f '%d:%i' "$staged") \
        || fail "could not capture staged $label identity"

    # link(2) is an exclusive same-filesystem publication primitive: it cannot replace a raced
    # destination. Removing the private staging name leaves the published file with one link.
    /bin/ln "$staged" "$destination" || fail "could not publish $label exclusively"
    [[ -f "$destination" && ! -L "$destination" \
        && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$destination")" \
            == "$staged_identity:$EUID:600:2" ]] \
        || fail "published $label identity is unsafe"
    /bin/rm "$staged" || fail "could not retire staged $label name"
    assert_private_regular_file "$destination" "published $label"
    [[ "$(/usr/bin/stat -f '%d:%i' "$destination")" == "$staged_identity" ]] \
        || fail "published $label identity changed"
}

if (( $# != 4 )); then
    print -u2 -- \
        "usage: $0 <signed-candidate-opensteamer-host.app> <trusted-predecessor-designated-requirement-reference-code> <trusted-predecessor-reference-sha256> <existing-private-output-directory>"
    exit 64
fi

readonly APP_INPUT=${1%/}
readonly DESIGNATED_REQUIREMENT_REFERENCE=${2%/}
readonly EXPECTED_REFERENCE_SHA256=$3
readonly OUTPUT_INPUT=${4%/}
[[ "$EXPECTED_REFERENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || fail "trusted predecessor reference SHA-256 must be 64 lowercase hexadecimal characters"
[[ -n "$APP_INPUT" && "$APP_INPUT" == /* \
    && "${APP_INPUT:a}" == "$APP_INPUT" && "${APP_INPUT:A}" == "$APP_INPUT" \
    && -d "$APP_INPUT" && ! -L "$APP_INPUT" ]] \
    || fail "candidate app must be an existing canonical absolute real directory"
[[ -n "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && "$DESIGNATED_REQUIREMENT_REFERENCE" == /* \
    && "${DESIGNATED_REQUIREMENT_REFERENCE:a}" == "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && "${DESIGNATED_REQUIREMENT_REFERENCE:A}" == "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && -f "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && ! -L "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && -x "$DESIGNATED_REQUIREMENT_REFERENCE" \
    && "$(/usr/bin/stat -f '%u:%Lp:%l' "$DESIGNATED_REQUIREMENT_REFERENCE")" \
        == "$EUID:755:1" ]] \
    || fail "designated-requirement reference must be canonical, owner-owned, executable, mode 0755, and one-link"
REFERENCE_XATTRS=$(/usr/bin/xattr "$DESIGNATED_REQUIREMENT_REFERENCE" 2>/dev/null) \
    || fail "designated-requirement reference extended attributes are unreadable"
readonly REFERENCE_XATTRS
[[ -z "$REFERENCE_XATTRS" ]] \
    || fail "designated-requirement reference must be xattr-free"
[[ -n "$OUTPUT_INPUT" && "$OUTPUT_INPUT" == /* \
    && "${OUTPUT_INPUT:a}" == "$OUTPUT_INPUT" && "${OUTPUT_INPUT:A}" == "$OUTPUT_INPUT" \
    && -d "$OUTPUT_INPUT" && ! -L "$OUTPUT_INPUT" ]] \
    || fail "output directory must be an existing canonical absolute real directory"
[[ "$APP_INPUT" != *[[:cntrl:]]* \
    && "$DESIGNATED_REQUIREMENT_REFERENCE" != *[[:cntrl:]]* \
    && "$OUTPUT_INPUT" != *[[:cntrl:]]* ]] \
    || fail "candidate, reference, and output paths may not contain control characters"
[[ "$OUTPUT_INPUT" != "$APP_INPUT" && "$OUTPUT_INPUT" != "$APP_INPUT/"* ]] \
    || fail "output directory may not be inside the signed candidate app"
[[ "$(/usr/bin/stat -f '%u:%Lp' "$OUTPUT_INPUT")" == "$EUID:700" ]] \
    || fail "output directory must be owner-owned mode 0700"
OUTPUT_LISTING_MODE=$(/bin/ls -lde "$OUTPUT_INPUT" | /usr/bin/awk 'NR == 1 { print $1 }') \
    || fail "could not inspect output directory access controls"
readonly OUTPUT_LISTING_MODE
[[ "$OUTPUT_LISTING_MODE" != *+* ]] || fail "output directory must not have an ACL"
OUTPUT_DIRECTORY_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$OUTPUT_INPUT") \
    || fail "could not capture output directory identity"
readonly OUTPUT_DIRECTORY_IDENTITY

readonly MANIFEST_PATH="${OUTPUT_INPUT}/${MANIFEST_BASENAME}"
readonly SIDECAR_PATH="${OUTPUT_INPUT}/${SIDECAR_BASENAME}"
[[ ! -e "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" \
    && ! -e "$SIDECAR_PATH" && ! -L "$SIDECAR_PATH" ]] \
    || fail "manifest publication destinations must both be absent"

[[ -f "$BUNDLE_VERIFIER" && ! -L "$BUNDLE_VERIFIER" && -x "$BUNDLE_VERIFIER" ]] \
    || fail "reviewed candidate-bundle verifier is unavailable"
readonly CANDIDATE_EXECUTABLE="${APP_INPUT}/Contents/MacOS/CaptureServer"
readonly CANDIDATE_FRAMEWORK_ALIAS="${APP_INPUT}/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
readonly CANDIDATE_FRAMEWORK_EXECUTABLE=${CANDIDATE_FRAMEWORK_ALIAS:A}
[[ -f "$CANDIDATE_EXECUTABLE" && ! -L "$CANDIDATE_EXECUTABLE" \
    && -x "$CANDIDATE_EXECUTABLE" ]] \
    || fail "candidate host executable is unavailable"
[[ -L "$CANDIDATE_FRAMEWORK_ALIAS" \
    && -f "$CANDIDATE_FRAMEWORK_EXECUTABLE" \
    && ! -L "$CANDIDATE_FRAMEWORK_EXECUTABLE" \
    && -x "$CANDIDATE_FRAMEWORK_EXECUTABLE" ]] \
    || fail "candidate media-framework executable is unavailable"
[[ "$(/usr/bin/stat -f '%d:%i' "$DESIGNATED_REQUIREMENT_REFERENCE")" \
    != "$(/usr/bin/stat -f '%d:%i' "$CANDIDATE_EXECUTABLE")" ]] \
    || fail "designated-requirement reference must be independent of the candidate executable"
REFERENCE_SHA256=$(sha256_file "$DESIGNATED_REQUIREMENT_REFERENCE") \
    || fail "designated-requirement reference SHA-256 is unavailable"
readonly REFERENCE_SHA256
[[ "$REFERENCE_SHA256" == "$EXPECTED_REFERENCE_SHA256" ]] \
    || fail "designated-requirement reference SHA-256 does not match the trusted predecessor digest"

"$BUNDLE_VERIFIER" "$APP_INPUT" "$EXPECTED_TEAM_ID" \
    "$DESIGNATED_REQUIREMENT_REFERENCE" >/dev/null \
    || fail "candidate host bundle failed reviewed verification"
APP_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i' "$APP_INPUT") \
    || fail "candidate app identity is unavailable"
EXECUTABLE_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_EXECUTABLE") \
    || fail "candidate executable identity is unavailable"
FRAMEWORK_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_FRAMEWORK_EXECUTABLE") \
    || fail "candidate media-framework identity is unavailable"
REFERENCE_IDENTITY_BEFORE=$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
    "$DESIGNATED_REQUIREMENT_REFERENCE") \
    || fail "designated-requirement reference identity is unavailable"
EXECUTABLE_SHA256=$(sha256_file "$CANDIDATE_EXECUTABLE") \
    || fail "candidate host executable SHA-256 is unavailable"
FRAMEWORK_SHA256=$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE") \
    || fail "candidate media-framework executable SHA-256 is unavailable"
readonly APP_IDENTITY_BEFORE EXECUTABLE_IDENTITY_BEFORE FRAMEWORK_IDENTITY_BEFORE
readonly REFERENCE_IDENTITY_BEFORE
readonly EXECUTABLE_SHA256 FRAMEWORK_SHA256
[[ "$REFERENCE_SHA256" != "$EXECUTABLE_SHA256" ]] \
    || fail "designated-requirement reference must not be derived from the candidate executable"

read_static_code_identity "$CANDIDATE_EXECUTABLE" "candidate host executable"
readonly EXECUTABLE_CDHASH=$CODE_CDHASH
readonly EXECUTABLE_IDENTIFIER=$CODE_IDENTIFIER
readonly EXECUTABLE_TEAM=$CODE_TEAM
read_static_code_identity "$CANDIDATE_FRAMEWORK_EXECUTABLE" \
    "candidate media-framework executable"
readonly FRAMEWORK_CDHASH=$CODE_CDHASH
readonly FRAMEWORK_IDENTIFIER=$CODE_IDENTIFIER
readonly FRAMEWORK_TEAM=$CODE_TEAM
[[ "$EXECUTABLE_TEAM" == "$FRAMEWORK_TEAM" ]] \
    || fail "candidate executable and media framework TeamIdentifier values differ"
[[ "$EXECUTABLE_TEAM" == "$EXPECTED_TEAM_ID" ]] \
    || fail "candidate executable is not signed by the approved release team"

STAGED_MANIFEST=$(/usr/bin/mktemp "${OUTPUT_INPUT}/.sealed-live-mac-host-identity.manifest.XXXXXX") \
    || fail "could not create private staged manifest"
STAGED_SIDECAR=$(/usr/bin/mktemp "${OUTPUT_INPUT}/.sealed-live-mac-host-identity.sidecar.XXXXXX") \
    || fail "could not create private staged digest sidecar"
cleanup() {
    if [[ "${PUBLICATION_COMMITTED:-false}" != true ]]; then
        if [[ -n "${SIDECAR_PUBLICATION_IDENTITY:-}" \
            && -f "$SIDECAR_PATH" && ! -L "$SIDECAR_PATH" \
            && "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$SIDECAR_PATH" 2>/dev/null)" \
                == "$SIDECAR_PUBLICATION_IDENTITY:$EUID:600" ]]; then
            /bin/rm -f "$SIDECAR_PATH"
        fi
        if [[ -n "${MANIFEST_PUBLICATION_IDENTITY:-}" \
            && -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" \
            && "$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$MANIFEST_PATH" 2>/dev/null)" \
                == "$MANIFEST_PUBLICATION_IDENTITY:$EUID:600" ]]; then
            /bin/rm -f "$MANIFEST_PATH"
        fi
    fi
    [[ -n "${STAGED_MANIFEST:-}" && -e "$STAGED_MANIFEST" ]] \
        && /bin/rm -f "$STAGED_MANIFEST"
    [[ -n "${STAGED_SIDECAR:-}" && -e "$STAGED_SIDECAR" ]] \
        && /bin/rm -f "$STAGED_SIDECAR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

/usr/bin/jq -n -S \
    --arg schema 'opensteamer.sealed-live-mac-host-identity.v1' \
    --arg executablePath "$INSTALLED_EXECUTABLE_PATH" \
    --arg executableSHA256 "$EXECUTABLE_SHA256" \
    --arg executableCDHash "$EXECUTABLE_CDHASH" \
    --arg executableIdentifier "$EXECUTABLE_IDENTIFIER" \
    --arg executableTeamIdentifier "$EXECUTABLE_TEAM" \
    --arg mediaFrameworkExecutablePath "$INSTALLED_FRAMEWORK_EXECUTABLE_PATH" \
    --arg mediaFrameworkExecutableSHA256 "$FRAMEWORK_SHA256" \
    --arg mediaFrameworkExecutableCDHash "$FRAMEWORK_CDHASH" \
    --arg mediaFrameworkExecutableIdentifier "$FRAMEWORK_IDENTIFIER" \
    --arg mediaFrameworkExecutableTeamIdentifier "$FRAMEWORK_TEAM" \
    '{
        schema: $schema,
        executablePath: $executablePath,
        executableSHA256: $executableSHA256,
        executableCDHash: $executableCDHash,
        executableIdentifier: $executableIdentifier,
        executableTeamIdentifier: $executableTeamIdentifier,
        mediaFrameworkExecutablePath: $mediaFrameworkExecutablePath,
        mediaFrameworkExecutableSHA256: $mediaFrameworkExecutableSHA256,
        mediaFrameworkExecutableCDHash: $mediaFrameworkExecutableCDHash,
        mediaFrameworkExecutableIdentifier: $mediaFrameworkExecutableIdentifier,
        mediaFrameworkExecutableTeamIdentifier: $mediaFrameworkExecutableTeamIdentifier
    }' >"$STAGED_MANIFEST" || fail "could not render sealed identity manifest"
/bin/chmod 600 "$STAGED_MANIFEST" || fail "could not protect staged manifest"

/usr/bin/jq --stream -c . "$STAGED_MANIFEST" | /usr/bin/jq -e -s '
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
' >/dev/null || fail "rendered manifest field set is invalid"
/usr/bin/jq -e '
    type == "object" and
    (keys | length) == 11 and
    .schema == "opensteamer.sealed-live-mac-host-identity.v1" and
    all(.[]; type == "string")
' "$STAGED_MANIFEST" >/dev/null || fail "rendered manifest schema is invalid"
manifest_size=$(/usr/bin/stat -f '%z' "$STAGED_MANIFEST") \
    || fail "could not inspect staged manifest size"
[[ "$manifest_size" =~ ^[0-9]+$ ]] && (( manifest_size >= 256 && manifest_size <= 8192 )) \
    || fail "rendered manifest size is outside the reviewed bounds"
MANIFEST_SHA256=$(sha256_file "$STAGED_MANIFEST") \
    || fail "could not hash rendered manifest"
readonly MANIFEST_SHA256
/usr/bin/printf '%s\n' "$MANIFEST_SHA256" >"$STAGED_SIDECAR" \
    || fail "could not render digest sidecar"
/bin/chmod 600 "$STAGED_SIDECAR" || fail "could not protect staged digest sidecar"
[[ "$(/usr/bin/stat -f '%z' "$STAGED_SIDECAR")" == 65 \
    && "$(/usr/bin/tr -d '\n' <"$STAGED_SIDECAR")" == "$MANIFEST_SHA256" \
    && "$(/usr/bin/tail -c 1 "$STAGED_SIDECAR" | /usr/bin/od -An -tuC \
        | /usr/bin/tr -d '[:space:]')" == 10 ]] \
    || fail "rendered digest sidecar is malformed"
assert_private_regular_file "$STAGED_MANIFEST" "staged manifest"
assert_private_regular_file "$STAGED_SIDECAR" "staged digest sidecar"
MANIFEST_PUBLICATION_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$STAGED_MANIFEST") \
    || fail "could not retain staged manifest publication identity"
SIDECAR_PUBLICATION_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$STAGED_SIDECAR") \
    || fail "could not retain staged digest-sidecar publication identity"
readonly MANIFEST_PUBLICATION_IDENTITY SIDECAR_PUBLICATION_IDENTITY
PUBLICATION_COMMITTED=false

# Re-run the complete bundle verifier and byte/identity snapshots immediately before publication.
# Nothing is read from /Applications or any live process while creating this release seal.
"$BUNDLE_VERIFIER" "$APP_INPUT" "$EXPECTED_TEAM_ID" \
    "$DESIGNATED_REQUIREMENT_REFERENCE" >/dev/null \
    || fail "candidate host bundle changed during identity generation"
REFERENCE_XATTRS_CURRENT=$(/usr/bin/xattr "$DESIGNATED_REQUIREMENT_REFERENCE" 2>/dev/null) \
    || fail "designated-requirement reference extended attributes became unreadable"
[[ "$REFERENCE_XATTRS_CURRENT" == "$REFERENCE_XATTRS" ]] \
    || fail "designated-requirement reference extended attributes changed"
[[ "$(/usr/bin/stat -f '%d:%i' "$APP_INPUT")" == "$APP_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_EXECUTABLE")" \
        == "$EXECUTABLE_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_FRAMEWORK_EXECUTABLE")" \
        == "$FRAMEWORK_IDENTITY_BEFORE" \
    && "$(sha256_file "$CANDIDATE_EXECUTABLE")" == "$EXECUTABLE_SHA256" \
    && "$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE")" == "$FRAMEWORK_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
        "$DESIGNATED_REQUIREMENT_REFERENCE")" \
        == "$REFERENCE_IDENTITY_BEFORE" \
    && "$(sha256_file "$DESIGNATED_REQUIREMENT_REFERENCE")" == "$REFERENCE_SHA256" \
    && "${CANDIDATE_FRAMEWORK_ALIAS:A}" == "$CANDIDATE_FRAMEWORK_EXECUTABLE" ]] \
    || fail "candidate host artifacts changed during identity generation"
[[ "$(/usr/bin/stat -f '%d:%i' "$OUTPUT_INPUT")" == "$OUTPUT_DIRECTORY_IDENTITY" \
    && "$(/usr/bin/stat -f '%u:%Lp' "$OUTPUT_INPUT")" == "$EUID:700" \
    && ! -e "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" \
    && ! -e "$SIDECAR_PATH" && ! -L "$SIDECAR_PATH" ]] \
    || fail "output publication topology changed during identity generation"

publish_exclusive "$STAGED_MANIFEST" "$MANIFEST_PATH" manifest
STAGED_MANIFEST=''
# Revalidate the candidate after the manifest is visible but before publishing the commit marker.
# A missing sidecar keeps an interrupted or failed attempt uncommitted and unusable by the capsule.
"$BUNDLE_VERIFIER" "$APP_INPUT" "$EXPECTED_TEAM_ID" \
    "$DESIGNATED_REQUIREMENT_REFERENCE" >/dev/null \
    || fail "candidate host bundle changed before identity commit"
REFERENCE_XATTRS_CURRENT=$(/usr/bin/xattr "$DESIGNATED_REQUIREMENT_REFERENCE" 2>/dev/null) \
    || fail "designated-requirement reference extended attributes became unreadable"
[[ "$REFERENCE_XATTRS_CURRENT" == "$REFERENCE_XATTRS" ]] \
    || fail "designated-requirement reference extended attributes changed before identity commit"
[[ "$(/usr/bin/stat -f '%d:%i' "$APP_INPUT")" == "$APP_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_EXECUTABLE")" \
        == "$EXECUTABLE_IDENTITY_BEFORE" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$CANDIDATE_FRAMEWORK_EXECUTABLE")" \
        == "$FRAMEWORK_IDENTITY_BEFORE" \
    && "$(sha256_file "$CANDIDATE_EXECUTABLE")" == "$EXECUTABLE_SHA256" \
    && "$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE")" == "$FRAMEWORK_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%z' \
        "$DESIGNATED_REQUIREMENT_REFERENCE")" \
        == "$REFERENCE_IDENTITY_BEFORE" \
    && "$(sha256_file "$DESIGNATED_REQUIREMENT_REFERENCE")" == "$REFERENCE_SHA256" \
    && "$(sha256_file "$MANIFEST_PATH")" == "$MANIFEST_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i' "$OUTPUT_INPUT")" == "$OUTPUT_DIRECTORY_IDENTITY" \
    && "$(/usr/bin/stat -f '%u:%Lp' "$OUTPUT_INPUT")" == "$EUID:700" \
    && "$(/bin/ls -lde "$OUTPUT_INPUT" | /usr/bin/awk 'NR == 1 { print $1 }')" \
        == "$OUTPUT_LISTING_MODE" \
    && ! -e "$SIDECAR_PATH" && ! -L "$SIDECAR_PATH" ]] \
    || fail "candidate or publication topology changed before identity commit"
# The sidecar is the transaction commit marker and is therefore published last and exclusively.
publish_exclusive "$STAGED_SIDECAR" "$SIDECAR_PATH" "digest sidecar"
STAGED_SIDECAR=''

[[ "$(sha256_file "$MANIFEST_PATH")" == "$MANIFEST_SHA256" \
    && "$(/usr/bin/tr -d '\n' <"$SIDECAR_PATH")" == "$MANIFEST_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i' "$OUTPUT_INPUT")" == "$OUTPUT_DIRECTORY_IDENTITY" ]] \
    || fail "published identity pair failed final verification"
PUBLICATION_COMMITTED=true

print -r -- "manifest_path=$MANIFEST_PATH"
print -r -- "manifest_sha256=$MANIFEST_SHA256"
print -r -- "manifest_sha256_path=$SIDECAR_PATH"
