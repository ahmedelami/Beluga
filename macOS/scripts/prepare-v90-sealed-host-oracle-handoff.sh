#!/bin/zsh

# Build and consume the V90-only, offline Mac-host identity handoff used by the
# production TestFlight screen oracle. This script never reads /Applications or
# a live process. `prepare` is single-use within a fresh V90 packaging capsule;
# `arm` accepts only the completed handoff commit marker.
set -euo pipefail
umask 077

readonly SCRIPT_DIR=${0:A:h}
readonly REPOSITORY_ROOT=${SCRIPT_DIR:h:h}
readonly IDENTITY_GENERATOR="${SCRIPT_DIR}/create-sealed-mac-host-identity-manifest.sh"
readonly SCREEN_ORACLE_ARMER="${REPOSITORY_ROOT}/iOS/opensteamer/scripts/arm-testflight-screen-visual-oracle.sh"
readonly EXPECTED_TEAM_ID='MSMG8CJLB3'
readonly EXPECTED_EXECUTABLE_IDENTIFIER='com.elamin.AudioStreamer.CaptureServer'
readonly EXPECTED_FRAMEWORK_IDENTIFIER='io.livekit.LiveKitWebRTC'
readonly USER_PROTECTED_RUNTIME_ROOT='/Users/ahmed/Library/Application Support/opensteamer'

readonly CAPSULE_METADATA_SCHEMA='opensteamer.v90-host-oracle-capsule-metadata.v1'
readonly HANDOFF_SCHEMA='opensteamer.v90-screen-oracle-host-identity-handoff.v1'
readonly OUTPUT_DIRECTORY_BASENAME='v90-screen-oracle-handoff'
readonly MANIFEST_BASENAME='sealed-live-mac-host-identity.json'
readonly MANIFEST_SIDECAR_BASENAME='sealed-live-mac-host-identity.json.sha256'
readonly HANDOFF_BASENAME='v90-screen-oracle-host-identity-handoff.json'
readonly HANDOFF_SIDECAR_BASENAME='v90-screen-oracle-host-identity-handoff.json.sha256'

fail() {
    print -u2 -- "prepare-v90-sealed-host-oracle-handoff: $*"
    exit 1
}

usage() {
    print -u2 -- \
        "usage: $0 prepare <trusted-v90-capsule-metadata.json> <external-metadata-sha256>"
    print -u2 -- \
        "       $0 arm <committed-handoff.json> <external-handoff-sha256> <coredevice-id> <hardware-udid> <testflight-build>"
    exit 64
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

assert_sha256() {
    local value=$1
    local label=$2
    [[ "$value" =~ '^[0-9a-f]{64}$' ]] || fail "$label is not a lowercase SHA-256"
}

assert_private_directory() {
    local target=$1
    local label=$2
    local listing_mode

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -d "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute real directory"
    [[ "$(/usr/bin/stat -f '%u:%Lp' "$target")" == "$EUID:700" ]] \
        || fail "$label must be owner-owned mode 0700"
    listing_mode=$(/bin/ls -lde "$target" | /usr/bin/awk 'NR == 1 { print $1 }') \
        || fail "$label access controls are unavailable"
    [[ "$listing_mode" != *+* ]] || fail "$label must not have an ACL"
}

assert_private_regular_file() {
    local target=$1
    local label=$2

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -f "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute regular file"
    [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$target")" == "$EUID:600:1" ]] \
        || fail "$label must be owner-owned mode 0600 with one hard link"
    [[ -z "$(/usr/bin/xattr "$target" 2>/dev/null)" ]] \
        || fail "$label contains extended attributes"
}

assert_capsule_code_file() {
    local target=$1
    local mode=$2
    local label=$3

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -f "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute regular file"
    [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$target")" == "$EUID:${mode}:1" ]] \
        || fail "$label must be owner-owned mode 0${mode} with one hard link"
}

assert_relative_capsule_path() {
    local value=$1
    local label=$2

    [[ -n "$value" && "$value" != /* && "$value" != *[[:cntrl:]]* \
        && "$value" != . && "$value" != .. \
        && "$value" != ./* && "$value" != ../* \
        && "$value" != */. && "$value" != */.. \
        && "$value" != */./* && "$value" != */../* \
        && "$value" != *//* && "$value" != */ ]] \
        || fail "$label must be a normalized relative capsule path"
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
    /bin/ln "$staged" "$destination" || fail "could not publish $label exclusively"
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$destination")" \
        == "$staged_identity:$EUID:600:2" ]] \
        || fail "published $label identity is unsafe"
    /bin/rm "$staged" || fail "could not retire staged $label name"
    assert_private_regular_file "$destination" "published $label"
    [[ "$(/usr/bin/stat -f '%d:%i' "$destination")" == "$staged_identity" ]] \
        || fail "published $label identity changed"
}

validate_capsule_metadata_shape() {
    local metadata=$1

    /usr/bin/jq --stream -c . "$metadata" | /usr/bin/jq -e -s '
        [ .[] | select(length == 2) | .[0] ] as $paths
        | ($paths | length) == 6
          and ($paths | all(length == 1))
          and (($paths | map(.[0]) | sort) == [
            "candidateAppRelativePath",
            "candidateExecutableSHA256",
            "candidateMediaFrameworkExecutableSHA256",
            "designatedRequirementReferenceRelativePath",
            "designatedRequirementReferenceSHA256",
            "schema"
          ])
    ' >/dev/null || fail "trusted capsule metadata has duplicate, nested, or unknown fields"
    /usr/bin/jq -e --arg schema "$CAPSULE_METADATA_SCHEMA" '
        type == "object" and
        (keys | length) == 6 and
        .schema == $schema and
        all(.[]; type == "string")
    ' "$metadata" >/dev/null || fail "trusted capsule metadata schema is invalid"
}

validate_identity_manifest() {
    local manifest=$1
    local executable_sha256=$2
    local framework_sha256=$3

    /usr/bin/jq --stream -c . "$manifest" | /usr/bin/jq -e -s '
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
    ' >/dev/null || fail "generated identity manifest has duplicate, nested, or unknown fields"
    /usr/bin/jq -e \
        --arg executableSHA256 "$executable_sha256" \
        --arg frameworkSHA256 "$framework_sha256" \
        --arg team "$EXPECTED_TEAM_ID" \
        --arg executableIdentifier "$EXPECTED_EXECUTABLE_IDENTIFIER" \
        --arg frameworkIdentifier "$EXPECTED_FRAMEWORK_IDENTIFIER" '
        type == "object" and
        (keys | length) == 11 and
        .schema == "opensteamer.sealed-live-mac-host-identity.v1" and
        all(.[]; type == "string") and
        .executablePath == "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer" and
        .mediaFrameworkExecutablePath == "/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" and
        .executableSHA256 == $executableSHA256 and
        .mediaFrameworkExecutableSHA256 == $frameworkSHA256 and
        .executableIdentifier == $executableIdentifier and
        .mediaFrameworkExecutableIdentifier == $frameworkIdentifier and
        .executableTeamIdentifier == $team and
        .mediaFrameworkExecutableTeamIdentifier == $team
    ' "$manifest" >/dev/null || fail "generated identity manifest does not match the pinned candidate"
}

validate_handoff_shape() {
    local handoff=$1

    /usr/bin/jq --stream -c . "$handoff" | /usr/bin/jq -e -s '
        [ .[] | select(length == 2) | .[0] ] as $paths
        | ($paths | length) == 11
          and ($paths | all(length == 1))
          and (($paths | map(.[0]) | sort) == [
            "candidateAppRelativePath",
            "candidateExecutableSHA256",
            "candidateMediaFrameworkExecutableSHA256",
            "capsuleMetadataSHA256",
            "designatedRequirementReferenceRelativePath",
            "designatedRequirementReferenceSHA256",
            "expectedTeamIdentifier",
            "hostIdentityManifestBasename",
            "hostIdentityManifestSHA256",
            "hostIdentityManifestSHA256Basename",
            "schema"
          ])
    ' >/dev/null || fail "handoff has duplicate, nested, or unknown fields"
    /usr/bin/jq -e \
        --arg schema "$HANDOFF_SCHEMA" \
        --arg team "$EXPECTED_TEAM_ID" \
        --arg manifest "$MANIFEST_BASENAME" \
        --arg sidecar "$MANIFEST_SIDECAR_BASENAME" '
        type == "object" and
        (keys | length) == 11 and
        .schema == $schema and
        all(.[]; type == "string") and
        .expectedTeamIdentifier == $team and
        .hostIdentityManifestBasename == $manifest and
        .hostIdentityManifestSHA256Basename == $sidecar
    ' "$handoff" >/dev/null || fail "handoff schema is invalid"
}

prepare_handoff() {
    (( $# == 2 )) || usage
    local metadata=${1%/}
    local expected_metadata_sha256=$2
    local capsule_root output_directory
    local metadata_identity capsule_root_identity metadata_size
    local candidate_relative candidate_executable_sha256
    local candidate_framework_sha256 reference_relative reference_sha256
    local candidate_app candidate_executable framework_alias framework_executable reference
    local candidate_app_identity candidate_executable_identity framework_identity reference_identity
    local manifest manifest_sidecar manifest_sha256 generator_output expected_generator_output
    local staged_handoff staged_handoff_sidecar handoff handoff_sidecar handoff_sha256
    local output_identity

    assert_sha256 "$expected_metadata_sha256" "external trusted-metadata digest"
    assert_private_regular_file "$metadata" "trusted capsule metadata"
    capsule_root=${metadata:h}
    assert_private_directory "$capsule_root" "V90 capsule root"
    [[ "$capsule_root" != "$USER_PROTECTED_RUNTIME_ROOT" \
        && "$capsule_root" != "$USER_PROTECTED_RUNTIME_ROOT/"* ]] \
        || fail "V90 capsule must be outside the user-protected runtime and retained evidence root"
    metadata_size=$(/usr/bin/stat -f '%z' "$metadata") \
        || fail "trusted capsule metadata size is unavailable"
    [[ "$metadata_size" =~ '^[0-9]+$' ]] \
        && (( metadata_size >= 256 && metadata_size <= 8192 )) \
        || fail "trusted capsule metadata size is outside the reviewed bounds"
    [[ "$(sha256_file "$metadata")" == "$expected_metadata_sha256" ]] \
        || fail "trusted capsule metadata does not match its external digest"
    validate_capsule_metadata_shape "$metadata"

    candidate_relative=$(/usr/bin/jq -er '.candidateAppRelativePath' "$metadata") \
        || fail "candidate app path is unavailable from trusted capsule metadata"
    candidate_executable_sha256=$(/usr/bin/jq -er '.candidateExecutableSHA256' "$metadata") \
        || fail "candidate executable digest is unavailable from trusted capsule metadata"
    candidate_framework_sha256=$(/usr/bin/jq -er \
        '.candidateMediaFrameworkExecutableSHA256' "$metadata") \
        || fail "candidate media-framework digest is unavailable from trusted capsule metadata"
    reference_relative=$(/usr/bin/jq -er \
        '.designatedRequirementReferenceRelativePath' "$metadata") \
        || fail "designated-requirement reference path is unavailable from trusted capsule metadata"
    reference_sha256=$(/usr/bin/jq -er \
        '.designatedRequirementReferenceSHA256' "$metadata") \
        || fail "designated-requirement reference digest is unavailable from trusted capsule metadata"
    assert_relative_capsule_path "$candidate_relative" "candidate app path"
    assert_relative_capsule_path "$reference_relative" "designated-requirement reference path"
    [[ "$candidate_relative" == *.app ]] || fail "candidate app path must end in .app"
    assert_sha256 "$candidate_executable_sha256" "pinned candidate executable digest"
    assert_sha256 "$candidate_framework_sha256" "pinned candidate media-framework digest"
    assert_sha256 "$reference_sha256" "pinned designated-requirement reference digest"

    candidate_app="${capsule_root}/${candidate_relative}"
    reference="${capsule_root}/${reference_relative}"
    [[ "$candidate_app" == "$capsule_root/"* \
        && "${candidate_app:a}" == "$candidate_app" \
        && "${candidate_app:A}" == "$candidate_app" \
        && -d "$candidate_app" && ! -L "$candidate_app" ]] \
        || fail "pinned candidate app is not a canonical real directory inside the capsule"
    [[ "$reference" == "$capsule_root/"* ]] \
        || fail "pinned designated-requirement reference escapes the capsule"
    [[ "$reference" != "$candidate_app" && "$reference" != "$candidate_app/"* ]] \
        || fail "pinned designated-requirement reference may not come from the candidate app"

    candidate_executable="${candidate_app}/Contents/MacOS/CaptureServer"
    framework_alias="${candidate_app}/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
    framework_executable=${framework_alias:A}
    assert_capsule_code_file "$candidate_executable" 755 "pinned candidate executable"
    [[ -L "$framework_alias" ]] \
        || fail "pinned candidate media-framework alias is not a symbolic link"
    assert_capsule_code_file "$framework_executable" 755 \
        "pinned candidate media-framework executable"
    assert_capsule_code_file "$reference" 755 \
        "pinned designated-requirement reference"
    [[ "$(sha256_file "$candidate_executable")" == "$candidate_executable_sha256" ]] \
        || fail "candidate executable does not match trusted capsule metadata"
    [[ "$(sha256_file "$framework_executable")" == "$candidate_framework_sha256" ]] \
        || fail "candidate media-framework executable does not match trusted capsule metadata"
    [[ "$(sha256_file "$reference")" == "$reference_sha256" ]] \
        || fail "designated-requirement reference does not match trusted capsule metadata"
    [[ "$reference_sha256" != "$candidate_executable_sha256" ]] \
        || fail "designated-requirement reference digest may not be candidate-derived"
    [[ "$(/usr/bin/stat -f '%d:%i' "$reference")" \
        != "$(/usr/bin/stat -f '%d:%i' "$candidate_executable")" ]] \
        || fail "designated-requirement reference aliases the candidate executable"

    [[ -f "$IDENTITY_GENERATOR" && ! -L "$IDENTITY_GENERATOR" \
        && -x "$IDENTITY_GENERATOR" ]] \
        || fail "reviewed identity generator is unavailable"
    metadata_identity=$(/usr/bin/stat -f '%d:%i:%z' "$metadata") \
        || fail "trusted capsule metadata identity is unavailable"
    capsule_root_identity=$(/usr/bin/stat -f '%d:%i' "$capsule_root") \
        || fail "V90 capsule-root identity is unavailable"
    candidate_app_identity=$(/usr/bin/stat -f '%d:%i' "$candidate_app") \
        || fail "candidate app identity is unavailable"
    candidate_executable_identity=$(/usr/bin/stat -f '%d:%i:%z' "$candidate_executable") \
        || fail "candidate executable identity is unavailable"
    framework_identity=$(/usr/bin/stat -f '%d:%i:%z' "$framework_executable") \
        || fail "candidate media-framework identity is unavailable"
    reference_identity=$(/usr/bin/stat -f '%d:%i:%z' "$reference") \
        || fail "designated-requirement reference identity is unavailable"

    output_directory="${capsule_root}/${OUTPUT_DIRECTORY_BASENAME}"
    [[ ! -e "$output_directory" && ! -L "$output_directory" ]] \
        || fail "V90 handoff output already exists; packaging preparation is single-use"
    /bin/mkdir -m 700 "$output_directory" \
        || fail "could not create the private V90 handoff output directory"
    assert_private_directory "$output_directory" "V90 handoff output directory"
    output_identity=$(/usr/bin/stat -f '%d:%i' "$output_directory") \
        || fail "V90 handoff output identity is unavailable"

    manifest="${output_directory}/${MANIFEST_BASENAME}"
    manifest_sidecar="${output_directory}/${MANIFEST_SIDECAR_BASENAME}"
    generator_output=$("$IDENTITY_GENERATOR" "$candidate_app" "$reference" \
        "$reference_sha256" "$output_directory") \
        || fail "candidate-specific identity generation failed"
    assert_private_regular_file "$manifest" "generated host-identity manifest"
    assert_private_regular_file "$manifest_sidecar" "generated host-identity digest sidecar"
    [[ "$(/usr/bin/stat -f '%z' "$manifest_sidecar")" == 65 \
        && "$(/usr/bin/tail -c 1 "$manifest_sidecar" | /usr/bin/od -An -tuC \
            | /usr/bin/tr -d '[:space:]')" == 10 ]] \
        || fail "generated host-identity digest sidecar is malformed"
    manifest_sha256=$(sha256_file "$manifest") \
        || fail "generated host-identity manifest digest is unavailable"
    [[ "$(/usr/bin/tr -d '\n' <"$manifest_sidecar")" == "$manifest_sha256" ]] \
        || fail "generated host-identity sidecar does not commit the manifest"
    validate_identity_manifest "$manifest" \
        "$candidate_executable_sha256" "$candidate_framework_sha256"
    expected_generator_output=$'manifest_path='"$manifest"$'\nmanifest_sha256='"$manifest_sha256"$'\nmanifest_sha256_path='"$manifest_sidecar"
    [[ "$generator_output" == "$expected_generator_output" ]] \
        || fail "identity generator returned an unexpected publication record"

    [[ "$(/usr/bin/stat -f '%d:%i:%z' "$metadata")" == "$metadata_identity" \
        && "$(sha256_file "$metadata")" == "$expected_metadata_sha256" \
        && "$(/usr/bin/stat -f '%d:%i' "$capsule_root")" == "$capsule_root_identity" \
        && "$(/usr/bin/stat -f '%d:%i' "$candidate_app")" == "$candidate_app_identity" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$candidate_executable")" \
            == "$candidate_executable_identity" \
        && "$(sha256_file "$candidate_executable")" == "$candidate_executable_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$framework_executable")" \
            == "$framework_identity" \
        && "$(sha256_file "$framework_executable")" == "$candidate_framework_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$reference")" == "$reference_identity" \
        && "$(sha256_file "$reference")" == "$reference_sha256" \
        && "$(/usr/bin/stat -f '%d:%i' "$output_directory")" == "$output_identity" ]] \
        || fail "trusted capsule inputs changed during identity generation"

    handoff="${output_directory}/${HANDOFF_BASENAME}"
    handoff_sidecar="${output_directory}/${HANDOFF_SIDECAR_BASENAME}"
    [[ ! -e "$handoff" && ! -L "$handoff" \
        && ! -e "$handoff_sidecar" && ! -L "$handoff_sidecar" ]] \
        || fail "V90 handoff publication destinations must be absent"
    staged_handoff=$(/usr/bin/mktemp "${output_directory}/.v90-host-handoff.XXXXXX") \
        || fail "could not create the staged V90 handoff"
    staged_handoff_sidecar=$(/usr/bin/mktemp \
        "${output_directory}/.v90-host-handoff-sidecar.XXXXXX") \
        || fail "could not create the staged V90 handoff commit marker"
    cleanup_staging() {
        [[ -n "${staged_handoff:-}" && -e "$staged_handoff" ]] \
            && /bin/rm -f "$staged_handoff"
        [[ -n "${staged_handoff_sidecar:-}" && -e "$staged_handoff_sidecar" ]] \
            && /bin/rm -f "$staged_handoff_sidecar"
    }
    trap cleanup_staging EXIT
    trap 'exit 1' HUP INT TERM

    /usr/bin/jq -n -S \
        --arg schema "$HANDOFF_SCHEMA" \
        --arg capsuleMetadataSHA256 "$expected_metadata_sha256" \
        --arg candidateAppRelativePath "$candidate_relative" \
        --arg candidateExecutableSHA256 "$candidate_executable_sha256" \
        --arg candidateMediaFrameworkExecutableSHA256 "$candidate_framework_sha256" \
        --arg designatedRequirementReferenceRelativePath "$reference_relative" \
        --arg designatedRequirementReferenceSHA256 "$reference_sha256" \
        --arg expectedTeamIdentifier "$EXPECTED_TEAM_ID" \
        --arg hostIdentityManifestBasename "$MANIFEST_BASENAME" \
        --arg hostIdentityManifestSHA256 "$manifest_sha256" \
        --arg hostIdentityManifestSHA256Basename "$MANIFEST_SIDECAR_BASENAME" '
        {
          schema: $schema,
          capsuleMetadataSHA256: $capsuleMetadataSHA256,
          candidateAppRelativePath: $candidateAppRelativePath,
          candidateExecutableSHA256: $candidateExecutableSHA256,
          candidateMediaFrameworkExecutableSHA256: $candidateMediaFrameworkExecutableSHA256,
          designatedRequirementReferenceRelativePath: $designatedRequirementReferenceRelativePath,
          designatedRequirementReferenceSHA256: $designatedRequirementReferenceSHA256,
          expectedTeamIdentifier: $expectedTeamIdentifier,
          hostIdentityManifestBasename: $hostIdentityManifestBasename,
          hostIdentityManifestSHA256: $hostIdentityManifestSHA256,
          hostIdentityManifestSHA256Basename: $hostIdentityManifestSHA256Basename
        }
    ' >"$staged_handoff" || fail "could not render the V90 handoff"
    /bin/chmod 600 "$staged_handoff" || fail "could not protect the staged V90 handoff"
    validate_handoff_shape "$staged_handoff"
    handoff_sha256=$(sha256_file "$staged_handoff") \
        || fail "could not hash the staged V90 handoff"
    /usr/bin/printf '%s\n' "$handoff_sha256" >"$staged_handoff_sidecar" \
        || fail "could not render the V90 handoff commit marker"
    /bin/chmod 600 "$staged_handoff_sidecar" \
        || fail "could not protect the V90 handoff commit marker"
    assert_private_regular_file "$staged_handoff" "staged V90 handoff"
    assert_private_regular_file "$staged_handoff_sidecar" \
        "staged V90 handoff commit marker"

    publish_exclusive "$staged_handoff" "$handoff" "V90 handoff"
    staged_handoff=''
    [[ "$(/usr/bin/stat -f '%d:%i:%z' "$metadata")" == "$metadata_identity" \
        && "$(sha256_file "$metadata")" == "$expected_metadata_sha256" \
        && "$(/usr/bin/stat -f '%d:%i' "$candidate_app")" == "$candidate_app_identity" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$candidate_executable")" \
            == "$candidate_executable_identity" \
        && "$(sha256_file "$candidate_executable")" == "$candidate_executable_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$framework_executable")" \
            == "$framework_identity" \
        && "$(sha256_file "$framework_executable")" == "$candidate_framework_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$reference")" == "$reference_identity" \
        && "$(sha256_file "$reference")" == "$reference_sha256" \
        && "$(sha256_file "$manifest")" == "$manifest_sha256" \
        && "$(/usr/bin/tr -d '\n' <"$manifest_sidecar")" == "$manifest_sha256" \
        && "$(sha256_file "$handoff")" == "$handoff_sha256" \
        && "$(/usr/bin/stat -f '%d:%i' "$output_directory")" == "$output_identity" \
        && ! -e "$handoff_sidecar" && ! -L "$handoff_sidecar" ]] \
        || fail "V90 capsule inputs or publication topology changed before commit"
    publish_exclusive "$staged_handoff_sidecar" "$handoff_sidecar" \
        "V90 handoff commit marker"
    staged_handoff_sidecar=''
    trap - EXIT HUP INT TERM

    [[ "$(sha256_file "$handoff")" == "$handoff_sha256" \
        && "$(/usr/bin/tr -d '\n' <"$handoff_sidecar")" == "$handoff_sha256" ]] \
        || fail "published V90 handoff failed final verification"
    print -r -- "handoff_path=$handoff"
    print -r -- "handoff_sha256=$handoff_sha256"
    print -r -- "handoff_sha256_path=$handoff_sidecar"
    print -r -- "manifest_path=$manifest"
    print -r -- "manifest_sha256=$manifest_sha256"
    print -r -- "manifest_sha256_path=$manifest_sidecar"
}

arm_from_handoff() {
    (( $# == 5 )) || usage
    local handoff=${1%/}
    local expected_handoff_sha256=$2
    local device_id=$3
    local hardware_udid=$4
    local expected_build=$5
    local output_directory handoff_sidecar manifest manifest_sidecar
    local manifest_sha256 candidate_executable_sha256 candidate_framework_sha256
    local capsule_metadata_sha256 reference_sha256
    local candidate_relative reference_relative handoff_size manifest_size
    local handoff_identity handoff_sidecar_identity manifest_identity manifest_sidecar_identity

    assert_sha256 "$expected_handoff_sha256" "external handoff digest"
    [[ "$device_id" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
        && -n "$hardware_udid" && "$hardware_udid" != *[^0-9A-Fa-f-]* \
        && -n "$expected_build" && "$expected_build" != *[^0-9]* ]] \
        || usage
    assert_private_regular_file "$handoff" "committed V90 handoff"
    [[ "$handoff:t" == "$HANDOFF_BASENAME" ]] \
        || fail "committed V90 handoff has the wrong basename"
    output_directory=${handoff:h}
    assert_private_directory "$output_directory" "V90 handoff output directory"
    [[ "$output_directory:t" == "$OUTPUT_DIRECTORY_BASENAME" ]] \
        || fail "V90 handoff is outside the fixed output directory"
    handoff_sidecar="${output_directory}/${HANDOFF_SIDECAR_BASENAME}"
    assert_private_regular_file "$handoff_sidecar" "V90 handoff commit marker"
    handoff_size=$(/usr/bin/stat -f '%z' "$handoff") \
        || fail "V90 handoff size is unavailable"
    [[ "$handoff_size" =~ '^[0-9]+$' ]] \
        && (( handoff_size >= 256 && handoff_size <= 8192 )) \
        || fail "V90 handoff size is outside the reviewed bounds"
    [[ "$(/usr/bin/stat -f '%z' "$handoff_sidecar")" == 65 \
        && "$(/usr/bin/tail -c 1 "$handoff_sidecar" | /usr/bin/od -An -tuC \
            | /usr/bin/tr -d '[:space:]')" == 10 \
        && "$(/usr/bin/tr -d '\n' <"$handoff_sidecar")" == "$expected_handoff_sha256" \
        && "$(sha256_file "$handoff")" == "$expected_handoff_sha256" ]] \
        || fail "V90 handoff is uncommitted or does not match its external digest"
    validate_handoff_shape "$handoff"

    manifest_sha256=$(/usr/bin/jq -er '.hostIdentityManifestSHA256' "$handoff") \
        || fail "host-identity manifest digest is unavailable from the V90 handoff"
    candidate_executable_sha256=$(/usr/bin/jq -er '.candidateExecutableSHA256' "$handoff") \
        || fail "candidate executable digest is unavailable from the V90 handoff"
    candidate_framework_sha256=$(/usr/bin/jq -er \
        '.candidateMediaFrameworkExecutableSHA256' "$handoff") \
        || fail "candidate media-framework digest is unavailable from the V90 handoff"
    capsule_metadata_sha256=$(/usr/bin/jq -er '.capsuleMetadataSHA256' "$handoff") \
        || fail "capsule metadata digest is unavailable from the V90 handoff"
    reference_sha256=$(/usr/bin/jq -er \
        '.designatedRequirementReferenceSHA256' "$handoff") \
        || fail "designated-requirement reference digest is unavailable from the V90 handoff"
    candidate_relative=$(/usr/bin/jq -er '.candidateAppRelativePath' "$handoff") \
        || fail "candidate app path is unavailable from the V90 handoff"
    reference_relative=$(/usr/bin/jq -er \
        '.designatedRequirementReferenceRelativePath' "$handoff") \
        || fail "designated-requirement reference path is unavailable from the V90 handoff"
    assert_sha256 "$manifest_sha256" "handoff host-identity manifest digest"
    assert_sha256 "$candidate_executable_sha256" "handoff candidate executable digest"
    assert_sha256 "$candidate_framework_sha256" "handoff candidate media-framework digest"
    assert_sha256 "$capsule_metadata_sha256" "handoff capsule metadata digest"
    assert_sha256 "$reference_sha256" "handoff designated-requirement reference digest"
    assert_relative_capsule_path "$candidate_relative" "handoff candidate app path"
    assert_relative_capsule_path "$reference_relative" \
        "handoff designated-requirement reference path"
    [[ "$candidate_relative" == *.app ]] \
        || fail "handoff candidate app path must end in .app"
    [[ "$reference_relative" != "$candidate_relative" \
        && "$reference_relative" != "$candidate_relative/"* ]] \
        || fail "handoff designated-requirement reference path is candidate-derived"
    [[ "$reference_sha256" != "$candidate_executable_sha256" ]] \
        || fail "handoff designated-requirement reference digest is candidate-derived"

    manifest="${output_directory}/${MANIFEST_BASENAME}"
    manifest_sidecar="${output_directory}/${MANIFEST_SIDECAR_BASENAME}"
    assert_private_regular_file "$manifest" "sealed host-identity manifest"
    assert_private_regular_file "$manifest_sidecar" "sealed host-identity digest sidecar"
    manifest_size=$(/usr/bin/stat -f '%z' "$manifest") \
        || fail "sealed host-identity manifest size is unavailable"
    [[ "$manifest_size" =~ '^[0-9]+$' ]] \
        && (( manifest_size >= 256 && manifest_size <= 8192 )) \
        || fail "sealed host-identity manifest size is outside the reviewed bounds"
    [[ "$(/usr/bin/stat -f '%z' "$manifest_sidecar")" == 65 \
        && "$(/usr/bin/tail -c 1 "$manifest_sidecar" | /usr/bin/od -An -tuC \
            | /usr/bin/tr -d '[:space:]')" == 10 \
        && "$(/usr/bin/tr -d '\n' <"$manifest_sidecar")" == "$manifest_sha256" \
        && "$(sha256_file "$manifest")" == "$manifest_sha256" ]] \
        || fail "sealed host-identity manifest pair is uncommitted or mismatched"
    validate_identity_manifest "$manifest" \
        "$candidate_executable_sha256" "$candidate_framework_sha256"

    [[ -f "$SCREEN_ORACLE_ARMER" && ! -L "$SCREEN_ORACLE_ARMER" \
        && -x "$SCREEN_ORACLE_ARMER" ]] \
        || fail "reviewed production screen-oracle armer is unavailable"
    handoff_identity=$(/usr/bin/stat -f '%d:%i:%z' "$handoff") \
        || fail "V90 handoff identity is unavailable"
    handoff_sidecar_identity=$(/usr/bin/stat -f '%d:%i:%z' "$handoff_sidecar") \
        || fail "V90 handoff commit-marker identity is unavailable"
    manifest_identity=$(/usr/bin/stat -f '%d:%i:%z' "$manifest") \
        || fail "sealed host-identity manifest identity is unavailable"
    manifest_sidecar_identity=$(/usr/bin/stat -f '%d:%i:%z' "$manifest_sidecar") \
        || fail "sealed host-identity sidecar identity is unavailable"
    [[ "$(/usr/bin/stat -f '%d:%i:%z' "$handoff")" == "$handoff_identity" \
        && "$(sha256_file "$handoff")" == "$expected_handoff_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$handoff_sidecar")" \
            == "$handoff_sidecar_identity" \
        && "$(/usr/bin/tr -d '\n' <"$handoff_sidecar")" == "$expected_handoff_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$manifest")" == "$manifest_identity" \
        && "$(sha256_file "$manifest")" == "$manifest_sha256" \
        && "$(/usr/bin/stat -f '%d:%i:%z' "$manifest_sidecar")" \
            == "$manifest_sidecar_identity" \
        && "$(/usr/bin/tr -d '\n' <"$manifest_sidecar")" == "$manifest_sha256" ]] \
        || fail "committed V90 handoff changed before armer handoff"

    OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST="$manifest" \
    OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH="$manifest_sidecar" \
    OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256="$manifest_sha256" \
        exec "$SCREEN_ORACLE_ARMER" "$device_id" "$hardware_udid" "$expected_build"
}

(( $# >= 1 )) || usage
case $1 in
    prepare)
        shift
        prepare_handoff "$@"
        ;;
    arm)
        shift
        arm_from_handoff "$@"
        ;;
    *)
        usage
        ;;
esac
