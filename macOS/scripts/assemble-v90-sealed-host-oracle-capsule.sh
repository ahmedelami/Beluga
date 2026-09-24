#!/bin/zsh

# Assemble the offline, single-use V90 host capsule consumed by the guarded cutover and
# physical-screen oracle. This script only reads an explicitly supplied clean source checkout and
# predecessor reference. It does not inspect or mutate the installed host or any running service.
set -euo pipefail
umask 077
# No caller-controlled temporary directory is inherited by Git, hashing, or validation tools.
# A capsule-private TMPDIR is exported only after the fresh capsule identity is established.
unset TMPDIR

readonly EXPECTED_SOURCE_BRANCH='fix/ios-metal-watchdog-testflight-83'
readonly EXPECTED_SOURCE_UPSTREAM='origin/fix/ios-metal-watchdog-testflight-83'
readonly EXPECTED_SOURCE_COMMIT='229eabc22b9990891c5e5b2a5cfa27111f0a6b3e'
readonly EXPECTED_SOURCE_TREE='0192ef02be478f094afe1f66b50fe3b14717d0ea'
readonly EXPECTED_TOOLING_REMOTE_URL='https://github.com/ahmedelami/opensteamer.git'
readonly ASSEMBLER_RELATIVE_PATH='macOS/scripts/assemble-v90-sealed-host-oracle-capsule.sh'
readonly EXPECTED_DEVELOPER_DIR='/Volumes/t7/opensteamer-space-recovery-20260804/nonrepo/Xcode-26.6.0.app/Contents/Developer'
readonly EXPECTED_SIGNING_IDENTITY_SHA1='483C08B6517EBC1CFCCAB1A88BBEE8028750AA13'
readonly EXPECTED_TEAM_ID='MSMG8CJLB3'
readonly EXPECTED_ARCHITECTURES='arm64'
readonly APPROVED_PREDECESSOR_REFERENCE_SHA256='553892526e1f9de1e6d67b5556b3c2c008d9b48bbd553eb799c2260ee184ac66'
readonly APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE='11442304'
readonly APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATAOFF='11401072'
readonly APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATASIZE='41232'
readonly APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256='a7885a8d1ffef70f5a747eaed984a6cb70fe382491fcc6fbf8505aa0ad47ff5b'
readonly APPROVED_PREDECESSOR_REFERENCE_CDHASH='e41c23322912104a648e791bfb0d3a5714323b26'
readonly APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256='e41c23322912104a648e791bfb0d3a5714323b26b1b299ae5f0cfa225f68aba0'
readonly APPROVED_PREDECESSOR_REFERENCE_TEAM_ID='MSMG8CJLB3'
readonly APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER='com.elamin.AudioStreamer.CaptureServer'
readonly APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT='identifier "com.elamin.AudioStreamer.CaptureServer" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Ahmed Elamin (92LVX32M8K)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */'
readonly PROTECTED_RUNTIME_ROOT='/Users/ahmed/Library/Application Support/opensteamer'
readonly METADATA_SCHEMA='opensteamer.v90-host-oracle-capsule-metadata.v1'
readonly METADATA_BASENAME='trusted-v90-host-oracle-capsule-metadata.json'
readonly CANDIDATE_RELATIVE='candidate/opensteamer Host.app'
readonly REFERENCE_RELATIVE='trusted-reference/CaptureServer'
readonly SOURCE_TREE_MANIFEST_BASENAME='v90-source-export-tree-manifest.txt'
readonly CANDIDATE_TREE_MANIFEST_BASENAME='v90-candidate-app-tree-manifest.txt'
readonly CANDIDATE_COPY_MANIFEST_BASENAME='v90-candidate-app-copy-manifest.txt'
readonly PAYLOAD_SCHEMA='opensteamer.v90-deployment-payload-manifest.v2'
readonly PAYLOAD_MANIFEST_BASENAME='v90-deployment-payload-manifest.json'
readonly PAYLOAD_SIDECAR_BASENAME='v90-deployment-payload-manifest.json.sha256'

fail() {
    print -u2 -- "assemble-v90-sealed-host-oracle-capsule: $*"
    exit 1
}

usage() {
    print -u2 -- \
        "usage: $0 <clean-pinned-release-source-checkout> <fresh-absolute-capsule-root> <trusted-predecessor-reference-code> <independently-supplied-reference-sha256>"
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

sha256_text() {
    /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '
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

sha256_prefix() {
    local target=$1
    local length=$2

    /usr/bin/head -c "$length" "$target" | /usr/bin/shasum -a 256 | /usr/bin/awk '
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

codesign_single_field() {
    local metadata=$1
    local prefix=$2

    /usr/bin/printf '%s\n' "$metadata" | /usr/bin/awk -v prefix="$prefix" '
        index($0, prefix) == 1 {
            value=substr($0, length(prefix) + 1)
            count++
        }
        END { if (count != 1 || value == "") exit 1; print value }
    '
}

assert_predecessor_reference_fingerprint() {
    local target=$1
    local label=$2
    local require_bundle_strict=$3
    local signature_fields dataoff datasize size prefix_sha metadata cdhash code_directory_sha
    local team identifier requirement_output requirement app_root

    assert_private_file "$target" 755 "$label"
    [[ "$(sha256_file "$target")" == "$APPROVED_PREDECESSOR_REFERENCE_SHA256" ]] \
        || fail "$label full-file SHA-256 differs from the approved predecessor"
    size=$(/usr/bin/stat -f '%z' "$target") \
        || fail "$label size is unavailable"
    [[ "$size" == "$APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE" ]] \
        || fail "$label size differs from the approved predecessor"

    signature_fields=$(/usr/bin/otool -l "$target" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_CODE_SIGNATURE" {
            count++
            active=1
            next
        }
        active && $1 == "dataoff" {
            dataoff=$2
            next
        }
        active && $1 == "datasize" {
            datasize=$2
            active=0
            next
        }
        END {
            if (count != 1 || dataoff !~ /^[0-9]+$/ || datasize !~ /^[0-9]+$/) exit 1
            print dataoff ":" datasize
        }
    ') || fail "$label has no unique parseable LC_CODE_SIGNATURE"
    dataoff=${signature_fields%%:*}
    datasize=${signature_fields##*:}
    [[ "$dataoff" == "$APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATAOFF" \
        && "$datasize" == "$APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATASIZE" \
        && "$(( dataoff + datasize ))" == "$size" ]] \
        || fail "$label LC_CODE_SIGNATURE layout differs from the approved predecessor "\
"(actual=${dataoff}:${datasize}/${size}, expected="\
"${APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATAOFF}:"\
"${APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATASIZE}/"\
"${APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE})"
    prefix_sha=$(sha256_prefix "$target" "$dataoff") \
        || fail "$label unsigned-prefix digest is unavailable"
    [[ "$prefix_sha" == "$APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256" ]] \
        || fail "$label unsigned-prefix digest differs from the approved predecessor"

    metadata=$(/usr/bin/codesign --display --verbose=6 "$target" 2>&1) \
        || fail "$label code-signature metadata is unavailable"
    identifier=$(codesign_single_field "$metadata" 'Identifier=') \
        || fail "$label has ambiguous code identifier metadata"
    team=$(codesign_single_field "$metadata" 'TeamIdentifier=') \
        || fail "$label has ambiguous TeamIdentifier metadata"
    cdhash=$(codesign_single_field "$metadata" 'CDHash=') \
        || fail "$label has ambiguous CDHash metadata"
    code_directory_sha=$(codesign_single_field "$metadata" 'CandidateCDHashFull sha256=') \
        || fail "$label has ambiguous full CodeDirectory digest metadata"
    [[ "$identifier" == "$APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER" \
        && "$team" == "$APPROVED_PREDECESSOR_REFERENCE_TEAM_ID" \
        && "$cdhash" == "$APPROVED_PREDECESSOR_REFERENCE_CDHASH" \
        && "$code_directory_sha" == "$APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256" ]] \
        || fail "$label code-signature identity differs from the approved predecessor"

    requirement_output=$(/usr/bin/codesign --display --requirements - "$target" 2>&1) \
        || fail "$label designated requirement is unavailable"
    requirement=$(/usr/bin/printf '%s\n' "$requirement_output" | /usr/bin/awk '
        sub(/^# /, "")
        index($0, "designated => ") == 1 {
            value=substr($0, length("designated => ") + 1)
            count++
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ') || fail "$label has no unique designated requirement"
    [[ "$requirement" == "$APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT" ]] \
        || fail "$label designated requirement differs from the approved predecessor"

    if [[ "$require_bundle_strict" == 1 ]]; then
        [[ "$target" == */Contents/MacOS/CaptureServer ]] \
            || fail "$label is not the CaptureServer executable inside a complete app bundle"
        app_root=${target%/Contents/MacOS/CaptureServer}
        [[ "$app_root" == *.app && -d "$app_root" && ! -L "$app_root" \
            && "${app_root:A}" == "$app_root" ]] \
            || fail "$label does not belong to a canonical complete app bundle"
        /usr/bin/codesign --verify --strict --verbose=4 "$target" \
            || fail "$label is not strict-valid in its original bundle context"
        /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_root" \
            || fail "$label original app bundle is not deep strict-valid"
    elif [[ "$require_bundle_strict" != 0 ]]; then
        fail "$label fingerprint verifier received an invalid strict-verification mode"
    fi
}

assert_sha256() {
    [[ "$1" =~ '^[0-9a-f]{64}$' ]] || fail "$2 is not a lowercase SHA-256"
}

assert_no_acl() {
    local target=$1
    local label=$2
    local listing_mode

    listing_mode=$(/bin/ls -lde "$target" | /usr/bin/awk 'NR == 1 { print $1 }') \
        || fail "$label access controls are unavailable"
    [[ "$listing_mode" != *+* ]] || fail "$label must not have an ACL"
}

assert_no_xattrs() {
    local target=$1
    local label=$2
    local attributes

    if [[ -L "$target" ]]; then
        attributes=$(/usr/bin/xattr -s "$target" 2>/dev/null) \
            || fail "$label symbolic-link extended attributes are unreadable"
    else
        attributes=$(/usr/bin/xattr "$target" 2>/dev/null) \
            || fail "$label extended attributes are unreadable"
    fi
    [[ -z "$attributes" ]] || fail "$label contains extended attributes"
}

assert_private_directory() {
    local target=$1
    local label=$2
    local metadata

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -d "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute real directory"
    metadata=$(/usr/bin/stat -f '%u:%Lp:%f' "$target") \
        || fail "$label metadata is unavailable"
    [[ "$metadata" == "$EUID:700:0" ]] \
        || fail "$label must be owner-owned mode 0700 with zero BSD flags"
    assert_no_acl "$target" "$label"
    assert_no_xattrs "$target" "$label"
}

assert_candidate_app_root() {
    local target=$1
    local label=$2
    local metadata

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -d "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute real directory"
    metadata=$(/usr/bin/stat -f '%u:%Lp:%f' "$target") \
        || fail "$label metadata is unavailable"
    [[ "$metadata" == "$EUID:755:0" ]] \
        || fail "$label must be owner-owned mode 0755 with zero BSD flags"
    assert_no_acl "$target" "$label"
    assert_no_xattrs "$target" "$label"
}

assert_private_file() {
    local target=$1
    local mode=$2
    local label=$3

    [[ -n "$target" && "$target" == /* && "$target" != *[[:cntrl:]]* \
        && "${target:a}" == "$target" && "${target:A}" == "$target" \
        && -f "$target" && ! -L "$target" ]] \
        || fail "$label is not a canonical absolute regular file"
    [[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$target")" == "$EUID:${mode}:1" ]] \
        || fail "$label must be owner-owned mode 0${mode} with one hard link"
    assert_no_acl "$target" "$label"
    assert_no_xattrs "$target" "$label"
}

assert_exact_private_directory_shape() {
    local target=$1
    local label=$2
    local expected=$3
    local actual

    assert_private_directory "$target" "$label"
    actual=$(/bin/ls -1A "$target" | LC_ALL=C /usr/bin/sort) \
        || fail "could not inspect $label contents"
    [[ "$actual" == "$expected" ]] \
        || fail "$label contains missing, unexpected, or duplicate-named entries"
}

assert_outside_forbidden_roots() {
    local target=$1
    local label=$2
    local lowered=${target:l}
    local protected_lowered=${PROTECTED_RUNTIME_ROOT:l}

    [[ "$lowered" != '/applications' && "$lowered" != '/applications/'* \
        && "$lowered" != "$protected_lowered" \
        && "$lowered" != "$protected_lowered/"* ]] \
        || fail "$label is inside an installed-runtime or retained-evidence root"
    case "$lowered" in
        *'/paired-host-updates-'*|*'/migration-'*|*'/rollback-'*|*'/install-hold-'*|\
        *'/retained-'*|*'/consumed-'*|*'/evidence-'*|*'-capsule.'*|*'-capsule/'*)
            fail "$label appears to come from a retained or consumed runtime/evidence capsule"
            ;;
    esac
}

paths_overlap() {
    local left=$1
    local right=$2

    [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

assert_source_state() {
    local repository=$1
    local actual_root head tree worktree_status

    actual_root=$(/usr/bin/git -C "$repository" rev-parse --show-toplevel 2>/dev/null) \
        || fail "source checkout is not a Git worktree"
    [[ "$actual_root" == "$repository" ]] \
        || fail "source checkout must be the canonical Git worktree root"
    head=$(/usr/bin/git -C "$repository" rev-parse --verify HEAD 2>/dev/null) \
        || fail "source HEAD is unavailable"
    tree=$(/usr/bin/git -C "$repository" rev-parse --verify 'HEAD^{tree}' 2>/dev/null) \
        || fail "source tree is unavailable"
    worktree_status=$(/usr/bin/git -C "$repository" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none) \
        || fail "source status is unavailable"

    [[ "$head" == "$EXPECTED_SOURCE_COMMIT" ]] \
        || fail "source HEAD is '$head', expected '$EXPECTED_SOURCE_COMMIT'"
    [[ "$tree" == "$EXPECTED_SOURCE_TREE" ]] \
        || fail "source tree is '$tree', expected '$EXPECTED_SOURCE_TREE'"
    [[ -z "$worktree_status" ]] || fail "source checkout is not clean"
}

validate_tooling_state() {
    local repository=$1
    local assembler=$2
    local actual_root branch upstream head upstream_head tree worktree_status
    local remote_url push_url remote_listing remote_tip remote_ref
    local tracked_blob actual_blob pinned_release_tree

    actual_root=$(/usr/bin/git -C "$repository" rev-parse --show-toplevel 2>/dev/null) \
        || fail "tooling checkout is not a Git worktree"
    [[ "$actual_root" == "$repository" ]] \
        || fail "tooling checkout must be the canonical Git worktree root"
    branch=$(/usr/bin/git -C "$repository" symbolic-ref --quiet --short HEAD 2>/dev/null) \
        || fail "tooling checkout must be on the release branch"
    upstream=$(/usr/bin/git -C "$repository" rev-parse --abbrev-ref \
        --symbolic-full-name '@{upstream}' 2>/dev/null) \
        || fail "tooling checkout has no upstream"
    head=$(/usr/bin/git -C "$repository" rev-parse --verify HEAD 2>/dev/null) \
        || fail "tooling HEAD is unavailable"
    upstream_head=$(/usr/bin/git -C "$repository" rev-parse --verify '@{upstream}' 2>/dev/null) \
        || fail "tooling upstream commit is unavailable"
    tree=$(/usr/bin/git -C "$repository" rev-parse --verify 'HEAD^{tree}' 2>/dev/null) \
        || fail "tooling tree is unavailable"
    worktree_status=$(/usr/bin/git -C "$repository" status --porcelain=v1 \
        --untracked-files=all --ignore-submodules=none) \
        || fail "tooling status is unavailable"
    remote_url=$(/usr/bin/git -C "$repository" remote get-url origin 2>/dev/null) \
        || fail "tooling origin URL is unavailable"
    push_url=$(/usr/bin/git -C "$repository" remote get-url --push origin 2>/dev/null) \
        || fail "tooling origin push URL is unavailable"

    [[ "$branch" == "$EXPECTED_SOURCE_BRANCH" ]] \
        || fail "tooling branch is '$branch', expected '$EXPECTED_SOURCE_BRANCH'"
    [[ "$upstream" == "$EXPECTED_SOURCE_UPSTREAM" ]] \
        || fail "tooling upstream is '$upstream', expected '$EXPECTED_SOURCE_UPSTREAM'"
    [[ "$head" == "$upstream_head" ]] \
        || fail "tooling HEAD and local upstream are not exactly equal"
    [[ -z "$worktree_status" ]] || fail "tooling checkout is not clean"
    [[ "$remote_url" == "$EXPECTED_TOOLING_REMOTE_URL" \
        && "$push_url" == "$EXPECTED_TOOLING_REMOTE_URL" ]] \
        || fail "tooling origin fetch/push URL differs from the exact reviewed remote"

    remote_listing=$(/usr/bin/git -C "$repository" ls-remote --heads origin \
        "refs/heads/${EXPECTED_SOURCE_BRANCH}" 2>/dev/null) \
        || fail "fresh tooling remote-tip proof failed"
    remote_tip=$(print -r -- "$remote_listing" | /usr/bin/awk \
        -v expected="refs/heads/${EXPECTED_SOURCE_BRANCH}" '
        NF == 2 && $1 ~ /^[0-9a-f]{40}$/ && $2 == expected {
            sha=$1
            ref=$2
            count++
        }
        END { if (count != 1) exit 1; print sha }
    ') || fail "tooling remote-tip proof is not one exact branch record"
    remote_ref=$(print -r -- "$remote_listing" | /usr/bin/awk 'NF == 2 { print $2 }') \
        || fail "tooling remote ref is unavailable"
    [[ "$remote_ref" == "refs/heads/${EXPECTED_SOURCE_BRANCH}" \
        && "$head" == "$remote_tip" ]] \
        || fail "tooling HEAD/upstream do not equal the freshly read remote branch tip"

    [[ "$assembler" == "${repository}/${ASSEMBLER_RELATIVE_PATH}" \
        && "${assembler:A}" == "$assembler" ]] \
        || fail "running assembler is not the canonical tracked tooling path"
    assert_private_file "$assembler" 755 "running assembler"
    tracked_blob=$(/usr/bin/git -C "$repository" rev-parse --verify \
        "HEAD:${ASSEMBLER_RELATIVE_PATH}" 2>/dev/null) \
        || fail "tracked assembler blob is unavailable"
    actual_blob=$(/usr/bin/git -C "$repository" hash-object --no-filters "$assembler" 2>/dev/null) \
        || fail "running assembler blob identity is unavailable"
    [[ "$tracked_blob" =~ '^[0-9a-f]{40}$' && "$actual_blob" == "$tracked_blob" ]] \
        || fail "running assembler bytes do not equal the tracked HEAD blob"

    pinned_release_tree=$(/usr/bin/git -C "$repository" rev-parse --verify \
        "${EXPECTED_SOURCE_COMMIT}^{tree}" 2>/dev/null) \
        || fail "pinned release-source tree is unavailable from tooling repository"
    [[ "$pinned_release_tree" == "$EXPECTED_SOURCE_TREE" ]] \
        || fail "pinned release-source commit does not resolve to its reviewed tree"
    /usr/bin/git -C "$repository" merge-base --is-ancestor \
        "$EXPECTED_SOURCE_COMMIT" "$remote_tip" >/dev/null 2>&1 \
        || fail "pinned release source is not an ancestor of the fresh tooling tip"

    TOOLING_COMMIT_RESULT=$head
    TOOLING_TREE_RESULT=$tree
    TOOLING_ASSEMBLER_BLOB_RESULT=$actual_blob
    TOOLING_REMOTE_TIP_RESULT=$remote_tip
}

publish_exclusive() {
    local staged=$1
    local destination=$2
    local label=$3
    local identity

    assert_private_file "$staged" 600 "staged $label"
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || fail "$label destination already exists"
    identity=$(/usr/bin/stat -f '%d:%i' "$staged") \
        || fail "could not capture staged $label identity"
    /bin/ln "$staged" "$destination" || fail "could not publish $label exclusively"
    [[ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l' "$destination")" \
        == "$identity:$EUID:600:2" ]] \
        || fail "published $label identity is unsafe"
    /bin/rm "$staged" || fail "could not retire staged $label name"
    assert_private_file "$destination" 600 "published $label"
    [[ "$(/usr/bin/stat -f '%d:%i' "$destination")" == "$identity" ]] \
        || fail "published $label identity changed"
}

assert_reviewed_candidate_symlink() {
    local relative=$1
    local target=$2

    case "$relative:$target" in
        'Contents/Frameworks/LiveKitWebRTC.framework/Headers:Versions/Current/Headers'|\
        'Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC:Versions/Current/LiveKitWebRTC'|\
        'Contents/Frameworks/LiveKitWebRTC.framework/Modules:Versions/Current/Modules'|\
        'Contents/Frameworks/LiveKitWebRTC.framework/Resources:Versions/Current/Resources'|\
        'Contents/Frameworks/LiveKitWebRTC.framework/Versions/Current:A')
            ;;
        *)
            fail "candidate app contains an unreviewed symbolic link: $relative -> $target"
            ;;
    esac
}

render_tree_manifest() {
    local root=$1
    local root_kind=$2
    local output=$3
    local listing path relative metadata mode uid gid links size flags
    local target target_sha file_sha resolved record_count=0 link_count=0

    [[ -d "$root" && ! -L "$root" && "${root:A}" == "$root" ]] \
        || fail "$root_kind manifest root is unsafe"
    [[ ! -e "$output" && ! -L "$output" ]] \
        || fail "$root_kind manifest output already exists"
    listing=$(/usr/bin/mktemp "${CAPSULE_ROOT}/.${root_kind}-tree-listing.XXXXXX") \
        || fail "could not stage $root_kind tree listing"
    : >"$listing"
    /bin/chmod 600 "$listing" || fail "could not protect staged $root_kind tree listing"
    /usr/bin/find "$root" -mindepth 1 -print | LC_ALL=C /usr/bin/sort >"$listing" \
        || fail "could not enumerate $root_kind tree"
    [[ -s "$listing" ]] || fail "$root_kind tree is empty"

    : >"$output" || fail "could not create staged $root_kind tree manifest"
    /bin/chmod 600 "$output" || fail "could not protect staged $root_kind tree manifest"
    while IFS= read -r path; do
        [[ -n "$path" && "$path" == "$root/"* && "$path" != *[[:cntrl:]]* ]] \
            || fail "$root_kind tree contains an unsafe path"
        relative=${path#"$root/"}
        [[ -n "$relative" && "$relative" != /* && "$relative" != . \
            && "$relative" != .. && "$relative" != ./* && "$relative" != ../* \
            && "$relative" != */. && "$relative" != */.. \
            && "$relative" != */./* && "$relative" != */../* \
            && "$relative" != *//* && "$relative" != */ ]] \
            || fail "$root_kind tree contains a non-normalized relative path"
        assert_no_acl "$path" "$root_kind tree entry '$relative'"
        assert_no_xattrs "$path" "$root_kind tree entry '$relative'"
        metadata=$(/usr/bin/stat -f '%Lp:%u:%g:%l:%z:%f' "$path") \
            || fail "could not stat $root_kind tree entry: $relative"
        IFS=: read -r mode uid gid links size flags <<<"$metadata"
        [[ "$mode" =~ '^[0-7]{3,4}$' && "$uid" =~ '^[0-9]+$' \
            && "$gid" =~ '^[0-9]+$' && "$links" =~ '^[0-9]+$' \
            && "$size" =~ '^[0-9]+$' && "$flags" =~ '^[0-9]+$' ]] \
            || fail "$root_kind tree entry metadata is malformed: $relative"
        [[ "$flags" == 0 ]] \
            || fail "$root_kind tree entry has nonzero BSD flags: $relative"
        mode="0${mode}"
        mode=${mode[-4,-1]}
        if [[ -L "$path" ]]; then
            [[ "$root_kind" == candidate ]] \
                || fail "$root_kind tree contains a symbolic link: $relative"
            target=$(/usr/bin/readlink "$path") \
                || fail "could not read candidate symbolic link: $relative"
            [[ -n "$target" && "$target" != *[[:cntrl:]]* ]] \
                || fail "candidate symbolic link target is unsafe: $relative"
            assert_reviewed_candidate_symlink "$relative" "$target"
            resolved="${path:h}/${target}"
            resolved=${resolved:A}
            [[ "$resolved" == "$root/"* && -e "$resolved" && ! -L "$resolved" ]] \
                || fail "candidate symbolic link is dangling or escapes the app: $relative"
            if [[ "$relative" == \
                'Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC' ]]; then
                [[ -f "$resolved" && -x "$resolved" ]] \
                    || fail "candidate framework executable alias does not resolve to executable code"
            else
                [[ -d "$resolved" ]] \
                    || fail "candidate framework directory alias does not resolve to a directory: $relative"
            fi
            [[ "$links" == 1 ]] \
                || fail "candidate symbolic link has multiple hard links: $relative"
            target_sha=$(sha256_text "$target") \
                || fail "could not hash candidate symbolic link target: $relative"
            /usr/bin/printf 'L\t%s:%s:%s:%s:%s:%s\t%s\t%s\t%s\n' \
                "$mode" "$uid" "$gid" "$links" "$size" "$flags" \
                "$target_sha" "$target" "$relative" >>"$output" \
                || fail "could not record candidate symbolic link: $relative"
            (( link_count += 1 ))
        elif [[ -f "$path" ]]; then
            [[ "$links" == 1 ]] \
                || fail "$root_kind tree contains a hard-linked file: $relative"
            file_sha=$(sha256_file "$path") \
                || fail "could not hash $root_kind tree file: $relative"
            /usr/bin/printf 'F\t%s:%s:%s:%s:%s:%s\t%s\t%s\n' \
                "$mode" "$uid" "$gid" "$links" "$size" "$flags" \
                "$file_sha" "$relative" >>"$output" \
                || fail "could not record $root_kind tree file: $relative"
        elif [[ -d "$path" ]]; then
            [[ ! -L "$path" ]] || fail "$root_kind directory is a symbolic link: $relative"
            /usr/bin/printf 'D\t%s:%s:%s:%s:%s:%s\t%s\n' \
                "$mode" "$uid" "$gid" "$links" "$size" "$flags" \
                "$relative" >>"$output" \
                || fail "could not record $root_kind tree directory: $relative"
        else
            fail "$root_kind tree contains an unsupported file type: $relative"
        fi
        (( record_count += 1 ))
    done <"$listing"
    /bin/rm "$listing" || fail "could not retire staged $root_kind tree listing"
    (( record_count > 0 )) || fail "$root_kind tree manifest is empty"
    if [[ "$root_kind" == candidate ]]; then
        (( link_count == 5 )) \
            || fail "candidate app must contain exactly five reviewed framework aliases"
    else
        (( link_count == 0 )) \
            || fail "$root_kind tree unexpectedly contains symbolic links"
    fi
    assert_private_file "$output" 600 "staged $root_kind tree manifest"
}

render_candidate_copy_manifest() {
    local root=$1
    local output=$2
    local listing path relative metadata mode uid gid links size flags
    local target target_sha file_sha resolved record_count=0 link_count=0

    [[ -d "$root" && ! -L "$root" && "${root:A}" == "$root" ]] \
        || fail "candidate copy-manifest root is unsafe"
    [[ ! -e "$output" && ! -L "$output" ]] \
        || fail "candidate copy-manifest output already exists"
    listing=$(/usr/bin/mktemp "${CAPSULE_ROOT}/.candidate-copy-listing.XXXXXX") \
        || fail "could not stage candidate copy listing"
    /bin/chmod 600 "$listing" || fail "could not protect candidate copy listing"
    /usr/bin/find "$root" -mindepth 1 -print | LC_ALL=C /usr/bin/sort >"$listing" \
        || fail "could not enumerate candidate copy tree"
    [[ -s "$listing" ]] || fail "candidate copy tree is empty"
    : >"$output" || fail "could not create staged candidate copy manifest"
    /bin/chmod 600 "$output" || fail "could not protect staged candidate copy manifest"

    while IFS= read -r path; do
        [[ -n "$path" && "$path" == "$root/"* && "$path" != *[[:cntrl:]]* ]] \
            || fail "candidate copy tree contains an unsafe path"
        relative=${path#"$root/"}
        [[ -n "$relative" && "$relative" != /* && "$relative" != . \
            && "$relative" != .. && "$relative" != ./* && "$relative" != ../* \
            && "$relative" != */. && "$relative" != */.. \
            && "$relative" != */./* && "$relative" != */../* \
            && "$relative" != *//* && "$relative" != */ ]] \
            || fail "candidate copy tree contains a non-normalized relative path"
        assert_no_acl "$path" "candidate copy entry '$relative'"
        assert_no_xattrs "$path" "candidate copy entry '$relative'"
        metadata=$(/usr/bin/stat -f '%Lp:%u:%g:%l:%z:%f' "$path") \
            || fail "could not stat candidate copy entry: $relative"
        IFS=: read -r mode uid gid links size flags <<<"$metadata"
        [[ "$mode" =~ '^[0-7]{3,4}$' && "$uid" =~ '^[0-9]+$' \
            && "$gid" =~ '^[0-9]+$' && "$links" =~ '^[0-9]+$' \
            && "$size" =~ '^[0-9]+$' && "$flags" == 0 ]] \
            || fail "candidate copy entry metadata is unsafe: $relative"
        mode="0${mode}"
        mode=${mode[-4,-1]}
        if [[ -L "$path" ]]; then
            target=$(/usr/bin/readlink "$path") \
                || fail "could not read candidate copy symbolic link: $relative"
            [[ -n "$target" && "$target" != *[[:cntrl:]]* ]] \
                || fail "candidate copy symbolic-link target is unsafe: $relative"
            assert_reviewed_candidate_symlink "$relative" "$target"
            resolved="${path:h}/${target}"
            resolved=${resolved:A}
            [[ "$resolved" == "$root/"* && -e "$resolved" && ! -L "$resolved" \
                && "$links" == 1 ]] \
                || fail "candidate copy symbolic link is dangling, aliased, or escapes the app: $relative"
            if [[ "$relative" == \
                'Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC' ]]; then
                [[ -f "$resolved" && -x "$resolved" ]] \
                    || fail "candidate copy framework alias does not resolve to executable code"
            else
                [[ -d "$resolved" ]] \
                    || fail "candidate copy directory alias does not resolve to a directory: $relative"
            fi
            target_sha=$(sha256_text "$target") \
                || fail "could not hash candidate copy symbolic-link target: $relative"
            /usr/bin/printf 'L\t%s\t%s\t%s\n' \
                "$target_sha" "$target" "$relative" >>"$output" \
                || fail "could not record candidate copy symbolic link: $relative"
            (( link_count += 1 ))
        elif [[ -f "$path" ]]; then
            [[ "$links" == 1 ]] \
                || fail "candidate copy tree contains a hard-linked file: $relative"
            file_sha=$(sha256_file "$path") \
                || fail "could not hash candidate copy file: $relative"
            /usr/bin/printf 'F\t%s:%s\t%s\t%s\n' \
                "$mode" "$size" "$file_sha" "$relative" >>"$output" \
                || fail "could not record candidate copy file: $relative"
        elif [[ -d "$path" && ! -L "$path" ]]; then
            /usr/bin/printf 'D\t%s\t%s\n' "$mode" "$relative" >>"$output" \
                || fail "could not record candidate copy directory: $relative"
        else
            fail "candidate copy tree contains an unsupported file type: $relative"
        fi
        (( record_count += 1 ))
    done <"$listing"
    /bin/rm "$listing" || fail "could not retire candidate copy listing"
    (( record_count > 0 && link_count == 5 )) \
        || fail "candidate copy manifest requires exactly five reviewed aliases"
    assert_private_file "$output" 600 "staged candidate copy manifest"
}

publish_digest_sidecar() {
    local committed=$1
    local destination=$2
    local label=$3
    local digest=$4
    local staged

    assert_sha256 "$digest" "$label digest"
    staged=$(/usr/bin/mktemp "${CAPSULE_ROOT}/.${label// /-}-sidecar.XXXXXX") \
        || fail "could not stage $label sidecar"
    /usr/bin/printf '%s\n' "$digest" >"$staged" \
        || fail "could not render $label sidecar"
    /bin/chmod 600 "$staged" || fail "could not protect staged $label sidecar"
    assert_private_file "$staged" 600 "staged $label sidecar"
    [[ "$(sha256_file "$committed")" == "$digest" ]] \
        || fail "$label changed before sidecar publication"
    publish_exclusive "$staged" "$destination" "$label sidecar"
}

validate_deployment_launch_plist() {
    local plist=$1
    local json

    /usr/bin/plutil -lint "$plist" >/dev/null \
        || fail "deployment launch plist is malformed"
    json=$(/usr/bin/plutil -convert json -o - "$plist") \
        || fail "deployment launch plist JSON projection is unavailable"
    print -r -- "$json" | /usr/bin/jq -e '
        type == "object" and
        (keys | sort) == [
          "EnvironmentVariables", "KeepAlive", "Label", "ProgramArguments",
          "RunAtLoad", "StandardErrorPath", "StandardOutPath", "ThrottleInterval"
        ] and
        .Label == "org.example.opensteamer.worldwide" and
        .ProgramArguments == [
          "/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer",
          "--worldwide",
          "--allow-remote-control",
          "--virtual-phone-display",
          "--secondary-test-viewer",
          "--duration",
          "0",
          "--verbose",
          "--rendezvous-url",
          "wss://audiostreamer-rendezvous.elaminahmed03.workers.dev"
        ] and
        .EnvironmentVariables == {"OSLogRateLimit":"64"} and
        .RunAtLoad == true and
        .KeepAlive == true and
        .ThrottleInterval == 10 and
        .StandardOutPath == "/var/tmp/opensteamer-worldwide-host.log" and
        .StandardErrorPath == "/var/tmp/opensteamer-worldwide-host.err.log"
    ' >/dev/null || fail "deployment launch plist differs from the exact V90 contract"
}

revalidate_committed_tree_manifests() {
    local source_check="${CAPSULE_ROOT}/.v90-source-export-tree-final-check"
    local candidate_check="${CAPSULE_ROOT}/.v90-candidate-app-tree-final-check"
    local copy_check="${CAPSULE_ROOT}/.v90-candidate-app-copy-final-check"

    [[ ! -e "$source_check" && ! -L "$source_check" \
        && ! -e "$candidate_check" && ! -L "$candidate_check" \
        && ! -e "$copy_check" && ! -L "$copy_check" ]] \
        || fail "final tree revalidation staging names already exist"
    render_tree_manifest "$SOURCE_EXPORT" source "$source_check"
    render_tree_manifest "$CANDIDATE_APP" candidate "$candidate_check"
    render_candidate_copy_manifest "$CANDIDATE_APP" "$copy_check"
    [[ "$(sha256_file "$source_check")" == "$SOURCE_TREE_MANIFEST_SHA256" \
        && "$(sha256_file "$candidate_check")" == "$CANDIDATE_TREE_MANIFEST_SHA256" \
        && "$(sha256_file "$copy_check")" == "$CANDIDATE_COPY_MANIFEST_SHA256" ]] \
        || fail "source or candidate tree changed after manifest commitment"
    /usr/bin/cmp -s "$source_check" "$SOURCE_TREE_MANIFEST" \
        || fail "source-export tree no longer equals its committed manifest bytes"
    /usr/bin/cmp -s "$candidate_check" "$CANDIDATE_TREE_MANIFEST" \
        || fail "candidate app no longer equals its committed strong manifest bytes"
    /usr/bin/cmp -s "$copy_check" "$CANDIDATE_COPY_MANIFEST" \
        || fail "candidate app no longer equals its committed copy manifest bytes"
    /bin/rm "$source_check" "$candidate_check" "$copy_check" \
        || fail "could not retire final tree-revalidation staging files"
}

(( $# == 4 )) || usage
readonly ASSEMBLER_SCRIPT=${0:A}
readonly TOOLING_ROOT=${ASSEMBLER_SCRIPT:h:h:h}
readonly SOURCE_INPUT=${1%/}
readonly CAPSULE_INPUT=${2%/}
readonly REFERENCE_INPUT=${3%/}
readonly EXPECTED_REFERENCE_SHA256=$4
assert_sha256 "$EXPECTED_REFERENCE_SHA256" "independently supplied predecessor-reference digest"
assert_sha256 "$APPROVED_PREDECESSOR_REFERENCE_SHA256" \
    "compiled approved predecessor-reference digest"
[[ "$EXPECTED_REFERENCE_SHA256" == "$APPROVED_PREDECESSOR_REFERENCE_SHA256" ]] \
    || fail "external predecessor-reference digest does not equal the explicitly approved compiled pin"

# Reject forbidden roots lexically before resolving or opening any caller-supplied path.
assert_outside_forbidden_roots "$SOURCE_INPUT" "source checkout"
assert_outside_forbidden_roots "$CAPSULE_INPUT" "V90 capsule"
assert_outside_forbidden_roots "$REFERENCE_INPUT" "trusted predecessor reference"

[[ -n "$SOURCE_INPUT" && "$SOURCE_INPUT" == /* && "$SOURCE_INPUT" != *[[:cntrl:]]* \
    && "${SOURCE_INPUT:a}" == "$SOURCE_INPUT" && "${SOURCE_INPUT:A}" == "$SOURCE_INPUT" \
    && -d "$SOURCE_INPUT" && ! -L "$SOURCE_INPUT" ]] \
    || fail "source checkout is not a canonical absolute real directory"
readonly SOURCE_ROOT=$SOURCE_INPUT
! paths_overlap "$SOURCE_ROOT" "$TOOLING_ROOT" \
    || fail "pinned release source and tooling checkout must not overlap"
[[ -n "$CAPSULE_INPUT" && "$CAPSULE_INPUT" == /* \
    && "$CAPSULE_INPUT" != *[[:cntrl:]]* && "${CAPSULE_INPUT:a}" == "$CAPSULE_INPUT" \
    && ! -e "$CAPSULE_INPUT" && ! -L "$CAPSULE_INPUT" ]] \
    || fail "V90 capsule path must be canonical, absolute, and previously absent"
readonly CAPSULE_ROOT=$CAPSULE_INPUT
! paths_overlap "$CAPSULE_ROOT" "$SOURCE_ROOT" \
    || fail "V90 capsule and source checkout must not overlap"
! paths_overlap "$CAPSULE_ROOT" "$TOOLING_ROOT" \
    || fail "V90 capsule and tooling checkout must not overlap"
readonly CAPSULE_PARENT=${CAPSULE_ROOT:h}
[[ "${CAPSULE_PARENT:A}" == "$CAPSULE_PARENT" \
    && -d "$CAPSULE_PARENT" && ! -L "$CAPSULE_PARENT" ]] \
    || fail "V90 capsule parent must be a canonical real directory"
assert_private_directory "$CAPSULE_PARENT" "V90 capsule parent"

[[ -n "$REFERENCE_INPUT" && "$REFERENCE_INPUT" == /* \
    && "$REFERENCE_INPUT" != *[[:cntrl:]]* \
    && "${REFERENCE_INPUT:a}" == "$REFERENCE_INPUT" \
    && "${REFERENCE_INPUT:A}" == "$REFERENCE_INPUT" ]] \
    || fail "trusted predecessor reference path must be canonical and symlink-free"
assert_private_file "$REFERENCE_INPUT" 755 "trusted predecessor reference"
[[ "$REFERENCE_INPUT" != "$SOURCE_ROOT" && "$REFERENCE_INPUT" != "$SOURCE_ROOT/"* \
    && "$REFERENCE_INPUT" != "$CAPSULE_ROOT" && "$REFERENCE_INPUT" != "$CAPSULE_ROOT/"* ]] \
    || fail "trusted predecessor reference must be independent of source and capsule"
assert_predecessor_reference_fingerprint \
    "$REFERENCE_INPUT" "trusted predecessor reference" 1
readonly REFERENCE_INPUT_IDENTITY=$(/usr/bin/stat -f '%d:%i:%z' "$REFERENCE_INPUT") \
    || fail "trusted predecessor reference identity is unavailable"
readonly REFERENCE_INPUT_SHA256=$(sha256_file "$REFERENCE_INPUT") \
    || fail "trusted predecessor reference digest is unavailable"
[[ "$REFERENCE_INPUT_SHA256" == "$EXPECTED_REFERENCE_SHA256" ]] \
    || fail "trusted predecessor reference does not match its independently supplied digest"

[[ -d "$EXPECTED_DEVELOPER_DIR" && ! -L "$EXPECTED_DEVELOPER_DIR" \
    && "${EXPECTED_DEVELOPER_DIR:A}" == "$EXPECTED_DEVELOPER_DIR" ]] \
    || fail "pinned Xcode developer directory is unavailable"
validate_tooling_state "$TOOLING_ROOT" "$ASSEMBLER_SCRIPT"
readonly TOOLING_COMMIT=$TOOLING_COMMIT_RESULT
readonly TOOLING_TREE=$TOOLING_TREE_RESULT
readonly TOOLING_ASSEMBLER_BLOB=$TOOLING_ASSEMBLER_BLOB_RESULT
readonly TOOLING_REMOTE_TIP=$TOOLING_REMOTE_TIP_RESULT
assert_source_state "$SOURCE_ROOT"

/bin/mkdir -m 700 "$CAPSULE_ROOT" \
    || fail "could not create the fresh private V90 capsule"
assert_private_directory "$CAPSULE_ROOT" "V90 capsule root"
readonly CAPSULE_ROOT_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$CAPSULE_ROOT") \
    || fail "V90 capsule identity is unavailable"
readonly CAPSULE_TMPDIR="${CAPSULE_ROOT}/private-tmp"
/bin/mkdir -m 700 "$CAPSULE_TMPDIR" \
    || fail "could not create the private V90 capsule temporary directory"
assert_private_directory "$CAPSULE_TMPDIR" "V90 capsule temporary directory"
readonly CAPSULE_TMPDIR_IDENTITY=$(/usr/bin/stat -f '%d:%i' "$CAPSULE_TMPDIR") \
    || fail "V90 capsule temporary-directory identity is unavailable"
export TMPDIR="$CAPSULE_TMPDIR"

readonly SOURCE_EXPORT="${CAPSULE_ROOT}/source"
readonly BUILD_OUTPUT="${CAPSULE_ROOT}/candidate"
readonly SCRATCH_PATH="${CAPSULE_TMPDIR}/swiftpm-scratch"
readonly REFERENCE_DIRECTORY="${CAPSULE_ROOT}/${REFERENCE_RELATIVE:h}"
readonly REFERENCE_COPY="${CAPSULE_ROOT}/${REFERENCE_RELATIVE}"
/bin/mkdir -m 700 "$SOURCE_EXPORT" "$REFERENCE_DIRECTORY" \
    || fail "could not create private V90 capsule inputs"
assert_private_directory "$SOURCE_EXPORT" "source-export directory"
assert_private_directory "$REFERENCE_DIRECTORY" "trusted-reference directory"

( umask 022
  /usr/bin/git -C "$SOURCE_ROOT" archive --format=tar "$EXPECTED_SOURCE_COMMIT" \
      | /usr/bin/tar -x -f - -C "$SOURCE_EXPORT"
) \
    || fail "could not export the pinned source tree"
assert_source_state "$SOURCE_ROOT"
[[ "$(/usr/bin/git -C "$SOURCE_ROOT" rev-parse --verify \
    "${EXPECTED_SOURCE_COMMIT}^{tree}")" == "$EXPECTED_SOURCE_TREE" ]] \
    || fail "exported source commit no longer resolves to the pinned tree"
readonly SOURCE_TREE_BASELINE="${CAPSULE_ROOT}/.v90-source-export-tree-before-build.txt"
render_tree_manifest "$SOURCE_EXPORT" source "$SOURCE_TREE_BASELINE"
readonly SOURCE_TREE_BASELINE_SHA256=$(sha256_file "$SOURCE_TREE_BASELINE") \
    || fail "could not hash the pre-build source-export tree manifest"

readonly SOURCE_LAUNCH_PLIST="${SOURCE_EXPORT}/macOS/LaunchAgents/org.example.opensteamer.worldwide.plist"
readonly DEPLOYMENT_DIRECTORY="${CAPSULE_ROOT}/deployment"
readonly DEPLOYMENT_LAUNCH_RELATIVE='deployment/org.example.opensteamer.worldwide.plist'
readonly DEPLOYMENT_LAUNCH_PLIST="${CAPSULE_ROOT}/${DEPLOYMENT_LAUNCH_RELATIVE}"
assert_private_file "$SOURCE_LAUNCH_PLIST" 644 "pinned source launch plist"
validate_deployment_launch_plist "$SOURCE_LAUNCH_PLIST"
readonly SOURCE_LAUNCH_PLIST_SHA256=$(sha256_file "$SOURCE_LAUNCH_PLIST") \
    || fail "pinned source launch-plist digest is unavailable"
/bin/mkdir -m 700 "$DEPLOYMENT_DIRECTORY" \
    || fail "could not create private deployment-payload directory"
assert_private_directory "$DEPLOYMENT_DIRECTORY" "deployment-payload directory"
deployment_launch_staged="${DEPLOYMENT_DIRECTORY}/.org.example.opensteamer.worldwide.plist.staged"
/bin/cp "$SOURCE_LAUNCH_PLIST" "$deployment_launch_staged" \
    || fail "could not stage the V90 deployment launch plist"
/bin/chmod 600 "$deployment_launch_staged" \
    || fail "could not protect the staged V90 deployment launch plist"
assert_private_file "$deployment_launch_staged" 600 "staged V90 deployment launch plist"
validate_deployment_launch_plist "$deployment_launch_staged"
[[ "$(sha256_file "$deployment_launch_staged")" == "$SOURCE_LAUNCH_PLIST_SHA256" ]] \
    || fail "deployment launch plist is not an exact byte copy of pinned source"
publish_exclusive "$deployment_launch_staged" "$DEPLOYMENT_LAUNCH_PLIST" \
    "V90 deployment launch plist"
deployment_launch_staged=''
readonly DEPLOYMENT_LAUNCH_PLIST_SHA256=$(sha256_file "$DEPLOYMENT_LAUNCH_PLIST") \
    || fail "V90 deployment launch-plist digest is unavailable"
[[ "$DEPLOYMENT_LAUNCH_PLIST_SHA256" == "$SOURCE_LAUNCH_PLIST_SHA256" ]] \
    || fail "published deployment launch plist differs from pinned source bytes"

/bin/cp "$REFERENCE_INPUT" "$REFERENCE_COPY" \
    || fail "could not copy the trusted predecessor reference into the capsule"
/bin/chmod 755 "$REFERENCE_COPY" \
    || fail "could not normalize the capsule predecessor-reference mode"
assert_private_file "$REFERENCE_COPY" 755 "capsule predecessor reference"
[[ "$(sha256_file "$REFERENCE_COPY")" == "$EXPECTED_REFERENCE_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i' "$REFERENCE_COPY")" \
        != "$(/usr/bin/stat -f '%d:%i' "$REFERENCE_INPUT")" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$REFERENCE_INPUT")" \
        == "$REFERENCE_INPUT_IDENTITY" \
    && "$(sha256_file "$REFERENCE_INPUT")" == "$EXPECTED_REFERENCE_SHA256" ]] \
    || fail "trusted predecessor reference changed or was not independently copied"
assert_predecessor_reference_fingerprint \
    "$REFERENCE_INPUT" "trusted predecessor reference after capsule copy" 1
assert_predecessor_reference_fingerprint \
    "$REFERENCE_COPY" "capsule predecessor reference" 0

readonly BUILDER="${SOURCE_EXPORT}/macOS/scripts/build-opensteamer-host-app.sh"
readonly HANDOFF_PREPARER="${SOURCE_EXPORT}/macOS/scripts/prepare-v90-sealed-host-oracle-handoff.sh"
[[ -f "$BUILDER" && ! -L "$BUILDER" && -x "$BUILDER" \
    && -f "$HANDOFF_PREPARER" && ! -L "$HANDOFF_PREPARER" \
    && -x "$HANDOFF_PREPARER" ]] \
    || fail "pinned source export lacks the reviewed V90 builder or handoff preparer"

builder_output=$(/usr/bin/env -i \
    HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    PATH='/usr/bin:/bin:/usr/sbin:/sbin' TMPDIR="$CAPSULE_TMPDIR" \
    DEVELOPER_DIR="$EXPECTED_DEVELOPER_DIR" \
    OPENSTEAMER_HOST_APP_OUTPUT_DIR="$BUILD_OUTPUT" \
    OPENSTEAMER_HOST_SCRATCH_PATH="$SCRATCH_PATH" \
    OPENSTEAMER_REQUIRE_FRESH_RELEASE=1 \
    OPENSTEAMER_HOST_CODESIGN_IDENTITY="$EXPECTED_SIGNING_IDENTITY_SHA1" \
    OPENSTEAMER_EXPECTED_SIGNING_IDENTITY_SHA1="$EXPECTED_SIGNING_IDENTITY_SHA1" \
    OPENSTEAMER_EXPECTED_TEAM_ID="$EXPECTED_TEAM_ID" \
    OPENSTEAMER_HOST_DESIGNATED_REQUIREMENT_REFERENCE="$REFERENCE_COPY" \
    OPENSTEAMER_EXPECTED_ARCHITECTURES="$EXPECTED_ARCHITECTURES" \
    "$BUILDER") || fail "fresh pinned V90 host build failed"
readonly CANDIDATE_APP="${CAPSULE_ROOT}/${CANDIDATE_RELATIVE}"
[[ "$builder_output" == "$CANDIDATE_APP" ]] \
    || fail "V90 builder returned an unexpected candidate path"
assert_exact_private_directory_shape "$BUILD_OUTPUT" \
    "V90 candidate output directory" 'opensteamer Host.app'
assert_candidate_app_root "$CANDIDATE_APP" "V90 candidate app root"
readonly CANDIDATE_EXECUTABLE="${CANDIDATE_APP}/Contents/MacOS/CaptureServer"
readonly CANDIDATE_FRAMEWORK_ALIAS="${CANDIDATE_APP}/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
readonly CANDIDATE_FRAMEWORK_RELATIVE="${CANDIDATE_RELATIVE}/Contents/Frameworks/LiveKitWebRTC.framework/Versions/A/LiveKitWebRTC"
readonly CANDIDATE_FRAMEWORK_EXECUTABLE="${CAPSULE_ROOT}/${CANDIDATE_FRAMEWORK_RELATIVE}"
assert_private_file "$CANDIDATE_EXECUTABLE" 755 "V90 candidate executable"
[[ -L "$CANDIDATE_FRAMEWORK_ALIAS" ]] \
    || fail "V90 candidate media-framework alias is unavailable"
[[ "${CANDIDATE_FRAMEWORK_ALIAS:A}" == "$CANDIDATE_FRAMEWORK_EXECUTABLE" ]] \
    || fail "V90 candidate media-framework alias does not resolve to the canonical Versions/A executable"
assert_private_file "$CANDIDATE_FRAMEWORK_EXECUTABLE" 755 \
    "V90 candidate media-framework executable"
readonly CANDIDATE_EXECUTABLE_SHA256=$(sha256_file "$CANDIDATE_EXECUTABLE") \
    || fail "V90 candidate executable digest is unavailable"
readonly CANDIDATE_FRAMEWORK_SHA256=$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE") \
    || fail "V90 candidate media-framework digest is unavailable"
[[ "$CANDIDATE_EXECUTABLE_SHA256" != "$EXPECTED_REFERENCE_SHA256" \
    && "$(/usr/bin/stat -f '%d:%i' "$CANDIDATE_EXECUTABLE")" \
        != "$(/usr/bin/stat -f '%d:%i' "$REFERENCE_COPY")" ]] \
    || fail "V90 candidate and predecessor reference are not independent"

readonly SOURCE_TREE_MANIFEST="${CAPSULE_ROOT}/${SOURCE_TREE_MANIFEST_BASENAME}"
readonly CANDIDATE_TREE_MANIFEST="${CAPSULE_ROOT}/${CANDIDATE_TREE_MANIFEST_BASENAME}"
readonly CANDIDATE_COPY_MANIFEST="${CAPSULE_ROOT}/${CANDIDATE_COPY_MANIFEST_BASENAME}"
source_tree_staged="${CAPSULE_ROOT}/.v90-source-export-tree-manifest.staged"
candidate_tree_staged="${CAPSULE_ROOT}/.v90-candidate-app-tree-manifest.staged"
candidate_copy_staged="${CAPSULE_ROOT}/.v90-candidate-app-copy-manifest.staged"
[[ ! -e "$source_tree_staged" && ! -L "$source_tree_staged" \
    && ! -e "$candidate_tree_staged" && ! -L "$candidate_tree_staged" \
    && ! -e "$candidate_copy_staged" && ! -L "$candidate_copy_staged" ]] \
    || fail "tree-manifest staging names already exist"
render_tree_manifest "$SOURCE_EXPORT" source "$source_tree_staged"
readonly SOURCE_TREE_MANIFEST_SHA256=$(sha256_file "$source_tree_staged") \
    || fail "could not hash final source-export tree manifest"
[[ "$SOURCE_TREE_MANIFEST_SHA256" == "$SOURCE_TREE_BASELINE_SHA256" ]] \
    || fail "pinned source export changed during the V90 build"
/bin/rm "$SOURCE_TREE_BASELINE" \
    || fail "could not retire pre-build source-export tree manifest"
publish_exclusive "$source_tree_staged" "$SOURCE_TREE_MANIFEST" \
    "source-export tree manifest"
source_tree_staged=''
render_tree_manifest "$CANDIDATE_APP" candidate "$candidate_tree_staged"
readonly CANDIDATE_TREE_MANIFEST_SHA256=$(sha256_file "$candidate_tree_staged") \
    || fail "could not hash candidate-app tree manifest"
publish_exclusive "$candidate_tree_staged" "$CANDIDATE_TREE_MANIFEST" \
    "candidate-app tree manifest"
candidate_tree_staged=''
render_candidate_copy_manifest "$CANDIDATE_APP" "$candidate_copy_staged"
readonly CANDIDATE_COPY_MANIFEST_SHA256=$(sha256_file "$candidate_copy_staged") \
    || fail "could not hash candidate-app copy manifest"
publish_exclusive "$candidate_copy_staged" "$CANDIDATE_COPY_MANIFEST" \
    "candidate-app copy manifest"
candidate_copy_staged=''

readonly METADATA="${CAPSULE_ROOT}/${METADATA_BASENAME}"
staged_metadata=$(/usr/bin/mktemp "${CAPSULE_ROOT}/.v90-capsule-metadata.XXXXXX") \
    || fail "could not create staged V90 capsule metadata"
cleanup_staging() {
    [[ -n "${staged_metadata:-}" && -e "$staged_metadata" ]] \
        && /bin/rm -f "$staged_metadata"
}
trap cleanup_staging EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/jq -n -S \
    --arg schema "$METADATA_SCHEMA" \
    --arg candidateAppRelativePath "$CANDIDATE_RELATIVE" \
    --arg candidateExecutableSHA256 "$CANDIDATE_EXECUTABLE_SHA256" \
    --arg candidateMediaFrameworkExecutableSHA256 "$CANDIDATE_FRAMEWORK_SHA256" \
    --arg designatedRequirementReferenceRelativePath "$REFERENCE_RELATIVE" \
    --arg designatedRequirementReferenceSHA256 "$EXPECTED_REFERENCE_SHA256" '
    {
      schema: $schema,
      candidateAppRelativePath: $candidateAppRelativePath,
      candidateExecutableSHA256: $candidateExecutableSHA256,
      candidateMediaFrameworkExecutableSHA256: $candidateMediaFrameworkExecutableSHA256,
      designatedRequirementReferenceRelativePath: $designatedRequirementReferenceRelativePath,
      designatedRequirementReferenceSHA256: $designatedRequirementReferenceSHA256
    }
' >"$staged_metadata" || fail "could not render V90 capsule metadata"
/bin/chmod 600 "$staged_metadata" || fail "could not protect staged V90 capsule metadata"
assert_private_file "$staged_metadata" 600 "staged V90 capsule metadata"
publish_exclusive "$staged_metadata" "$METADATA" "V90 capsule metadata"
staged_metadata=''
trap - EXIT HUP INT TERM
readonly METADATA_SHA256=$(sha256_file "$METADATA") \
    || fail "V90 capsule metadata digest is unavailable"

[[ "$(/usr/bin/stat -f '%d:%i' "$CAPSULE_ROOT")" == "$CAPSULE_ROOT_IDENTITY" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$REFERENCE_INPUT")" \
        == "$REFERENCE_INPUT_IDENTITY" \
    && "$(sha256_file "$REFERENCE_INPUT")" == "$EXPECTED_REFERENCE_SHA256" \
    && "$(sha256_file "$REFERENCE_COPY")" == "$EXPECTED_REFERENCE_SHA256" \
    && "$(sha256_file "$CANDIDATE_EXECUTABLE")" == "$CANDIDATE_EXECUTABLE_SHA256" \
    && "$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE")" \
        == "$CANDIDATE_FRAMEWORK_SHA256" ]] \
    || fail "V90 capsule inputs changed before handoff preparation"

handoff_output=$(/usr/bin/env -i \
    HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
    PATH='/usr/bin:/bin:/usr/sbin:/sbin' TMPDIR="$CAPSULE_TMPDIR" \
    "$HANDOFF_PREPARER" prepare "$METADATA" "$METADATA_SHA256") \
    || fail "V90 sealed-host handoff preparation failed"

readonly HANDOFF_RELATIVE='v90-screen-oracle-handoff/v90-screen-oracle-host-identity-handoff.json'
readonly HANDOFF_SIDECAR_RELATIVE='v90-screen-oracle-handoff/v90-screen-oracle-host-identity-handoff.json.sha256'
readonly HOST_IDENTITY_RELATIVE='v90-screen-oracle-handoff/sealed-live-mac-host-identity.json'
readonly HOST_IDENTITY_SIDECAR_RELATIVE='v90-screen-oracle-handoff/sealed-live-mac-host-identity.json.sha256'
readonly HANDOFF="${CAPSULE_ROOT}/${HANDOFF_RELATIVE}"
readonly HANDOFF_SIDECAR="${CAPSULE_ROOT}/${HANDOFF_SIDECAR_RELATIVE}"
readonly HOST_IDENTITY="${CAPSULE_ROOT}/${HOST_IDENTITY_RELATIVE}"
readonly HOST_IDENTITY_SIDECAR="${CAPSULE_ROOT}/${HOST_IDENTITY_SIDECAR_RELATIVE}"
assert_private_file "$HANDOFF" 600 "committed V90 handoff"
assert_private_file "$HANDOFF_SIDECAR" 600 "committed V90 handoff sidecar"
assert_private_file "$HOST_IDENTITY" 600 "sealed V90 host-identity manifest"
assert_private_file "$HOST_IDENTITY_SIDECAR" 600 "sealed V90 host-identity sidecar"
readonly HANDOFF_SHA256=$(sha256_file "$HANDOFF") \
    || fail "committed V90 handoff digest is unavailable"
readonly HOST_IDENTITY_SHA256=$(sha256_file "$HOST_IDENTITY") \
    || fail "sealed V90 host-identity digest is unavailable"
[[ "$(/usr/bin/stat -f '%z' "$HANDOFF_SIDECAR")" == 65 \
    && "$(/usr/bin/tr -d '\n' <"$HANDOFF_SIDECAR")" == "$HANDOFF_SHA256" \
    && "$(/usr/bin/stat -f '%z' "$HOST_IDENTITY_SIDECAR")" == 65 \
    && "$(/usr/bin/tr -d '\n' <"$HOST_IDENTITY_SIDECAR")" == "$HOST_IDENTITY_SHA256" ]] \
    || fail "V90 handoff or host-identity commit marker is malformed"
expected_handoff_output=$'handoff_path='"$HANDOFF"$'\nhandoff_sha256='"$HANDOFF_SHA256"$'\nhandoff_sha256_path='"$HANDOFF_SIDECAR"$'\nmanifest_path='"$HOST_IDENTITY"$'\nmanifest_sha256='"$HOST_IDENTITY_SHA256"$'\nmanifest_sha256_path='"$HOST_IDENTITY_SIDECAR"
[[ "$handoff_output" == "$expected_handoff_output" ]] \
    || fail "V90 handoff preparer returned an unexpected publication record"

readonly CANDIDATE_EXECUTABLE_RELATIVE="${CANDIDATE_RELATIVE}/Contents/MacOS/CaptureServer"
readonly CANDIDATE_INFO_RELATIVE="${CANDIDATE_RELATIVE}/Contents/Info.plist"
readonly CANDIDATE_INFO="${CAPSULE_ROOT}/${CANDIDATE_INFO_RELATIVE}"
assert_private_file "$CANDIDATE_INFO" 644 "V90 candidate Info.plist"
readonly CANDIDATE_INFO_SHA256=$(sha256_file "$CANDIDATE_INFO") \
    || fail "V90 candidate Info.plist digest is unavailable"
validate_deployment_launch_plist "$DEPLOYMENT_LAUNCH_PLIST"
[[ "$(sha256_file "$DEPLOYMENT_LAUNCH_PLIST")" == "$DEPLOYMENT_LAUNCH_PLIST_SHA256" ]] \
    || fail "V90 deployment launch plist changed before payload publication"

readonly PAYLOAD_MANIFEST="${CAPSULE_ROOT}/${PAYLOAD_MANIFEST_BASENAME}"
readonly PAYLOAD_SIDECAR="${CAPSULE_ROOT}/${PAYLOAD_SIDECAR_BASENAME}"
payload_staged=$(/usr/bin/mktemp "${CAPSULE_ROOT}/.v90-deployment-payload.XXXXXX") \
    || fail "could not create staged V90 deployment-payload manifest"
/usr/bin/jq -n -S \
    --arg schema "$PAYLOAD_SCHEMA" \
    --arg sourceCommit "$EXPECTED_SOURCE_COMMIT" \
    --arg sourceTree "$EXPECTED_SOURCE_TREE" \
    --arg sourceBranch "$EXPECTED_SOURCE_BRANCH" \
    --arg sourceUpstream "$EXPECTED_SOURCE_UPSTREAM" \
    --arg toolingBranch "$EXPECTED_SOURCE_BRANCH" \
    --arg toolingUpstream "$EXPECTED_SOURCE_UPSTREAM" \
    --arg toolingCommit "$TOOLING_COMMIT" \
    --arg toolingTree "$TOOLING_TREE" \
    --arg toolingRemoteURL "$EXPECTED_TOOLING_REMOTE_URL" \
    --arg assemblerScriptRelativePath "$ASSEMBLER_RELATIVE_PATH" \
    --arg assemblerScriptGitBlob "$TOOLING_ASSEMBLER_BLOB" \
    --arg sourceExportRelativePath source \
    --arg sourceTreeManifestRelativePath "$SOURCE_TREE_MANIFEST_BASENAME" \
    --arg sourceTreeManifestSHA256 "$SOURCE_TREE_MANIFEST_SHA256" \
    --arg candidateAppRelativePath "$CANDIDATE_RELATIVE" \
    --arg candidateAppTreeManifestRelativePath "$CANDIDATE_TREE_MANIFEST_BASENAME" \
    --arg candidateAppTreeManifestSHA256 "$CANDIDATE_TREE_MANIFEST_SHA256" \
    --arg candidateAppCopyManifestRelativePath "$CANDIDATE_COPY_MANIFEST_BASENAME" \
    --arg candidateAppCopyManifestSHA256 "$CANDIDATE_COPY_MANIFEST_SHA256" \
    --arg candidateExecutableRelativePath "$CANDIDATE_EXECUTABLE_RELATIVE" \
    --arg candidateExecutableSHA256 "$CANDIDATE_EXECUTABLE_SHA256" \
    --arg candidateMediaFrameworkExecutableRelativePath "$CANDIDATE_FRAMEWORK_RELATIVE" \
    --arg candidateMediaFrameworkExecutableSHA256 "$CANDIDATE_FRAMEWORK_SHA256" \
    --arg candidateInfoPlistRelativePath "$CANDIDATE_INFO_RELATIVE" \
    --arg candidateInfoPlistSHA256 "$CANDIDATE_INFO_SHA256" \
    --arg candidateLaunchPlistRelativePath "$DEPLOYMENT_LAUNCH_RELATIVE" \
    --arg candidateLaunchPlistSHA256 "$DEPLOYMENT_LAUNCH_PLIST_SHA256" \
    --arg capsuleMetadataRelativePath "$METADATA_BASENAME" \
    --arg capsuleMetadataSHA256 "$METADATA_SHA256" \
    --arg handoffRelativePath "$HANDOFF_RELATIVE" \
    --arg handoffSHA256 "$HANDOFF_SHA256" \
    --arg hostIdentityManifestRelativePath "$HOST_IDENTITY_RELATIVE" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_SHA256" \
    --arg designatedRequirementReferenceRelativePath "$REFERENCE_RELATIVE" \
    --arg designatedRequirementReferenceSHA256 "$EXPECTED_REFERENCE_SHA256" \
    --arg designatedRequirementReferenceFileSize "$APPROVED_PREDECESSOR_REFERENCE_FILE_SIZE" \
    --arg designatedRequirementReferenceCodeSignatureDataOffset "$APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATAOFF" \
    --arg designatedRequirementReferenceCodeSignatureDataSize "$APPROVED_PREDECESSOR_REFERENCE_CODE_SIGNATURE_DATASIZE" \
    --arg designatedRequirementReferenceUnsignedPrefixSHA256 "$APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256" \
    --arg designatedRequirementReferenceCDHash "$APPROVED_PREDECESSOR_REFERENCE_CDHASH" \
    --arg designatedRequirementReferenceCodeDirectorySHA256 "$APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256" \
    --arg designatedRequirementReferenceTeamIdentifier "$APPROVED_PREDECESSOR_REFERENCE_TEAM_ID" \
    --arg designatedRequirementReferenceIdentifier "$APPROVED_PREDECESSOR_REFERENCE_IDENTIFIER" \
    --arg designatedRequirementReferenceDesignatedRequirement "$APPROVED_PREDECESSOR_REFERENCE_DESIGNATED_REQUIREMENT" '
    {
      schema: $schema,
      sourceCommit: $sourceCommit,
      sourceTree: $sourceTree,
      sourceBranch: $sourceBranch,
      sourceUpstream: $sourceUpstream,
      toolingBranch: $toolingBranch,
      toolingUpstream: $toolingUpstream,
      toolingCommit: $toolingCommit,
      toolingTree: $toolingTree,
      toolingRemoteURL: $toolingRemoteURL,
      assemblerScriptRelativePath: $assemblerScriptRelativePath,
      assemblerScriptGitBlob: $assemblerScriptGitBlob,
      sourceExportRelativePath: $sourceExportRelativePath,
      sourceTreeManifestRelativePath: $sourceTreeManifestRelativePath,
      sourceTreeManifestSHA256: $sourceTreeManifestSHA256,
      candidateAppRelativePath: $candidateAppRelativePath,
      candidateAppTreeManifestRelativePath: $candidateAppTreeManifestRelativePath,
      candidateAppTreeManifestSHA256: $candidateAppTreeManifestSHA256,
      candidateAppCopyManifestRelativePath: $candidateAppCopyManifestRelativePath,
      candidateAppCopyManifestSHA256: $candidateAppCopyManifestSHA256,
      candidateExecutableRelativePath: $candidateExecutableRelativePath,
      candidateExecutableSHA256: $candidateExecutableSHA256,
      candidateMediaFrameworkExecutableRelativePath: $candidateMediaFrameworkExecutableRelativePath,
      candidateMediaFrameworkExecutableSHA256: $candidateMediaFrameworkExecutableSHA256,
      candidateInfoPlistRelativePath: $candidateInfoPlistRelativePath,
      candidateInfoPlistSHA256: $candidateInfoPlistSHA256,
      candidateLaunchPlistRelativePath: $candidateLaunchPlistRelativePath,
      candidateLaunchPlistSHA256: $candidateLaunchPlistSHA256,
      capsuleMetadataRelativePath: $capsuleMetadataRelativePath,
      capsuleMetadataSHA256: $capsuleMetadataSHA256,
      handoffRelativePath: $handoffRelativePath,
      handoffSHA256: $handoffSHA256,
      hostIdentityManifestRelativePath: $hostIdentityManifestRelativePath,
      hostIdentityManifestSHA256: $hostIdentityManifestSHA256,
      designatedRequirementReferenceRelativePath: $designatedRequirementReferenceRelativePath,
      designatedRequirementReferenceSHA256: $designatedRequirementReferenceSHA256,
      designatedRequirementReferenceFileSize: $designatedRequirementReferenceFileSize,
      designatedRequirementReferenceCodeSignatureDataOffset: $designatedRequirementReferenceCodeSignatureDataOffset,
      designatedRequirementReferenceCodeSignatureDataSize: $designatedRequirementReferenceCodeSignatureDataSize,
      designatedRequirementReferenceUnsignedPrefixSHA256: $designatedRequirementReferenceUnsignedPrefixSHA256,
      designatedRequirementReferenceCDHash: $designatedRequirementReferenceCDHash,
      designatedRequirementReferenceCodeDirectorySHA256: $designatedRequirementReferenceCodeDirectorySHA256,
      designatedRequirementReferenceTeamIdentifier: $designatedRequirementReferenceTeamIdentifier,
      designatedRequirementReferenceIdentifier: $designatedRequirementReferenceIdentifier,
      designatedRequirementReferenceDesignatedRequirement: $designatedRequirementReferenceDesignatedRequirement
    }
' >"$payload_staged" || fail "could not render V90 deployment-payload manifest"
/bin/chmod 600 "$payload_staged" \
    || fail "could not protect staged V90 deployment-payload manifest"
assert_private_file "$payload_staged" 600 "staged V90 deployment-payload manifest"
/usr/bin/jq --stream -c . "$payload_staged" | /usr/bin/jq -e -s '
    [ .[] | select(length == 2) | .[0] ] as $paths
    | ($paths | length) == 45
      and ($paths | all(length == 1))
      and (($paths | map(.[0]) | sort) == [
        "assemblerScriptGitBlob",
        "assemblerScriptRelativePath",
        "candidateAppCopyManifestRelativePath",
        "candidateAppCopyManifestSHA256",
        "candidateAppRelativePath",
        "candidateAppTreeManifestRelativePath",
        "candidateAppTreeManifestSHA256",
        "candidateExecutableRelativePath",
        "candidateExecutableSHA256",
        "candidateInfoPlistRelativePath",
        "candidateInfoPlistSHA256",
        "candidateLaunchPlistRelativePath",
        "candidateLaunchPlistSHA256",
        "candidateMediaFrameworkExecutableRelativePath",
        "candidateMediaFrameworkExecutableSHA256",
        "capsuleMetadataRelativePath",
        "capsuleMetadataSHA256",
        "designatedRequirementReferenceCDHash",
        "designatedRequirementReferenceCodeDirectorySHA256",
        "designatedRequirementReferenceCodeSignatureDataOffset",
        "designatedRequirementReferenceCodeSignatureDataSize",
        "designatedRequirementReferenceDesignatedRequirement",
        "designatedRequirementReferenceFileSize",
        "designatedRequirementReferenceIdentifier",
        "designatedRequirementReferenceRelativePath",
        "designatedRequirementReferenceSHA256",
        "designatedRequirementReferenceTeamIdentifier",
        "designatedRequirementReferenceUnsignedPrefixSHA256",
        "handoffRelativePath",
        "handoffSHA256",
        "hostIdentityManifestRelativePath",
        "hostIdentityManifestSHA256",
        "schema",
        "sourceBranch",
        "sourceCommit",
        "sourceExportRelativePath",
        "sourceTree",
        "sourceTreeManifestRelativePath",
        "sourceTreeManifestSHA256",
        "sourceUpstream",
        "toolingBranch",
        "toolingCommit",
        "toolingRemoteURL",
        "toolingTree",
        "toolingUpstream"
      ])
' >/dev/null || fail "V90 deployment-payload manifest has duplicate, nested, or unknown fields"
/usr/bin/jq -e --arg schema "$PAYLOAD_SCHEMA" '
    type == "object" and (keys | length) == 45 and .schema == $schema and
    all(.[]; type == "string")
' "$payload_staged" >/dev/null \
    || fail "V90 deployment-payload manifest shape is invalid"
publish_exclusive "$payload_staged" "$PAYLOAD_MANIFEST" \
    "V90 deployment-payload manifest"
payload_staged=''
readonly PAYLOAD_MANIFEST_SHA256=$(sha256_file "$PAYLOAD_MANIFEST") \
    || fail "V90 deployment-payload digest is unavailable"
publish_digest_sidecar "$PAYLOAD_MANIFEST" "$PAYLOAD_SIDECAR" \
    "V90 deployment-payload manifest" "$PAYLOAD_MANIFEST_SHA256"

validate_tooling_state "$TOOLING_ROOT" "$ASSEMBLER_SCRIPT"
[[ "$TOOLING_COMMIT_RESULT" == "$TOOLING_COMMIT" \
    && "$TOOLING_TREE_RESULT" == "$TOOLING_TREE" \
    && "$TOOLING_ASSEMBLER_BLOB_RESULT" == "$TOOLING_ASSEMBLER_BLOB" \
    && "$TOOLING_REMOTE_TIP_RESULT" == "$TOOLING_REMOTE_TIP" ]] \
    || fail "tooling checkout or fresh remote proof changed during assembly"
assert_source_state "$SOURCE_ROOT"

[[ "$(/usr/bin/stat -f '%d:%i' "$CAPSULE_TMPDIR")" == "$CAPSULE_TMPDIR_IDENTITY" \
    && "$CAPSULE_TMPDIR" == "$CAPSULE_ROOT/"* && -d "$CAPSULE_TMPDIR" \
    && ! -L "$CAPSULE_TMPDIR" ]] \
    || fail "private V90 build workspace identity changed before retirement"
/bin/rm -R "$CAPSULE_TMPDIR" \
    || fail "could not retire the private V90 build workspace"
unset TMPDIR
[[ ! -e "$CAPSULE_TMPDIR" && ! -L "$CAPSULE_TMPDIR" \
    && ! -e "${CAPSULE_ROOT}/swiftpm-scratch" \
    && ! -L "${CAPSULE_ROOT}/swiftpm-scratch" ]] \
    || fail "unsealed V90 build scratch survived finalization"

private_file_specs=(
    "$REFERENCE_COPY" 755 'capsule predecessor reference'
    "$CANDIDATE_EXECUTABLE" 755 'V90 candidate executable'
    "$CANDIDATE_FRAMEWORK_EXECUTABLE" 755 'V90 candidate media-framework executable'
    "$CANDIDATE_INFO" 644 'V90 candidate Info.plist'
    "$DEPLOYMENT_LAUNCH_PLIST" 600 'V90 deployment launch plist'
    "$SOURCE_TREE_MANIFEST" 600 'source-export tree manifest'
    "$CANDIDATE_TREE_MANIFEST" 600 'candidate-app strong manifest'
    "$CANDIDATE_COPY_MANIFEST" 600 'candidate-app copy manifest'
    "$METADATA" 600 'V90 capsule metadata'
    "$HANDOFF" 600 'committed V90 handoff'
    "$HANDOFF_SIDECAR" 600 'committed V90 handoff sidecar'
    "$HOST_IDENTITY" 600 'sealed V90 host-identity manifest'
    "$HOST_IDENTITY_SIDECAR" 600 'sealed V90 host-identity sidecar'
    "$PAYLOAD_MANIFEST" 600 'V90 deployment-payload manifest'
    "$PAYLOAD_SIDECAR" 600 'V90 deployment-payload sidecar'
)
for (( private_file_index = 1; \
    private_file_index <= ${#private_file_specs}; \
    private_file_index += 3 )); do
    assert_private_file \
        "${private_file_specs[$private_file_index]}" \
        "${private_file_specs[$(( private_file_index + 1 ))]}" \
        "${private_file_specs[$(( private_file_index + 2 ))]}"
done
validate_deployment_launch_plist "$DEPLOYMENT_LAUNCH_PLIST"
assert_private_directory "$CAPSULE_ROOT" "final V90 capsule root"
readonly FINAL_TOP_LEVEL_ENTRIES=$(/bin/ls -1A "$CAPSULE_ROOT" | LC_ALL=C /usr/bin/sort) \
    || fail "could not inspect final V90 capsule shape"
[[ "$FINAL_TOP_LEVEL_ENTRIES" == $'candidate\ndeployment\nsource\ntrusted-reference\ntrusted-v90-host-oracle-capsule-metadata.json\nv90-candidate-app-copy-manifest.txt\nv90-candidate-app-tree-manifest.txt\nv90-deployment-payload-manifest.json\nv90-deployment-payload-manifest.json.sha256\nv90-screen-oracle-handoff\nv90-source-export-tree-manifest.txt' ]] \
    || fail "final V90 capsule contains uncommitted or unexpected top-level entries"
assert_exact_private_directory_shape "$REFERENCE_DIRECTORY" \
    "final trusted-reference directory" 'CaptureServer'
assert_exact_private_directory_shape "$DEPLOYMENT_DIRECTORY" \
    "final deployment directory" 'org.example.opensteamer.worldwide.plist'
assert_exact_private_directory_shape "${CAPSULE_ROOT}/v90-screen-oracle-handoff" \
    "final V90 handoff directory" \
    $'sealed-live-mac-host-identity.json\nsealed-live-mac-host-identity.json.sha256\nv90-screen-oracle-host-identity-handoff.json\nv90-screen-oracle-host-identity-handoff.json.sha256'
revalidate_committed_tree_manifests
assert_exact_private_directory_shape "$BUILD_OUTPUT" \
    "final V90 candidate output directory" 'opensteamer Host.app'
assert_candidate_app_root "$CANDIDATE_APP" "final V90 candidate app root"
assert_predecessor_reference_fingerprint \
    "$REFERENCE_INPUT" "final trusted predecessor reference" 1
assert_predecessor_reference_fingerprint \
    "$REFERENCE_COPY" "final capsule predecessor reference" 0
[[ "$(/usr/bin/stat -f '%d:%i' "$CAPSULE_ROOT")" == "$CAPSULE_ROOT_IDENTITY" \
    && "$(/usr/bin/stat -f '%d:%i:%z' "$REFERENCE_INPUT")" \
        == "$REFERENCE_INPUT_IDENTITY" \
    && "$(sha256_file "$REFERENCE_INPUT")" == "$EXPECTED_REFERENCE_SHA256" \
    && "$(sha256_file "$REFERENCE_COPY")" == "$EXPECTED_REFERENCE_SHA256" \
    && "$(sha256_file "$CANDIDATE_EXECUTABLE")" == "$CANDIDATE_EXECUTABLE_SHA256" \
    && "$(sha256_file "$CANDIDATE_FRAMEWORK_EXECUTABLE")" == "$CANDIDATE_FRAMEWORK_SHA256" \
    && "$(sha256_file "$CANDIDATE_INFO")" == "$CANDIDATE_INFO_SHA256" \
    && "$(sha256_file "$SOURCE_LAUNCH_PLIST")" == "$SOURCE_LAUNCH_PLIST_SHA256" \
    && "$(sha256_file "$DEPLOYMENT_LAUNCH_PLIST")" == "$SOURCE_LAUNCH_PLIST_SHA256" \
    && "$(sha256_file "$SOURCE_TREE_MANIFEST")" == "$SOURCE_TREE_MANIFEST_SHA256" \
    && "$(sha256_file "$CANDIDATE_TREE_MANIFEST")" == "$CANDIDATE_TREE_MANIFEST_SHA256" \
    && "$(sha256_file "$CANDIDATE_COPY_MANIFEST")" == "$CANDIDATE_COPY_MANIFEST_SHA256" \
    && "$(sha256_file "$METADATA")" == "$METADATA_SHA256" \
    && "$(sha256_file "$HANDOFF")" == "$HANDOFF_SHA256" \
    && "$(/usr/bin/tr -d '\n' <"$HANDOFF_SIDECAR")" == "$HANDOFF_SHA256" \
    && "$(sha256_file "$HOST_IDENTITY")" == "$HOST_IDENTITY_SHA256" \
    && "$(/usr/bin/tr -d '\n' <"$HOST_IDENTITY_SIDECAR")" == "$HOST_IDENTITY_SHA256" \
    && "$(sha256_file "$PAYLOAD_MANIFEST")" == "$PAYLOAD_MANIFEST_SHA256" \
    && "$(/usr/bin/tr -d '\n' <"$PAYLOAD_SIDECAR")" == "$PAYLOAD_MANIFEST_SHA256" ]] \
    || fail "committed V90 deployment payload changed before final output"

print -r -- "capsule_path=$CAPSULE_ROOT"
print -r -- "source_export_path=$SOURCE_EXPORT"
print -r -- "source_branch=$EXPECTED_SOURCE_BRANCH"
print -r -- "source_upstream=$EXPECTED_SOURCE_UPSTREAM"
print -r -- "source_commit=$EXPECTED_SOURCE_COMMIT"
print -r -- "source_tree=$EXPECTED_SOURCE_TREE"
print -r -- "tooling_commit=$TOOLING_COMMIT"
print -r -- "tooling_tree=$TOOLING_TREE"
print -r -- "tooling_remote_url=$EXPECTED_TOOLING_REMOTE_URL"
print -r -- "assembler_script_git_blob=$TOOLING_ASSEMBLER_BLOB"
print -r -- "candidate_app_path=$CANDIDATE_APP"
print -r -- "source_tree_manifest_path=$SOURCE_TREE_MANIFEST"
print -r -- "source_tree_manifest_sha256=$SOURCE_TREE_MANIFEST_SHA256"
print -r -- "candidate_app_tree_manifest_path=$CANDIDATE_TREE_MANIFEST"
print -r -- "candidate_app_tree_manifest_sha256=$CANDIDATE_TREE_MANIFEST_SHA256"
print -r -- "candidate_app_copy_manifest_path=$CANDIDATE_COPY_MANIFEST"
print -r -- "candidate_app_copy_manifest_sha256=$CANDIDATE_COPY_MANIFEST_SHA256"
print -r -- "candidate_executable_sha256=$CANDIDATE_EXECUTABLE_SHA256"
print -r -- "candidate_media_framework_executable_sha256=$CANDIDATE_FRAMEWORK_SHA256"
print -r -- "candidate_launch_plist_path=$DEPLOYMENT_LAUNCH_PLIST"
print -r -- "candidate_launch_plist_sha256=$DEPLOYMENT_LAUNCH_PLIST_SHA256"
print -r -- "designated_requirement_reference_path=$REFERENCE_COPY"
print -r -- "designated_requirement_reference_sha256=$EXPECTED_REFERENCE_SHA256"
print -r -- "designated_requirement_reference_unsigned_prefix_sha256=$APPROVED_PREDECESSOR_REFERENCE_UNSIGNED_PREFIX_SHA256"
print -r -- "designated_requirement_reference_cdhash=$APPROVED_PREDECESSOR_REFERENCE_CDHASH"
print -r -- "designated_requirement_reference_code_directory_sha256=$APPROVED_PREDECESSOR_REFERENCE_CODE_DIRECTORY_SHA256"
print -r -- "metadata_path=$METADATA"
print -r -- "metadata_sha256=$METADATA_SHA256"
print -r -- "$handoff_output"
print -r -- "deployment_payload_manifest_path=$PAYLOAD_MANIFEST"
print -r -- "deployment_payload_manifest_sha256=$PAYLOAD_MANIFEST_SHA256"
print -r -- "deployment_payload_manifest_sha256_path=$PAYLOAD_SIDECAR"
