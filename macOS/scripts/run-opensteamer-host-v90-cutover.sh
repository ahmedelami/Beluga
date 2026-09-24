#!/bin/zsh
# Pinned entry point for the one-shot V90 host cutover controller.
# Live modes remain gated by the exact compiled predecessor-reference digest and clean tooling.
set -euo pipefail
umask 077

readonly SCRIPT_NAME='run-opensteamer-host-v90-cutover'
readonly TOOLING_ROOT='/Volumes/t7/beluga-ios-metal-watchdog-release-83'
readonly TOOLING_BRANCH='fix/ios-metal-watchdog-testflight-83'
readonly TOOLING_UPSTREAM='origin/fix/ios-metal-watchdog-testflight-83'
readonly TOOLING_REMOTE_URL='https://github.com/ahmedelami/opensteamer.git'
readonly EXPECTED_SCRIPT_DIRECTORY="${TOOLING_ROOT}/macOS/scripts"
readonly LAUNCHER_BASENAME='run-opensteamer-host-v90-cutover.sh'
readonly CONTROLLER_BASENAME='opensteamer-host-v90-cutover-controller.rb'
readonly MONITOR_BASENAME='opensteamer-v90-coreaudio-route-monitor.swift'
readonly ASSEMBLER_BASENAME='assemble-v90-sealed-host-oracle-capsule.sh'
readonly CONTROLLER_SHA256='d5aaa66e8b15e758cce0fa2b635d8f68cddc2a4b6738353bb5b00a72bd1d6500'
readonly MONITOR_SHA256='4a788f63122b84a51b3009a544cda62589664ba51fd5a6bc1658381fdc28e36d'
readonly RUBY='/usr/bin/ruby'
readonly RUBY_SHA256='9d6ff3e289c7d908e3c785e0bedd6692d1d6a3377965c88c04d847104b7c892c'
readonly SWIFTC='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
readonly SWIFTC_TARGET='swift-frontend'
readonly SWIFTC_SHA256='2ed38571e92c0283091838c1649e27650ad9c99950288e883c7b2dc6c4ce89fb'
readonly SWIFTC_IDENTITY='16777240:15755469'
readonly MACOS_SDK='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk'
readonly MACOS_SDK_TARGET='MacOSX.sdk'
readonly MACOS_SDK_IDENTITY='16777240:15672618'
readonly MACOS_SDK_SETTINGS_SHA256='f8d005f09381389167f9e0aeaa169bc9e7dff162ef22ca2fd8e98df7ff1acafe'
readonly APPROVED_PREDECESSOR_REFERENCE_SHA256='553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66'
readonly LAUNCHER_ATTESTATION='opensteamer-v90-pinned-launcher-v1'

fail() {
    print -u2 -- "${SCRIPT_NAME}: $*"
    exit 1
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '
        NF == 2 && $1 ~ /^[0-9a-f]{64}$/ { value=$1; count++ }
        END { if (count != 1) exit 1; print value }
    '
}

assert_no_acl_or_xattrs() {
    local path=$1 label=$2 mode attributes
    mode=$(/bin/ls -lde "$path" | /usr/bin/awk 'NR == 1 { print $1 }') \
        || fail "could not inspect ${label} ACL"
    [[ "$mode" != *+* ]] || fail "${label} has an ACL"
    attributes=$(/usr/bin/xattr "$path" 2>/dev/null) \
        || fail "could not inspect ${label} xattrs"
    [[ -z "$attributes" ]] || fail "${label} has extended attributes"
}

verify_regular_file() {
    local path=$1 digest=$2 owner=$3 mode=$4 flags=$5 label=$6 metadata
    verify_regular_metadata "$path" "$owner" "$mode" "$flags" "$label"
    [[ "$(sha256_file "$path")" == "$digest" ]] || fail "${label} digest changed"
}

verify_regular_metadata() {
    local path=$1 owner=$2 mode=$3 flags=$4 label=$5 metadata
    [[ -f "$path" && ! -L "$path" ]] || fail "${label} is not a real file"
    metadata=$(/usr/bin/stat -f '%u:%Lp:%l:%f' "$path") \
        || fail "could not stat ${label}"
    [[ "$metadata" == "${owner}:${mode}:1:${flags}" ]] \
        || fail "${label} metadata changed"
    assert_no_acl_or_xattrs "$path" "$label"
}

verify_directory_metadata() {
    local path=$1 owner=$2 mode=$3 flags=$4 label=$5 metadata
    [[ -d "$path" && ! -L "$path" ]] || fail "${label} is not a real directory"
    metadata=$(/usr/bin/stat -f '%u:%Lp:%f' "$path") \
        || fail "could not stat ${label}"
    [[ "$metadata" == "${owner}:${mode}:${flags}" ]] \
        || fail "${label} metadata changed"
    assert_no_acl_or_xattrs "$path" "$label"
}

git_value() {
    /usr/bin/git -C "$TOOLING_ROOT" "$@" \
        || fail "Git tooling proof failed: git $*"
}

verify_clean_remote_tooling() {
    local root branch upstream fetch_urls push_urls head tree upstream_head worktree_status remote_record
    local relative path tracked working_blob head_blob mode

    root=$(git_value rev-parse --show-toplevel)
    [[ "$root" == "$TOOLING_ROOT" && "${root:A}" == "$TOOLING_ROOT" ]] \
        || fail 'tooling Git root is not the canonical reviewed worktree'
    verify_directory_metadata "$root" 501 755 0 'V90 tooling root'
    branch=$(git_value symbolic-ref --short HEAD)
    upstream=$(git_value rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    [[ "$branch" == "$TOOLING_BRANCH" ]] || fail 'tooling branch differs from pinned V90 branch'
    [[ "$upstream" == "$TOOLING_UPSTREAM" ]] || fail 'tooling upstream differs from pinned V90 upstream'

    fetch_urls=$(git_value remote get-url --all origin)
    push_urls=$(git_value remote get-url --push --all origin)
    [[ "$fetch_urls" == "$TOOLING_REMOTE_URL" ]] || fail 'tooling origin fetch URL differs'
    [[ "$push_urls" == "$TOOLING_REMOTE_URL" ]] || fail 'tooling origin push URL differs'

    head=$(git_value rev-parse HEAD)
    tree=$(git_value rev-parse 'HEAD^{tree}')
    upstream_head=$(git_value rev-parse '@{u}')
    [[ "$head" =~ ^[0-9a-f]{40}$ && "$tree" =~ ^[0-9a-f]{40}$ ]] \
        || fail 'tooling HEAD/tree identity is malformed'
    [[ "$head" == "$upstream_head" ]] || fail 'tooling HEAD differs from local upstream'
    worktree_status=$(git_value status --porcelain=v1 --untracked-files=all)
    [[ -z "$worktree_status" ]] || fail 'tooling worktree is not clean'
    remote_record=$(git_value ls-remote --exit-code --refs --heads origin "refs/heads/${branch}")
    [[ "$remote_record" == "${head}"$'\t'"refs/heads/${branch}" ]] \
        || fail 'fresh remote branch tip differs from exact tooling HEAD'

    for relative in \
        "macOS/scripts/${ASSEMBLER_BASENAME}" \
        "macOS/scripts/${CONTROLLER_BASENAME}" \
        "macOS/scripts/${MONITOR_BASENAME}" \
        "macOS/scripts/${LAUNCHER_BASENAME}"
    do
        path="${TOOLING_ROOT}/${relative}"
        case "$relative" in
            *"/${ASSEMBLER_BASENAME}"|*"/${LAUNCHER_BASENAME}") mode=755 ;;
            *) mode=644 ;;
        esac
        verify_regular_metadata "$path" 501 "$mode" 0 "tracked V90 tooling file ${relative}"
        tracked=$(git_value ls-files --error-unmatch -- "$relative")
        [[ "$tracked" == "$relative" ]] || fail "V90 tooling file is not uniquely tracked: ${relative}"
        working_blob=$(git_value hash-object --no-filters -- "$relative")
        head_blob=$(git_value rev-parse "HEAD:${relative}")
        [[ "$working_blob" =~ ^[0-9a-f]{40}$ && "$working_blob" == "$head_blob" ]] \
            || fail "V90 tooling bytes differ from tracked HEAD: ${relative}"
        case "$relative" in
            *"/${ASSEMBLER_BASENAME}") TOOLING_ASSEMBLER_BLOB=$head_blob ;;
            *"/${LAUNCHER_BASENAME}") TOOLING_LAUNCHER_BLOB=$head_blob ;;
        esac
    done
    TOOLING_COMMIT=$head
    TOOLING_TREE=$tree
}

readonly LAUNCHER=${0:A}
readonly SCRIPT_DIRECTORY=${LAUNCHER:h}
[[ "$SCRIPT_DIRECTORY" == "$EXPECTED_SCRIPT_DIRECTORY" ]] \
    || fail 'launcher is not running from the authoritative reviewed worktree'
[[ "$LAUNCHER" == "${EXPECTED_SCRIPT_DIRECTORY}/${LAUNCHER_BASENAME}" ]] \
    || fail 'launcher path differs from the canonical reviewed path'
readonly CONTROLLER="${SCRIPT_DIRECTORY}/${CONTROLLER_BASENAME}"
readonly MONITOR="${SCRIPT_DIRECTORY}/${MONITOR_BASENAME}"

verify_regular_metadata "$LAUNCHER" 501 755 0 'V90 launcher'

verify_regular_file "$CONTROLLER" "$CONTROLLER_SHA256" 501 644 0 'controller source'
verify_regular_file "$MONITOR" "$MONITOR_SHA256" 501 644 0 'route-monitor source'
verify_regular_file "$RUBY" "$RUBY_SHA256" 0 555 524320 'system Ruby'

[[ -L "$SWIFTC" && "$(/usr/bin/readlink "$SWIFTC")" == "$SWIFTC_TARGET" ]] \
    || fail 'pinned swiftc link changed'
readonly SWIFTC_REAL=${SWIFTC:A}
verify_regular_file "$SWIFTC_REAL" "$SWIFTC_SHA256" 501 755 0 'swiftc executable'
[[ "$(/usr/bin/stat -f '%d:%i' "$SWIFTC_REAL")" == "$SWIFTC_IDENTITY" ]] \
    || fail 'swiftc filesystem identity changed'

[[ -L "$MACOS_SDK" && "$(/usr/bin/readlink "$MACOS_SDK")" == "$MACOS_SDK_TARGET" ]] \
    || fail 'pinned macOS SDK link changed'
readonly MACOS_SDK_REAL=${MACOS_SDK:A}
[[ -d "$MACOS_SDK_REAL" && ! -L "$MACOS_SDK_REAL" \
    && "$(/usr/bin/stat -f '%u:%Lp:%d:%i:%f' "$MACOS_SDK_REAL")" \
        == "501:755:${MACOS_SDK_IDENTITY}:0" ]] \
    || fail 'pinned macOS SDK identity changed'
assert_no_acl_or_xattrs "$MACOS_SDK_REAL" 'macOS SDK'
verify_regular_file \
    "${MACOS_SDK}/SDKSettings.json" "$MACOS_SDK_SETTINGS_SHA256" 501 644 0 \
    'macOS SDK settings'

(( $# >= 1 )) || fail \
    'usage: launcher --self-test-v90-cutover | --verify-v90-cutover-preflight <capsule> <handoff-sha256> <payload-sha256> | --execute-authorized-v90-cutover <capsule> <handoff-sha256> <payload-sha256>'
readonly MODE=$1
typeset -g TOOLING_COMMIT=''
typeset -g TOOLING_TREE=''
typeset -g TOOLING_LAUNCHER_BLOB=''
typeset -g TOOLING_ASSEMBLER_BLOB=''
case "$MODE" in
    --self-test-v90-cutover)
        (( $# == 1 )) || fail 'self-test accepts no arguments'
        ;;
    --verify-v90-cutover-preflight|--execute-authorized-v90-cutover)
        (( $# == 4 )) || fail 'live mode requires capsule root and exactly two external digests'
        [[ "$APPROVED_PREDECESSOR_REFERENCE_SHA256" =~ ^[0-9a-f]{64}$ ]] \
            || fail 'compiled approved predecessor-reference digest is invalid'
        verify_clean_remote_tooling
        ;;
    *)
        fail 'unknown V90 controller mode'
        ;;
esac

exec /usr/bin/env -i \
    HOME=/Users/ahmed \
    USER=ahmed \
    LOGNAME=ahmed \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    TMPDIR=/private/tmp \
    LC_ALL=C \
    OPENSTEAMER_V90_LAUNCHER_ATTESTATION="$LAUNCHER_ATTESTATION" \
    OPENSTEAMER_V90_LAUNCHER_PATH="$LAUNCHER" \
    OPENSTEAMER_V90_TOOLING_COMMIT="$TOOLING_COMMIT" \
    OPENSTEAMER_V90_TOOLING_TREE="$TOOLING_TREE" \
    OPENSTEAMER_V90_LAUNCHER_BLOB="$TOOLING_LAUNCHER_BLOB" \
    OPENSTEAMER_V90_ASSEMBLER_BLOB="$TOOLING_ASSEMBLER_BLOB" \
    "$RUBY" --disable-gems "$CONTROLLER" "$@"
