#!/bin/zsh
# Read-only, non-minting idle observer for the renewable secondary-viewer endpoint.
set -euo pipefail

readonly SCRIPT_NAME="verify-v90-secondary-viewer-readiness"
readonly PROBE_FLAG="--probe-secondary-test-viewer-status"
readonly SOCKET_FLAG="--secondary-test-viewer-control-socket"
readonly PROBE_TIMEOUT_SECONDS=6
readonly MAX_PROBE_ATTEMPTS=2
readonly INTER_PROBE_DELAY_SECONDS=0.05
readonly MAXIMUM_STATUS_BYTES=1024
readonly HOST_LOCK_DIRECTORY_NAME="com.elamin.AudioStreamer.CaptureServer.runtime"
readonly EXPECTED_CANDIDATE_IDENTIFIER="com.elamin.AudioStreamer.CaptureServer"

fail() {
    print -u2 -- "${SCRIPT_NAME}: $*"
    exit 1
}

usage() {
    print -u2 -- \
        "usage: $0 <candidate-CaptureServer> <exact-sha256> [absolute-control-socket-path]"
    exit 64
}

is_canonical_absolute_path() {
    local path="$1"
    [[ "$path" == /* && "${path:A}" == "$path" ]]
}

metadata() {
    /usr/bin/stat -f '%HT|%u|%Lp|%d|%i|%l|%z|%B|%m' -- "$1"
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

require_private_directory() {
    local path="$1" label="$2" signature kind owner mode device inode links rest
    is_canonical_absolute_path "$path" || fail "$label path is not canonical"
    signature="$(metadata "$path")" || fail "could not inspect $label"
    IFS='|' read -r kind owner mode device inode links rest <<< "$signature"
    [[ "$kind" == "Directory" ]] || fail "$label is not a directory"
    [[ "$owner" == "$EUID" ]] || fail "$label is not owner-only"
    [[ "$mode" == "700" ]] || fail "$label mode is not exactly 0700"
    print -r -- "${kind}|${owner}|${mode}|${device}|${inode}"
}

require_temporary_root() {
    local path="$1" label="$2" signature kind owner mode raw_mode device inode
    is_canonical_absolute_path "$path" || fail "$label path is not canonical"
    signature="$(/usr/bin/stat -f '%HT|%u|%Lp|%p|%d|%i' -- "$path")" \
        || fail "could not inspect $label"
    IFS='|' read -r kind owner mode raw_mode device inode <<< "$signature"
    [[ "$kind" == "Directory" ]] || fail "$label is not a directory"
    if [[ "$path" == "/private/tmp" ]]; then
        [[ "$owner" == "0" && "$raw_mode" == "41777" ]] || fail \
            "$label is not the canonical sticky system temporary directory"
    else
        [[ "$owner" == "$EUID" ]] || fail "$label has the wrong owner"
        [[ "$mode" == "700" ]] || fail "$label mode is not exactly 0700"
    fi
    print -r -- "${kind}|${owner}|${mode}|${raw_mode}|${device}|${inode}"
}

require_host_lock() {
    local path="$1" signature kind owner mode device inode links size birth modified
    is_canonical_absolute_path "$path" || fail "host-lock path is not canonical"
    signature="$(metadata "$path")" || fail "could not inspect host lock"
    IFS='|' read -r kind owner mode device inode links size birth modified <<< "$signature"
    [[ "$kind" == "Regular File" ]] || fail "host lock is not a regular file"
    [[ "$owner" == "$EUID" ]] || fail "host lock has the wrong owner"
    [[ "$mode" == "600" ]] || fail "host-lock mode is not exactly 0600"
    [[ "$links" == "1" ]] || fail "host lock must have exactly one hard link"
    [[ "$size" == <1-256> ]] || fail "host-lock size is outside its strict bound"
    print -r -- "$signature"
}

parse_host_lock() {
    local path="$1" parsed lock_pid lock_generation
    parsed="$(/usr/bin/perl -0777 -ne '
        if (/\AOPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1\npid=([1-9][0-9]*)\nnonce=([0-9a-f]{64})\n\z/) {
            print "$1\n$2";
            exit 0;
        }
        exit 1;
    ' "$path")" || fail "host-lock record is malformed"
    lock_pid="${parsed%%$'\n'*}"
    lock_generation="${parsed#*$'\n'}"
    [[ "$lock_pid" == <1-2147483647> ]] || fail "host-lock PID is outside Int32"
    print -r -- "${lock_pid}|${lock_generation}"
}

require_control_socket() {
    local path="$1" signature kind owner mode device inode links size birth modified
    is_canonical_absolute_path "$path" || fail "control-socket path is not canonical"
    signature="$(metadata "$path")" || fail "could not inspect control socket"
    IFS='|' read -r kind owner mode device inode links size birth modified <<< "$signature"
    [[ "$kind" == "Socket" ]] || fail "control endpoint is not a socket"
    [[ "$owner" == "$EUID" ]] || fail "control socket has the wrong owner"
    [[ "$mode" == "600" ]] || fail "control-socket mode is not exactly 0600"
    [[ "$links" == "1" ]] || fail "control socket must have exactly one link"
    print -r -- "$signature"
}

typeset WORK_DIRECTORY=""
typeset WORK_DIRECTORY_IDENTITY=""
typeset STATUS_OUTPUT=""
typeset PROBE_STDOUT=""
typeset PROBE_STDERR=""

cleanup() {
    local original_status=$? current_metadata current_identity cleanup_failed=0
    local candidate attempt kind owner mode device inode links rest
    trap - EXIT HUP INT TERM
    set +e
    if [[ -n "$WORK_DIRECTORY" && -n "$WORK_DIRECTORY_IDENTITY" ]]; then
        current_metadata="$(metadata "$WORK_DIRECTORY" 2>/dev/null)"
        IFS='|' read -r kind owner mode device inode links rest <<< "$current_metadata"
        current_identity="${kind}|${owner}|${mode}|${device}|${inode}"
        if [[ "$current_identity" == "$WORK_DIRECTORY_IDENTITY" ]]; then
            # Every removable name is inside the fresh private directory. rm unlinks a symlink;
            # it never follows one, and no recursive removal is used.
            for attempt in 1 2; do
                for candidate in \
                    "$WORK_DIRECTORY/status-${attempt}.json" \
                    "$WORK_DIRECTORY/probe-${attempt}.stdout" \
                    "$WORK_DIRECTORY/probe-${attempt}.stderr" \
                    "$WORK_DIRECTORY"/.status-${attempt}.json.*.tmp(N); do
                    [[ -n "$candidate" ]] && /bin/rm -f -- "$candidate"
                done
            done
            /bin/rmdir -- "$WORK_DIRECTORY" || cleanup_failed=1
        else
            cleanup_failed=1
        fi
    fi
    if (( cleanup_failed != 0 )); then
        print -u2 -- "${SCRIPT_NAME}: private probe output cleanup was not confirmed"
        original_status=1
    fi
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

(( $# == 2 || $# == 3 )) || usage
(( MAX_PROBE_ATTEMPTS == 2 && MAX_PROBE_ATTEMPTS < 16 )) || fail \
    "probe-attempt bound is unsafe"
(( PROBE_TIMEOUT_SECONDS > 0 && PROBE_TIMEOUT_SECONDS <= 10 )) || fail \
    "probe deadline is unsafe"

readonly CANDIDATE_INPUT="${1%/}"
readonly EXPECTED_CANDIDATE_SHA256="$2"
[[ "$EXPECTED_CANDIDATE_SHA256" =~ '^[0-9a-f]{64}$' ]] || fail \
    "expected candidate SHA-256 is malformed"
is_canonical_absolute_path "$CANDIDATE_INPUT" || fail \
    "candidate CaptureServer path is not canonical"
[[ -f "$CANDIDATE_INPUT" && ! -L "$CANDIDATE_INPUT" && -x "$CANDIDATE_INPUT" ]] || fail \
    "candidate CaptureServer is not a real executable file"
readonly CANDIDATE_IDENTITY="$(metadata "$CANDIDATE_INPUT")"
typeset candidate_kind candidate_owner candidate_mode candidate_device candidate_inode \
    candidate_links candidate_size candidate_birth candidate_modified
IFS='|' read -r candidate_kind candidate_owner candidate_mode candidate_device candidate_inode \
    candidate_links candidate_size candidate_birth candidate_modified <<< "$CANDIDATE_IDENTITY"
[[ "$candidate_kind" == "Regular File" \
    && "$candidate_owner" == "$EUID" \
    && "$candidate_mode" == "755" \
    && "$candidate_links" == "1" ]] || fail \
    "candidate CaptureServer identity is unsafe"
readonly CANDIDATE_SHA256="$(sha256_file "$CANDIDATE_INPUT")"
[[ "$CANDIDATE_SHA256" == "$EXPECTED_CANDIDATE_SHA256" ]] || fail \
    "candidate CaptureServer SHA-256 differs from the sealed expectation"
/usr/bin/codesign --verify --strict --verbose=2 "$CANDIDATE_INPUT" \
    >/dev/null 2>&1 || fail "candidate CaptureServer failed strict code-signature validation"
readonly CANDIDATE_IDENTIFIER="$(/usr/bin/codesign -dv --verbose=4 \
    "$CANDIDATE_INPUT" 2>&1 \
    | /usr/bin/awk -F= '$1 == "Identifier" && NF == 2 { print $2 }')"
[[ "$CANDIDATE_IDENTIFIER" == "$EXPECTED_CANDIDATE_IDENTIFIER" ]] || fail \
    "candidate CaptureServer has the wrong preserved code identifier"

readonly CONTROL_SOCKET="${3:-/private/tmp/opensteamer-wv-${EUID}/control.sock}"
is_canonical_absolute_path "$CONTROL_SOCKET" || fail \
    "control-socket path is not canonical"
readonly CONTROL_DIRECTORY="${CONTROL_SOCKET:h}"
readonly CONTROL_DIRECTORY_BEFORE="$(require_private_directory \
    "$CONTROL_DIRECTORY" "control-socket directory")"
readonly CONTROL_SOCKET_BEFORE="$(require_control_socket "$CONTROL_SOCKET")"

[[ -n "${HOME:-}" ]] || fail "HOME is unavailable"
readonly HOST_LOCK_DIRECTORY="${HOME%/}/Library/Application Support/${HOST_LOCK_DIRECTORY_NAME}"
readonly HOST_LOCK_PATH="${HOST_LOCK_DIRECTORY}/worldwide-host.lock"
readonly HOST_LOCK_DIRECTORY_BEFORE="$(require_private_directory \
    "$HOST_LOCK_DIRECTORY" "host-lock directory")"
readonly HOST_LOCK_BEFORE="$(require_host_lock "$HOST_LOCK_PATH")"
readonly HOST_RECORD_BEFORE="$(parse_host_lock "$HOST_LOCK_PATH")"
readonly HOST_PID="${HOST_RECORD_BEFORE%%|*}"
readonly HOST_GENERATION="${HOST_RECORD_BEFORE#*|}"
/bin/kill -0 "$HOST_PID" 2>/dev/null || fail "host-lock PID is not alive"
readonly HOST_PROCESS_START_BEFORE="$(/bin/ps -p "$HOST_PID" -o lstart= 2>/dev/null)"
[[ -n "$HOST_PROCESS_START_BEFORE" ]] || fail "host-lock PID has no process-start identity"

umask 077
typeset temporary_root_input="${TMPDIR:-/private/tmp}"
temporary_root_input="${temporary_root_input%/}"
[[ -n "$temporary_root_input" && "$temporary_root_input" == /* ]] || fail \
    "temporary root path is not absolute"
readonly TEMPORARY_ROOT="${temporary_root_input:A}"
readonly TEMPORARY_ROOT_BEFORE="$(require_temporary_root \
    "$TEMPORARY_ROOT" "temporary root")"
WORK_DIRECTORY="$(/usr/bin/mktemp -d \
    "${TEMPORARY_ROOT}/opensteamer-v90-readiness.XXXXXX")" || fail \
    "could not create private probe directory"
/bin/chmod 700 "$WORK_DIRECTORY" || fail "could not restrict private probe directory"
WORK_DIRECTORY_IDENTITY="$(require_private_directory \
    "$WORK_DIRECTORY" "probe output directory")"

require_probe_fences_unchanged() {
    local candidate_after candidate_sha256_after candidate_identifier_after
    local control_directory_after control_socket_after
    local host_lock_directory_after host_lock_after host_record_after process_start_after
    local temporary_root_after
    candidate_after="$(metadata "$CANDIDATE_INPUT")"
    [[ "$candidate_after" == "$CANDIDATE_IDENTITY" ]] || fail \
        "candidate CaptureServer was replaced during a probe"
    candidate_sha256_after="$(sha256_file "$CANDIDATE_INPUT")"
    [[ "$candidate_sha256_after" == "$EXPECTED_CANDIDATE_SHA256" ]] || fail \
        "candidate CaptureServer bytes changed during a probe"
    /usr/bin/codesign --verify --strict --verbose=2 "$CANDIDATE_INPUT" \
        >/dev/null 2>&1 || fail \
        "candidate CaptureServer code signature changed during a probe"
    candidate_identifier_after="$(/usr/bin/codesign -dv --verbose=4 \
        "$CANDIDATE_INPUT" 2>&1 \
        | /usr/bin/awk -F= '$1 == "Identifier" && NF == 2 { print $2 }')"
    [[ "$candidate_identifier_after" == "$EXPECTED_CANDIDATE_IDENTIFIER" ]] || fail \
        "candidate CaptureServer code identifier changed during a probe"
    control_directory_after="$(require_private_directory \
        "$CONTROL_DIRECTORY" "control-socket directory")"
    [[ "$control_directory_after" == "$CONTROL_DIRECTORY_BEFORE" ]] || fail \
        "control-socket directory was replaced during a probe"
    control_socket_after="$(require_control_socket "$CONTROL_SOCKET")"
    [[ "$control_socket_after" == "$CONTROL_SOCKET_BEFORE" ]] || fail \
        "control socket was replaced during a probe"
    host_lock_directory_after="$(require_private_directory \
        "$HOST_LOCK_DIRECTORY" "host-lock directory")"
    [[ "$host_lock_directory_after" == "$HOST_LOCK_DIRECTORY_BEFORE" ]] || fail \
        "host-lock directory was replaced during a probe"
    host_lock_after="$(require_host_lock "$HOST_LOCK_PATH")"
    [[ "$host_lock_after" == "$HOST_LOCK_BEFORE" ]] || fail \
        "host lock was replaced during a probe"
    host_record_after="$(parse_host_lock "$HOST_LOCK_PATH")"
    [[ "$host_record_after" == "$HOST_RECORD_BEFORE" ]] || fail \
        "host-lock PID or generation changed during a probe"
    /bin/kill -0 "$HOST_PID" 2>/dev/null || fail "host-lock PID exited during a probe"
    process_start_after="$(/bin/ps -p "$HOST_PID" -o lstart= 2>/dev/null)"
    [[ "$process_start_after" == "$HOST_PROCESS_START_BEFORE" ]] || fail \
        "host-lock PID was reused during a probe"
    temporary_root_after="$(require_temporary_root \
        "$TEMPORARY_ROOT" "temporary root")"
    [[ "$temporary_root_after" == "$TEMPORARY_ROOT_BEFORE" ]] || fail \
        "temporary root was replaced during a probe"
}

probe_failure_classification() {
    local stderr_bytes error_text rejected_status protocol_error_code
    [[ -f "$PROBE_STDERR" && ! -L "$PROBE_STDERR" ]] || {
        print -r -- 'unavailable'
        return
    }
    stderr_bytes="$(/usr/bin/stat -f '%z' -- "$PROBE_STDERR")" || return
    (( stderr_bytes <= 4096 )) || {
        print -r -- 'oversized_stderr'
        return
    }
    error_text="$(<"$PROBE_STDERR")"
    case "$error_text" in
        '') print -r -- 'no_stderr' ;;
        'error: The secondary viewer request arguments are invalid.')
            print -r -- 'invalid_arguments' ;;
        'error: The secondary viewer control endpoint failed owner or identity validation.')
            print -r -- 'unsafe_endpoint' ;;
        'error: The secondary viewer control response was invalid.')
            print -r -- 'invalid_response' ;;
        'error: The secondary viewer invitation output path is unsafe or already exists.')
            print -r -- 'unsafe_output' ;;
        *)
            # This Error-only enum bridges to a fixed NSError description before client
            # validation (for example, loading the host lock). Keep its bounded numeric
            # code rather than attributing a case name to a compiler-generated code.
            for protocol_error_code in 0 1 2 3; do
                if [[ "$error_text" == "error: The operation couldn’t be completed. (CaptureServer.WorldwideSecondaryTestViewerControlProtocolError error ${protocol_error_code}.)" ]]; then
                    print -r -- "protocol_error_${protocol_error_code}"
                    return
                fi
            done
            for rejected_status in observed started stopped busy staleGeneration quarantined \
                shutdown unavailable replayed wrongHost invalidReceipt invalidRequest; do
                if [[ "$error_text" == "error: The secondary viewer status probe was rejected with status ${rejected_status}." ]]; then
                    print -r -- "rejected_${rejected_status}"
                    return
                fi
            done
            print -r -- 'unrecognized_stderr'
            ;;
    esac
}

execute_status_probe() {
    local attempt="$1" probe_status=0 signal_hint='none' classification stderr_bytes
    set +e
    /usr/bin/perl -e '
        my $seconds = shift @ARGV;
        alarm($seconds);
        exec {$ARGV[0]} @ARGV;
        exit 127;
    ' "$PROBE_TIMEOUT_SECONDS" \
        "$CANDIDATE_INPUT" \
        "$PROBE_FLAG" "$STATUS_OUTPUT" \
        "$SOCKET_FLAG" "$CONTROL_SOCKET" \
        >"$PROBE_STDOUT" 2>"$PROBE_STDERR"
    probe_status=$?
    set -e
    if (( probe_status != 0 )); then
        # Shell status cannot distinguish an explicit exit 142 from SIGALRM; retain a hint,
        # not an unsupported timeout claim. Never forward unclassified client stderr.
        if (( probe_status > 128 && probe_status <= 192 )); then
            signal_hint="$(( probe_status - 128 ))"
        fi
        classification="$(probe_failure_classification)"
        stderr_bytes="$(/usr/bin/stat -f '%z' -- "$PROBE_STDERR")" || stderr_bytes='unknown'
        fail "candidate status probe ${attempt} failed shell_status=${probe_status} signal_hint=${signal_hint} classification=${classification} stderr_bytes=${stderr_bytes}"
    fi
    [[ ! -s "$PROBE_STDOUT" && ! -s "$PROBE_STDERR" ]] || fail \
        "candidate status probe ${attempt} wrote unexpected console output"
}

run_and_validate_probe() {
    local attempt="$1" probe_started_at probe_finished_at
    local status_identity status_kind status_owner status_mode status_device status_inode
    local status_links status_size status_birth status_modified canonical_status last_status_byte
    local status_identity_after work_directory_after manager_generation request_nonce
    STATUS_OUTPUT="${WORK_DIRECTORY}/status-${attempt}.json"
    PROBE_STDOUT="${WORK_DIRECTORY}/probe-${attempt}.stdout"
    PROBE_STDERR="${WORK_DIRECTORY}/probe-${attempt}.stderr"
    [[ ! -e "$STATUS_OUTPUT" && ! -L "$STATUS_OUTPUT" ]] || fail \
        "fresh status output path collided before probe ${attempt}"

    probe_started_at="$(/bin/date +%s)"
    execute_status_probe "$attempt"
    probe_finished_at="$(/bin/date +%s)"
    require_probe_fences_unchanged

    status_identity="$(metadata "$STATUS_OUTPUT")" || fail \
        "candidate did not publish one status output for probe ${attempt}"
    IFS='|' read -r status_kind status_owner status_mode status_device status_inode \
        status_links status_size status_birth status_modified <<< "$status_identity"
    [[ "$status_kind" == "Regular File" ]] || fail "status output is not a regular file"
    [[ "$status_owner" == "$EUID" ]] || fail "status output has the wrong owner"
    [[ "$status_mode" == "600" ]] || fail "status-output mode is not exactly 0600"
    [[ "$status_links" == "1" ]] || fail "status output must have exactly one hard link"
    (( status_size >= 1 && status_size <= MAXIMUM_STATUS_BYTES )) || fail \
        "status-output size is outside its strict bound"
    (( status_birth >= probe_started_at && status_birth <= probe_finished_at )) || fail \
        "status output is not fresh for probe ${attempt}"
    (( status_modified >= probe_started_at && status_modified <= probe_finished_at )) || fail \
        "status output was not written during probe ${attempt}"

    /usr/bin/jq --stream -e -s '
        [ .[] | select(length == 2) | .[0] ] as $paths
        | ($paths | length) == 8
          and ($paths | all(length == 1))
          and (($paths | map(.[0]) | sort) == [
            "hostGeneration", "hostProcessIdentifier", "managerGeneration",
            "managerIsIdle", "managerPhase", "requestNonce", "type", "v"
          ])
    ' "$STATUS_OUTPUT" >/dev/null || fail \
        "status output does not contain exactly one copy of each field"
    /usr/bin/jq -e \
        --arg hostGeneration "$HOST_GENERATION" \
        --argjson hostProcessIdentifier "$HOST_PID" '
        type == "object"
        and (keys == [
          "hostGeneration", "hostProcessIdentifier", "managerGeneration",
          "managerIsIdle", "managerPhase", "requestNonce", "type", "v"
        ])
        and (.v | type == "number") and .v == 1 and .v == (.v | floor)
        and (.type | type == "string")
        and .type == "secondaryTestViewerStatusProbeResult"
        and (.hostProcessIdentifier | type == "number")
        and .hostProcessIdentifier == $hostProcessIdentifier
        and .hostProcessIdentifier == (.hostProcessIdentifier | floor)
        and (.hostGeneration | type == "string")
        and .hostGeneration == $hostGeneration
        and (.managerGeneration | type == "number")
        and .managerGeneration >= 0
        and .managerGeneration == (.managerGeneration | floor)
        and (.managerPhase | type == "string") and .managerPhase == "idle"
        and (.managerIsIdle | type == "boolean") and .managerIsIdle == true
        and (.requestNonce | type == "string")
        and (.requestNonce | test("^[0-9a-f]{32}$"))
    ' "$STATUS_OUTPUT" >/dev/null || fail \
        "status output is not an exact idle result for the current host generation"

    canonical_status="$(/usr/bin/jq -cS . "$STATUS_OUTPUT")" || fail \
        "status output could not be canonicalized"
    last_status_byte="$(/usr/bin/tail -c 1 "$STATUS_OUTPUT" \
        | /usr/bin/od -An -tuC | /usr/bin/tr -d '[:space:]')"
    [[ "$last_status_byte" == "10" ]] || fail "status output lacks its single final newline"
    (( status_size == ${#canonical_status} + 1 )) || fail \
        "status output contains noncanonical or trailing data"
    [[ "$(<"$STATUS_OUTPUT")" == "$canonical_status" ]] || fail \
        "status output is not canonical strict JSON"
    status_identity_after="$(metadata "$STATUS_OUTPUT")"
    [[ "$status_identity_after" == "$status_identity" ]] || fail \
        "status output was replaced while it was validated"
    work_directory_after="$(require_private_directory \
        "$WORK_DIRECTORY" "probe output directory")"
    [[ "$work_directory_after" == "$WORK_DIRECTORY_IDENTITY" ]] || fail \
        "probe output directory was replaced while it was validated"

    manager_generation="$(/usr/bin/jq -r '.managerGeneration' "$STATUS_OUTPUT")"
    request_nonce="$(/usr/bin/jq -r '.requestNonce' "$STATUS_OUTPUT")"
    REPLY="${manager_generation}|${request_nonce}"
}

run_and_validate_probe 1
readonly FIRST_PROBE_RESULT="$REPLY"
/bin/sleep "$INTER_PROBE_DELAY_SECONDS"
run_and_validate_probe 2
readonly SECOND_PROBE_RESULT="$REPLY"
readonly FIRST_MANAGER_GENERATION="${FIRST_PROBE_RESULT%%|*}"
readonly SECOND_MANAGER_GENERATION="${SECOND_PROBE_RESULT%%|*}"
readonly FIRST_REQUEST_NONCE="${FIRST_PROBE_RESULT#*|}"
readonly SECOND_REQUEST_NONCE="${SECOND_PROBE_RESULT#*|}"
[[ "$SECOND_MANAGER_GENERATION" == "$FIRST_MANAGER_GENERATION" ]] || fail \
    "secondary-viewer manager generation advanced between readiness probes"
[[ "$SECOND_REQUEST_NONCE" != "$FIRST_REQUEST_NONCE" ]] || fail \
    "endpoint idle probes did not carry distinct fresh nonces"
require_probe_fences_unchanged

print -r -- \
    "V90_SECONDARY_VIEWER_ENDPOINT_IDLE_OK candidateSHA256=${CANDIDATE_SHA256} pid=${HOST_PID} managerGeneration=${FIRST_MANAGER_GENERATION} probes=${MAX_PROBE_ATTEMPTS}"
