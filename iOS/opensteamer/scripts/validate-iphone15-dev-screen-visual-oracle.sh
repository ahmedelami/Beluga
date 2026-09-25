#!/bin/zsh

# Run the development-only final-pixel oracle on the dedicated physical iPhone 15.
#
# This runner is deliberately incapable of targeting the production bundle or personal iPhone.
# It never starts, stops, or restarts the Mac host. After every slower product/device preflight and
# the `.dev` install completes, it asks the already-running guarded host for one fresh renewable
# secondary-viewer invitation through the owner-only local control socket. The host client writes
# that capability directly into this run's private artifact directory without printing it. This
# process validates the file, copies it into the development app's Documents container, deletes
# both Mac copies, and runs the one hardcoded development UI test.
#
# The invitation source is consumed: after it passes metadata validation, every exit path attempts
# to delete it. The script never accepts the capability in argv, an XCTest environment variable,
# a result bundle, or a log.
set -euo pipefail
umask 077

readonly DEVICE_ID='10B6E5EE-D3B9-5334-99C1-EA12EFA34447'
readonly HARDWARE_UDID='00008120-0000242E3E32201E'
readonly APP_BUNDLE_ID='org.example.AudioStreamer.dev'
readonly RUNNER_BUNDLE_ID='org.example.AudioStreamerUITests.xctrunner'
readonly DEVELOPMENT_TEAM_ID='MSMG8CJLB3'
readonly DEVELOPMENT_RENDEZVOUS_URL='wss://audiostreamer-rendezvous.elaminahmed03.workers.dev'
readonly HOST_SERVICE="gui/${UID}/org.example.opensteamer.worldwide"
readonly HOST_APP='/Applications/opensteamer Host.app'
readonly HOST_EXECUTABLE='/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer'
readonly HOST_MEDIA_FRAMEWORK_EXECUTABLE='/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC'
readonly HOST_LOG=/var/tmp/opensteamer-worldwide-host.log
readonly HOST_LOCK="${HOME}/Library/Application Support/com.elamin.AudioStreamer.CaptureServer.runtime/worldwide-host.lock"
readonly HOST_AUDIO_CLIENT_REPORT="${HOME}/Library/Application Support/opensteamer/diagnostics/audio-client-v1.json"
readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly REPOSITORY_ROOT=${PROJECT_DIR:h:h}
readonly SEALED_HOST_IDENTITY_VERIFIER="${REPOSITORY_ROOT}/macOS/scripts/verify-sealed-live-mac-host-identity.sh"
readonly HOST_IDENTITY_MANIFEST=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST:-}
readonly HOST_IDENTITY_MANIFEST_SHA256_PATH=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH:-}
readonly HOST_IDENTITY_MANIFEST_SHA256=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256:-}
readonly CHALLENGE_SOURCE="${SCRIPT_DIR}/physical-screen-sequence-challenge.swift"
readonly CHALLENGE_PROTOCOL_SOURCE="${PROJECT_DIR}/OracleTestSupport/PhysicalScreenSequenceProtocol.swift"
readonly UI_TEST_SOURCE="${PROJECT_DIR}/UITests/IPhone15SecondaryViewerDevelopmentPhysicalUITests.swift"
readonly POWER_ASSERTION_HELPER="${SCRIPT_DIR}/iphone15-dev-power-assertion.py"
readonly UNLOCK_ACK_HELPER="${SCRIPT_DIR}/ack-iphone15-dev-screen-visual-oracle-unlock.sh"
readonly TEST_ID='opensteamerUITests/IPhone15SecondaryViewerDevelopmentPhysicalUITests/testTemporaryViewerFinalPixelsTrackFreshMacChallenge'
readonly TEST_NODE='IPhone15SecondaryViewerDevelopmentPhysicalUITests/testTemporaryViewerFinalPixelsTrackFreshMacChallenge()'
readonly PRODUCTION_DERIVED_DATA=/Volumes/t7/opensteamer-iphone15-dev-build
readonly PRODUCTION_RUN_STATE_ROOT=/Volumes/t7/opensteamer-screen-oracle-state
readonly PRODUCTION_ARTIFACT_ROOT=/Volumes/t7
readonly IPHONE_CONTROL_PYTHON='/Users/ahmed/.local/share/uv/python/cpython-3.13.14-macos-aarch64-none/bin/python3.13'
readonly IPHONE_CONTROL_PYTHON_SHA256='b5a0d384a1641cd7366eba632a3e5d9387af5216feb50fb29a77d9c84e97138d'
readonly UNLOCK_GATE_TIMEOUT_SECONDS=1800
readonly UNLOCK_ACK_MAX_AGE_SECONDS=30
readonly RUN_STATUS_HEARTBEAT_MAX_AGE_SECONDS=5
readonly POWER_ASSERTION_HEARTBEAT_MAX_AGE_SECONDS=7
readonly LOCK_STATE_TRANSPORT_ATTEMPTS=3
readonly LOCK_STATE_RETRY_DELAY_SECONDS=0.25
readonly HOST_BASELINE_TAIL_BYTES=16777216
readonly SECONDARY_MANAGER_PROBE_TIMEOUT_SECONDS=6
readonly INVITATION_MAX_AGE_SECONDS=120
readonly INVITATION_DESTINATION_NAME='.opensteamer-dev-secondary-invitation'
readonly DEVICE_CLEANUP_LAUNCH_ARGUMENT='--opensteamer-iphone15-dev-secondary-cleanup'
readonly DEVICE_CLEANUP_RECEIPT_ARGUMENT='--opensteamer-iphone15-dev-cleanup-receipt'
readonly DEVICE_CLEANUP_RECEIPT_PREFIX='.opensteamer-dev-secondary-cleanup-receipt-'
readonly EXPECTED_PRIMARY_BUILD=${OPENSTEAMER_EXPECTED_PRIMARY_BUILD:-85}
readonly SELF_TEST_MODE=${OPENSTEAMER_SCREEN_ORACLE_SELF_TEST:-}
readonly SELF_TEST_ROOT_INPUT=${OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT:-}

if (( $# != 0 )); then
  print -u2 -- "usage: $0"
  exit 2
fi
if [[ -n "$SELF_TEST_MODE" && "$SELF_TEST_MODE" != final-status-failure ]]; then
  print -u2 -- "Unsupported OPENSTEAMER_SCREEN_ORACLE_SELF_TEST: ${SELF_TEST_MODE}"
  exit 2
fi
if [[ -z "$EXPECTED_PRIMARY_BUILD" || "$EXPECTED_PRIMARY_BUILD" == *[^0-9]* \
    || "$EXPECTED_PRIMARY_BUILD" == 0 ]]; then
  print -u2 -- 'OPENSTEAMER_EXPECTED_PRIMARY_BUILD must be a positive build number.'
  exit 2
fi
if [[ -z "$SELF_TEST_MODE" ]] && [[ -z "$HOST_IDENTITY_MANIFEST" \
    || "$HOST_IDENTITY_MANIFEST" != /* \
    || "${HOST_IDENTITY_MANIFEST:A}" != "$HOST_IDENTITY_MANIFEST" \
    || ! -f "$HOST_IDENTITY_MANIFEST" || -L "$HOST_IDENTITY_MANIFEST" \
    || "$HOST_IDENTITY_MANIFEST_SHA256_PATH" != "${HOST_IDENTITY_MANIFEST}.sha256" \
    || "${HOST_IDENTITY_MANIFEST_SHA256_PATH:A}" \
      != "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || ! -f "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || -L "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || ! "$HOST_IDENTITY_MANIFEST_SHA256" =~ '^[0-9a-f]{64}$' \
    || ! -f "$SEALED_HOST_IDENTITY_VERIFIER" \
    || -L "$SEALED_HOST_IDENTITY_VERIFIER" ]]; then
  print -u2 -- \
    'A release-sealed Mac host identity manifest, committed SHA-256 sidecar, and external SHA-256 are required.'
  exit 2
fi

typeset DERIVED_DATA RUN_STATE_ROOT ARTIFACT_PARENT
if [[ -n "$SELF_TEST_MODE" ]]; then
  if [[ -z "$SELF_TEST_ROOT_INPUT" || "$SELF_TEST_ROOT_INPUT" != /* \
      || "${SELF_TEST_ROOT_INPUT:A}" != "$SELF_TEST_ROOT_INPUT" \
      || ! -d "$SELF_TEST_ROOT_INPUT" || -L "$SELF_TEST_ROOT_INPUT" \
      || "$(/usr/bin/stat -f '%u:%Lp' "$SELF_TEST_ROOT_INPUT")" != "$EUID:700" ]]; then
    print -u2 -- 'Development oracle self-test root must be a canonical owner-only mode-0700 directory.'
    exit 2
  fi
  DERIVED_DATA="${SELF_TEST_ROOT_INPUT}/derived-data"
  RUN_STATE_ROOT="${SELF_TEST_ROOT_INPUT}/state"
  ARTIFACT_PARENT=$SELF_TEST_ROOT_INPUT
else
  if [[ -n "$SELF_TEST_ROOT_INPUT" ]]; then
    print -u2 -- 'OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT is self-test-only.'
    exit 2
  fi
  DERIVED_DATA=$PRODUCTION_DERIVED_DATA
  RUN_STATE_ROOT=$PRODUCTION_RUN_STATE_ROOT
  ARTIFACT_PARENT=$PRODUCTION_ARTIFACT_ROOT
fi
readonly DERIVED_DATA RUN_STATE_ROOT ARTIFACT_PARENT

for tool in xcrun xcodebuild swiftc jq rg openssl launchctl ps cmp plutil \
    codesign lockf ditto shasum stat install awk grep tail sort; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 -- "Missing required tool: $tool"
    exit 2
  fi
done
if [[ -z "$SELF_TEST_MODE" ]] && [[ ! -d /Volumes/t7 || -L /Volumes/t7 \
    || ! -f "$CHALLENGE_SOURCE" || ! -f "$CHALLENGE_PROTOCOL_SOURCE" \
    || ! -f "$UI_TEST_SOURCE" || ! -f "$POWER_ASSERTION_HELPER" \
    || ! -x "$UNLOCK_ACK_HELPER" \
    || ! -f "$IPHONE_CONTROL_PYTHON" || -L "$IPHONE_CONTROL_PYTHON" \
    || ! -x "$IPHONE_CONTROL_PYTHON" \
    || "$(/usr/bin/shasum -a 256 "$IPHONE_CONTROL_PYTHON" \
      | /usr/bin/awk '{ print $1 }')" != "$IPHONE_CONTROL_PYTHON_SHA256" \
    || ( -e "$DERIVED_DATA" && ( ! -d "$DERIVED_DATA" || -L "$DERIVED_DATA" ) ) ]]; then
  print -u2 -- 'T7, the verified iPhone runtime, or versioned oracle source is unavailable.'
  exit 2
fi
if [[ -z "$SELF_TEST_MODE" ]]; then
  /bin/mkdir -p -m 700 "$DERIVED_DATA"
fi
if [[ -e "$RUN_STATE_ROOT" && ( ! -d "$RUN_STATE_ROOT" || -L "$RUN_STATE_ROOT" ) ]]; then
  print -u2 -- 'Visual-oracle state root is unsafe.'
  exit 2
fi
/bin/mkdir -p -m 700 "$RUN_STATE_ROOT"
/bin/chmod 700 "$RUN_STATE_ROOT"

readonly RUN_KEY="${DEVICE_ID}-${APP_BUNDLE_ID}"
readonly RUN_LOCK_FILE="${RUN_STATE_ROOT}/${RUN_KEY}.lock"
readonly RUN_STATUS="${RUN_STATE_ROOT}/${RUN_KEY}.json"
if [[ -e "$RUN_LOCK_FILE" && ( ! -f "$RUN_LOCK_FILE" || -L "$RUN_LOCK_FILE" \
    || "$(/usr/bin/stat -f '%u' "$RUN_LOCK_FILE")" != "$UID" \
    || "$(/usr/bin/stat -f '%l' "$RUN_LOCK_FILE")" != 1 ) ]]; then
  print -u2 -- 'Development visual-oracle lock file is unsafe.'
  exit 2
fi
if [[ -e "$RUN_STATUS" && ( ! -f "$RUN_STATUS" || -L "$RUN_STATUS" ) ]]; then
  print -u2 -- 'Development visual-oracle status file is unsafe.'
  exit 2
fi
/usr/bin/touch "$RUN_LOCK_FILE"
/bin/chmod 600 "$RUN_LOCK_FILE"
typeset -gi RUN_LOCK_FD
exec {RUN_LOCK_FD}>>"$RUN_LOCK_FILE"
if ! /usr/bin/lockf -s -t 0 "$RUN_LOCK_FD"; then
  print -u2 -- 'An iPhone 15 development visual oracle is already active.'
  exit 75
fi
readonly RUN_LOCK_FD
readonly RUN_PROCESS_START=$(LC_ALL=C ps -ww -p "$$" -o lstart= \
  | /usr/bin/awk '{$1=$1; print}')
if [[ -z "$RUN_PROCESS_START" ]]; then
  print -u2 -- 'Development visual-oracle process-start identity is unavailable.'
  exit 2
fi
jq -n \
  --arg schema 'opensteamer.iphone15-dev-screen-visual-oracle-lock.v1' \
  --argjson pid "$$" --arg runnerProcessStart "$RUN_PROCESS_START" \
  --arg deviceId "$DEVICE_ID" --arg hardwareUDID "$HARDWARE_UDID" \
  --arg bundleId "$APP_BUNDLE_ID" \
  '{schema:$schema,pid:$pid,runnerProcessStart:$runnerProcessStart,
    deviceId:$deviceId,hardwareUDID:$hardwareUDID,bundleId:$bundleId}' \
  > "$RUN_LOCK_FILE"
/bin/chmod 600 "$RUN_LOCK_FILE"

readonly ARTIFACT_DIR=$(/usr/bin/mktemp -d \
  "${ARTIFACT_PARENT}/opensteamer-iphone15-dev-screen-oracle.XXXXXX")
readonly SUMMARY="${ARTIFACT_DIR}/summary.json"
readonly RESULT_BUNDLE="${ARTIFACT_DIR}/iphone15-dev-screen-oracle.xcresult"
readonly CHALLENGE_BINARY="${ARTIFACT_DIR}/screen-visual-challenge"
readonly CHALLENGE_HEARTBEAT="${ARTIFACT_DIR}/challenge-heartbeat.txt"
readonly AUDIO_ROUTE_READER="${ARTIFACT_DIR}/coreaudio-default-route-reader"
readonly AUDIO_ROUTE_MONITOR_STATUS="${ARTIFACT_DIR}/audio-route-monitor-status.json"
readonly AUDIO_ROUTE_MONITOR_STOP="${ARTIFACT_DIR}/audio-route-monitor.stop"
readonly HOST_IDENTITY_SEALED_BASELINE="${ARTIFACT_DIR}/host-identity-sealed-baseline.txt"
readonly HOST_IDENTITY_BEFORE_CHALLENGE="${ARTIFACT_DIR}/host-identity-before-challenge.txt"
readonly UNLOCK_REQUEST="${ARTIFACT_DIR}/unlock-request.json"
readonly UNLOCK_ACK="${ARTIFACT_DIR}/unlock-ack.json"
readonly POWER_ASSERTION_HEARTBEAT="${ARTIFACT_DIR}/device-power-assertion.json"
readonly POWER_ASSERTION_STOP="${ARTIFACT_DIR}/device-power-assertion.stop"
readonly PREPARED_PRODUCTS="${ARTIFACT_DIR}/prepared-test-products"
readonly PREPARED_PRODUCTS_MANIFEST="${ARTIFACT_DIR}/prepared-test-products.sha256"
readonly INVITATION_SOURCE="${ARTIFACT_DIR}/secondary-viewer-invitation.txt"
readonly HOST_GENERATION_RECEIPT="${INVITATION_SOURCE}.receipt"
readonly STAGED_INVITATION_DIR="${ARTIFACT_DIR}/Documents"
readonly STAGED_INVITATION="${STAGED_INVITATION_DIR}/${INVITATION_DESTINATION_NAME}"
readonly RUN_STARTED_AT=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')

typeset -g STAGE=preflight
typeset -g FAILURE_REASON=''
typeset -g PHYSICAL_TEST_EXIT_STATUS=''
typeset -g PHYSICAL_TEST_FAILURE_CLASS=''
typeset -g PHYSICAL_TEST_FAILURE_REASON=''
typeset -g SELECTED_TEST_RECORD=unavailable
typeset -gi XCRESULT_SUMMARY_CAPTURED=0
typeset -gi XCRESULT_TESTS_CAPTURED=0
typeset -g SIGNAL_NAME=''
typeset -g PENDING_SIGNAL_NAME=''
typeset -gi PENDING_SIGNAL_STATUS=0
typeset -gi OWNED_CHILD_PUBLICATION_PENDING=0
typeset -gi FINISHING=0
typeset -gi VERIFIED=0
typeset -gi INVITATION_SOURCE_MINT_ATTEMPTED=0
typeset -gi INVITATION_SOURCE_VALIDATED=0
typeset -gi INVITATION_SOURCE_DELETED=0
typeset -gi HOST_GENERATION_RECEIPT_VALIDATED=0
typeset -gi HOST_GENERATION_STOP_ATTEMPTED=0
typeset -gi HOST_GENERATION_STOPPED=0
typeset -g SECONDARY_HOST_GENERATION=''
typeset -g SECONDARY_MANAGER_GENERATION=''
typeset -g SECONDARY_MANAGER_GENERATION_BASELINE=''
typeset -g SECONDARY_RENEWAL_REQUEST_NONCE=''
typeset -g SECONDARY_VALIDATED_RECEIPT_SHA256=''
typeset -gi INVITATION_STAGED=0
typeset -gi INVITATION_COPIED=0
typeset -gi DEVICE_SECRET_CLEANUP_REQUIRED=0
typeset -gi DEVICE_SECRET_CLEANUP_CONFIRMED=0
typeset -gi UNLOCK_REQUEST_PUBLISHED=0
typeset -gi UNLOCK_ACK_VALIDATED=0
typeset -gi POWER_ASSERTION_STOPPED=0
typeset -g CHALLENGE_PID=''
typeset -g AUDIO_ROUTE_MONITOR_PID=''
typeset -g POWER_ASSERTION_PID=''
typeset -g PHYSICAL_TEST_PID=''
typeset -g POWER_ASSERTION_PHASE=''
typeset -g POWER_ASSERTION_SEQUENCE=''
typeset -g AUDIO_ROUTE_MONITOR_PHASE=''
typeset -g AUDIO_ROUTE_NOTIFICATION_COUNT=''
typeset -g HOST_PID=''
typeset -g HOST_COMMAND=''
typeset -g HOST_LOG_DEVICE=''
typeset -g HOST_LOG_INODE=''
typeset -g HOST_LOG_BASE_SIZE=''
typeset -g HOST_LOG_CONTINUITY_CURSOR=''
typeset -g HOST_LOG_CONTINUITY_PENDING_CURSOR=''
typeset -g HOST_ELAPSED_SECONDS=''
typeset -g HOST_GENERATION=''
typeset -g DEFAULT_INPUT_UID=''
typeset -g DEFAULT_OUTPUT_UID=''
typeset -g DEFAULT_SYSTEM_OUTPUT_UID=''
typeset -g NONCE=''
typeset -g UNLOCK_REQUEST_SHA256=''
typeset -g VISUAL_MARKER=''
typeset -g LOCAL_APP_BUILD=''
typeset -g LOCAL_APP_URL=''
typeset -g XCTESTRUN_FILE=''
typeset -g PRIMARY_SESSION_ID=''
typeset -g PRIMARY_PEER_GENERATION=''
typeset -g PRIMARY_NEGOTIATION_EPOCH=''
typeset -g PRIMARY_BASELINE_MODE=''
typeset -g PRIMARY_INACTIVE_EVIDENCE=log
typeset -g PRIMARY_STOPPED_REPORT_IDENTITY=''
typeset -g PRIMARY_STOPPED_REPORT_DIRECTORIES=''
typeset -g PRIMARY_STOPPED_REPORT_HOST_START=''
typeset -g STOPPED_REPORT_READ_IDENTITY=''
typeset -g STOPPED_REPORT_READ_DIRECTORIES=''
typeset -g PRIMARY_AUDIO_STATUS=''
typeset -g PRIMARY_AUDIO_APP_ACTIVE=''
typeset -g PRIMARY_AUDIO_SEQUENCE_BEFORE=''
typeset -g PRIMARY_AUDIO_SEQUENCE_PREMINT=''
typeset -g PRIMARY_AUDIO_SEQUENCE_AFTER=''
typeset -g PRIMARY_INBOUND_PACKETS_BEFORE=''
typeset -g PRIMARY_INBOUND_PACKETS_PREMINT=''
typeset -g PRIMARY_INBOUND_PACKETS_AFTER=''
typeset -g PRIMARY_INBOUND_BYTES_BEFORE=''
typeset -g PRIMARY_INBOUND_BYTES_PREMINT=''
typeset -g PRIMARY_INBOUND_BYTES_AFTER=''
typeset -g PRIMARY_AUDIO_CALLBACKS_BEFORE=''
typeset -g PRIMARY_AUDIO_CALLBACKS_PREMINT=''
typeset -g PRIMARY_AUDIO_CALLBACKS_AFTER=''
typeset -g PRIMARY_AUDIO_FRAMES_BEFORE=''
typeset -g PRIMARY_AUDIO_FRAMES_PREMINT=''
typeset -g PRIMARY_AUDIO_FRAMES_AFTER=''
typeset -g PRIMARY_AUDIO_NONZERO_BEFORE=''
typeset -g PRIMARY_AUDIO_NONZERO_PREMINT=''
typeset -g PRIMARY_AUDIO_NONZERO_AFTER=''
typeset -g PRIMARY_MIC_BASELINE_MODE=''
typeset -g PRIMARY_CONTINUITY_ASSURANCE=''
typeset -g PRIMARY_MIC_FORWARDING_PHASE=''
typeset -g PRIMARY_MIC_ROUTING_EPOCH=''
typeset -g PRIMARY_MIC_DEVICE_GENERATION=''
typeset -g PRIMARY_MIC_PCM_GENERATION=''
typeset -g PRIMARY_MIC_BOUND_DEC_GENERATION=''
typeset -g PRIMARY_MIC_DEC_GENERATION=''
typeset -g PRIMARY_MIC_MONITOR_EPOCH=''
typeset -g PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH=''
typeset -g PRIMARY_MIC_TRACK_GENERATION=''
typeset -g PRIMARY_MIC_ATTEMPT_GENERATION=''
typeset -g PRIMARY_MIC_CALLBACKS_BEFORE=''
typeset -g PRIMARY_MIC_CALLBACKS_PREMINT=''
typeset -g PRIMARY_MIC_CALLBACKS_AFTER=''
typeset -g PRIMARY_MIC_FRAMES_BEFORE=''
typeset -g PRIMARY_MIC_FRAMES_PREMINT=''
typeset -g PRIMARY_MIC_FRAMES_AFTER=''
typeset -g PRIMARY_MIC_PCM_WINDOWS_BEFORE=''
typeset -g PRIMARY_MIC_PCM_WINDOWS_PREMINT=''
typeset -g PRIMARY_MIC_PCM_WINDOWS_AFTER=''
typeset -g PRIMARY_MIC_DEC_CALLS_BEFORE=''
typeset -g PRIMARY_MIC_DEC_CALLS_PREMINT=''
typeset -g PRIMARY_MIC_DEC_CALLS_AFTER=''
typeset -g PRIMARY_MIC_DEC_FRAMES_BEFORE=''
typeset -g PRIMARY_MIC_DEC_FRAMES_PREMINT=''
typeset -g PRIMARY_MIC_DEC_FRAMES_AFTER=''
typeset -g PRIMARY_MIC_MEDIA_SAMPLE_BEFORE=''
typeset -g PRIMARY_MIC_MEDIA_SAMPLE_PREMINT=''
typeset -g PRIMARY_MIC_MEDIA_SAMPLE_AFTER=''

function write_run_status() {
  local phase=$1
  local reason=${2:-}
  local updated_at updated_at_epoch temporary_status
  if [[ "$SELF_TEST_MODE" == final-status-failure && "$phase" == passed ]]; then
    return 1
  fi
  updated_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
  updated_at_epoch=$(/bin/date '+%s')
  temporary_status=$(/usr/bin/mktemp "${RUN_STATUS}.tmp.XXXXXX")
  jq -n \
    --arg schema 'opensteamer.iphone15-dev-screen-visual-oracle-run.v1' \
    --arg phase "$phase" \
    --arg pid "$$" \
    --arg runnerProcessStart "$RUN_PROCESS_START" \
    --arg startedAt "$RUN_STARTED_AT" \
    --arg updatedAt "$updated_at" \
    --argjson updatedAtEpoch "$updated_at_epoch" \
    --arg stage "$STAGE" \
    --arg reason "$reason" \
    --arg deviceId "$DEVICE_ID" \
    --arg hardwareUDID "$HARDWARE_UDID" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" \
    --arg hostIdentityBeforeChallenge "$HOST_IDENTITY_BEFORE_CHALLENGE" \
    --arg artifactDir "$ARTIFACT_DIR" \
    --arg summary "$SUMMARY" \
    --arg unlockRequest "$UNLOCK_REQUEST" \
    '{schema:$schema,phase:$phase,pid:($pid | tonumber),
      runnerProcessStart:$runnerProcessStart,startedAt:$startedAt,
      updatedAt:$updatedAt,updatedAtEpoch:$updatedAtEpoch,
      stage:$stage,reason:$reason,deviceId:$deviceId,
      hardwareUDID:$hardwareUDID,bundleId:$bundleId,artifactDir:$artifactDir,
      hostIdentityManifestSHA256Path:$hostIdentityManifestSHA256Path,
      hostIdentityManifestSHA256:$hostIdentityManifestSHA256,
      hostIdentityBeforeChallenge:$hostIdentityBeforeChallenge,
      summary:$summary,unlockRequest:$unlockRequest}' > "$temporary_status"
  /bin/chmod 600 "$temporary_status"
  /bin/mv "$temporary_status" "$RUN_STATUS"
}

function fail() {
  append_failure_reason "$1"
  print -u2 -- "iPhone 15 development screen oracle: ${FAILURE_REASON} (artifacts: ${ARTIFACT_DIR})"
  exit 1
}

function append_failure_reason() {
  local reason=$1
  [[ "$FAILURE_REASON" != "$reason" ]] || return 0
  if [[ -n "$FAILURE_REASON" ]]; then
    FAILURE_REASON="${FAILURE_REASON}; ${reason}"
  else
    FAILURE_REASON=$reason
  fi
}

function capture_physical_test_result() {
  PHYSICAL_TEST_EXIT_STATUS=$1
  if xcrun xcresulttool get test-results summary \
      --path "$RESULT_BUNDLE" --compact > "${ARTIFACT_DIR}/xcresult-summary.json" \
      2> "${ARTIFACT_DIR}/xcresult-summary.stderr.log"; then
    XCRESULT_SUMMARY_CAPTURED=1
  fi
  if xcrun xcresulttool get test-results tests \
      --path "$RESULT_BUNDLE" --compact > "${ARTIFACT_DIR}/xcresult-tests.json" \
      2> "${ARTIFACT_DIR}/xcresult-tests.stderr.log"; then
    XCRESULT_TESTS_CAPTURED=1
  fi
  if (( XCRESULT_TESTS_CAPTURED )) && jq -e --arg udid "$HARDWARE_UDID" '
      (.devices | type == "array" and length == 1) and
      .devices[0].deviceId == $udid and (.testNodes | type == "array")
    ' "${ARTIFACT_DIR}/xcresult-tests.json" >/dev/null 2>&1; then
    SELECTED_TEST_RECORD=$(jq -r --arg test "$TEST_NODE" '
      if any(.. | objects; .nodeType? == "Test Case" and .nodeIdentifier? == $test)
      then "present" else "absent" end
    ' "${ARTIFACT_DIR}/xcresult-tests.json")
  fi
  (( PHYSICAL_TEST_EXIT_STATUS != 0 )) || return 0
  PHYSICAL_TEST_FAILURE_CLASS=xctestExecutionFailure
  PHYSICAL_TEST_FAILURE_REASON='physical iPhone 15 final-pixel test failed; see test.log and xcresult'
  local selected_test_log_scan_status=2
  if [[ "$SELECTED_TEST_RECORD" == absent && -f "${ARTIFACT_DIR}/test.log" ]]; then
    if rg -q 'Test Case .*IPhone15SecondaryViewerDevelopmentPhysicalUITests.*testTemporaryViewerFinalPixelsTrackFreshMacChallenge' \
        "${ARTIFACT_DIR}/test.log" 2> "${ARTIFACT_DIR}/selected-test-log-scan.stderr.log"; then
      selected_test_log_scan_status=0
    else
      selected_test_log_scan_status=$?
    fi
  fi
  # XCTest reports runner initialization errors as synthetic test cases, not zero total tests.
  if [[ "$SELECTED_TEST_RECORD" == absent ]] && (( XCRESULT_SUMMARY_CAPTURED )) \
      && jq -e --arg udid "$HARDWARE_UDID" '
        .result == "Failed" and
        (.devicesAndConfigurations | type == "array" and length == 1) and
        .devicesAndConfigurations[0].device.deviceId == $udid and
        any(.testFailures[]?; .targetName == "opensteamerUITests" and
          (.failureText | startswith("The test runner failed to initialize for UI testing.")))
      ' "${ARTIFACT_DIR}/xcresult-summary.json" >/dev/null 2>&1 \
      && (( selected_test_log_scan_status == 1 )); then
    PHYSICAL_TEST_FAILURE_CLASS=xctestInitializationFailure
    PHYSICAL_TEST_FAILURE_REASON='XCTest initialization failed before the selected iPhone 15 oracle test ran; see test.log and xcresult'
  fi
  append_failure_reason "$PHYSICAL_TEST_FAILURE_REASON"
}

function owned_child_is_alive() {
  local child_pid=$1
  local parent_pid
  kill -0 "$child_pid" 2>/dev/null || return 1
  parent_pid=$(ps -p "$child_pid" -o ppid=,state= 2>/dev/null \
    | /usr/bin/awk '$2 !~ /^Z/ { print $1; exit }') || return 1
  [[ "$parent_pid" == "$$" ]]
}

function delete_invitation_source() {
  if (( INVITATION_SOURCE_MINT_ATTEMPTED != 0 && INVITATION_SOURCE_DELETED == 0 )); then
    if /bin/rm -f "$INVITATION_SOURCE" 2>/dev/null && [[ ! -e "$INVITATION_SOURCE" ]]; then
      INVITATION_SOURCE_DELETED=1
    else
      append_failure_reason 'Mac invitation source could not be deleted'
      return 1
    fi
  fi
  return 0
}

function delete_staged_invitation() {
  if (( INVITATION_STAGED != 0 )); then
    if /bin/rm -f "$STAGED_INVITATION" 2>/dev/null \
        && [[ ! -e "$STAGED_INVITATION" ]] \
        && /bin/rmdir "$STAGED_INVITATION_DIR" 2>/dev/null \
        && [[ ! -e "$STAGED_INVITATION_DIR" ]]; then
      INVITATION_STAGED=0
    else
      append_failure_reason 'staged Mac invitation copy could not be deleted'
      return 1
    fi
  fi
  return 0
}

function secondary_manager_receipt_generation_is_expected() {
  local manager_generation=$1
  local expected_manager_generation
  [[ -n "$manager_generation" && "$manager_generation" != *[^0-9]* \
      && -n "$SECONDARY_MANAGER_GENERATION_BASELINE" \
      && "$SECONDARY_MANAGER_GENERATION_BASELINE" != *[^0-9]* ]] \
    || return 1
  (( SECONDARY_MANAGER_GENERATION_BASELINE < 9223372036854775807 )) \
    || return 1
  expected_manager_generation=$(( SECONDARY_MANAGER_GENERATION_BASELINE + 1 ))
  [[ "$manager_generation" == "$expected_manager_generation" ]]
}

function validate_host_generation_receipt() {
  local validated_receipt_json validated_host_generation
  local validated_manager_generation validated_renewal_request_nonce
  local validated_receipt_sha256
  [[ -f "$HOST_GENERATION_RECEIPT" && ! -L "$HOST_GENERATION_RECEIPT" \
      && "$(/usr/bin/stat -f '%u' "$HOST_GENERATION_RECEIPT")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$HOST_GENERATION_RECEIPT")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$HOST_GENERATION_RECEIPT")" == 1 \
      && "$(/usr/bin/stat -f '%z' "$HOST_GENERATION_RECEIPT")" -gt 0 \
      && "$(/usr/bin/stat -f '%z' "$HOST_GENERATION_RECEIPT")" -le 2048 ]] \
    || return 1
  jq --stream -e -s '
    [ .[] | select(length == 2) | .[0] ] as $paths
    | ($paths | length) == 9
      and (($paths | sort) == ([
        ["invitationOutputPath"], ["receipt", "hostGeneration"],
        ["receipt", "hostProcessIdentifier"], ["receipt", "managerGeneration"],
        ["receipt", "renewalRequestNonce"], ["receipt", "type"],
        ["receipt", "v"], ["type"], ["v"]
      ] | sort))
  ' "$HOST_GENERATION_RECEIPT" >/dev/null || return 1
  validated_receipt_json=$(jq -c -e -S -s \
    --arg path "$INVITATION_SOURCE" --arg pid "$HOST_PID" \
    --arg generation "$HOST_GENERATION" '
      def is_valid_receipt:
        (keys | sort) == ["invitationOutputPath", "receipt", "type", "v"] and
        .v == 1 and .type == "secondaryTestViewerPersistedGenerationReceipt" and
        .invitationOutputPath == $path and
        (.receipt | type == "object") and
        (.receipt | keys | sort) == ["hostGeneration", "hostProcessIdentifier",
          "managerGeneration", "renewalRequestNonce", "type", "v"] and
        .receipt.v == 1 and
        .receipt.type == "secondaryTestViewerGenerationReceipt" and
        .receipt.hostProcessIdentifier == ($pid | tonumber) and
        .receipt.hostGeneration == $generation and
        (.receipt.managerGeneration | type == "number") and
        .receipt.managerGeneration > 0 and
        (.receipt.managerGeneration | floor) == .receipt.managerGeneration and
        (.receipt.renewalRequestNonce | type == "string") and
        (.receipt.renewalRequestNonce | test("^[0-9a-f]{32}$"));
      if length == 1 and (.[0] | is_valid_receipt) then .[0]
      else error("invalid persisted generation receipt") end
    ' "$HOST_GENERATION_RECEIPT") || return 1
  validated_host_generation=$(print -rn -- "$validated_receipt_json" \
    | jq -e -r '.receipt.hostGeneration') || return 1
  validated_manager_generation=$(print -rn -- "$validated_receipt_json" \
    | jq -e -r '.receipt.managerGeneration | tostring') || return 1
  validated_renewal_request_nonce=$(print -rn -- "$validated_receipt_json" \
    | jq -e -r '.receipt.renewalRequestNonce') || return 1
  validated_receipt_sha256=$(print -rn -- "$validated_receipt_json" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }') || return 1
  [[ "$validated_host_generation" =~ '^[0-9a-f]{64}$' \
      && "$validated_manager_generation" =~ '^[1-9][0-9]*$' \
      && "$validated_renewal_request_nonce" =~ '^[0-9a-f]{32}$' \
      && "$validated_receipt_sha256" =~ '^[0-9a-f]{64}$' ]] || return 1
  secondary_manager_receipt_generation_is_expected \
    "$validated_manager_generation" \
    || return 1
  if (( HOST_GENERATION_RECEIPT_VALIDATED != 0 )); then
    [[ "$validated_host_generation" == "$SECONDARY_HOST_GENERATION" \
        && "$validated_manager_generation" == "$SECONDARY_MANAGER_GENERATION" \
        && "$validated_renewal_request_nonce" == "$SECONDARY_RENEWAL_REQUEST_NONCE" \
        && "$validated_receipt_sha256" == "$SECONDARY_VALIDATED_RECEIPT_SHA256" ]] \
      || return 1
  else
    # The canonical receipt contains only generation metadata and the private file path,
    # never the invitation body. Keep its identity after exact-generation stop consumes it.
    SECONDARY_HOST_GENERATION=$validated_host_generation
    SECONDARY_MANAGER_GENERATION=$validated_manager_generation
    SECONDARY_RENEWAL_REQUEST_NONCE=$validated_renewal_request_nonce
    SECONDARY_VALIDATED_RECEIPT_SHA256=$validated_receipt_sha256
  fi
  HOST_GENERATION_RECEIPT_VALIDATED=1
}

function host_identity_is_current_for_cleanup() {
  local actual_pid actual_executable actual_command lock_bytes lock_pid lock_generation
  actual_pid=$(current_host_pid 2>/dev/null) || return 1
  [[ -n "$actual_pid" && "$actual_pid" == "$HOST_PID" ]] || return 1
  actual_executable=$(ps -p "$actual_pid" -o comm= 2>/dev/null) || return 1
  [[ "$actual_executable" == "$HOST_EXECUTABLE" ]] || return 1
  actual_command=$(ps -ww -p "$actual_pid" -o command= 2>/dev/null) || return 1
  [[ "$actual_command" == "$HOST_COMMAND" ]] || return 1
  local lock_directory=${HOST_LOCK:h}
  [[ -d "$lock_directory" && ! -L "$lock_directory" \
      && "$(/usr/bin/stat -f '%u' "$lock_directory" 2>/dev/null)" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$lock_directory" 2>/dev/null)" == 700 \
      && -f "$HOST_LOCK" && ! -L "$HOST_LOCK" \
      && "$(/usr/bin/stat -f '%u' "$HOST_LOCK" 2>/dev/null)" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$HOST_LOCK" 2>/dev/null)" == 600 \
      && "$(/usr/bin/stat -f '%l' "$HOST_LOCK" 2>/dev/null)" == 1 \
      && "$(/usr/bin/stat -f '%z' "$HOST_LOCK" 2>/dev/null)" -le 256 ]] \
    || return 1
  lock_bytes=$(<"$HOST_LOCK") || return 1
  lock_pid=$(print -r -- "$lock_bytes" \
    | /usr/bin/awk -F= '$1 == "pid" { print $2; found = 1 } END { if (!found) exit 1 }') \
    || return 1
  lock_generation=$(print -r -- "$lock_bytes" \
    | /usr/bin/awk -F= '$1 == "nonce" { print $2; found = 1 } END { if (!found) exit 1 }') \
    || return 1
  [[ "$(print -r -- "$lock_bytes" | /usr/bin/head -n 1)" \
        == 'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1' \
      && "$lock_pid" == "$HOST_PID" \
      && "$lock_generation" == "$HOST_GENERATION" ]]
}

function stop_secondary_generation() {
  if (( HOST_GENERATION_STOPPED != 0 )); then
    return 0
  fi
  if [[ ! -e "$HOST_GENERATION_RECEIPT" ]]; then
    if (( HOST_GENERATION_RECEIPT_VALIDATED != 0 )); then
      append_failure_reason 'secondary generation receipt disappeared before exact cleanup'
      return 1
    fi
    return 0
  fi
  if (( HOST_GENERATION_STOP_ATTEMPTED != 0 )); then
    append_failure_reason 'secondary generation exact cleanup was already attempted without proof'
    return 1
  fi
  HOST_GENERATION_STOP_ATTEMPTED=1
  validate_host_generation_receipt || {
    append_failure_reason 'secondary generation receipt was unsafe or malformed'
    return 1
  }
  host_identity_is_current_for_cleanup || {
    append_failure_reason 'Mac host identity changed before secondary generation cleanup'
    return 1
  }
  local stop_stdout="${ARTIFACT_DIR}/generation-stop.stdout.log"
  local stop_stderr="${ARTIFACT_DIR}/generation-stop.stderr.log"
  local stop_status=0
  if ( run_sealed_host_management_child \
      secondary-generation-stop "$stop_stdout" "$stop_stderr" 0 \
      --stop-secondary-test-viewer-generation "$HOST_GENERATION_RECEIPT" ); then
    stop_status=0
  else
    stop_status=$?
  fi
  if (( stop_status != 0 )) || [[ -s "$stop_stdout" || -s "$stop_stderr" \
      || -e "$HOST_GENERATION_RECEIPT" ]]; then
    append_failure_reason 'secondary generation exact cleanup was not confirmed'
    return 1
  fi
  host_identity_is_current_for_cleanup || {
    append_failure_reason 'Mac host identity changed during secondary generation cleanup'
    return 1
  }
  HOST_GENERATION_STOPPED=1
  return 0
}

function stop_physical_test_process() {
  local prefix=$1
  local child_pid child_attempt forced=0
  [[ -n "$PHYSICAL_TEST_PID" ]] || return 0
  child_pid=$PHYSICAL_TEST_PID
  if owned_child_is_alive "$child_pid"; then
    kill -TERM "$child_pid" 2>/dev/null || true
    for (( child_attempt = 0; child_attempt < 100; child_attempt++ )); do
      owned_child_is_alive "$child_pid" || break
      /bin/sleep 0.05
    done
  fi
  if owned_child_is_alive "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    forced=1
  fi
  wait "$child_pid" 2>/dev/null || true
  PHYSICAL_TEST_PID=''
  if (( forced != 0 )); then
    append_failure_reason \
      "physical iPhone test required forced termination at ${prefix}"
    return 1
  fi
  return 0
}

function finish() {
  local prior_status=$?
  local result=${1:-$prior_status}
  if (( FINISHING != 0 )); then
    return
  fi
  FINISHING=1
  trap - EXIT
  trap '' HUP INT TERM
  local cleanup_teardown_clean=1
  local monitor_was_active=0
  local monitor_teardown_clean=1
  local monitor_forced=0
  local monitor_wait_status=0
  local child_attempt monitor_attempt monitor_pid=''

  # The test may still own the development app/container. Stop and reap it before cleanup so the
  # credential-free lease remains healthy while the cleanup launch removes every copied secret.
  if [[ -n "$PHYSICAL_TEST_PID" ]]; then
    if ! stop_physical_test_process finalizer-before-device-secret-cleanup; then
      result=1
      cleanup_teardown_clean=0
    fi
  fi
  if (( DEVICE_SECRET_CLEANUP_REQUIRED != 0 )); then
    if ! run_device_secret_cleanup finalizer; then
      append_failure_reason 'iPhone development secret cleanup could not be proven'
      result=1
      cleanup_teardown_clean=0
    fi
  fi
  if [[ -n "$POWER_ASSERTION_PID" ]]; then
    if ! stop_device_power_assertion finalizer; then
      append_failure_reason \
        'exact-device power assertion did not stop cleanly after secret cleanup'
      result=1
      cleanup_teardown_clean=0
    fi
  fi
  stop_secondary_generation || { result=1; cleanup_teardown_clean=0; }
  delete_staged_invitation || { result=1; cleanup_teardown_clean=0; }
  delete_invitation_source || { result=1; cleanup_teardown_clean=0; }

  if [[ -n "$CHALLENGE_PID" ]]; then
    if owned_child_is_alive "$CHALLENGE_PID"; then
      kill -TERM "$CHALLENGE_PID" 2>/dev/null || true
      for (( child_attempt = 0; child_attempt < 40; child_attempt++ )); do
        owned_child_is_alive "$CHALLENGE_PID" || break
        /bin/sleep 0.05
      done
      if owned_child_is_alive "$CHALLENGE_PID"; then
        kill -KILL "$CHALLENGE_PID" 2>/dev/null || true
        append_failure_reason 'visual challenge required forced finalizer teardown'
        result=1
        cleanup_teardown_clean=0
      fi
    fi
    wait "$CHALLENGE_PID" 2>/dev/null || true
    CHALLENGE_PID=''
  fi

  if [[ -n "$AUDIO_ROUTE_MONITOR_PID" ]]; then
    monitor_pid=$AUDIO_ROUTE_MONITOR_PID
    monitor_was_active=1
    /usr/bin/touch "$AUDIO_ROUTE_MONITOR_STOP" 2>/dev/null || true
    for (( monitor_attempt = 0; monitor_attempt < 100; monitor_attempt++ )); do
      if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
          && jq -e '.phase == "stopped"' "$AUDIO_ROUTE_MONITOR_STATUS" \
            >/dev/null 2>&1; then
        break
      fi
      owned_child_is_alive "$monitor_pid" || break
      /bin/sleep 0.05
    done
    if owned_child_is_alive "$monitor_pid" \
        && ! jq -e '.phase == "stopped"' "$AUDIO_ROUTE_MONITOR_STATUS" \
          >/dev/null 2>&1; then
      kill -TERM "$monitor_pid" 2>/dev/null || true
    fi
    for (( child_attempt = 0; child_attempt < 40; child_attempt++ )); do
      owned_child_is_alive "$monitor_pid" || break
      /bin/sleep 0.05
    done
    if owned_child_is_alive "$monitor_pid"; then
      kill -KILL "$monitor_pid" 2>/dev/null || true
      monitor_forced=1
    fi
    if wait "$monitor_pid" 2>/dev/null; then
      monitor_wait_status=0
    else
      monitor_wait_status=$?
    fi
    AUDIO_ROUTE_MONITOR_PID=''
  fi
  if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]]; then
    AUDIO_ROUTE_MONITOR_PHASE=$(jq -r '.phase // empty' \
      "$AUDIO_ROUTE_MONITOR_STATUS" 2>/dev/null || true)
    AUDIO_ROUTE_NOTIFICATION_COUNT=$(jq -r '.notificationCount // empty' \
      "$AUDIO_ROUTE_MONITOR_STATUS" 2>/dev/null || true)
  fi
  if (( monitor_was_active )) && { (( monitor_forced != 0 \
      || monitor_wait_status != 0 )) || ! jq -e --argjson pid "$monitor_pid" '
      .schema == "opensteamer.default-route-monitor.v1" and
      .phase == "stopped" and .pid == $pid and .listenersInstalled == 3 and
      .listenersRemoved == true and .notificationCount == 0 and .clean == true and
      (.baseline.defaultInputUID | type == "string" and length > 0) and
      (.baseline.defaultOutputUID | type == "string" and length > 0) and
      (.baseline.defaultSystemOutputUID | type == "string" and length > 0) and
      .current == .baseline
    ' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; }; then
    monitor_teardown_clean=0
    cleanup_teardown_clean=0
    result=1
    append_failure_reason \
      'CoreAudio route monitor finalizer teardown was not clean with zero notifications'
  fi

  local verdict=failed
  local run_phase=failed
  if (( result == 0 && VERIFIED == 1 )); then
    verdict=passed
    run_phase=passed
  elif [[ -n "$SIGNAL_NAME" ]] && (( monitor_teardown_clean == 1 \
      && cleanup_teardown_clean == 1 )); then
    verdict=parked
    run_phase=parked
  elif (( result == 0 )); then
    result=1
    FAILURE_REASON="unverified normal exit during ${STAGE}"
  fi
  if [[ "$verdict" == failed && -z "$FAILURE_REASON" ]]; then
    FAILURE_REASON="unexpected command failure during ${STAGE}"
  fi
  local summary_staged=0
  if jq -n \
    --arg schema 'opensteamer.iphone15-dev-screen-visual-oracle.v1' \
    --arg status "$verdict" \
    --arg stage "$STAGE" \
    --arg reason "$FAILURE_REASON" \
    --arg signal "$SIGNAL_NAME" \
    --arg deviceId "$DEVICE_ID" \
    --arg hardwareUDID "$HARDWARE_UDID" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg build "$LOCAL_APP_BUILD" \
    --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" \
    --arg hostIdentityBeforeChallenge "$HOST_IDENTITY_BEFORE_CHALLENGE" \
    --arg hostPid "$HOST_PID" \
    --arg hostElapsedSeconds "$HOST_ELAPSED_SECONDS" \
    --arg expectedPrimaryBuild "$EXPECTED_PRIMARY_BUILD" \
    --arg primaryBaselineMode "$PRIMARY_BASELINE_MODE" \
    --arg primaryAudioStatus "$PRIMARY_AUDIO_STATUS" \
    --arg primarySession "$PRIMARY_SESSION_ID" \
    --arg primaryPeerGeneration "$PRIMARY_PEER_GENERATION" \
    --arg primaryNegotiationEpoch "$PRIMARY_NEGOTIATION_EPOCH" \
    --arg primaryAudioAppActive "$PRIMARY_AUDIO_APP_ACTIVE" \
    --arg primaryAudioSequenceBefore "$PRIMARY_AUDIO_SEQUENCE_BEFORE" \
    --arg primaryAudioSequencePremint "$PRIMARY_AUDIO_SEQUENCE_PREMINT" \
    --arg primaryAudioSequenceAfter "$PRIMARY_AUDIO_SEQUENCE_AFTER" \
    --arg primaryInboundPacketsBefore "$PRIMARY_INBOUND_PACKETS_BEFORE" \
    --arg primaryInboundPacketsPremint "$PRIMARY_INBOUND_PACKETS_PREMINT" \
    --arg primaryInboundPacketsAfter "$PRIMARY_INBOUND_PACKETS_AFTER" \
    --arg primaryInboundBytesBefore "$PRIMARY_INBOUND_BYTES_BEFORE" \
    --arg primaryInboundBytesPremint "$PRIMARY_INBOUND_BYTES_PREMINT" \
    --arg primaryInboundBytesAfter "$PRIMARY_INBOUND_BYTES_AFTER" \
    --arg primaryAudioCallbacksBefore "$PRIMARY_AUDIO_CALLBACKS_BEFORE" \
    --arg primaryAudioCallbacksPremint "$PRIMARY_AUDIO_CALLBACKS_PREMINT" \
    --arg primaryAudioCallbacksAfter "$PRIMARY_AUDIO_CALLBACKS_AFTER" \
    --arg primaryAudioFramesBefore "$PRIMARY_AUDIO_FRAMES_BEFORE" \
    --arg primaryAudioFramesPremint "$PRIMARY_AUDIO_FRAMES_PREMINT" \
    --arg primaryAudioFramesAfter "$PRIMARY_AUDIO_FRAMES_AFTER" \
    --arg primaryAudioNonzeroBefore "$PRIMARY_AUDIO_NONZERO_BEFORE" \
    --arg primaryAudioNonzeroPremint "$PRIMARY_AUDIO_NONZERO_PREMINT" \
    --arg primaryAudioNonzeroAfter "$PRIMARY_AUDIO_NONZERO_AFTER" \
    --arg primaryMicBaselineMode "$PRIMARY_MIC_BASELINE_MODE" \
    --arg primaryContinuityAssurance "$PRIMARY_CONTINUITY_ASSURANCE" \
    --arg primaryMicForwardingPhase "$PRIMARY_MIC_FORWARDING_PHASE" \
    --arg primaryMicRoutingEpoch "$PRIMARY_MIC_ROUTING_EPOCH" \
    --arg primaryMicDeviceGeneration "$PRIMARY_MIC_DEVICE_GENERATION" \
    --arg primaryMicPCMGeneration "$PRIMARY_MIC_PCM_GENERATION" \
    --arg primaryMicBoundDecGeneration "$PRIMARY_MIC_BOUND_DEC_GENERATION" \
    --arg primaryMicDecGeneration "$PRIMARY_MIC_DEC_GENERATION" \
    --arg primaryMicMonitorEpoch "$PRIMARY_MIC_MONITOR_EPOCH" \
    --arg primaryMicTransportAuthorizationEpoch "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
    --arg primaryMicTrackGeneration "$PRIMARY_MIC_TRACK_GENERATION" \
    --arg primaryMicAttemptGeneration "$PRIMARY_MIC_ATTEMPT_GENERATION" \
    --arg primaryMicCallbacksBefore "$PRIMARY_MIC_CALLBACKS_BEFORE" \
    --arg primaryMicCallbacksPremint "$PRIMARY_MIC_CALLBACKS_PREMINT" \
    --arg primaryMicCallbacksAfter "$PRIMARY_MIC_CALLBACKS_AFTER" \
    --arg primaryMicFramesBefore "$PRIMARY_MIC_FRAMES_BEFORE" \
    --arg primaryMicFramesPremint "$PRIMARY_MIC_FRAMES_PREMINT" \
    --arg primaryMicFramesAfter "$PRIMARY_MIC_FRAMES_AFTER" \
    --arg primaryMicPCMWindowsBefore "$PRIMARY_MIC_PCM_WINDOWS_BEFORE" \
    --arg primaryMicPCMWindowsPremint "$PRIMARY_MIC_PCM_WINDOWS_PREMINT" \
    --arg primaryMicPCMWindowsAfter "$PRIMARY_MIC_PCM_WINDOWS_AFTER" \
    --arg primaryMicDecCallsBefore "$PRIMARY_MIC_DEC_CALLS_BEFORE" \
    --arg primaryMicDecCallsPremint "$PRIMARY_MIC_DEC_CALLS_PREMINT" \
    --arg primaryMicDecCallsAfter "$PRIMARY_MIC_DEC_CALLS_AFTER" \
    --arg primaryMicDecFramesBefore "$PRIMARY_MIC_DEC_FRAMES_BEFORE" \
    --arg primaryMicDecFramesPremint "$PRIMARY_MIC_DEC_FRAMES_PREMINT" \
    --arg primaryMicDecFramesAfter "$PRIMARY_MIC_DEC_FRAMES_AFTER" \
    --arg primaryMicMediaSampleBefore "$PRIMARY_MIC_MEDIA_SAMPLE_BEFORE" \
    --arg primaryMicMediaSamplePremint "$PRIMARY_MIC_MEDIA_SAMPLE_PREMINT" \
    --arg primaryMicMediaSampleAfter "$PRIMARY_MIC_MEDIA_SAMPLE_AFTER" \
    --arg defaultInputUID "$DEFAULT_INPUT_UID" \
    --arg defaultOutputUID "$DEFAULT_OUTPUT_UID" \
    --arg defaultSystemOutputUID "$DEFAULT_SYSTEM_OUTPUT_UID" \
    --arg audioRouteMonitorPhase "$AUDIO_ROUTE_MONITOR_PHASE" \
    --arg audioRouteNotificationCount "$AUDIO_ROUTE_NOTIFICATION_COUNT" \
    --arg audioRouteMonitorStatus "$AUDIO_ROUTE_MONITOR_STATUS" \
    --arg nonce "$NONCE" \
    --arg visualMarker "$VISUAL_MARKER" \
    --arg testId "$TEST_ID" \
    --arg resultBundle "$RESULT_BUNDLE" \
    --arg physicalTestExitStatus "$PHYSICAL_TEST_EXIT_STATUS" \
    --arg physicalTestFailureClass "$PHYSICAL_TEST_FAILURE_CLASS" \
    --arg selectedTestRecord "$SELECTED_TEST_RECORD" \
    --arg secondaryHostGeneration "$SECONDARY_HOST_GENERATION" \
    --arg secondaryManagerGenerationBaseline "$SECONDARY_MANAGER_GENERATION_BASELINE" \
    --arg secondaryManagerGeneration "$SECONDARY_MANAGER_GENERATION" \
    --arg secondaryRenewalRequestNonce "$SECONDARY_RENEWAL_REQUEST_NONCE" \
    --arg secondaryValidatedReceiptSHA256 "$SECONDARY_VALIDATED_RECEIPT_SHA256" \
    --arg unlockRequestSHA256 "$UNLOCK_REQUEST_SHA256" \
    --arg powerAssertionPhase "$POWER_ASSERTION_PHASE" \
    --arg powerAssertionSequence "$POWER_ASSERTION_SEQUENCE" \
    --argjson secondaryGenerationReceiptValidated "$HOST_GENERATION_RECEIPT_VALIDATED" \
    --argjson unlockAcknowledgementValidated "$UNLOCK_ACK_VALIDATED" \
    --argjson powerAssertionStopped "$POWER_ASSERTION_STOPPED" \
    --argjson invitationCopied "$INVITATION_COPIED" \
    --argjson invitationSourceDeleted "$INVITATION_SOURCE_DELETED" \
    --argjson secondaryGenerationStopped "$HOST_GENERATION_STOPPED" \
    --argjson deviceSecretCleanupConfirmed "$DEVICE_SECRET_CLEANUP_CONFIRMED" \
    'def emptyToNull: if . == "" then null else . end;
    {schema:$schema,status:$status,stage:$stage,reason:$reason,signal:$signal,
      deviceId:$deviceId,hardwareUDID:$hardwareUDID,bundleId:$bundleId,build:$build,
      hostIdentityManifestSHA256Path:$hostIdentityManifestSHA256Path,
      hostIdentityManifestSHA256:$hostIdentityManifestSHA256,
      hostIdentityBeforeChallenge:$hostIdentityBeforeChallenge,
      hostPid:$hostPid,hostElapsedSeconds:$hostElapsedSeconds,
      primaryContinuity:{expectedBuild:$expectedPrimaryBuild,
        baselineMode:$primaryBaselineMode,
        assurance:$primaryContinuityAssurance,
        session:$primarySession,peerGeneration:$primaryPeerGeneration,
        negotiationEpoch:$primaryNegotiationEpoch,
        appActive:$primaryAudioAppActive,
        audio:{status:$primaryAudioStatus,
          sequence:{before:($primaryAudioSequenceBefore | emptyToNull),
            premint:($primaryAudioSequencePremint | emptyToNull),
            after:($primaryAudioSequenceAfter | emptyToNull)},
          inboundPackets:{before:($primaryInboundPacketsBefore | emptyToNull),
            premint:($primaryInboundPacketsPremint | emptyToNull),
            after:($primaryInboundPacketsAfter | emptyToNull)},
          inboundBytes:{before:($primaryInboundBytesBefore | emptyToNull),
            premint:($primaryInboundBytesPremint | emptyToNull),
            after:($primaryInboundBytesAfter | emptyToNull)},
          callbacks:{before:($primaryAudioCallbacksBefore | emptyToNull),
            premint:($primaryAudioCallbacksPremint | emptyToNull),
            after:($primaryAudioCallbacksAfter | emptyToNull)},
          frames:{before:($primaryAudioFramesBefore | emptyToNull),
            premint:($primaryAudioFramesPremint | emptyToNull),
            after:($primaryAudioFramesAfter | emptyToNull)},
          nonzeroSamples:{before:($primaryAudioNonzeroBefore | emptyToNull),
            premint:($primaryAudioNonzeroPremint | emptyToNull),
            after:($primaryAudioNonzeroAfter | emptyToNull)}},
        microphone:{baselineMode:$primaryMicBaselineMode,
          forwardingPhase:$primaryMicForwardingPhase,
          routingEpoch:$primaryMicRoutingEpoch,
          deviceGeneration:$primaryMicDeviceGeneration,
          pcmGeneration:$primaryMicPCMGeneration,
          boundDecodedGeneration:$primaryMicBoundDecGeneration,
          decodedGeneration:$primaryMicDecGeneration,
          monitorEpoch:$primaryMicMonitorEpoch,
          transportAuthorizationEpoch:$primaryMicTransportAuthorizationEpoch,
          trackGeneration:$primaryMicTrackGeneration,
          attemptGeneration:$primaryMicAttemptGeneration,
          callbacks:{before:($primaryMicCallbacksBefore | emptyToNull),
            premint:($primaryMicCallbacksPremint | emptyToNull),
            after:($primaryMicCallbacksAfter | emptyToNull)},
          frames:{before:($primaryMicFramesBefore | emptyToNull),
            premint:($primaryMicFramesPremint | emptyToNull),
            after:($primaryMicFramesAfter | emptyToNull)},
          pcmWindows:{before:($primaryMicPCMWindowsBefore | emptyToNull),
            premint:($primaryMicPCMWindowsPremint | emptyToNull),
            after:($primaryMicPCMWindowsAfter | emptyToNull)},
          decodedCalls:{before:($primaryMicDecCallsBefore | emptyToNull),
            premint:($primaryMicDecCallsPremint | emptyToNull),
            after:($primaryMicDecCallsAfter | emptyToNull)},
          decodedFrames:{before:($primaryMicDecFramesBefore | emptyToNull),
            premint:($primaryMicDecFramesPremint | emptyToNull),
            after:($primaryMicDecFramesAfter | emptyToNull)},
          mediaSample:{before:($primaryMicMediaSampleBefore | emptyToNull),
            premint:($primaryMicMediaSamplePremint | emptyToNull),
            after:($primaryMicMediaSampleAfter | emptyToNull)}}},
      defaultInputUID:$defaultInputUID,
      defaultOutputUID:$defaultOutputUID,
      defaultSystemOutputUID:$defaultSystemOutputUID,
      audioRouteMonitorPhase:$audioRouteMonitorPhase,
      audioRouteNotificationCount:$audioRouteNotificationCount,
      audioRouteMonitorStatus:$audioRouteMonitorStatus,nonce:$nonce,
      visualMarker:$visualMarker,testId:$testId,resultBundle:$resultBundle,
      testExecution:{exitStatus:(if $physicalTestExitStatus == "" then null
          else ($physicalTestExitStatus | tonumber) end),
        failureClass:($physicalTestFailureClass | emptyToNull),
        selectedTestRecord:$selectedTestRecord},
      unlockedStateGate:{requestSHA256:(if $unlockRequestSHA256 == "" then null
          else $unlockRequestSHA256 end),
        acknowledgementValidated:($unlockAcknowledgementValidated == 1)},
      powerAssertion:{phase:(if $powerAssertionPhase == "" then null
          else $powerAssertionPhase end),
        lastSequence:(if $powerAssertionSequence == "" then null
          else ($powerAssertionSequence | tonumber) end),
        stopped:($powerAssertionStopped == 1)},
      secondaryGeneration:{
        receiptValidated:($secondaryGenerationReceiptValidated == 1),
        hostGeneration:(if $secondaryHostGeneration == "" then null
          else $secondaryHostGeneration end),
        baselineManagerGeneration:(if $secondaryManagerGenerationBaseline == ""
          then null else ($secondaryManagerGenerationBaseline | tonumber) end),
        managerGeneration:(if $secondaryManagerGeneration == "" then null
          else ($secondaryManagerGeneration | tonumber) end),
        renewalRequestNonce:(if $secondaryRenewalRequestNonce == "" then null
          else $secondaryRenewalRequestNonce end),
        validatedReceiptSHA256:(if $secondaryValidatedReceiptSHA256 == "" then null
          else $secondaryValidatedReceiptSHA256 end),
        stopped:($secondaryGenerationStopped == 1)},
      invitationCopied:($invitationCopied == 1),
      invitationSourceDeleted:($invitationSourceDeleted == 1),
      secondaryGenerationStopped:($secondaryGenerationStopped == 1),
      deviceSecretCleanupConfirmed:($deviceSecretCleanupConfirmed == 1)}' \
      > "${SUMMARY}.tmp"; then
    summary_staged=1
  else
    /bin/rm -f "${SUMMARY}.tmp"
    result=1
    verdict=failed
    run_phase=failed
    FAILURE_REASON=${FAILURE_REASON:-'verified run could not persist its summary'}
    print -u2 -- \
      "iPhone 15 development screen oracle failed: could not write ${SUMMARY}"
  fi

  if [[ "$verdict" == passed && "$summary_staged" == 1 ]]; then
    if write_run_status passed "$FAILURE_REASON"; then
      if /bin/mv "${SUMMARY}.tmp" "$SUMMARY"; then
        print -- "iPhone 15 development screen oracle passed: ${SUMMARY}"
      else
        result=1
        verdict=failed
        run_phase=failed
        append_failure_reason 'verified run status committed but its passing summary could not be published'
        /bin/rm -f "${SUMMARY}.tmp"
        write_run_status failed "$FAILURE_REASON" >/dev/null 2>&1 || true
        print -u2 -- \
          "iPhone 15 development screen oracle failed: could not publish ${SUMMARY}"
      fi
    else
      result=1
      verdict=failed
      run_phase=failed
      append_failure_reason 'verified run could not commit its final passed status'
      if jq --arg reason "$FAILURE_REASON" \
          '.status = "failed" | .reason = $reason' "${SUMMARY}.tmp" \
          > "${SUMMARY}.failed.tmp" \
          && /bin/mv "${SUMMARY}.failed.tmp" "${SUMMARY}.tmp" \
          && /bin/mv "${SUMMARY}.tmp" "$SUMMARY"; then
        print -u2 -- "iPhone 15 development screen oracle failed: ${SUMMARY}"
      else
        /bin/rm -f "${SUMMARY}.tmp" "${SUMMARY}.failed.tmp"
      fi
      if ! write_run_status failed "$FAILURE_REASON"; then
        print -u2 -- "Development screen oracle failed: could not update ${RUN_STATUS}"
      fi
    fi
  else
    if (( summary_staged )); then
      if /bin/mv "${SUMMARY}.tmp" "$SUMMARY"; then
        print -- "iPhone 15 development screen oracle ${verdict}: ${SUMMARY}"
      else
        result=1
        verdict=failed
        run_phase=failed
        append_failure_reason 'run summary could not be published'
        /bin/rm -f "${SUMMARY}.tmp"
        print -u2 -- \
          "iPhone 15 development screen oracle failed: could not publish ${SUMMARY}"
      fi
    fi
    if ! write_run_status "$run_phase" "$FAILURE_REASON"; then
      result=1
      print -u2 -- "Development screen oracle failed: could not update ${RUN_STATUS}"
    fi
  fi
  exit "$result"
}

function handle_signal() {
  local signal_name=$1
  local signal_status=$2
  if (( OWNED_CHILD_PUBLICATION_PENDING != 0 )); then
    if [[ -z "$PENDING_SIGNAL_NAME" ]]; then
      PENDING_SIGNAL_NAME=$signal_name
      PENDING_SIGNAL_STATUS=$signal_status
    fi
    return
  fi
  SIGNAL_NAME=$signal_name
  FAILURE_REASON="received SIG${signal_name} during ${STAGE}"
  finish "$signal_status"
}

function finish_owned_child_publication() {
  OWNED_CHILD_PUBLICATION_PENDING=0
  if [[ -n "$PENDING_SIGNAL_NAME" ]]; then
    local signal_name=$PENDING_SIGNAL_NAME
    local signal_status=$PENDING_SIGNAL_STATUS
    PENDING_SIGNAL_NAME=''
    PENDING_SIGNAL_STATUS=0
    handle_signal "$signal_name" "$signal_status"
  fi
}

trap finish EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM
write_run_status preparing

if [[ "$SELF_TEST_MODE" == final-status-failure ]]; then
  STAGE=self-test-final-status-failure
  VERIFIED=1
  exit 0
fi

function require_no_production_observer() {
  local process_pid process_command status_file phase
  while read -r process_pid process_command; do
    [[ -n "$process_pid" ]] || continue
    if [[ "$process_command" == *'validate-testflight-screen-visual-oracle.sh'* ]]; then
      fail 'a production screen visual-oracle process is active'
    fi
  done < <(ps -axo pid=,command=)

  for status_file in "${RUN_STATE_ROOT}"/*-com.elamin.opensteamer.json(N); do
    [[ -f "$status_file" && ! -L "$status_file" ]] \
      || fail 'a production visual-oracle status path is unsafe'
    jq -e '
      .schema == "opensteamer.screen-visual-oracle-run.v1" and
      .bundleId == "com.elamin.opensteamer" and
      (.phase | type == "string") and (.pid | type == "number")
    ' "$status_file" >/dev/null \
      || fail 'a production visual-oracle status file is malformed'
    phase=$(jq -er '.phase' "$status_file") \
      || fail 'a production visual-oracle phase is unavailable'
    case "$phase" in
      preparing|armed|gate-open|observing)
        fail 'the production screen visual oracle is not parked'
        ;;
      parked|passed|failed)
        ;;
      *)
        fail 'a production visual-oracle status has an unknown phase'
        ;;
    esac
  done
}

function validate_invitation_source() {
  local owner mode links size modified now age
  [[ -f "$INVITATION_SOURCE" && ! -L "$INVITATION_SOURCE" ]] \
    || fail 'secondary invitation source must be a regular non-symbolic-link file'
  owner=$(/usr/bin/stat -f '%u' "$INVITATION_SOURCE") \
    || fail 'secondary invitation owner is unavailable'
  mode=$(/usr/bin/stat -f '%Lp' "$INVITATION_SOURCE") \
    || fail 'secondary invitation mode is unavailable'
  links=$(/usr/bin/stat -f '%l' "$INVITATION_SOURCE") \
    || fail 'secondary invitation link count is unavailable'
  size=$(/usr/bin/stat -f '%z' "$INVITATION_SOURCE") \
    || fail 'secondary invitation size is unavailable'
  modified=$(/usr/bin/stat -f '%m' "$INVITATION_SOURCE") \
    || fail 'secondary invitation timestamp is unavailable'
  [[ "$owner" == "$UID" && "$mode" == 600 && "$links" == 1 ]] \
    || fail 'secondary invitation must be owned by this user with mode 0600 and one link'
  [[ "$size" == 47 || "$size" == 48 ]] \
    || fail 'secondary invitation has an invalid canonical length'
  LC_ALL=C /usr/bin/grep -Eq \
    '^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){7}$' \
    "$INVITATION_SOURCE" \
    || fail 'secondary invitation is not in canonical redacted-safe format'
  now=$(/bin/date '+%s')
  [[ "$modified" != *[^0-9]* && "$now" != *[^0-9]* ]] \
    || fail 'secondary invitation timestamp is malformed'
  age=$(( now - modified ))
  (( age >= -5 && age <= INVITATION_MAX_AGE_SECONDS )) \
    || fail 'secondary invitation is not fresh enough for this bounded run'
  INVITATION_SOURCE_VALIDATED=1

  /bin/mkdir -m 700 "$STAGED_INVITATION_DIR" \
    || fail 'private Documents staging directory could not be created'
  [[ -d "$STAGED_INVITATION_DIR" && ! -L "$STAGED_INVITATION_DIR" \
      && "$(/usr/bin/stat -f '%u' "$STAGED_INVITATION_DIR")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$STAGED_INVITATION_DIR")" == 700 ]] \
    || fail 'private Documents staging directory metadata is unsafe'
  INVITATION_STAGED=1
  /usr/bin/install -m 600 "$INVITATION_SOURCE" "$STAGED_INVITATION" \
    || fail 'secondary invitation could not be staged privately'
  [[ -f "$STAGED_INVITATION" && ! -L "$STAGED_INVITATION" \
      && "$(/usr/bin/stat -f '%u' "$STAGED_INVITATION")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$STAGED_INVITATION")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$STAGED_INVITATION")" == 1 ]] \
    || fail 'staged secondary invitation metadata is unsafe'
  /usr/bin/cmp -s "$INVITATION_SOURCE" "$STAGED_INVITATION" \
    || fail 'secondary invitation changed while it was staged'
}

function current_host_pid() {
  launchctl print "$HOST_SERVICE" 2>/dev/null \
    | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

function require_same_host() {
  local actual_pid actual_executable actual_command
  actual_pid=$(current_host_pid) || fail 'Mac host launch agent is unavailable'
  [[ -n "$actual_pid" && "$actual_pid" != *[^0-9]* ]] \
    || fail 'Mac host PID cannot be verified'
  if [[ -z "$HOST_PID" ]]; then HOST_PID=$actual_pid; fi
  [[ "$actual_pid" == "$HOST_PID" ]] \
    || fail 'Mac host changed during development visual validation'
  actual_executable=$(ps -p "$HOST_PID" -o comm= 2>/dev/null) \
    || fail 'Mac host process is unavailable'
  [[ "$actual_executable" == "$HOST_EXECUTABLE" ]] \
    || fail 'Mac host executable identity is unexpected'
  actual_command=$(ps -ww -p "$HOST_PID" -o command= 2>/dev/null) \
    || fail 'Mac host command identity is unavailable'
  [[ " $actual_command " == *' --worldwide '* \
      && " $actual_command " == *' --secondary-test-viewer '* ]] \
    || fail 'Mac host is not the guarded secondary-viewer host'
  if [[ -z "$HOST_COMMAND" ]]; then HOST_COMMAND=$actual_command; fi
  [[ "$actual_command" == "$HOST_COMMAND" ]] \
    || fail 'Mac host command identity changed during validation'
}

function verify_sealed_host_identity() {
  local prefix=$1
  local snapshot="${ARTIFACT_DIR}/${prefix}-sealed-host-identity.txt"
  local error="${ARTIFACT_DIR}/${prefix}-sealed-host-identity.error.log"
  [[ "$prefix" =~ '^[a-z0-9-]+$' ]] \
    || fail 'sealed Mac host identity checkpoint name is invalid'
  [[ -n "$HOST_PID" && "$HOST_PID" != *[^0-9]* ]] \
    || fail "Mac host PID is not bound at ${prefix}"
  if ! /bin/zsh "$SEALED_HOST_IDENTITY_VERIFIER" \
      "$HOST_IDENTITY_MANIFEST" "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
      "$HOST_IDENTITY_MANIFEST_SHA256" \
      "$HOST_PID" "$HOST_EXECUTABLE" "$HOST_MEDIA_FRAMEWORK_EXECUTABLE" \
      "$HOST_APP" > "$snapshot" 2> "$error"; then
    fail "live Mac host does not match the release-sealed identity at ${prefix}"
  fi
  /usr/bin/grep -Fxq "manifest_sha256=${HOST_IDENTITY_MANIFEST_SHA256}" "$snapshot" \
    && /usr/bin/grep -Fxq "pid=${HOST_PID}" "$snapshot" \
    && /usr/bin/grep -Fxq "executable=${HOST_EXECUTABLE}" "$snapshot" \
    && /usr/bin/grep -Fxq 'installed_bundle_verified=true' "$snapshot" \
    || fail "sealed Mac host identity evidence is incomplete at ${prefix}"
  if [[ ! -e "$HOST_IDENTITY_SEALED_BASELINE" \
      && ! -L "$HOST_IDENTITY_SEALED_BASELINE" ]]; then
    /bin/cp "$snapshot" "$HOST_IDENTITY_SEALED_BASELINE" \
      || fail 'sealed Mac host identity baseline could not be retained'
    /bin/chmod 600 "$HOST_IDENTITY_SEALED_BASELINE"
  else
    [[ -f "$HOST_IDENTITY_SEALED_BASELINE" \
        && ! -L "$HOST_IDENTITY_SEALED_BASELINE" ]] \
      && /usr/bin/cmp -s "$HOST_IDENTITY_SEALED_BASELINE" "$snapshot" \
      || fail "sealed Mac host identity changed at ${prefix}"
  fi
  if [[ "$prefix" == before-challenge ]]; then
    /bin/cp "$snapshot" "$HOST_IDENTITY_BEFORE_CHALLENGE" \
      || fail 'sealed Mac host identity baseline could not be retained'
    /bin/chmod 600 "$HOST_IDENTITY_BEFORE_CHALLENGE"
  fi
}

# Every invocation of the installed CaptureServer as a management client is bracketed by the same
# external release seal that binds the live host. A pre-existing replacement is rejected before it
# can execute; the post-check also rejects any at-rest identity change while the child was running.
function run_sealed_host_management_child() {
  local prefix=$1
  local stdout=$2
  local stderr=$3
  local timeout_seconds=$4
  shift 4
  local child_status=0
  [[ "$prefix" =~ '^[a-z0-9-]+$' \
      && "$timeout_seconds" != *[^0-9]* ]] \
    || fail 'sealed host management invocation parameters are invalid'
  require_same_host
  verify_sealed_host_identity "${prefix}-client-before"
  if (( timeout_seconds > 0 )); then
    if /usr/bin/perl -e '
        my $seconds = shift @ARGV;
        alarm($seconds);
        exec {$ARGV[0]} @ARGV;
        exit 127;
      ' "$timeout_seconds" "$HOST_EXECUTABLE" "$@" \
        > "$stdout" 2> "$stderr"; then
      child_status=0
    else
      child_status=$?
    fi
  elif "$HOST_EXECUTABLE" "$@" > "$stdout" 2> "$stderr"; then
    child_status=0
  else
    child_status=$?
  fi
  require_same_host
  verify_sealed_host_identity "${prefix}-client-after"
  return "$child_status"
}

function host_elapsed_seconds() {
  local elapsed days=0 hours=0 minutes=0 seconds=0 clock
  local -a fields
  elapsed=$(ps -p "$HOST_PID" -o etime= 2>/dev/null) \
    || fail 'Mac host elapsed time is unavailable'
  elapsed=${elapsed//[[:space:]]/}
  [[ -n "$elapsed" ]] || fail 'Mac host elapsed time is empty'
  if [[ "$elapsed" == *-* ]]; then
    days=${elapsed%%-*}
    clock=${elapsed#*-}
  else
    clock=$elapsed
  fi
  [[ "$days" != *[^0-9]* ]] || fail 'Mac host elapsed day count is malformed'
  fields=("${(@s/:/)clock}")
  case ${#fields[@]} in
    3)
      hours=${fields[1]}
      minutes=${fields[2]}
      seconds=${fields[3]}
      ;;
    2)
      minutes=${fields[1]}
      seconds=${fields[2]}
      ;;
    *)
      fail 'Mac host elapsed clock is malformed'
      ;;
  esac
  [[ "$hours" != *[^0-9]* && "$minutes" != *[^0-9]* \
      && "$seconds" != *[^0-9]* && "$minutes" -lt 60 \
      && "$seconds" -lt 60 ]] \
    || fail 'Mac host elapsed clock fields are malformed'
  print -r -- "$(( days * 86400 + hours * 3600 + minutes * 60 + seconds ))"
}

function diagnostic_field() {
  local line=$1
  local key=$2
  print -r -- "$line" | /usr/bin/awk -v prefix="${key}=" '
    {
      for (field_index = 1; field_index <= NF; field_index++) {
        if (substr($field_index, 1, length(prefix)) == prefix) {
          print substr($field_index, length(prefix) + 1)
          found = 1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  '
}

function require_unsigned_diagnostic_field() {
  local value=$1
  local description=$2
  [[ -n "$value" && "$value" != *[^0-9]* ]] \
    || fail "${description} is missing or malformed"
}

function primary_audio_diagnostic_is_current_healthy() {
  local line=$1
  local native_age inbound_age
  [[ "$(diagnostic_field "$line" status 2>/dev/null || true)" \
      == renderingNonzero ]] || return 1
  native_age=$(diagnostic_field "$line" nativeAgeMs 2>/dev/null) || return 1
  inbound_age=$(diagnostic_field "$line" inboundAgeMs 2>/dev/null) || return 1
  [[ -n "$native_age" && "$native_age" != *[^0-9]* \
      && -n "$inbound_age" && "$inbound_age" != *[^0-9]* ]] || return 1
  (( native_age <= 5000 && inbound_age <= 5000 ))
}

function primary_audio_diagnostic_is_terminal_inactive() {
  local line=$1
  local build_value session_value peer_generation negotiation_epoch
  [[ "$line" == *"Worldwide audio client diagnostics pid=${HOST_PID} "* ]] \
    || return 1
  [[ "$(diagnostic_field "$line" status 2>/dev/null || true)" \
        == unavailable.stopped \
      && "$(diagnostic_field "$line" appActive 2>/dev/null || true)" \
        == false ]] || return 1
  build_value=$(diagnostic_field "$line" build 2>/dev/null) || return 1
  [[ "$build_value" == *"(${EXPECTED_PRIMARY_BUILD})" ]] || return 1
  session_value=$(diagnostic_field "$line" session 2>/dev/null) || return 1
  [[ "$session_value" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
    || return 1
  peer_generation=$(diagnostic_field "$line" peerGeneration 2>/dev/null) \
    || return 1
  negotiation_epoch=$(diagnostic_field "$line" negotiationEpoch 2>/dev/null) \
    || return 1
  [[ -n "$peer_generation" && "$peer_generation" != *[^0-9]* \
      && -n "$negotiation_epoch" && "$negotiation_epoch" != *[^0-9]* ]] \
    || return 1
  (( peer_generation > 0 && negotiation_epoch > 0 ))
}

function primary_audio_operational_fields_are_exact() {
  local line=$1
  local required_key required_value
  [[ "$(diagnostic_field "$line" playback 2>/dev/null || true)" == playing ]] \
    || return 1
  for required_key in peerConnected iceConnected controlOpen trackAvailable \
      micIntent micPermission initialized playoutInitialized nativePlaying \
      nativeActive nativeOwnsActivation outputRoute; do
    required_value=$(diagnostic_field "$line" "$required_key" 2>/dev/null) \
      || return 1
    [[ "$required_value" == true ]] || return 1
  done
  [[ "$(diagnostic_field "$line" micCallBlocked 2>/dev/null || true)" == false \
      && "$(diagnostic_field "$line" proof 2>/dev/null || true)" == complete \
      && "$(diagnostic_field "$line" authorization 2>/dev/null || true)" == valid \
      && "$(diagnostic_field "$line" targetMatched 2>/dev/null || true)" == true \
      && "$(diagnostic_field "$line" failureCode 2>/dev/null || true)" == 0 \
      && "$(diagnostic_field "$line" lifecycleStatus 2>/dev/null || true)" == 0 \
      && "$(diagnostic_field "$line" playoutStatus 2>/dev/null || true)" == 0 ]]
}

function parse_inactive_primary_audio_diagnostic() {
  local prefix=$1
  local line=$2
  local build_value session_value peer_generation negotiation_epoch audio_status
  local retained_playback
  [[ "$prefix" == before ]] \
    || fail "inactive primary audio is only a baseline proof at ${prefix}"
  primary_audio_diagnostic_is_terminal_inactive "$line" \
    || fail 'inactive primary terminal audio diagnostic is malformed'
  build_value=$(diagnostic_field "$line" build)
  session_value=$(diagnostic_field "$line" session)
  peer_generation=$(diagnostic_field "$line" peerGeneration)
  negotiation_epoch=$(diagnostic_field "$line" negotiationEpoch)
  audio_status=$(diagnostic_field "$line" status)
  retained_playback=$(diagnostic_field "$line" playback 2>/dev/null || true)

  PRIMARY_BASELINE_MODE=inactivePrimary
  PRIMARY_AUDIO_STATUS=$audio_status
  PRIMARY_SESSION_ID=${session_value:l}
  PRIMARY_PEER_GENERATION=$peer_generation
  PRIMARY_NEGOTIATION_EPOCH=$negotiation_epoch
  PRIMARY_AUDIO_APP_ACTIVE=false
  PRIMARY_MIC_BASELINE_MODE=inactivePrimary
  PRIMARY_MIC_FORWARDING_PHASE=inactive
  PRIMARY_CONTINUITY_ASSURANCE=inactivePrimaryNoAudioProof

  jq -n --arg session "${session_value:l}" --arg build "$build_value" \
    --arg peerGeneration "$peer_generation" \
    --arg negotiationEpoch "$negotiation_epoch" --arg status "$audio_status" \
    --arg retainedPlayback "$retained_playback" \
    '{proof:"inactive-terminal-only",session:$session,build:$build,
      peerGeneration:$peerGeneration,negotiationEpoch:$negotiationEpoch,
      status:$status,retainedPlayback:$retainedPlayback,appActive:false}' \
    > "${ARTIFACT_DIR}/${prefix}-primary-audio-continuity.json"
  jq -n \
    '{proof:"inactive-terminal-only",mode:"inactivePrimary",
      phase:"inactive",appActive:false}' \
    > "${ARTIFACT_DIR}/${prefix}-primary-microphone-continuity.json"
}

function parse_primary_audio_diagnostic() {
  local prefix=$1
  local line=$2
  local build_value session_value peer_generation negotiation_epoch
  local audio_sequence inbound_packets inbound_bytes callbacks frames nonzero_samples
  local audio_status native_age inbound_age app_active
  local required_key required_value

  [[ "$line" == *"Worldwide audio client diagnostics pid=${HOST_PID} "* ]] \
    || fail "primary audio diagnostic is not bound to the current host at ${prefix}"
  primary_audio_diagnostic_is_current_healthy "$line" \
    || fail "primary audio diagnostic is not fresh renderingNonzero evidence at ${prefix}"
  primary_audio_operational_fields_are_exact "$line" \
    || fail "primary audio operational proof is incomplete at ${prefix}"
  audio_status=$(diagnostic_field "$line" status)
  native_age=$(diagnostic_field "$line" nativeAgeMs)
  inbound_age=$(diagnostic_field "$line" inboundAgeMs)
  app_active=$(diagnostic_field "$line" appActive) \
    || fail "primary audio app-active state is unavailable at ${prefix}"
  [[ "$app_active" == true || "$app_active" == false ]] \
    || fail "primary audio app-active state is malformed at ${prefix}"
  build_value=$(diagnostic_field "$line" build) \
    || fail "primary audio build is unavailable at ${prefix}"
  [[ "$build_value" == *"(${EXPECTED_PRIMARY_BUILD})" ]] \
    || fail "primary audio diagnostic is not build ${EXPECTED_PRIMARY_BUILD} at ${prefix}"
  session_value=$(diagnostic_field "$line" session) \
    || fail "primary audio session is unavailable at ${prefix}"
  [[ "$session_value" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
    || fail "primary audio session UUID is malformed at ${prefix}"
  peer_generation=$(diagnostic_field "$line" peerGeneration) \
    || fail "primary audio peer generation is unavailable at ${prefix}"
  negotiation_epoch=$(diagnostic_field "$line" negotiationEpoch) \
    || fail "primary audio negotiation epoch is unavailable at ${prefix}"
  require_unsigned_diagnostic_field "$peer_generation" \
    "primary audio peer generation at ${prefix}"
  require_unsigned_diagnostic_field "$negotiation_epoch" \
    "primary audio negotiation epoch at ${prefix}"
  (( peer_generation > 0 && negotiation_epoch > 0 )) \
    || fail "primary audio identity is not active at ${prefix}"
  [[ "$(diagnostic_field "$line" playback)" == playing ]] \
    || fail "primary audio playback is not playing at ${prefix}"
  for required_key in peerConnected iceConnected controlOpen trackAvailable \
      micIntent micPermission initialized playoutInitialized nativePlaying \
      nativeActive nativeOwnsActivation outputRoute; do
    required_value=$(diagnostic_field "$line" "$required_key") \
      || fail "primary audio ${required_key} is unavailable at ${prefix}"
    [[ "$required_value" == true ]] \
      || fail "primary audio ${required_key} is not true at ${prefix}"
  done
  [[ "$(diagnostic_field "$line" micCallBlocked)" == false \
      && "$(diagnostic_field "$line" proof)" == complete \
      && "$(diagnostic_field "$line" authorization)" == valid \
      && "$(diagnostic_field "$line" targetMatched)" == true \
      && "$(diagnostic_field "$line" failureCode)" == 0 \
      && "$(diagnostic_field "$line" lifecycleStatus)" == 0 \
      && "$(diagnostic_field "$line" playoutStatus)" == 0 ]] \
    || fail "primary audio health proof is incomplete at ${prefix}"

  audio_sequence=$(diagnostic_field "$line" sequence) \
    || fail "primary audio sequence is unavailable at ${prefix}"
  inbound_packets=$(diagnostic_field "$line" inboundPackets) \
    || fail "primary inbound packet count is unavailable at ${prefix}"
  inbound_bytes=$(diagnostic_field "$line" inboundBytes) \
    || fail "primary inbound byte count is unavailable at ${prefix}"
  callbacks=$(diagnostic_field "$line" callbacks) \
    || fail "primary native callback count is unavailable at ${prefix}"
  frames=$(diagnostic_field "$line" frames) \
    || fail "primary native frame count is unavailable at ${prefix}"
  nonzero_samples=$(diagnostic_field "$line" nonzeroSamples) \
    || fail "primary nonzero sample count is unavailable at ${prefix}"
  for required_value in "$audio_sequence" "$inbound_packets" "$inbound_bytes" \
      "$callbacks" "$frames" "$nonzero_samples"; do
    require_unsigned_diagnostic_field "$required_value" \
      "primary audio progress counter at ${prefix}"
  done
  (( audio_sequence > 0 && inbound_packets > 0 && inbound_bytes > 0 \
      && callbacks > 0 && frames > 0 && nonzero_samples > 0 )) \
    || fail "primary audio progress has not started at ${prefix}"

  if [[ "$prefix" == before ]]; then
    PRIMARY_BASELINE_MODE=activePrimary
    PRIMARY_AUDIO_STATUS=$audio_status
    PRIMARY_SESSION_ID=${session_value:l}
    PRIMARY_PEER_GENERATION=$peer_generation
    PRIMARY_NEGOTIATION_EPOCH=$negotiation_epoch
    PRIMARY_AUDIO_APP_ACTIVE=$app_active
    PRIMARY_AUDIO_SEQUENCE_BEFORE=$audio_sequence
    PRIMARY_INBOUND_PACKETS_BEFORE=$inbound_packets
    PRIMARY_INBOUND_BYTES_BEFORE=$inbound_bytes
    PRIMARY_AUDIO_CALLBACKS_BEFORE=$callbacks
    PRIMARY_AUDIO_FRAMES_BEFORE=$frames
    PRIMARY_AUDIO_NONZERO_BEFORE=$nonzero_samples
  elif [[ "$prefix" == premint ]]; then
    [[ "${session_value:l}" == "$PRIMARY_SESSION_ID" \
        && "$peer_generation" == "$PRIMARY_PEER_GENERATION" \
        && "$negotiation_epoch" == "$PRIMARY_NEGOTIATION_EPOCH" \
        && "$app_active" == "$PRIMARY_AUDIO_APP_ACTIVE" ]] \
      || fail 'primary audio session, peer generation, or negotiation epoch changed'
    (( audio_sequence > PRIMARY_AUDIO_SEQUENCE_BEFORE \
        && inbound_packets > PRIMARY_INBOUND_PACKETS_BEFORE \
        && inbound_bytes > PRIMARY_INBOUND_BYTES_BEFORE \
        && callbacks > PRIMARY_AUDIO_CALLBACKS_BEFORE \
        && frames > PRIMARY_AUDIO_FRAMES_BEFORE \
        && nonzero_samples > PRIMARY_AUDIO_NONZERO_BEFORE )) \
      || fail 'primary audio playback counters stalled during development validation'
    PRIMARY_AUDIO_SEQUENCE_PREMINT=$audio_sequence
    PRIMARY_INBOUND_PACKETS_PREMINT=$inbound_packets
    PRIMARY_INBOUND_BYTES_PREMINT=$inbound_bytes
    PRIMARY_AUDIO_CALLBACKS_PREMINT=$callbacks
    PRIMARY_AUDIO_FRAMES_PREMINT=$frames
    PRIMARY_AUDIO_NONZERO_PREMINT=$nonzero_samples
  elif [[ "$prefix" == after ]]; then
    [[ "${session_value:l}" == "$PRIMARY_SESSION_ID" \
        && "$peer_generation" == "$PRIMARY_PEER_GENERATION" \
        && "$negotiation_epoch" == "$PRIMARY_NEGOTIATION_EPOCH" \
        && "$app_active" == "$PRIMARY_AUDIO_APP_ACTIVE" ]] \
      || fail 'primary audio session, peer generation, or negotiation epoch changed'
    (( audio_sequence > PRIMARY_AUDIO_SEQUENCE_PREMINT \
        && inbound_packets > PRIMARY_INBOUND_PACKETS_PREMINT \
        && inbound_bytes > PRIMARY_INBOUND_BYTES_PREMINT \
        && callbacks > PRIMARY_AUDIO_CALLBACKS_PREMINT \
        && frames > PRIMARY_AUDIO_FRAMES_PREMINT \
        && nonzero_samples > PRIMARY_AUDIO_NONZERO_PREMINT )) \
      || fail 'primary audio playback counters did not advance after invitation mint'
    PRIMARY_AUDIO_SEQUENCE_AFTER=$audio_sequence
    PRIMARY_INBOUND_PACKETS_AFTER=$inbound_packets
    PRIMARY_INBOUND_BYTES_AFTER=$inbound_bytes
    PRIMARY_AUDIO_CALLBACKS_AFTER=$callbacks
    PRIMARY_AUDIO_FRAMES_AFTER=$frames
    PRIMARY_AUDIO_NONZERO_AFTER=$nonzero_samples
  else
    fail "unsupported primary audio continuity phase: ${prefix}"
  fi

  jq -n --arg session "${session_value:l}" --arg build "$build_value" \
    --arg peerGeneration "$peer_generation" \
    --arg negotiationEpoch "$negotiation_epoch" \
    --arg sequence "$audio_sequence" --arg inboundPackets "$inbound_packets" \
    --arg inboundBytes "$inbound_bytes" --arg callbacks "$callbacks" \
    --arg frames "$frames" --arg nonzeroSamples "$nonzero_samples" \
    --arg status "$audio_status" --arg nativeAgeMs "$native_age" \
    --arg inboundAgeMs "$inbound_age" --arg appActive "$app_active" \
    '{session:$session,build:$build,peerGeneration:$peerGeneration,
      negotiationEpoch:$negotiationEpoch,status:$status,
      nativeAgeMs:$nativeAgeMs,inboundAgeMs:$inboundAgeMs,
      appActive:$appActive,
      playback:"playing",peerConnected:true,
      iceConnected:true,controlOpen:true,sequence:$sequence,
      inboundPackets:$inboundPackets,inboundBytes:$inboundBytes,
      callbacks:$callbacks,frames:$frames,nonzeroSamples:$nonzeroSamples}' \
    > "${ARTIFACT_DIR}/${prefix}-primary-audio-continuity.json"
}

function primary_microphone_quiescent_source_is_exact() {
  local audio_line=$1
  local forwarding_line=$2
  local required_key required_value

  required_value=$(diagnostic_field "$audio_line" appActive) || return 1
  [[ "$required_value" == false ]] || return 1
  required_value=$(diagnostic_field "$forwarding_line" phase) || return 1
  [[ "$required_value" == sourceMediaStalled ]] || return 1
  required_value=$(diagnostic_field "$forwarding_line" failure) || return 1
  [[ "$required_value" == sourceMediaStalled ]] || return 1

  required_value=$(diagnostic_field "$forwarding_line" monitorEpoch) || return 1
  [[ "$required_value" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] \
    || return 1
  for required_key in deviceGeneration peerGeneration \
      transportAuthorizationEpoch trackGeneration attemptGeneration; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ -n "$required_value" && "$required_value" != *[^0-9]* ]] || return 1
    (( required_value > 0 )) || return 1
  done
  required_value=$(diagnostic_field \
    "$forwarding_line" lastAttemptedKeyMatchesSnapshot) || return 1
  [[ "$required_value" == true ]] || return 1

  for required_key in inputEndpointAvailable hiddenSinkAvailable transport; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == true ]] || return 1
  done
  for required_key in hiddenWriterSelectionProven trackAdmitted queueRunning \
      decLatestExact decHasWindow decAllZero contentWindowsAlign \
      contentFingerprintsMatch mediaFresh; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == false ]] || return 1
  done
  for required_key in callbacks pulls frames silenceFallbacks enqueueFailures \
      pcmLifecycleGeneration pcmWindowSequence pcmCompletedFrames \
      pcmSourceStartFrame pcmSourceEndFrame pcmWindowFrames pcmWindowBytes \
      boundDecGeneration boundDecRenderFloor decGeneration decCalls \
      decRequestedFrames decRequestedBytes decReturnedBytes decNativeSuccess \
      decNativeFailure decExactContracts decAnalyzedCalls decAnalyzedFrames \
      decAnalyzedBytes decDropped decContractMismatch decPendingFrames \
      decLatestCall decLatestStatus decLatestRequestedFrames \
      decLatestRequestedBytes decLatestReturnedBytes decWindowSequence \
      decWindowGeneration decSourceStartFrame decSourceEndFrame decWindowFrames \
      decWindowBytes decFrozenBlocks decLongestFrozenRun mediaAdvances mediaStale; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == 0 ]] || return 1
  done
  for required_key in pcmRMS pcmPeak pcmDC pcmZeroFraction pcmClippingFraction \
      decRMS decPeak decDC decZeroFraction decClippingFraction; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == 0.000000 ]] || return 1
  done
  for required_key in pcmRMSdBFS pcmPeakdBFS decRMSdBFS decPeakdBFS; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == -160.00 ]] || return 1
  done
  required_value=$(diagnostic_field "$forwarding_line" mediaSample) || return 1
  [[ -n "$required_value" && "$required_value" != *[^0-9]* ]] || return 1
  (( required_value > 0 ))
}

function primary_microphone_forwarding_is_exact() {
  local forwarding_line=$1
  local required_key required_value
  [[ "$(diagnostic_field "$forwarding_line" phase 2>/dev/null || true)" \
      == forwardingHealthy ]] || return 1
  [[ "$(diagnostic_field "$forwarding_line" failure 2>/dev/null || true)" \
      == none ]] || return 1
  required_value=$(diagnostic_field "$forwarding_line" monitorEpoch) || return 1
  [[ "$required_value" =~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' ]] \
    || return 1
  for required_key in deviceGeneration peerGeneration \
      transportAuthorizationEpoch trackGeneration attemptGeneration; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ -n "$required_value" && "$required_value" != *[^0-9]* ]] || return 1
    (( required_value > 0 )) || return 1
  done
  required_value=$(diagnostic_field \
    "$forwarding_line" lastAttemptedKeyMatchesSnapshot) || return 1
  [[ "$required_value" == true ]] || return 1
  for required_key in inputEndpointAvailable hiddenSinkAvailable \
      hiddenWriterSelectionProven transport trackAdmitted queueRunning \
      decLatestExact decHasWindow contentWindowsAlign \
      contentFingerprintsMatch mediaFresh; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == true ]] || return 1
  done
  for required_key in decAllZero; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == false ]] || return 1
  done
  for required_key in silenceFallbacks enqueueFailures decNativeFailure \
      decDropped decContractMismatch decLatestStatus mediaStale; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ "$required_value" == 0 ]] || return 1
  done
  for required_key in pcmLifecycleGeneration boundDecGeneration decGeneration \
      callbacks frames pcmWindowSequence decCalls decAnalyzedFrames \
      mediaSample mediaAdvances; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") || return 1
    [[ -n "$required_value" && "$required_value" != *[^0-9]* ]] || return 1
    (( required_value > 0 )) || return 1
  done
}

function parse_primary_microphone_diagnostic() {
  local prefix=$1
  local selection_line=$2
  local forwarding_line=$3
  local audio_line=$4
  local routing_epoch selection_peer device_generation selection_pid
  local pcm_generation bound_dec_generation dec_generation
  local callbacks frames pcm_windows dec_calls dec_frames media_sample
  local required_key required_value monitor_epoch transport_epoch track_generation
  local attempt_generation
  local forwarding_phase microphone_mode

  routing_epoch=$(diagnostic_field "$selection_line" routingEpoch) \
    || fail "primary microphone routing epoch is unavailable at ${prefix}"
  selection_peer=$(diagnostic_field "$selection_line" peerGeneration) \
    || fail "primary microphone peer generation is unavailable at ${prefix}"
  device_generation=$(diagnostic_field "$selection_line" deviceGeneration) \
    || fail "primary microphone device generation is unavailable at ${prefix}"
  selection_pid=$(diagnostic_field "$selection_line" pid) \
    || fail "primary microphone host PID is unavailable at ${prefix}"
  [[ "$routing_epoch" =~ '^[0-9a-f]{32}$' \
      && "$selection_pid" == "$HOST_PID" \
      && "$selection_peer" == "$PRIMARY_PEER_GENERATION" ]] \
    || fail "primary microphone routing identity is invalid at ${prefix}"
  require_unsigned_diagnostic_field "$device_generation" \
    "primary microphone device generation at ${prefix}"
  (( device_generation > 0 )) \
    || fail "primary microphone device generation is inactive at ${prefix}"

  forwarding_phase=$(diagnostic_field "$forwarding_line" phase) \
    || fail "primary microphone forwarding phase is unavailable at ${prefix}"
  if [[ "$forwarding_phase" == sourceMediaStalled ]]; then
    primary_microphone_quiescent_source_is_exact "$audio_line" "$forwarding_line" \
      || fail "primary microphone quiescent baseline is malformed at ${prefix}"
    microphone_mode=quiescentInactiveSource
    monitor_epoch=$(diagnostic_field "$forwarding_line" monitorEpoch)
    transport_epoch=$(diagnostic_field \
      "$forwarding_line" transportAuthorizationEpoch)
    track_generation=$(diagnostic_field "$forwarding_line" trackGeneration)
    attempt_generation=$(diagnostic_field "$forwarding_line" attemptGeneration)
    [[ "$(diagnostic_field "$forwarding_line" deviceGeneration)" \
          == "$device_generation" \
        && "$(diagnostic_field "$forwarding_line" peerGeneration)" \
          == "$selection_peer" ]] \
      || fail "primary microphone quiescent identity disagrees with routing selection at ${prefix}"
    pcm_generation=0
    bound_dec_generation=0
    dec_generation=0
    callbacks=0
    frames=0
    pcm_windows=0
    dec_calls=0
    dec_frames=0
    media_sample=$(diagnostic_field "$forwarding_line" mediaSample)
    if [[ "$prefix" == before ]]; then
      PRIMARY_MIC_BASELINE_MODE=$microphone_mode
      PRIMARY_CONTINUITY_ASSURANCE=exactAttemptBound
      PRIMARY_MIC_FORWARDING_PHASE=$forwarding_phase
      PRIMARY_MIC_ROUTING_EPOCH=$routing_epoch
      PRIMARY_MIC_DEVICE_GENERATION=$device_generation
      PRIMARY_MIC_PCM_GENERATION=$pcm_generation
      PRIMARY_MIC_BOUND_DEC_GENERATION=$bound_dec_generation
      PRIMARY_MIC_DEC_GENERATION=$dec_generation
      PRIMARY_MIC_MONITOR_EPOCH=$monitor_epoch
      PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH=$transport_epoch
      PRIMARY_MIC_TRACK_GENERATION=$track_generation
      PRIMARY_MIC_ATTEMPT_GENERATION=$attempt_generation
      PRIMARY_MIC_CALLBACKS_BEFORE=$callbacks
      PRIMARY_MIC_FRAMES_BEFORE=$frames
      PRIMARY_MIC_PCM_WINDOWS_BEFORE=$pcm_windows
      PRIMARY_MIC_DEC_CALLS_BEFORE=$dec_calls
      PRIMARY_MIC_DEC_FRAMES_BEFORE=$dec_frames
      PRIMARY_MIC_MEDIA_SAMPLE_BEFORE=$media_sample
    elif [[ "$prefix" == premint ]]; then
      [[ "$PRIMARY_MIC_BASELINE_MODE" == "$microphone_mode" \
          && "$PRIMARY_MIC_FORWARDING_PHASE" == "$forwarding_phase" \
          && "$routing_epoch" == "$PRIMARY_MIC_ROUTING_EPOCH" \
          && "$device_generation" == "$PRIMARY_MIC_DEVICE_GENERATION" \
          && "$pcm_generation" == "$PRIMARY_MIC_PCM_GENERATION" \
          && "$bound_dec_generation" == "$PRIMARY_MIC_BOUND_DEC_GENERATION" \
          && "$dec_generation" == "$PRIMARY_MIC_DEC_GENERATION" \
          && "$monitor_epoch" == "$PRIMARY_MIC_MONITOR_EPOCH" \
          && "$transport_epoch" == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
          && "$track_generation" == "$PRIMARY_MIC_TRACK_GENERATION" \
          && "$attempt_generation" == "$PRIMARY_MIC_ATTEMPT_GENERATION" \
          && "$callbacks" == "$PRIMARY_MIC_CALLBACKS_BEFORE" \
          && "$frames" == "$PRIMARY_MIC_FRAMES_BEFORE" \
          && "$pcm_windows" == "$PRIMARY_MIC_PCM_WINDOWS_BEFORE" \
          && "$dec_calls" == "$PRIMARY_MIC_DEC_CALLS_BEFORE" \
          && "$dec_frames" == "$PRIMARY_MIC_DEC_FRAMES_BEFORE" \
          && "$media_sample" -gt "$PRIMARY_MIC_MEDIA_SAMPLE_BEFORE" ]] \
        || fail 'primary microphone quiescent baseline changed during development validation'
      PRIMARY_MIC_CALLBACKS_PREMINT=$callbacks
      PRIMARY_MIC_FRAMES_PREMINT=$frames
      PRIMARY_MIC_PCM_WINDOWS_PREMINT=$pcm_windows
      PRIMARY_MIC_DEC_CALLS_PREMINT=$dec_calls
      PRIMARY_MIC_DEC_FRAMES_PREMINT=$dec_frames
      PRIMARY_MIC_MEDIA_SAMPLE_PREMINT=$media_sample
    elif [[ "$prefix" == after ]]; then
      [[ "$PRIMARY_MIC_BASELINE_MODE" == "$microphone_mode" \
          && "$PRIMARY_MIC_FORWARDING_PHASE" == "$forwarding_phase" \
          && "$routing_epoch" == "$PRIMARY_MIC_ROUTING_EPOCH" \
          && "$device_generation" == "$PRIMARY_MIC_DEVICE_GENERATION" \
          && "$monitor_epoch" == "$PRIMARY_MIC_MONITOR_EPOCH" \
          && "$transport_epoch" == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
          && "$track_generation" == "$PRIMARY_MIC_TRACK_GENERATION" \
          && "$attempt_generation" == "$PRIMARY_MIC_ATTEMPT_GENERATION" \
          && "$callbacks" == "$PRIMARY_MIC_CALLBACKS_PREMINT" \
          && "$frames" == "$PRIMARY_MIC_FRAMES_PREMINT" \
          && "$pcm_windows" == "$PRIMARY_MIC_PCM_WINDOWS_PREMINT" \
          && "$dec_calls" == "$PRIMARY_MIC_DEC_CALLS_PREMINT" \
          && "$dec_frames" == "$PRIMARY_MIC_DEC_FRAMES_PREMINT" \
          && "$media_sample" -gt "$PRIMARY_MIC_MEDIA_SAMPLE_PREMINT" ]] \
        || fail 'primary microphone quiescent identity changed after invitation mint'
      PRIMARY_MIC_CALLBACKS_AFTER=$callbacks
      PRIMARY_MIC_FRAMES_AFTER=$frames
      PRIMARY_MIC_PCM_WINDOWS_AFTER=$pcm_windows
      PRIMARY_MIC_DEC_CALLS_AFTER=$dec_calls
      PRIMARY_MIC_DEC_FRAMES_AFTER=$dec_frames
      PRIMARY_MIC_MEDIA_SAMPLE_AFTER=$media_sample
    else
      fail "unsupported primary microphone continuity phase: ${prefix}"
    fi
    jq -n --arg mode "$microphone_mode" --arg phase "$forwarding_phase" \
      --arg routingEpoch "$routing_epoch" \
      --arg peerGeneration "$selection_peer" \
      --arg deviceGeneration "$device_generation" \
      --arg monitorEpoch "$monitor_epoch" \
      --arg transportAuthorizationEpoch "$transport_epoch" \
      --arg trackGeneration "$track_generation" \
      --arg attemptGeneration "$attempt_generation" \
      --arg mediaSample "$media_sample" \
      '{mode:$mode,phase:$phase,routingEpoch:$routingEpoch,
        peerGeneration:$peerGeneration,deviceGeneration:$deviceGeneration,
        monitorEpoch:$monitorEpoch,
        transportAuthorizationEpoch:$transportAuthorizationEpoch,
        trackGeneration:$trackGeneration,attemptGeneration:$attemptGeneration,
        mediaSample:$mediaSample,
        appActive:false,transport:true,trackAdmitted:false,queueRunning:false,
        callbacks:"0",frames:"0",pcmWindows:"0",decodedCalls:"0",
        decodedFrames:"0"}' \
      > "${ARTIFACT_DIR}/${prefix}-primary-microphone-continuity.json"
    return
  fi
  [[ "$forwarding_phase" == forwardingHealthy ]] \
    || fail "primary microphone forwarding phase is unsupported at ${prefix}"
  microphone_mode=forwardingHealthy
  primary_microphone_forwarding_is_exact "$forwarding_line" \
    || fail "primary microphone forwarding proof is malformed at ${prefix}"
  monitor_epoch=$(diagnostic_field "$forwarding_line" monitorEpoch)
  transport_epoch=$(diagnostic_field \
    "$forwarding_line" transportAuthorizationEpoch)
  track_generation=$(diagnostic_field "$forwarding_line" trackGeneration)
  attempt_generation=$(diagnostic_field "$forwarding_line" attemptGeneration)
  [[ "$(diagnostic_field "$forwarding_line" deviceGeneration)" \
        == "$device_generation" \
      && "$(diagnostic_field "$forwarding_line" peerGeneration)" \
        == "$selection_peer" ]] \
    || fail "primary microphone forwarding identity disagrees with routing selection at ${prefix}"
  for required_key in inputEndpointAvailable hiddenSinkAvailable \
      hiddenWriterSelectionProven transport trackAdmitted queueRunning \
      decLatestExact decHasWindow mediaFresh; do
    required_value=$(diagnostic_field "$forwarding_line" "$required_key") \
      || fail "primary microphone ${required_key} is unavailable at ${prefix}"
    [[ "$required_value" == true ]] \
      || fail "primary microphone ${required_key} is not true at ${prefix}"
  done
  [[ "$(diagnostic_field "$forwarding_line" silenceFallbacks)" == 0 \
      && "$(diagnostic_field "$forwarding_line" enqueueFailures)" == 0 \
      && "$(diagnostic_field "$forwarding_line" decNativeFailure)" == 0 \
      && "$(diagnostic_field "$forwarding_line" decDropped)" == 0 \
      && "$(diagnostic_field "$forwarding_line" decContractMismatch)" == 0 \
      && "$(diagnostic_field "$forwarding_line" decLatestStatus)" == 0 ]] \
    || fail "primary microphone forwarding reported a transport or render failure at ${prefix}"

  pcm_generation=$(diagnostic_field "$forwarding_line" pcmLifecycleGeneration) \
    || fail "primary microphone PCM generation is unavailable at ${prefix}"
  bound_dec_generation=$(diagnostic_field "$forwarding_line" boundDecGeneration) \
    || fail "primary microphone bound decoded generation is unavailable at ${prefix}"
  dec_generation=$(diagnostic_field "$forwarding_line" decGeneration) \
    || fail "primary microphone decoded generation is unavailable at ${prefix}"
  callbacks=$(diagnostic_field "$forwarding_line" callbacks) \
    || fail "primary microphone callback count is unavailable at ${prefix}"
  frames=$(diagnostic_field "$forwarding_line" frames) \
    || fail "primary microphone frame count is unavailable at ${prefix}"
  pcm_windows=$(diagnostic_field "$forwarding_line" pcmWindowSequence) \
    || fail "primary microphone PCM window sequence is unavailable at ${prefix}"
  dec_calls=$(diagnostic_field "$forwarding_line" decCalls) \
    || fail "primary microphone decoded call count is unavailable at ${prefix}"
  dec_frames=$(diagnostic_field "$forwarding_line" decAnalyzedFrames) \
    || fail "primary microphone decoded frame count is unavailable at ${prefix}"
  media_sample=$(diagnostic_field "$forwarding_line" mediaSample) \
    || fail "primary microphone media sample is unavailable at ${prefix}"
  for required_value in "$pcm_generation" "$bound_dec_generation" \
      "$dec_generation" "$callbacks" "$frames" "$pcm_windows" "$dec_calls" \
      "$dec_frames" "$media_sample"; do
    require_unsigned_diagnostic_field "$required_value" \
      "primary microphone progress counter at ${prefix}"
  done
  (( pcm_generation > 0 && bound_dec_generation > 0 && dec_generation > 0 \
      && callbacks > 0 && frames > 0 && pcm_windows > 0 && dec_calls > 0 \
      && dec_frames > 0 && media_sample > 0 )) \
    || fail "primary microphone progress has not started at ${prefix}"

  if [[ "$prefix" == before ]]; then
    PRIMARY_MIC_BASELINE_MODE=$microphone_mode
    PRIMARY_CONTINUITY_ASSURANCE=exactAttemptBound
    PRIMARY_MIC_FORWARDING_PHASE=$forwarding_phase
    PRIMARY_MIC_ROUTING_EPOCH=$routing_epoch
    PRIMARY_MIC_DEVICE_GENERATION=$device_generation
    PRIMARY_MIC_PCM_GENERATION=$pcm_generation
    PRIMARY_MIC_BOUND_DEC_GENERATION=$bound_dec_generation
    PRIMARY_MIC_DEC_GENERATION=$dec_generation
    PRIMARY_MIC_MONITOR_EPOCH=$monitor_epoch
    PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH=$transport_epoch
    PRIMARY_MIC_TRACK_GENERATION=$track_generation
    PRIMARY_MIC_ATTEMPT_GENERATION=$attempt_generation
    PRIMARY_MIC_CALLBACKS_BEFORE=$callbacks
    PRIMARY_MIC_FRAMES_BEFORE=$frames
    PRIMARY_MIC_PCM_WINDOWS_BEFORE=$pcm_windows
    PRIMARY_MIC_DEC_CALLS_BEFORE=$dec_calls
    PRIMARY_MIC_DEC_FRAMES_BEFORE=$dec_frames
    PRIMARY_MIC_MEDIA_SAMPLE_BEFORE=$media_sample
  elif [[ "$prefix" == premint ]]; then
    [[ "$PRIMARY_MIC_BASELINE_MODE" == "$microphone_mode" \
        && "$PRIMARY_MIC_FORWARDING_PHASE" == "$forwarding_phase" \
        && "$routing_epoch" == "$PRIMARY_MIC_ROUTING_EPOCH" \
        && "$device_generation" == "$PRIMARY_MIC_DEVICE_GENERATION" \
        && "$pcm_generation" == "$PRIMARY_MIC_PCM_GENERATION" \
        && "$bound_dec_generation" == "$PRIMARY_MIC_BOUND_DEC_GENERATION" \
        && "$dec_generation" == "$PRIMARY_MIC_DEC_GENERATION" \
        && "$monitor_epoch" == "$PRIMARY_MIC_MONITOR_EPOCH" \
        && "$transport_epoch" == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
        && "$track_generation" == "$PRIMARY_MIC_TRACK_GENERATION" \
        && "$attempt_generation" == "$PRIMARY_MIC_ATTEMPT_GENERATION" ]] \
      || fail 'primary microphone exact forwarding attempt identity changed'
    (( callbacks > PRIMARY_MIC_CALLBACKS_BEFORE \
        && frames > PRIMARY_MIC_FRAMES_BEFORE \
        && pcm_windows > PRIMARY_MIC_PCM_WINDOWS_BEFORE \
        && dec_calls > PRIMARY_MIC_DEC_CALLS_BEFORE \
        && dec_frames > PRIMARY_MIC_DEC_FRAMES_BEFORE \
        && media_sample > PRIMARY_MIC_MEDIA_SAMPLE_BEFORE )) \
      || fail 'primary microphone forwarding counters stalled during development validation'
    PRIMARY_MIC_CALLBACKS_PREMINT=$callbacks
    PRIMARY_MIC_FRAMES_PREMINT=$frames
    PRIMARY_MIC_PCM_WINDOWS_PREMINT=$pcm_windows
    PRIMARY_MIC_DEC_CALLS_PREMINT=$dec_calls
    PRIMARY_MIC_DEC_FRAMES_PREMINT=$dec_frames
    PRIMARY_MIC_MEDIA_SAMPLE_PREMINT=$media_sample
  elif [[ "$prefix" == after ]]; then
    [[ "$PRIMARY_MIC_BASELINE_MODE" == "$microphone_mode" \
        && "$PRIMARY_MIC_FORWARDING_PHASE" == "$forwarding_phase" \
        && "$routing_epoch" == "$PRIMARY_MIC_ROUTING_EPOCH" \
        && "$device_generation" == "$PRIMARY_MIC_DEVICE_GENERATION" \
        && "$pcm_generation" == "$PRIMARY_MIC_PCM_GENERATION" \
        && "$bound_dec_generation" == "$PRIMARY_MIC_BOUND_DEC_GENERATION" \
        && "$dec_generation" == "$PRIMARY_MIC_DEC_GENERATION" \
        && "$monitor_epoch" == "$PRIMARY_MIC_MONITOR_EPOCH" \
        && "$transport_epoch" == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
        && "$track_generation" == "$PRIMARY_MIC_TRACK_GENERATION" \
        && "$attempt_generation" == "$PRIMARY_MIC_ATTEMPT_GENERATION" ]] \
      || fail 'primary microphone exact forwarding attempt identity changed'
    (( callbacks > PRIMARY_MIC_CALLBACKS_PREMINT \
        && frames > PRIMARY_MIC_FRAMES_PREMINT \
        && pcm_windows > PRIMARY_MIC_PCM_WINDOWS_PREMINT \
        && dec_calls > PRIMARY_MIC_DEC_CALLS_PREMINT \
        && dec_frames > PRIMARY_MIC_DEC_FRAMES_PREMINT \
        && media_sample > PRIMARY_MIC_MEDIA_SAMPLE_PREMINT )) \
      || fail 'primary microphone forwarding counters did not advance after invitation mint'
    PRIMARY_MIC_CALLBACKS_AFTER=$callbacks
    PRIMARY_MIC_FRAMES_AFTER=$frames
    PRIMARY_MIC_PCM_WINDOWS_AFTER=$pcm_windows
    PRIMARY_MIC_DEC_CALLS_AFTER=$dec_calls
    PRIMARY_MIC_DEC_FRAMES_AFTER=$dec_frames
    PRIMARY_MIC_MEDIA_SAMPLE_AFTER=$media_sample
  else
    fail "unsupported primary microphone continuity phase: ${prefix}"
  fi

  jq -n --arg mode "$microphone_mode" --arg phase "$forwarding_phase" \
    --arg routingEpoch "$routing_epoch" \
    --arg peerGeneration "$selection_peer" \
    --arg deviceGeneration "$device_generation" \
    --arg monitorEpoch "$monitor_epoch" \
    --arg transportAuthorizationEpoch "$transport_epoch" \
    --arg trackGeneration "$track_generation" \
    --arg attemptGeneration "$attempt_generation" \
    --arg pcmGeneration "$pcm_generation" \
    --arg decodedGeneration "$dec_generation" \
    --arg callbacks "$callbacks" --arg frames "$frames" \
    --arg pcmWindows "$pcm_windows" --arg decodedCalls "$dec_calls" \
    --arg decodedFrames "$dec_frames" --arg mediaSample "$media_sample" \
    '{mode:$mode,phase:$phase,routingEpoch:$routingEpoch,
      peerGeneration:$peerGeneration,deviceGeneration:$deviceGeneration,
      monitorEpoch:$monitorEpoch,
      transportAuthorizationEpoch:$transportAuthorizationEpoch,
      trackGeneration:$trackGeneration,attemptGeneration:$attemptGeneration,
      pcmGeneration:$pcmGeneration,decodedGeneration:$decodedGeneration,
      callbacks:$callbacks,frames:$frames,pcmWindows:$pcmWindows,
      decodedCalls:$decodedCalls,decodedFrames:$decodedFrames,
      mediaSample:$mediaSample}' \
    > "${ARTIFACT_DIR}/${prefix}-primary-microphone-continuity.json"
}

function primary_audio_line_matches_baseline() {
  local line=$1
  local build_value session_value peer_generation negotiation_epoch app_active
  [[ "$line" == *"Worldwide audio client diagnostics pid=${HOST_PID} "* ]] \
    || return 1
  build_value=$(diagnostic_field "$line" build 2>/dev/null) || return 1
  session_value=$(diagnostic_field "$line" session 2>/dev/null) || return 1
  peer_generation=$(diagnostic_field "$line" peerGeneration 2>/dev/null) \
    || return 1
  negotiation_epoch=$(diagnostic_field "$line" negotiationEpoch 2>/dev/null) \
    || return 1
  app_active=$(diagnostic_field "$line" appActive 2>/dev/null) || return 1
  [[ "$build_value" == *"(${EXPECTED_PRIMARY_BUILD})" \
      && "${session_value:l}" == "$PRIMARY_SESSION_ID" \
      && "$peer_generation" == "$PRIMARY_PEER_GENERATION" \
      && "$negotiation_epoch" == "$PRIMARY_NEGOTIATION_EPOCH" \
      && "$app_active" == "$PRIMARY_AUDIO_APP_ACTIVE" ]]
}

function primary_selection_line_matches_baseline() {
  local line=$1
  [[ "$(diagnostic_field "$line" routingEpoch 2>/dev/null || true)" \
        == "$PRIMARY_MIC_ROUTING_EPOCH" \
      && "$(diagnostic_field "$line" peerGeneration 2>/dev/null || true)" \
        == "$PRIMARY_PEER_GENERATION" \
      && "$(diagnostic_field "$line" deviceGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_DEVICE_GENERATION" \
      && "$(diagnostic_field "$line" pid 2>/dev/null || true)" \
        == "$HOST_PID" ]]
}

function primary_forwarding_identity_matches_baseline() {
  local line=$1
  [[ "$(diagnostic_field "$line" monitorEpoch 2>/dev/null || true)" \
        == "$PRIMARY_MIC_MONITOR_EPOCH" \
      && "$(diagnostic_field "$line" deviceGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_DEVICE_GENERATION" \
      && "$(diagnostic_field "$line" peerGeneration 2>/dev/null || true)" \
        == "$PRIMARY_PEER_GENERATION" \
      && "$(diagnostic_field "$line" transportAuthorizationEpoch 2>/dev/null || true)" \
        == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
      && "$(diagnostic_field "$line" trackGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_TRACK_GENERATION" \
      && "$(diagnostic_field "$line" attemptGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_ATTEMPT_GENERATION" \
      && "$(diagnostic_field "$line" lastAttemptedKeyMatchesSnapshot 2>/dev/null || true)" \
        == true ]]
}

function primary_quiescent_identity_matches_baseline() {
  local line=$1
  [[ "$(diagnostic_field "$line" monitorEpoch 2>/dev/null || true)" \
        == "$PRIMARY_MIC_MONITOR_EPOCH" \
      && "$(diagnostic_field "$line" deviceGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_DEVICE_GENERATION" \
      && "$(diagnostic_field "$line" peerGeneration 2>/dev/null || true)" \
        == "$PRIMARY_PEER_GENERATION" \
      && "$(diagnostic_field "$line" transportAuthorizationEpoch 2>/dev/null || true)" \
        == "$PRIMARY_MIC_TRANSPORT_AUTHORIZATION_EPOCH" \
      && "$(diagnostic_field "$line" trackGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_TRACK_GENERATION" \
      && "$(diagnostic_field "$line" attemptGeneration 2>/dev/null || true)" \
        == "$PRIMARY_MIC_ATTEMPT_GENERATION" ]]
}

function inactive_primary_lifecycle_is_terminal() {
  local file=$1
  local disconnect_record audio_record media_record audio_line suffix
  local disconnect_line audio_line_number media_line
  local latest_peer latest_connected latest_viewer_disconnect
  local latest_capture_start latest_capture_stop
  audio_record=$(rg -n \
    "Worldwide audio client diagnostics pid=${HOST_PID} " "$file" \
    | /usr/bin/tail -n 1 || true)
  media_record=$(rg -n 'Worldwide media ended;' "$file" \
    | /usr/bin/tail -n 1 || true)
  [[ -n "$audio_record" && -n "$media_record" ]] \
    || return 1
  audio_line_number=${audio_record%%:*}
  media_line=${media_record%%:*}
  disconnect_record=$(/usr/bin/sed -n "1,$(( audio_line_number - 1 ))p" "$file" \
    | rg -n 'Worldwide viewer disconnected;' | /usr/bin/tail -n 1 || true)
  [[ -n "$disconnect_record" ]] || return 1
  disconnect_line=${disconnect_record%%:*}
  audio_line=${audio_record#*:}
  primary_audio_diagnostic_is_terminal_inactive "$audio_line" || return 1
  (( disconnect_line < audio_line_number && audio_line_number < media_line )) \
    || return 1
  inactive_primary_lifecycle_suffix_is_quiescent "$file" "$media_line"
}

function inactive_primary_lifecycle_suffix_is_quiescent() {
  local file=$1 media_line=$2 suffix
  local latest_peer latest_connected latest_viewer_disconnect
  local latest_capture_start latest_capture_stop
  suffix=$(/usr/bin/sed -n "$(( media_line + 1 )),\$p" "$file")
  if print -r -- "$suffix" | rg -q \
      'Worldwide audio client diagnostics|Worldwide iPhone microphone forwarding|Worldwide iPhone microphone hidden writer selected|Worldwide authenticated media route selected virtual microphone|Worldwide media ended;|A fresh encrypted media rendezvous is ready for the paired iPhone|The paired iPhone left the availability exchange|Worldwide screen host is waiting for the paired iPhone media session|Fresh paired media rendezvous expires in about|Loaded the paired iPhone and started worldwide availability'; then
    return 1
  fi
  print -r -- "$suffix" | inactive_primary_online_announcements_are_exact || return 1
  latest_peer=$(print -r -- "$suffix" \
    | rg -n 'Worldwide WebRTC peer state:' | /usr/bin/tail -n 1 || true)
  latest_connected=$(print -r -- "$suffix" \
    | rg -n 'Worldwide WebRTC peer state: connected ' | /usr/bin/tail -n 1 || true)
  latest_viewer_disconnect=$(print -r -- "$suffix" \
    | rg -n 'Worldwide viewer disconnected;' | /usr/bin/tail -n 1 || true)
  latest_capture_start=$(print -r -- "$suffix" \
    | rg -n 'Starting screen video capture' | /usr/bin/tail -n 1 || true)
  latest_capture_stop=$(print -r -- "$suffix" \
    | rg -n 'Stopping screen video capture' | /usr/bin/tail -n 1 || true)
  if [[ -n "$latest_peer" ]]; then
    [[ -n "$latest_viewer_disconnect" \
        && "${latest_peer%%:*}" -lt "${latest_viewer_disconnect%%:*}" ]] \
      || return 1
  fi
  if [[ -n "$latest_connected" ]]; then
    [[ -n "$latest_viewer_disconnect" \
        && "${latest_connected%%:*}" -lt "${latest_viewer_disconnect%%:*}" ]] \
      || return 1
  fi
  if [[ -n "$latest_capture_start" ]]; then
    [[ -n "$latest_capture_stop" \
        && "${latest_capture_start%%:*}" -lt "${latest_capture_stop%%:*}" ]] \
      || return 1
  fi
  return 0
}

function inactive_primary_online_announcements_are_exact() {
  # Availability reconnections can reannounce the same immutable host identity after media
  # completion. They prove identity only, not inactivity; callers retain all lifecycle fences.
  /usr/bin/awk -v pid="${HOST_PID:-}" -v generation="${HOST_GENERATION:-}" '
    /Worldwide paired-device availability is online/ {
      sub(/^\[[a-z]+\] /, "")
      expected = "Worldwide paired-device availability is online pid=" pid " nonce=" generation
      if (pid !~ /^[1-9][0-9]*$/ || generation !~ /^[0-9a-f]+$/ ||
          length(generation) != 64 || $0 != expected) bad = 1
    }
    END { exit bad }
  '
}

function stopped_audio_report_directory_identity() {
  local directory_path identity='' acl scan_status
  for directory_path in "${HOST_AUDIO_CLIENT_REPORT:h:h:h}" \
      "${HOST_AUDIO_CLIENT_REPORT:h:h}" "${HOST_AUDIO_CLIENT_REPORT:h}"; do
    [[ -d "$directory_path" && ! -L "$directory_path" && "${directory_path:A}" == "$directory_path" \
        && "$(/usr/bin/stat -f '%u:%Lp' "$directory_path")" == "${UID}:700" ]] \
      || return 1
    acl=$(/bin/ls -lde "$directory_path") || return 1
    scan_status=0
    print -r -- "$acl" | rg -q '^[[:space:]]*[0-9]+:.* allow ' || scan_status=$?
    (( scan_status == 1 )) || return 1
    identity+="$(/usr/bin/stat -f '%d:%i:%u:%Lp' "$directory_path")|" || return 1
  done
  print -rn -- "$identity"
}

function stopped_audio_report_descriptor_identity() {
  local -A descriptor_stat
  zstat -H descriptor_stat -f "$1" || return 1
  (( (descriptor_stat[mode] & 8#170000) == 8#100000 )) || return 1
  printf 'Regular File|%d|%o|%d|%d|%d|%d|%d|%d' \
    "$descriptor_stat[uid]" "$(( descriptor_stat[mode] & 8#7777 ))" \
    "$descriptor_stat[nlink]" "$descriptor_stat[size]" "$descriptor_stat[device]" \
    "$descriptor_stat[inode]" "$descriptor_stat[mtime]" "$descriptor_stat[ctime]"
}

function read_private_stopped_audio_report() {
  local output=$1 identity directories descriptor descriptor_identity ok=0 acl scan_status=0
  local -a fields
  directories=$(stopped_audio_report_directory_identity) || return 1
  [[ -f "$HOST_AUDIO_CLIENT_REPORT" && ! -L "$HOST_AUDIO_CLIENT_REPORT" \
      && "${HOST_AUDIO_CLIENT_REPORT:A}" == "$HOST_AUDIO_CLIENT_REPORT" ]] || return 1
  identity=$(/usr/bin/stat -f '%HT|%u|%Lp|%l|%z|%d|%i|%m|%c' \
    "$HOST_AUDIO_CLIENT_REPORT") || return 1
  fields=("${(@s:|:)identity}")
  [[ ${#fields[@]} == 9 && "${fields[1]}" == 'Regular File' \
      && "${fields[2]}:${fields[3]}:${fields[4]}" == "${UID}:600:1" \
      && "${fields[5]}" -gt 0 && "${fields[5]}" -le 32768 ]] || return 1
  acl=$(/bin/ls -lde "$HOST_AUDIO_CLIENT_REPORT") || return 1
  print -r -- "$acl" | rg -q '^[[:space:]]*[0-9]+:.* allow ' || scan_status=$?
  (( scan_status == 1 )) || return 1
  zmodload zsh/system || return 1
  zmodload zsh/stat || return 1
  sysopen -r -o nofollow,nonblock,cloexec -u descriptor "$HOST_AUDIO_CLIENT_REPORT" || return 1
  descriptor_identity=$(stopped_audio_report_descriptor_identity "$descriptor") || descriptor_identity=''
  if [[ "$descriptor_identity" == "$identity" ]] \
      && /usr/bin/head -c 32769 <&$descriptor > "$output" \
      && [[ "$(/usr/bin/stat -f '%z' "$output")" == "${fields[5]}" \
        && "$(stopped_audio_report_descriptor_identity "$descriptor")" == "$identity" \
        && ! -L "$HOST_AUDIO_CLIENT_REPORT" \
        && "$(/usr/bin/stat -f '%HT|%u|%Lp|%l|%z|%d|%i|%m|%c' "$HOST_AUDIO_CLIENT_REPORT")" == "$identity" \
        && "$(stopped_audio_report_directory_identity)" == "$directories" ]]; then
    ok=1
  fi
  exec {descriptor}<&- || return 1
  (( ok )) || return 1
  STOPPED_REPORT_READ_IDENTITY=$identity
  STOPPED_REPORT_READ_DIRECTORIES=$directories
}

function stopped_audio_report_matches_logged_identity() {
  local report=$1 line=$2 session build peer epoch sequence app_active
  [[ "$line" == *"Worldwide audio client diagnostics pid=${HOST_PID} "* \
      && "${PRIMARY_STOPPED_REPORT_HOST_START:-}" =~ '^[1-9][0-9]*$' ]] || return 1
  session=$(diagnostic_field "$line" session) || return 1
  build=$(diagnostic_field "$line" build) || return 1
  peer=$(diagnostic_field "$line" peerGeneration) || return 1
  epoch=$(diagnostic_field "$line" negotiationEpoch) || return 1
  sequence=$(diagnostic_field "$line" sequence) || return 1
  app_active=$(diagnostic_field "$line" appActive) || return 1
  [[ "$session" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' \
      && "$peer" =~ '^[1-9][0-9]*$' && "$epoch" =~ '^[1-9][0-9]*$' \
      && "$sequence" =~ '^[1-9][0-9]*$' && "$app_active" == false \
      && "$build" == *"(${EXPECTED_PRIMARY_BUILD})" ]] || return 1
  # The interpreter bytes are pinned at runner startup. Reject duplicate objects as well as
  # duplicate leaves; jq alone would silently accept a second disjoint heartbeat container.
  "$IPHONE_CONTROL_PYTHON" -I -S -B - "$report" "$HOST_PID" "${session:l}" "$build" \
    "$peer" "$epoch" "$sequence" "$PRIMARY_STOPPED_REPORT_HOST_START" <<'PY'
import json
import sys
import time

def exact_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value

def require(condition):
    if not condition:
        raise ValueError("invalid stopped report")

def integer(value, minimum=1):
    return type(value) is int and value >= minimum

try:
    report, pid, session, build, peer, epoch, sequence, host_start = sys.argv[1:]
    with open(report, "rb") as source:
        value = json.load(source, object_pairs_hook=exact_object,
                          parse_constant=lambda _: require(False))
    require(type(value) is dict and set(value) == {
        "schemaVersion", "kind", "hostPID", "generatedAtUnixMilliseconds",
        "receivedAtUnixMilliseconds", "freshUntilUnixMilliseconds", "status",
        "acousticAudibility", "peerGeneration", "negotiationEpoch", "heartbeat"})
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    require(value["kind"] == "opensteamer.audio-client.v1")
    require(value["status"] == "unavailable.stopped" and value["acousticAudibility"] == "unverified")
    for key, expected in (("hostPID", pid), ("peerGeneration", peer), ("negotiationEpoch", epoch)):
        require(integer(value[key]) and value[key] == int(expected))
    generated, received, fresh_until = (value[key] for key in (
        "generatedAtUnixMilliseconds", "receivedAtUnixMilliseconds", "freshUntilUnixMilliseconds"))
    require(all(integer(item) for item in (generated, received, fresh_until)))
    require(int(host_start) * 1000 <= received <= generated <= time.time_ns() // 1_000_000)
    # freshUntil describes retained-heartbeat freshness, not a terminal-record expiry.
    require(fresh_until >= received)
    heartbeat = value["heartbeat"]
    require(type(heartbeat) is dict and type(heartbeat["i"]) is str)
    require(heartbeat["i"].lower() == session and integer(heartbeat["s"]) and heartbeat["s"] == int(sequence))
    require(type(heartbeat["n"]) is dict and heartbeat["n"]["l"] is False)
    version = heartbeat["b"]
    require(type(version) is dict and set(version) == {"a", "b", "c", "d"})
    require(all(integer(item, 0) for item in version.values()))
    require(f'{version["a"]}.{version["b"]}.{version["c"]}({version["d"]})' == build)
except (OSError, ValueError, TypeError, KeyError, RecursionError):
    sys.exit(1)
PY
}

function inactive_primary_report_lifecycle_is_terminal() {
  local file=$1 audio_record media_record audio_line_number media_line
  audio_record=$(rg -n "Worldwide audio client diagnostics pid=${HOST_PID} " "$file" \
    | /usr/bin/tail -n 1 || true)
  media_record=$(rg -n 'Worldwide media ended;' "$file" | /usr/bin/tail -n 1 || true)
  [[ -n "$audio_record" && -n "$media_record" ]] || return 1
  audio_line_number=${audio_record%%:*}
  media_line=${media_record%%:*}
  (( audio_line_number < media_line )) || return 1
  /usr/bin/sed -n "$(( media_line + 1 )),\$p" "$file" \
    | rg -q 'Worldwide availability is waiting for the paired iPhone' || return 1
  inactive_primary_lifecycle_suffix_is_quiescent "$file" "$media_line" || return 1
  # No newer primary session may borrow the older report while its first diagnostic is pending.
  if /usr/bin/sed -n "$(( audio_line_number + 1 )),${media_line}p" "$file" | rg -q \
      'Worldwide audio client diagnostics|A fresh encrypted media rendezvous is ready for the paired iPhone|Worldwide screen host is waiting for the paired iPhone media session|Fresh paired media rendezvous expires in about|Loaded the paired iPhone and started worldwide availability'; then
    return 1
  fi
  /usr/bin/sed -n "$(( audio_line_number + 1 )),${media_line}p" "$file" \
    | inactive_primary_online_announcements_are_exact || return 1
  return 0
}

function stopped_report_current_host_start() {
  local started
  started=$(LC_ALL=C ps -ww -p "$HOST_PID" -o lstart=) || return 1
  LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$started" '+%s' 2>/dev/null
}

function capture_inactive_primary_stopped_report() {
  local file=$1 line report="${ARTIFACT_DIR}/before-primary-stopped-report.json"
  inactive_primary_report_lifecycle_is_terminal "$file" || return 1
  PRIMARY_STOPPED_REPORT_HOST_START=$(stopped_report_current_host_start) || return 1
  line=$(rg "Worldwide audio client diagnostics pid=${HOST_PID} " "$file" \
    | /usr/bin/tail -n 1) || return 1
  read_private_stopped_audio_report "$report" || return 1
  stopped_audio_report_matches_logged_identity "$report" "$line" || return 1
  PRIMARY_STOPPED_REPORT_IDENTITY=$STOPPED_REPORT_READ_IDENTITY
  PRIMARY_STOPPED_REPORT_DIRECTORIES=$STOPPED_REPORT_READ_DIRECTORIES
  PRIMARY_INACTIVE_EVIDENCE=stoppedReport
}

function recheck_inactive_primary_stopped_report() {
  local prefix=$1 report="${ARTIFACT_DIR}/${1}-primary-stopped-report-readback.json"
  [[ "${PRIMARY_INACTIVE_EVIDENCE:-log}" == stoppedReport ]] || return 0
  capture_host_generation_identity "${prefix}-stopped-report"
  [[ "$(stopped_report_current_host_start)" == "$PRIMARY_STOPPED_REPORT_HOST_START" ]] \
    || fail "Mac host process start changed at ${prefix}"
  read_private_stopped_audio_report "$report" \
    && [[ "$STOPPED_REPORT_READ_IDENTITY" == "$PRIMARY_STOPPED_REPORT_IDENTITY" \
      && "$STOPPED_REPORT_READ_DIRECTORIES" == "$PRIMARY_STOPPED_REPORT_DIRECTORIES" ]] \
    && /usr/bin/cmp -s "$report" "${ARTIFACT_DIR}/before-primary-stopped-report.json" \
    || fail "primary stopped report changed or became unsafe at ${prefix}"
}

function record_inactive_primary_stopped_report_baseline() {
  local report="${ARTIFACT_DIR}/before-primary-stopped-report.json"
  recheck_inactive_primary_stopped_report before
  PRIMARY_BASELINE_MODE=inactivePrimary
  PRIMARY_AUDIO_STATUS=unavailable.stopped
  PRIMARY_SESSION_ID=$(jq -er '.heartbeat.i | ascii_downcase' "$report")
  PRIMARY_PEER_GENERATION=$(jq -er '.peerGeneration' "$report")
  PRIMARY_NEGOTIATION_EPOCH=$(jq -er '.negotiationEpoch' "$report")
  PRIMARY_AUDIO_SEQUENCE_BEFORE=$(jq -er '.heartbeat.s' "$report")
  PRIMARY_AUDIO_APP_ACTIVE=false
  PRIMARY_MIC_BASELINE_MODE=inactivePrimary
  PRIMARY_MIC_FORWARDING_PHASE=inactive
  PRIMARY_CONTINUITY_ASSURANCE=inactivePrimaryNoAudioProof
  jq '{proof:"inactive-terminal-report-and-completed-lifecycle",status,
    session:.heartbeat.i,build:.heartbeat.b,peerGeneration,negotiationEpoch,
    retainedSequence:.heartbeat.s,appActive:false,audioProof:false,microphoneProof:false}' \
    "$report" > "${ARTIFACT_DIR}/before-primary-audio-continuity.json"
  jq -n '{proof:"inactive-terminal-only",mode:"inactivePrimary",phase:"inactive",appActive:false}' \
    > "${ARTIFACT_DIR}/before-primary-microphone-continuity.json"
}

function never_connected_primary_baseline_is_exact() {
  local file=$1
  [[ "${HOST_PID:-}" =~ '^[1-9][0-9]*$' \
      && "${HOST_GENERATION:-}" =~ '^[0-9a-f]{64}$' \
      && "${SECONDARY_MANAGER_GENERATION_BASELINE:-}" =~ '^[0-9]+$' ]] \
    || return 1
  # Startup must be present in the bounded snapshot; a later waiting marker alone could hide
  # a previous primary session outside the tail. The secondary idle probe is established first.
  /usr/bin/awk -v expected="Worldwide paired-device availability is online pid=${HOST_PID} nonce=${HOST_GENERATION}" '
    {
      line = $0
      sub(/^\[[a-z]+\] /, "", line)
      if (line == "Loaded the paired iPhone and started worldwide availability") {
        if (online) overlapping_generation = 1
        started = 1
        waiting = 0
        online = 0
        unsafe = 0
        next
      }
      if (!started) next
      if (line == "Worldwide availability is waiting for the paired iPhone") {
        waiting = 1
      } else if (index(line, "Worldwide paired-device availability is online ") == 1) {
        if (line != expected || !waiting) unsafe = 1
        else online = 1
      }
      if (line ~ /Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture|Worldwide viewer disconnected;|Worldwide media ended;|Worldwide audio client diagnostics|Worldwide iPhone microphone forwarding|Worldwide iPhone microphone hidden writer selected|Worldwide authenticated media route selected|A fresh encrypted media rendezvous is ready for the paired iPhone|The paired iPhone left the availability exchange|Worldwide screen host is waiting for the paired iPhone media session|Fresh paired media rendezvous expires in about|peerConnected=true|controlOpen=true/) {
        unsafe = 1
      }
    }
    END { exit !(started && waiting && online && !unsafe && !overlapping_generation) }
  ' "$file"
}

function record_never_connected_primary_baseline() {
  local file=$1
  never_connected_primary_baseline_is_exact "$file" \
    || fail 'fresh host generation does not prove a never-connected primary baseline'
  PRIMARY_BASELINE_MODE=neverConnectedPrimary
  PRIMARY_MIC_BASELINE_MODE=neverConnectedPrimary
  PRIMARY_AUDIO_STATUS=notObserved
  PRIMARY_MIC_FORWARDING_PHASE=notObserved
  PRIMARY_CONTINUITY_ASSURANCE=neverConnectedPrimaryNoAudioProof
  jq -n --arg pid "$HOST_PID" --arg generation "$HOST_GENERATION" \
    --arg managerGeneration "$SECONDARY_MANAGER_GENERATION_BASELINE" \
    '{proof:"no-primary-since-host-generation-start",hostPid:($pid | tonumber),
      hostGeneration:$generation,secondaryManagerGeneration:$managerGeneration,
      session:null,build:null,peerGeneration:null,negotiationEpoch:null,
      audioProof:false,microphoneProof:false}' \
    > "${ARTIFACT_DIR}/before-never-connected-primary-continuity.json"
}

function write_host_baseline_snapshot() {
  local output=$1
  local current_size latest_audio latest_forwarding
  local start_offset window_bytes raw="${output}.raw"
  local deadline=$(( SECONDS + 40 ))
  local complete_line_seen=0
  while (( SECONDS < deadline )); do
    [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" \
        && "$(/usr/bin/stat -f '%d' "$HOST_LOG")" == "$HOST_LOG_DEVICE" \
        && "$(/usr/bin/stat -f '%i' "$HOST_LOG")" == "$HOST_LOG_INODE" ]] \
      || fail 'Mac host log identity changed during baseline capture'
    current_size=$(/usr/bin/stat -f '%z' "$HOST_LOG") \
      || fail 'Mac host log size is unavailable during baseline capture'
    [[ "$current_size" != *[^0-9]* && "$current_size" -gt 0 ]] \
      || fail 'Mac host log size is malformed during baseline capture'
    if (( current_size > HOST_BASELINE_TAIL_BYTES )); then
      start_offset=$(( current_size - HOST_BASELINE_TAIL_BYTES + 1 ))
      window_bytes=$HOST_BASELINE_TAIL_BYTES
    else
      start_offset=1
      window_bytes=$current_size
    fi
    ( /usr/bin/tail -c "+${start_offset}" "$HOST_LOG" \
        | /usr/bin/head -c "$window_bytes" ) > "$raw" || true
    if [[ "$(/usr/bin/stat -f '%z' "$raw")" == "$window_bytes" \
        && "$(/usr/bin/tail -c 1 "$raw" | /usr/bin/od -An -tuC \
          | /usr/bin/tr -d '[:space:]')" == 10 ]]; then
      complete_line_seen=1
      if (( start_offset > 1 )); then
        # The bounded byte window can begin in the middle of a log line. Drop
        # that one partial record so every retained diagnostic is parseable.
        /usr/bin/tail -n +2 "$raw" > "$output"
      else
        /bin/cp "$raw" "$output"
      fi
      latest_audio=$(rg "Worldwide audio client diagnostics pid=${HOST_PID} " \
        "$output" | /usr/bin/tail -n 1 || true)
      latest_forwarding=$(rg \
        'Worldwide iPhone microphone forwarding phase=' "$output" \
        | /usr/bin/tail -n 1 || true)
      if [[ -z "$latest_audio" ]] && never_connected_primary_baseline_is_exact "$output"; then
        HOST_LOG_BASE_SIZE=$current_size
        HOST_LOG_CONTINUITY_CURSOR=$current_size
        /bin/rm -f "$raw"
        return
      fi
      if [[ -n "$latest_audio" ]] && { \
          { [[ -n "$latest_forwarding" ]] \
            && primary_audio_diagnostic_is_current_healthy "$latest_audio" \
            && primary_audio_operational_fields_are_exact "$latest_audio"; } \
          || { primary_audio_diagnostic_is_terminal_inactive "$latest_audio" \
            && inactive_primary_lifecycle_is_terminal "$output"; }; \
        }; then
        HOST_LOG_BASE_SIZE=$current_size
        HOST_LOG_CONTINUITY_CURSOR=$current_size
        /bin/rm -f "$raw"
        return
      fi
      if [[ -n "$latest_audio" ]] && capture_inactive_primary_stopped_report "$output"; then
        HOST_LOG_BASE_SIZE=$current_size
        HOST_LOG_CONTINUITY_CURSOR=$current_size
        /bin/rm -f "$raw"
        return
      fi
    fi
    /bin/sleep 0.05
  done
  /bin/rm -f "$raw"
  (( complete_line_seen == 0 )) \
    || fail 'Mac host complete-line baseline did not prove an admissible current primary lifecycle within 40 seconds'
  fail 'Mac host log did not reach a fresh complete-line baseline within 40 seconds'
}

function write_primary_continuity_window() {
  local output=$1
  local attempt current_size window_bytes forwarding_count raw="${output}.raw"
  [[ "$HOST_LOG_CONTINUITY_CURSOR" != *[^0-9]* ]] \
    || fail 'primary continuity cursor is malformed'
  for (( attempt = 0; attempt < 160; attempt++ )); do
    [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" \
        && "$(/usr/bin/stat -f '%d' "$HOST_LOG")" == "$HOST_LOG_DEVICE" \
        && "$(/usr/bin/stat -f '%i' "$HOST_LOG")" == "$HOST_LOG_INODE" ]] \
      || fail 'Mac host log identity changed during primary continuity capture'
    current_size=$(/usr/bin/stat -f '%z' "$HOST_LOG") \
      || fail 'Mac host log size is unavailable during primary continuity capture'
    [[ "$current_size" != *[^0-9]* \
        && "$current_size" -ge "$HOST_LOG_CONTINUITY_CURSOR" ]] \
      || fail 'Mac host log was truncated during primary continuity capture'
    window_bytes=$(( current_size - HOST_LOG_CONTINUITY_CURSOR ))
    if (( window_bytes > 0 )); then
      ( /usr/bin/tail -c "+$(( HOST_LOG_CONTINUITY_CURSOR + 1 ))" "$HOST_LOG" \
          | /usr/bin/head -c "$window_bytes" ) > "$raw" || true
      if [[ "$(/usr/bin/stat -f '%z' "$raw")" == "$window_bytes" \
          && "$(/usr/bin/tail -c 1 "$raw" | /usr/bin/od -An -tuC \
            | /usr/bin/tr -d '[:space:]')" == 10 ]]; then
        rg 'Worldwide audio client diagnostics|Worldwide iPhone microphone hidden writer selected|Worldwide iPhone microphone forwarding phase=' \
          "$raw" > "$output" || true
        forwarding_count=$(rg -c \
          'Worldwide iPhone microphone forwarding phase=' "$output" || true)
        forwarding_count=${forwarding_count:-0}
        if rg -q "Worldwide audio client diagnostics pid=${HOST_PID} " "$output" \
            && (( forwarding_count >= 2 )); then
          HOST_LOG_CONTINUITY_PENDING_CURSOR=$current_size
          /bin/rm -f "$raw"
          return
        fi
      fi
    fi
    /bin/sleep 0.25
  done
  /bin/rm -f "$raw"
  fail 'fresh primary audio and microphone diagnostics did not arrive within 40 seconds'
}

function require_quiescent_baseline_depth() {
  local filtered=$1
  local audio_line=$2
  local previous_sample=0 line sample first_line_number last_line_number
  typeset -a recent_lines
  recent_lines=("${(@f)$(rg 'Worldwide iPhone microphone forwarding phase=' \
    "$filtered" | /usr/bin/tail -n 2)}")
  (( ${#recent_lines[@]} == 2 )) \
    || fail 'primary microphone quiescent baseline lacks two consecutive samples'
  first_line_number=$(rg -n \
    'Worldwide iPhone microphone forwarding phase=' "$filtered" \
    | /usr/bin/tail -n 2 | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
  last_line_number=$(rg -n \
    'Worldwide iPhone microphone forwarding phase=' "$filtered" \
    | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1)
  if /usr/bin/sed -n "${first_line_number},${last_line_number}p" "$filtered" \
      | rg -q 'Worldwide iPhone microphone hidden writer selected'; then
    fail 'primary microphone quiescent baseline includes a hidden-writer transition'
  fi
  for line in "${recent_lines[@]}"; do
    primary_microphone_quiescent_source_is_exact "$audio_line" "$line" \
      || fail 'primary microphone quiescent baseline sample is not exact'
    primary_quiescent_identity_matches_baseline "$line" \
      || fail 'primary microphone quiescent baseline identity is inconsistent'
    sample=$(diagnostic_field "$line" mediaSample)
    if (( previous_sample > 0 )); then
      (( sample > previous_sample )) \
        || fail 'primary microphone quiescent baseline samples did not advance'
    fi
    previous_sample=$sample
  done
}

function require_primary_baseline_window_sticky() {
  local filtered=$1
  local audio_line=$2
  local line sample counter_value previous_sample=0 selection_count=0
  local audio_sequence inbound_packets inbound_bytes callbacks frames nonzero_samples
  local previous_audio_sequence=0 previous_inbound_packets=0 previous_inbound_bytes=0
  local previous_audio_callbacks=0 previous_audio_frames=0 previous_audio_nonzero=0
  if rg 'Worldwide audio client diagnostics' "$filtered" \
      | rg -v "Worldwide audio client diagnostics pid=${HOST_PID} " \
      >/dev/null; then
    fail 'another host PID emitted primary audio diagnostics within before interval'
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    primary_audio_line_matches_baseline "$line" \
      || fail 'primary audio identity changed within before interval'
    primary_audio_diagnostic_is_current_healthy "$line" \
      || fail 'primary audio health became stale or unavailable within before interval'
    primary_audio_operational_fields_are_exact "$line" \
      || fail 'primary audio operational proof changed within before interval'
    audio_sequence=$(diagnostic_field "$line" sequence)
    inbound_packets=$(diagnostic_field "$line" inboundPackets)
    inbound_bytes=$(diagnostic_field "$line" inboundBytes)
    callbacks=$(diagnostic_field "$line" callbacks)
    frames=$(diagnostic_field "$line" frames)
    nonzero_samples=$(diagnostic_field "$line" nonzeroSamples)
    for counter_value in "$audio_sequence" "$inbound_packets" \
        "$inbound_bytes" "$callbacks" "$frames" "$nonzero_samples"; do
      require_unsigned_diagnostic_field "$counter_value" \
        'primary audio progress counter within before interval'
    done
    if (( previous_audio_sequence > 0 )); then
      (( audio_sequence > previous_audio_sequence \
          && inbound_packets > previous_inbound_packets \
          && inbound_bytes > previous_inbound_bytes \
          && callbacks > previous_audio_callbacks \
          && frames > previous_audio_frames \
          && nonzero_samples > previous_audio_nonzero )) \
        || fail 'primary audio counters regressed or stalled within before interval'
    fi
    previous_audio_sequence=$audio_sequence
    previous_inbound_packets=$inbound_packets
    previous_inbound_bytes=$inbound_bytes
    previous_audio_callbacks=$callbacks
    previous_audio_frames=$frames
    previous_audio_nonzero=$nonzero_samples
  done < <(rg "Worldwide audio client diagnostics pid=${HOST_PID} " "$filtered")

  if [[ "$PRIMARY_MIC_BASELINE_MODE" == quiescentInactiveSource ]]; then
    if rg -q 'Worldwide iPhone microphone hidden writer selected' "$filtered"; then
      fail 'primary microphone entered quiescence after a fresh hidden-writer transition'
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_microphone_quiescent_source_is_exact "$audio_line" "$line" \
        || fail 'primary microphone quiescent invariant changed within before interval'
      primary_quiescent_identity_matches_baseline "$line" \
        || fail 'primary microphone quiescent identity changed within before interval'
      sample=$(diagnostic_field "$line" mediaSample)
      if (( previous_sample > 0 )); then
        (( sample > previous_sample )) \
          || fail 'primary microphone quiescent samples did not advance within before interval'
      fi
      previous_sample=$sample
    done < <(rg 'Worldwide iPhone microphone forwarding phase=' "$filtered")
  elif [[ "$PRIMARY_MIC_BASELINE_MODE" == forwardingHealthy ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_selection_line_matches_baseline "$line" \
        || fail 'primary microphone routing selection changed within before interval'
      selection_count=$(( selection_count + 1 ))
    done < <(rg 'Worldwide iPhone microphone hidden writer selected' \
      "$filtered" || true)
    (( selection_count > 0 )) \
      || fail 'primary microphone routing selection was not freshly proven at before'
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_microphone_forwarding_is_exact "$line" \
        || fail 'primary microphone forwarding invariant changed within before interval'
      primary_forwarding_identity_matches_baseline "$line" \
        || fail 'primary microphone forwarding attempt identity changed within before interval'
      sample=$(diagnostic_field "$line" mediaSample)
      if (( previous_sample > 0 )); then
        (( sample > previous_sample )) \
          || fail 'primary microphone media samples did not advance within before interval'
      fi
      previous_sample=$sample
    done < <(rg 'Worldwide iPhone microphone forwarding phase=' "$filtered")
  else
    fail "unsupported primary microphone baseline mode: ${PRIMARY_MIC_BASELINE_MODE}"
  fi
}

function require_primary_interval_sticky() {
  local prefix=$1
  local filtered=$2
  local audio_line=$3
  local line sample counter_value previous_sample selection_count=0
  local audio_sequence inbound_packets inbound_bytes callbacks frames nonzero_samples
  local previous_audio_sequence previous_inbound_packets previous_inbound_bytes
  local previous_audio_callbacks previous_audio_frames previous_audio_nonzero
  if [[ "$prefix" == premint ]]; then
    previous_audio_sequence=$PRIMARY_AUDIO_SEQUENCE_BEFORE
    previous_inbound_packets=$PRIMARY_INBOUND_PACKETS_BEFORE
    previous_inbound_bytes=$PRIMARY_INBOUND_BYTES_BEFORE
    previous_audio_callbacks=$PRIMARY_AUDIO_CALLBACKS_BEFORE
    previous_audio_frames=$PRIMARY_AUDIO_FRAMES_BEFORE
    previous_audio_nonzero=$PRIMARY_AUDIO_NONZERO_BEFORE
  else
    previous_audio_sequence=$PRIMARY_AUDIO_SEQUENCE_PREMINT
    previous_inbound_packets=$PRIMARY_INBOUND_PACKETS_PREMINT
    previous_inbound_bytes=$PRIMARY_INBOUND_BYTES_PREMINT
    previous_audio_callbacks=$PRIMARY_AUDIO_CALLBACKS_PREMINT
    previous_audio_frames=$PRIMARY_AUDIO_FRAMES_PREMINT
    previous_audio_nonzero=$PRIMARY_AUDIO_NONZERO_PREMINT
  fi
  if rg 'Worldwide audio client diagnostics' "$filtered" \
      | rg -v "Worldwide audio client diagnostics pid=${HOST_PID} " \
      >/dev/null; then
    fail "another host PID emitted primary audio diagnostics within ${prefix} interval"
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    primary_audio_line_matches_baseline "$line" \
      || fail "primary audio identity changed within ${prefix} interval"
    primary_audio_diagnostic_is_current_healthy "$line" \
      || fail "primary audio health became stale or unavailable within ${prefix} interval"
    primary_audio_operational_fields_are_exact "$line" \
      || fail "primary audio operational proof changed within ${prefix} interval"
    audio_sequence=$(diagnostic_field "$line" sequence)
    inbound_packets=$(diagnostic_field "$line" inboundPackets)
    inbound_bytes=$(diagnostic_field "$line" inboundBytes)
    callbacks=$(diagnostic_field "$line" callbacks)
    frames=$(diagnostic_field "$line" frames)
    nonzero_samples=$(diagnostic_field "$line" nonzeroSamples)
    for counter_value in "$audio_sequence" "$inbound_packets" \
        "$inbound_bytes" "$callbacks" "$frames" "$nonzero_samples"; do
      require_unsigned_diagnostic_field "$counter_value" \
        "primary audio progress counter within ${prefix} interval"
    done
    (( audio_sequence > previous_audio_sequence \
        && inbound_packets > previous_inbound_packets \
        && inbound_bytes > previous_inbound_bytes \
        && callbacks > previous_audio_callbacks \
        && frames > previous_audio_frames \
        && nonzero_samples > previous_audio_nonzero )) \
      || fail "primary audio counters regressed or stalled within ${prefix} interval"
    previous_audio_sequence=$audio_sequence
    previous_inbound_packets=$inbound_packets
    previous_inbound_bytes=$inbound_bytes
    previous_audio_callbacks=$callbacks
    previous_audio_frames=$frames
    previous_audio_nonzero=$nonzero_samples
  done < <(rg "Worldwide audio client diagnostics pid=${HOST_PID} " \
    "$filtered" || true)

  if [[ "$PRIMARY_MIC_BASELINE_MODE" == quiescentInactiveSource ]]; then
    [[ "$PRIMARY_AUDIO_APP_ACTIVE" == false ]] \
      || fail "primary microphone quiescent app state changed at ${prefix}"
    selection_count=$(rg -c \
      'Worldwide iPhone microphone hidden writer selected' "$filtered" || true)
    selection_count=${selection_count:-0}
    (( selection_count == 0 )) \
      || fail "primary microphone left quiescent mode within ${prefix} interval"
    if [[ "$prefix" == premint ]]; then
      previous_sample=$PRIMARY_MIC_MEDIA_SAMPLE_BEFORE
    else
      previous_sample=$PRIMARY_MIC_MEDIA_SAMPLE_PREMINT
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_microphone_quiescent_source_is_exact "$audio_line" "$line" \
        || fail "primary microphone quiescent invariant changed within ${prefix} interval"
      primary_quiescent_identity_matches_baseline "$line" \
        || fail "primary microphone quiescent identity changed within ${prefix} interval"
      sample=$(diagnostic_field "$line" mediaSample)
      (( sample > previous_sample )) \
        || fail "primary microphone quiescent samples did not advance within ${prefix} interval"
      previous_sample=$sample
    done < <(rg 'Worldwide iPhone microphone forwarding phase=' "$filtered")
  elif [[ "$PRIMARY_MIC_BASELINE_MODE" == forwardingHealthy ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_selection_line_matches_baseline "$line" \
        || fail "primary microphone routing selection changed within ${prefix} interval"
      selection_count=$(( selection_count + 1 ))
    done < <(rg 'Worldwide iPhone microphone hidden writer selected' \
      "$filtered" || true)
    (( selection_count > 0 )) \
      || fail "primary microphone routing selection was not freshly proven at ${prefix}"
    if [[ "$prefix" == premint ]]; then
      previous_sample=$PRIMARY_MIC_MEDIA_SAMPLE_BEFORE
    else
      previous_sample=$PRIMARY_MIC_MEDIA_SAMPLE_PREMINT
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      primary_microphone_forwarding_is_exact "$line" \
        || fail "primary microphone forwarding invariant changed within ${prefix} interval"
      primary_forwarding_identity_matches_baseline "$line" \
        || fail "primary microphone forwarding attempt identity changed within ${prefix} interval"
      sample=$(diagnostic_field "$line" mediaSample)
      (( sample > previous_sample )) \
        || fail "primary microphone media samples did not advance within ${prefix} interval"
      previous_sample=$sample
    done < <(rg 'Worldwide iPhone microphone forwarding phase=' "$filtered")
  else
    fail "unsupported primary microphone baseline mode: ${PRIMARY_MIC_BASELINE_MODE}"
  fi
}

function write_inactive_primary_append_window() {
  local output=$1
  local current_size window_bytes raw="${output}.raw"
  local deadline=$(( SECONDS + 40 ))
  [[ "$HOST_LOG_CONTINUITY_CURSOR" != *[^0-9]* ]] \
    || fail 'inactive primary continuity cursor is malformed'
  while (( SECONDS < deadline )); do
    [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" \
        && "$(/usr/bin/stat -f '%d' "$HOST_LOG")" == "$HOST_LOG_DEVICE" \
        && "$(/usr/bin/stat -f '%i' "$HOST_LOG")" == "$HOST_LOG_INODE" ]] \
      || fail 'Mac host log identity changed during inactive primary continuity capture'
    current_size=$(/usr/bin/stat -f '%z' "$HOST_LOG") \
      || fail 'Mac host log size is unavailable during inactive primary continuity capture'
    [[ "$current_size" != *[^0-9]* \
        && "$current_size" -ge "$HOST_LOG_CONTINUITY_CURSOR" ]] \
      || fail 'Mac host log was truncated during inactive primary continuity capture'
    window_bytes=$(( current_size - HOST_LOG_CONTINUITY_CURSOR ))
    if (( window_bytes == 0 )); then
      : > "$output"
      HOST_LOG_CONTINUITY_PENDING_CURSOR=$current_size
      /bin/rm -f "$raw"
      return
    fi
    ( /usr/bin/tail -c "+$(( HOST_LOG_CONTINUITY_CURSOR + 1 ))" "$HOST_LOG" \
        | /usr/bin/head -c "$window_bytes" ) > "$raw" || true
    if [[ "$(/usr/bin/stat -f '%z' "$raw")" == "$window_bytes" \
        && "$(/usr/bin/tail -c 1 "$raw" | /usr/bin/od -An -tuC \
          | /usr/bin/tr -d '[:space:]')" == 10 ]]; then
      /bin/cp "$raw" "$output"
      HOST_LOG_CONTINUITY_PENDING_CURSOR=$current_size
      /bin/rm -f "$raw"
      return
    fi
    /bin/sleep 0.25
  done
  /bin/rm -f "$raw"
  fail 'inactive primary append window did not reach a complete-line boundary within 40 seconds'
}

function inactive_primary_append_has_no_primary_activity() {
  local file=$1 scan_status=0
  # Primary rendezvous/authentication can begin before the first peer or audio diagnostic.
  rg -q \
    'Worldwide audio client diagnostics|Worldwide iPhone microphone forwarding|Worldwide iPhone microphone hidden writer selected|Worldwide authenticated media route selected virtual microphone|Worldwide media ended;|A fresh encrypted media rendezvous is ready for the paired iPhone|The paired iPhone left the availability exchange|Worldwide screen host is waiting for the paired iPhone media session|Fresh paired media rendezvous expires in about|Loaded the paired iPhone and started worldwide availability' \
    "$file" || scan_status=$?
  (( scan_status == 1 )) || return 1
  inactive_primary_online_announcements_are_exact < "$file"
}

function capture_inactive_primary_continuity() {
  local prefix=$1
  local filtered="${ARTIFACT_DIR}/${prefix}-inactive-primary-continuity.log"
  local line_count
  write_inactive_primary_append_window "$filtered"
  inactive_primary_append_has_no_primary_activity "$filtered" \
    || fail "primary audio, microphone, or media lifecycle reactivated at ${prefix}"
  case "$prefix" in
    premint)
      if rg -q \
          'Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture|Worldwide viewer disconnected;' \
          "$filtered"; then
        fail 'Mac peer or screen lifecycle changed while the inactive primary was fenced before mint'
      fi
      ;;
    after)
      host_delta_is_complete \
        || fail 'post-test host lifecycle is not exactly one closed secondary presentation'
      ;;
    *)
      fail "unsupported inactive primary continuity phase: ${prefix}"
      ;;
  esac
  if [[ "${PRIMARY_INACTIVE_EVIDENCE:-log}" == stoppedReport ]]; then
    recheck_inactive_primary_stopped_report "$prefix"
  fi
  line_count=$(/usr/bin/wc -l < "$filtered" | /usr/bin/tr -d '[:space:]')
  jq -n --arg phase "$prefix" --arg assurance "$PRIMARY_CONTINUITY_ASSURANCE" \
    --argjson appendedLineCount "$line_count" \
    '{proof:"no-primary-reactivation",phase:$phase,assurance:$assurance,
      appendedLineCount:$appendedLineCount}' \
    > "${ARTIFACT_DIR}/${prefix}-inactive-primary-continuity.json"
  HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_CONTINUITY_PENDING_CURSOR
}

function capture_primary_continuity() {
  local prefix=$1
  local filtered="${ARTIFACT_DIR}/${prefix}-primary-continuity.log"
  local audio_line selection_line forwarding_line
  if [[ "$PRIMARY_BASELINE_MODE" == inactivePrimary \
      || "$PRIMARY_BASELINE_MODE" == neverConnectedPrimary ]]; then
    capture_inactive_primary_continuity "$prefix"
    return
  fi
  if [[ "$prefix" == before ]]; then
    write_primary_continuity_window "$filtered"
  else
    write_primary_continuity_window "$filtered"
  fi
  audio_line=$(rg "Worldwide audio client diagnostics pid=${HOST_PID} " \
    "$filtered" | /usr/bin/tail -n 1 || true)
  forwarding_line=$(rg 'Worldwide iPhone microphone forwarding phase=' \
    "$filtered" | /usr/bin/tail -n 1 || true)
  [[ -n "$audio_line" ]] \
    || fail "no fresh primary audio diagnostic exists at ${prefix}"
  [[ -n "$forwarding_line" ]] \
    || fail "no fresh primary microphone forwarding diagnostic exists at ${prefix}"
  selection_line=$(rg 'Worldwide iPhone microphone hidden writer selected' \
    "$filtered" | /usr/bin/tail -n 1 || true)
  if [[ -z "$selection_line" \
      && ( "$prefix" == before \
        || "$PRIMARY_MIC_BASELINE_MODE" == quiescentInactiveSource ) ]]; then
    selection_line=$(rg 'Worldwide iPhone microphone hidden writer selected' \
      "${ARTIFACT_DIR}/before-host-baseline.log" | /usr/bin/tail -n 1 || true)
  fi
  [[ -n "$selection_line" ]] \
    || fail "primary microphone routing selection is unavailable at ${prefix}"
  parse_primary_audio_diagnostic "$prefix" "$audio_line"
  if [[ "$prefix" == before ]]; then
    parse_primary_microphone_diagnostic \
      "$prefix" "$selection_line" "$forwarding_line" "$audio_line"
    require_primary_baseline_window_sticky "$filtered" "$audio_line"
  else
    require_primary_interval_sticky "$prefix" "$filtered" "$audio_line"
    parse_primary_microphone_diagnostic \
      "$prefix" "$selection_line" "$forwarding_line" "$audio_line"
  fi
  if [[ "$prefix" == before \
      && "$PRIMARY_MIC_BASELINE_MODE" == quiescentInactiveSource ]]; then
    require_quiescent_baseline_depth "$filtered" "$audio_line"
  fi
  HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_CONTINUITY_PENDING_CURSOR
}

function capture_host_generation_identity() {
  local prefix=$1
  local lock_directory=${HOST_LOCK:h}
  local lock_bytes lock_pid lock_generation
  [[ -d "$lock_directory" && ! -L "$lock_directory" \
      && "$(/usr/bin/stat -f '%u' "$lock_directory")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$lock_directory")" == 700 \
      && -f "$HOST_LOCK" && ! -L "$HOST_LOCK" \
      && "$(/usr/bin/stat -f '%u' "$HOST_LOCK")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$HOST_LOCK")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$HOST_LOCK")" == 1 \
      && "$(/usr/bin/stat -f '%z' "$HOST_LOCK")" -le 256 ]] \
    || fail "Mac host generation record is unsafe at ${prefix}"
  lock_bytes=$(<"$HOST_LOCK") \
    || fail "Mac host generation record is unreadable at ${prefix}"
  lock_pid=$(print -r -- "$lock_bytes" \
    | /usr/bin/awk -F= '$1 == "pid" { print $2; found = 1 } END { if (!found) exit 1 }') \
    || fail "Mac host generation PID is unavailable at ${prefix}"
  lock_generation=$(print -r -- "$lock_bytes" \
    | /usr/bin/awk -F= '$1 == "nonce" { print $2; found = 1 } END { if (!found) exit 1 }') \
    || fail "Mac host generation nonce is unavailable at ${prefix}"
  [[ "$(print -r -- "$lock_bytes" | /usr/bin/head -n 1)" \
        == 'OPENSTEAMER_WORLDWIDE_HOST_GENERATION_V1' \
      && "$lock_pid" == "$HOST_PID" \
      && "$lock_generation" =~ '^[0-9a-f]{64}$' ]] \
    || fail "Mac host generation record is malformed or mismatched at ${prefix}"
  if [[ -z "$HOST_GENERATION" ]]; then
    HOST_GENERATION=$lock_generation
  fi
  [[ "$lock_generation" == "$HOST_GENERATION" ]] \
    || fail 'Mac host generation changed during development visual validation'
}

function secondary_manager_probe_generation_is_expected() {
  local prefix=$1
  local manager_generation=$2
  [[ -n "$manager_generation" && "$manager_generation" != *[^0-9]* ]] \
    || return 1
  case "$prefix" in
    baseline)
      [[ -z "$SECONDARY_MANAGER_GENERATION_BASELINE" ]] || return 1
      SECONDARY_MANAGER_GENERATION_BASELINE=$manager_generation
      ;;
    premint)
      [[ -n "$SECONDARY_MANAGER_GENERATION_BASELINE" \
          && "$manager_generation" == "$SECONDARY_MANAGER_GENERATION_BASELINE" ]] \
        || return 1
      ;;
    after)
      (( HOST_GENERATION_RECEIPT_VALIDATED != 0 )) \
        && [[ -n "$SECONDARY_MANAGER_GENERATION" \
          && "$manager_generation" == "$SECONDARY_MANAGER_GENERATION" ]] \
        || return 1
      ;;
    *)
      return 1
      ;;
  esac
}

function capture_secondary_manager_idle_probe() {
  local prefix=$1
  local output="${ARTIFACT_DIR}/${prefix}-secondary-viewer-status.json"
  local stdout="${ARTIFACT_DIR}/${prefix}-secondary-viewer-status.stdout.log"
  local stderr="${ARTIFACT_DIR}/${prefix}-secondary-viewer-status.stderr.log"
  local probe_status=0 started_at finished_at identity identity_after
  local canonical last_byte manager_generation
  [[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" \
      && "$(/usr/bin/stat -f '%u' "$ARTIFACT_DIR")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$ARTIFACT_DIR")" == 700 \
      && ! -e "$output" && ! -L "$output" \
      && ! -e "$stdout" && ! -L "$stdout" \
      && ! -e "$stderr" && ! -L "$stderr" ]] \
    || fail "secondary manager probe paths are unsafe at ${prefix}"
  require_same_host
  capture_host_generation_identity "${prefix}-secondary-manager-before"
  started_at=$(/bin/date '+%s')
  if run_sealed_host_management_child \
      "${prefix}-secondary-manager" "$stdout" "$stderr" \
      "$SECONDARY_MANAGER_PROBE_TIMEOUT_SECONDS" \
      --probe-secondary-test-viewer-status "$output"; then
    probe_status=0
  else
    probe_status=$?
  fi
  finished_at=$(/bin/date '+%s')
  (( probe_status == 0 )) \
    || fail "the running host cannot prove secondary-manager idle state at ${prefix}"
  [[ ! -s "$stdout" && ! -s "$stderr" ]] \
    || fail "secondary manager probe emitted unexpected process output at ${prefix}"
  require_same_host
  capture_host_generation_identity "${prefix}-secondary-manager-after"
  [[ -f "$output" && ! -L "$output" ]] \
    || fail "secondary manager probe output is unavailable at ${prefix}"
  identity=$(/usr/bin/stat -f '%HT|%u|%Lp|%l|%z|%B|%m|%d|%i' "$output") \
    || fail "secondary manager probe metadata is unavailable at ${prefix}"
  typeset -a identity_fields
  identity_fields=("${(@s/|/)identity}")
  (( ${#identity_fields[@]} == 9 )) \
    || fail "secondary manager probe metadata is malformed at ${prefix}"
  [[ "${identity_fields[1]}" == 'Regular File' \
      && "${identity_fields[2]}" == "$UID" \
      && "${identity_fields[3]}" == 600 \
      && "${identity_fields[4]}" == 1 \
      && "${identity_fields[5]}" != *[^0-9]* \
      && "${identity_fields[6]}" != *[^0-9]* \
      && "${identity_fields[7]}" != *[^0-9]* \
      && "${identity_fields[5]}" -ge 1 \
      && "${identity_fields[5]}" -le 1024 \
      && "${identity_fields[6]}" -ge "$started_at" \
      && "${identity_fields[6]}" -le "$finished_at" \
      && "${identity_fields[7]}" -ge "$started_at" \
      && "${identity_fields[7]}" -le "$finished_at" ]] \
    || fail "secondary manager probe file is unsafe or stale at ${prefix}"
  jq --stream -e -s '
    [ .[] | select(length == 2) | .[0] ] as $paths
    | ($paths | length) == 8
      and ($paths | all(length == 1))
      and (($paths | map(.[0]) | sort) == [
        "hostGeneration", "hostProcessIdentifier", "managerGeneration",
        "managerIsIdle", "managerPhase", "requestNonce", "type", "v"
      ])
  ' "$output" >/dev/null \
    || fail "secondary manager probe contains duplicate or unknown fields at ${prefix}"
  jq -e --arg generation "$HOST_GENERATION" --arg pid "$HOST_PID" '
    type == "object" and
    (keys == ["hostGeneration", "hostProcessIdentifier", "managerGeneration",
      "managerIsIdle", "managerPhase", "requestNonce", "type", "v"]) and
    (.v | type == "number") and .v == 1 and .v == (.v | floor) and
    .type == "secondaryTestViewerStatusProbeResult" and
    (.hostProcessIdentifier | type == "number") and
    .hostProcessIdentifier == ($pid | tonumber) and
    .hostProcessIdentifier == (.hostProcessIdentifier | floor) and
    .hostGeneration == $generation and
    (.managerGeneration | type == "number") and
    .managerGeneration >= 0 and
    .managerGeneration == (.managerGeneration | floor) and
    .managerPhase == "idle" and .managerIsIdle == true and
    (.requestNonce | type == "string") and
    (.requestNonce | test("^[0-9a-f]{32}$"))
  ' "$output" >/dev/null \
    || fail "secondary manager probe is not exact idle evidence at ${prefix}"
  canonical=$(jq -cS . "$output") \
    || fail "secondary manager probe cannot be canonicalized at ${prefix}"
  last_byte=$(/usr/bin/tail -c 1 "$output" | /usr/bin/od -An -tuC \
    | /usr/bin/tr -d '[:space:]')
  [[ "$last_byte" == 10 \
      && "${identity_fields[5]}" == $(( ${#canonical} + 1 )) \
      && "$(<"$output")" == "$canonical" ]] \
    || fail "secondary manager probe contains trailing or noncanonical data at ${prefix}"
  identity_after=$(/usr/bin/stat -f '%HT|%u|%Lp|%l|%z|%B|%m|%d|%i' "$output") \
    || fail "secondary manager probe metadata disappeared at ${prefix}"
  [[ "$identity_after" == "$identity" ]] \
    || fail "secondary manager probe output was replaced during validation at ${prefix}"
  manager_generation=$(jq -er '.managerGeneration | tostring' "$output") \
    || fail "secondary manager generation is unavailable at ${prefix}"
  secondary_manager_probe_generation_is_expected "$prefix" "$manager_generation" \
    || fail "secondary manager generation changed unexpectedly at ${prefix}"
}

function capture_host_baseline() {
  require_same_host
  capture_host_generation_identity baseline
  capture_secondary_manager_idle_probe baseline
  HOST_ELAPSED_SECONDS=$(host_elapsed_seconds)
  [[ "$HOST_ELAPSED_SECONDS" != *[^0-9]* ]] \
    || fail 'Mac host elapsed time could not be normalized'
  [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" ]] \
    || fail 'Mac host log is unavailable or unsafe'
  HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG") \
    || fail 'Mac host log device identity is unavailable'
  HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG") \
    || fail 'Mac host log inode identity is unavailable'
  write_host_baseline_snapshot "${ARTIFACT_DIR}/before-host-baseline.log"
  if [[ "${PRIMARY_INACTIVE_EVIDENCE:-log}" == stoppedReport ]]; then
    record_inactive_primary_stopped_report_baseline
    return
  fi
  if never_connected_primary_baseline_is_exact "${ARTIFACT_DIR}/before-host-baseline.log"; then
    capture_host_generation_identity never-connected-baseline
    record_never_connected_primary_baseline "${ARTIFACT_DIR}/before-host-baseline.log"
    return
  fi
  rg -n \
    'Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture|Worldwide viewer disconnected;|Worldwide audio client diagnostics|Worldwide media ended;' \
    "${ARTIFACT_DIR}/before-host-baseline.log" \
    > "${ARTIFACT_DIR}/before-host-lifecycle.log" \
    || fail 'Mac host lifecycle state cannot be determined'
  local latest_capture latest_peer latest_audio
  latest_capture=$(rg 'Starting screen video capture|Stopping screen video capture' \
    "${ARTIFACT_DIR}/before-host-lifecycle.log" | /usr/bin/tail -n 1 || true)
  [[ -z "$latest_capture" || "$latest_capture" == *'Stopping screen video capture'* ]] \
    || fail 'another screen presentation is active; development run must stay serialized'
  latest_audio=$(rg "Worldwide audio client diagnostics pid=${HOST_PID} " \
    "${ARTIFACT_DIR}/before-host-baseline.log" | /usr/bin/tail -n 1 || true)
  [[ -n "$latest_audio" ]] \
    || fail 'Mac host primary audio lifecycle is unavailable before development validation'
  if primary_audio_diagnostic_is_terminal_inactive "$latest_audio"; then
    inactive_primary_lifecycle_is_terminal \
      "${ARTIFACT_DIR}/before-host-baseline.log" \
      || fail 'inactive primary lifecycle is not terminal and serialized'
    parse_inactive_primary_audio_diagnostic before "$latest_audio"
    return
  fi
  latest_peer=$(rg 'Worldwide WebRTC peer state:' \
    "${ARTIFACT_DIR}/before-host-lifecycle.log" | /usr/bin/tail -n 1 || true)
  if [[ -n "$latest_peer" ]]; then
    [[ "$latest_peer" == *"Worldwide WebRTC peer state: connected pid=${HOST_PID}" ]] \
      || fail 'Mac host peer lifecycle is unstable before development validation'
  fi
  capture_primary_continuity before
}

function write_host_delta() {
  local output=${1:-"${ARTIFACT_DIR}/test-host-lifecycle.log"}
  require_same_host
  if [[ "${PRIMARY_BASELINE_MODE:-}" == inactivePrimary \
      || "${PRIMARY_BASELINE_MODE:-}" == neverConnectedPrimary ]]; then
    # Re-read the full bounded append at the final lifecycle fence, including events which
    # arrived during the preceding continuity/report/manager probes. Filter only after the
    # same complete-line snapshot has rejected primary reactivation; do not advance its cursor.
    local HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_BASE_SIZE
    local HOST_LOG_CONTINUITY_PENDING_CURSOR
    local raw="${output}.primary-fence"
    write_inactive_primary_append_window "$raw"
    inactive_primary_append_has_no_primary_activity "$raw" \
      || fail 'primary lifecycle reactivated at the final host lifecycle fence'
    rg 'Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture|Worldwide viewer disconnected;' \
      "$raw" > "$output" || true
    return
  fi
  [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" \
      && "$(/usr/bin/stat -f '%d' "$HOST_LOG")" == "$HOST_LOG_DEVICE" \
      && "$(/usr/bin/stat -f '%i' "$HOST_LOG")" == "$HOST_LOG_INODE" ]] \
    || fail 'Mac host log identity changed during validation'
  local current_size
  current_size=$(/usr/bin/stat -f '%z' "$HOST_LOG") \
    || fail 'Mac host log size is unavailable after test'
  [[ "$current_size" != *[^0-9]* && "$current_size" -ge "$HOST_LOG_BASE_SIZE" ]] \
    || fail 'Mac host log was truncated during validation'
  if (( current_size == HOST_LOG_BASE_SIZE )); then
    : > "$output"
  else
    /usr/bin/tail -c "+$(( HOST_LOG_BASE_SIZE + 1 ))" "$HOST_LOG" \
      | rg 'Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture|Worldwide viewer disconnected;' \
      > "$output" || true
  fi
}

function require_no_host_lifecycle_delta() {
  local prefix=$1
  local output="${ARTIFACT_DIR}/${prefix}-host-lifecycle.log"
  write_host_delta "$output"
  [[ ! -s "$output" ]] \
    || fail "Mac peer or screen lifecycle changed before invitation mint at ${prefix}"
}

function host_delta_is_complete() {
  write_host_delta
  local connected starts disconnects stops latest_capture latest_peer
  local connected_record start_record disconnect_record stop_record
  local connected_line start_line disconnect_line stop_line
  connected=$(rg -c "Worldwide WebRTC peer state: connected pid=${HOST_PID}$" \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" || true)
  starts=$(rg -c 'Starting screen video capture' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" || true)
  disconnects=$(rg -c 'Worldwide viewer disconnected;' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" || true)
  stops=$(rg -c 'Stopping screen video capture' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" || true)
  connected=${connected:-0}
  starts=${starts:-0}
  disconnects=${disconnects:-0}
  stops=${stops:-0}
  [[ "$connected" == 1 && "$starts" == 1 \
      && "$disconnects" == 1 && "$stops" == 1 ]] || return 1
  if rg 'Worldwide WebRTC peer state:' "${ARTIFACT_DIR}/test-host-lifecycle.log" \
      | rg -v "pid=${HOST_PID}$" >/dev/null; then
    fail 'Mac host emitted peer evidence for a different process identity'
  fi
  connected_record=$(rg -n \
    "Worldwide WebRTC peer state: connected pid=${HOST_PID}$" \
    "${ARTIFACT_DIR}/test-host-lifecycle.log")
  start_record=$(rg -n 'Starting screen video capture' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log")
  disconnect_record=$(rg -n 'Worldwide viewer disconnected;' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log")
  stop_record=$(rg -n 'Stopping screen video capture' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log")
  connected_line=${connected_record%%:*}
  start_line=${start_record%%:*}
  disconnect_line=${disconnect_record%%:*}
  stop_line=${stop_record%%:*}
  (( connected_line < start_line \
      && start_line < disconnect_line \
      && disconnect_line < stop_line )) || return 1
  latest_peer=$(rg 'Worldwide WebRTC peer state:' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" | /usr/bin/tail -n 1 || true)
  [[ "$latest_peer" \
      == *"Worldwide WebRTC peer state: connected pid=${HOST_PID}" ]] \
    || return 1
  latest_capture=$(rg 'Starting screen video capture|Stopping screen video capture' \
    "${ARTIFACT_DIR}/test-host-lifecycle.log" | /usr/bin/tail -n 1 || true)
  [[ "$latest_capture" == *'Stopping screen video capture'* ]]
}

function wait_for_host_delta() {
  local attempt
  for (( attempt = 0; attempt < 150; attempt++ )); do
    if host_delta_is_complete; then
      return
    fi
    /bin/sleep 0.10
  done
  fail 'host lifecycle did not prove one ordered connect, capture, viewer disconnect, and stop'
}

function lock_state_failure_is_retryable_service_start_transport() {
  local lock_json=$1
  [[ -f "$lock_json" && ! -L "$lock_json" ]] || return 1
  jq -e '
    (.info.outcome == "failed") and
    (.info.commandType == "devicectl.device.info.lockState") and
    (.error.domain == "com.apple.dt.CoreDeviceError") and
    (.error.code == -1) and
    (.error.userInfo.NSUnderlyingError.error.domain == "com.apple.mobiledevice") and
    (.error.userInfo.NSUnderlyingError.error.code == -402653149)
  ' "$lock_json" >/dev/null 2>&1
}

function capture_device_lock_state() {
  local prefix=$1
  local lock_requirement=$2
  local lock="${ARTIFACT_DIR}/${prefix}-lock.json"
  local attempt_lock attempt_stdout attempt_stderr
  typeset -i attempt lock_state_status lock_state_observed=0
  [[ "$lock_requirement" == unlocked || "$lock_requirement" == any ]] \
    || fail "unsupported development iPhone lock requirement at ${prefix}"
  for (( attempt = 1; attempt <= LOCK_STATE_TRANSPORT_ATTEMPTS; attempt++ )); do
    attempt_lock="${ARTIFACT_DIR}/${prefix}-lock-attempt-${attempt}.json"
    attempt_stdout="${ARTIFACT_DIR}/${prefix}-lock-attempt-${attempt}.stdout.log"
    attempt_stderr="${ARTIFACT_DIR}/${prefix}-lock-attempt-${attempt}.stderr.log"
    [[ ! -e "$attempt_lock" && ! -L "$attempt_lock" \
        && ! -e "$attempt_stdout" && ! -L "$attempt_stdout" \
        && ! -e "$attempt_stderr" && ! -L "$attempt_stderr" ]] \
      || fail "development iPhone lock-state evidence path is unsafe at ${prefix}"
    lock_state_status=0
    if xcrun devicectl device info lockState \
        --device "$DEVICE_ID" --timeout 20 --json-output "$attempt_lock" \
        >"$attempt_stdout" 2>"$attempt_stderr"; then
      lock_state_status=0
    else
      lock_state_status=$?
    fi
    if (( lock_state_status == 0 )); then
      jq -e --arg device "$DEVICE_ID" '(.info.outcome == "success") and
        (.result.deviceIdentifier == $device) and
        (.result.passcodeRequired | type == "boolean")' \
        "$attempt_lock" >/dev/null \
        || fail "development iPhone lock state is malformed at ${prefix}"
      /bin/mv "$attempt_lock" "$lock" \
        || fail "development iPhone lock-state evidence could not be retained at ${prefix}"
      lock_state_observed=1
      break
    fi
    lock_state_failure_is_retryable_service_start_transport "$attempt_lock" \
      || fail "development iPhone lock state returned a non-retryable error at ${prefix}"
    if (( attempt < LOCK_STATE_TRANSPORT_ATTEMPTS )); then
      /bin/sleep "$LOCK_STATE_RETRY_DELAY_SECONDS"
    fi
  done
  (( lock_state_observed == 1 )) \
    || fail "development iPhone lock state unavailable at ${prefix}"
  if [[ "$lock_requirement" == unlocked ]]; then
    jq -e '.result.passcodeRequired == false' "$lock" >/dev/null \
      || fail "development iPhone requires an unlock at ${prefix}"
  fi
}

function capture_device_identity() {
  local prefix=$1
  local lock_requirement=${2:-unlocked}
  local details="${ARTIFACT_DIR}/${prefix}-device.json"
  [[ "$lock_requirement" == unlocked || "$lock_requirement" == any ]] \
    || fail "unsupported development iPhone lock requirement at ${prefix}"
  xcrun devicectl device info details \
    --device "$DEVICE_ID" --timeout 20 --json-output "$details" >/dev/null \
    || fail "CoreDevice details unavailable at ${prefix}"
  jq -e --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" '
    (.info.outcome == "success") and (.result.identifier == $device) and
    (.result.hardwareProperties.udid == $udid) and
    (.result.hardwareProperties.platform == "iOS") and
    (.result.hardwareProperties.reality == "physical") and
    (.result.hardwareProperties.marketingName | startswith("iPhone 15")) and
    (.result.deviceProperties.bootState == "booted") and
    (.result.connectionProperties.pairingState == "paired")
  ' "$details" >/dev/null || fail "wrong or unavailable development iPhone at ${prefix}"
  capture_device_lock_state "$prefix" "$lock_requirement"
}

function require_no_unlock_controller() {
  local process_pid process_command
  while read -r process_pid process_command; do
    [[ -n "$process_pid" ]] || continue
    if [[ "$process_command" == *'/iphone-usb-unlock/scripts/control_session.py'* \
        && " $process_command " == *" --udid ${HARDWARE_UDID} "* ]]; then
      fail 'the exact iPhone credential-holding unlock controller is still active'
    fi
  done < <(ps -axo pid=,command=)
}

function publish_unlock_request() {
  local created_at expires_at temporary_request
  [[ "$NONCE" =~ '^[0-9a-f]{32}$' \
      && ! -e "$UNLOCK_REQUEST" && ! -L "$UNLOCK_REQUEST" \
      && ! -e "$UNLOCK_ACK" && ! -L "$UNLOCK_ACK" ]] \
    || fail 'private unlock rendezvous paths are unsafe or already used'
  created_at=$(/bin/date '+%s')
  expires_at=$(( created_at + UNLOCK_GATE_TIMEOUT_SECONDS ))
  temporary_request=$(/usr/bin/mktemp "${UNLOCK_REQUEST}.tmp.XXXXXX")
  jq -n --arg schema 'opensteamer.iphone15-dev-unlock-request.v1' \
    --arg nonce "$NONCE" --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
    --arg bundle "$APP_BUNDLE_ID" --arg artifact "$ARTIFACT_DIR" \
    --arg runnerProcessStart "$RUN_PROCESS_START" \
    --argjson pid "$$" --argjson created "$created_at" \
    --argjson expires "$expires_at" \
    '{schema:$schema,runNonce:$nonce,runnerPid:$pid,
      runnerProcessStart:$runnerProcessStart,deviceId:$device,
      hardwareUDID:$udid,bundleId:$bundle,artifactDir:$artifact,
      createdAt:$created,expiresAt:$expires}' > "$temporary_request" \
    || fail 'private unlock request could not be encoded'
  /bin/chmod 600 "$temporary_request"
  /bin/mv "$temporary_request" "$UNLOCK_REQUEST"
  [[ -f "$UNLOCK_REQUEST" && ! -L "$UNLOCK_REQUEST" \
      && "$(/usr/bin/stat -f '%u' "$UNLOCK_REQUEST")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$UNLOCK_REQUEST")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$UNLOCK_REQUEST")" == 1 ]] \
    || fail 'private unlock request metadata is unsafe'
  UNLOCK_REQUEST_SHA256=$(/usr/bin/shasum -a 256 "$UNLOCK_REQUEST" \
    | /usr/bin/awk '{ print $1 }') \
    || fail 'private unlock request identity is unavailable'
  [[ "$UNLOCK_REQUEST_SHA256" =~ '^[0-9a-f]{64}$' ]] \
    || fail 'private unlock request identity is malformed'
  UNLOCK_REQUEST_PUBLISHED=1
}

function require_unlock_request_unchanged() {
  local current_sha256
  (( UNLOCK_REQUEST_PUBLISHED == 1 )) || return 1
  [[ -f "$UNLOCK_REQUEST" && ! -L "$UNLOCK_REQUEST" \
      && "$(/usr/bin/stat -f '%u' "$UNLOCK_REQUEST")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$UNLOCK_REQUEST")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$UNLOCK_REQUEST")" == 1 ]] || return 1
  current_sha256=$(/usr/bin/shasum -a 256 "$UNLOCK_REQUEST" \
    | /usr/bin/awk '{ print $1 }') || return 1
  [[ "$current_sha256" == "$UNLOCK_REQUEST_SHA256" ]]
}

function validate_unlock_ack() {
  local now observed age
  require_unlock_request_unchanged || return 1
  [[ -f "$UNLOCK_ACK" && ! -L "$UNLOCK_ACK" \
      && "$(/usr/bin/stat -f '%u' "$UNLOCK_ACK")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$UNLOCK_ACK")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$UNLOCK_ACK")" == 1 \
      && "$(/usr/bin/stat -f '%z' "$UNLOCK_ACK")" -le 2048 ]] || return 1
  jq -e --arg nonce "$NONCE" --arg device "$DEVICE_ID" \
    --arg udid "$HARDWARE_UDID" --arg bundle "$APP_BUNDLE_ID" \
    --arg runnerProcessStart "$RUN_PROCESS_START" \
    --arg requestSHA256 "$UNLOCK_REQUEST_SHA256" --argjson pid "$$" '
      (keys | sort) == ["bundleId","deviceId","hardwareUDID","matchingUnlockControllerAbsent",
        "observedUnlockedAt","runNonce","runnerPid",
        "runnerProcessStart","schema","unlockRequestSHA256"] and
      .schema == "opensteamer.iphone15-dev-unlock-ack.v1" and
      .runNonce == $nonce and .runnerPid == $pid and .deviceId == $device and
      .runnerProcessStart == $runnerProcessStart and
      .unlockRequestSHA256 == $requestSHA256 and
      .hardwareUDID == $udid and .bundleId == $bundle and
      .matchingUnlockControllerAbsent == true and
      (.observedUnlockedAt | type == "number") and
      (.observedUnlockedAt | floor) == .observedUnlockedAt
    ' "$UNLOCK_ACK" >/dev/null || return 1
  observed=$(jq -er '.observedUnlockedAt' "$UNLOCK_ACK") || return 1
  now=$(/bin/date '+%s') || return 1
  age=$(( now - observed ))
  (( age >= -5 && age <= UNLOCK_ACK_MAX_AGE_SECONDS ))
}

function wait_for_exact_device_unlocked_state_acknowledgement() {
  local deadline=$(( SECONDS + UNLOCK_GATE_TIMEOUT_SECONDS ))
  local next_host_check=$SECONDS
  local next_status_heartbeat=$(( SECONDS + 1 ))
  publish_unlock_request
  STAGE=awaiting-exact-device-unlocked-state-acknowledgement
  write_run_status armed \
    'awaiting exact-UDID iphone-usb-unlock skill completion and private acknowledgement'
  while (( SECONDS < deadline )); do
    require_unlock_request_unchanged \
      || fail 'private unlock request changed while the runner was armed'
    if [[ -e "$UNLOCK_ACK" || -L "$UNLOCK_ACK" ]]; then
      validate_unlock_ack \
        || fail 'private unlock acknowledgement is malformed, stale, or mismatched'
      require_no_unlock_controller
      capture_device_identity after-unlock unlocked
      UNLOCK_ACK_VALIDATED=1
      write_run_status gate-open
      return
    fi
    if (( SECONDS >= next_host_check )); then
      host_identity_is_current_for_cleanup \
        || fail 'Mac host identity changed while awaiting the bounded unlock step'
      next_host_check=$(( SECONDS + 5 ))
    fi
    if (( SECONDS >= next_status_heartbeat )); then
      write_run_status armed \
        'awaiting exact-UDID iphone-usb-unlock skill completion and private acknowledgement'
      next_status_heartbeat=$(( SECONDS + 1 ))
    fi
    /bin/sleep 0.25
  done
  fail 'timed out waiting for the bounded exact-device unlocked-state acknowledgement'
}

function power_assertion_status_is_valid() {
  local expected_phase=$1
  local now
  [[ -f "$POWER_ASSERTION_HEARTBEAT" && ! -L "$POWER_ASSERTION_HEARTBEAT" \
      && "$(/usr/bin/stat -f '%u' "$POWER_ASSERTION_HEARTBEAT")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$POWER_ASSERTION_HEARTBEAT")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$POWER_ASSERTION_HEARTBEAT")" == 1 ]] \
    || return 1
  now=$(/bin/date '+%s') || return 1
  if [[ "$expected_phase" == active ]]; then
    jq -e --arg udid "$HARDWARE_UDID" --argjson pid "$POWER_ASSERTION_PID" \
      --argjson owner "$$" --argjson now "$now" \
      --argjson maxAge "$POWER_ASSERTION_HEARTBEAT_MAX_AGE_SECONDS" '
        .schema == "opensteamer.iphone15-dev-power-assertion.v1" and
        .phase == "active" and .pid == $pid and .ownerPid == $owner and
        .udid == $udid and .assertionType == "PreventUserIdleSystemSleep" and
        (.sequence | type == "number" and . >= 1 and floor == .) and
        (.observedAt | type == "number" and . >= ($now - $maxAge) and . <= ($now + 2)) and
        (.leaseExpiresAt | type == "number" and . > ($now + 5)) and
        .residualLeaseExpiresAt == null and .maximumResidualLeaseSeconds == 45 and
        .serviceClosed == false and .tunnelClosed == false and
        .errorType == null
      ' "$POWER_ASSERTION_HEARTBEAT" >/dev/null 2>&1
  else
    jq -e --arg udid "$HARDWARE_UDID" --argjson pid "$POWER_ASSERTION_PID" \
      --argjson owner "$$" --argjson now "$now" '
        .schema == "opensteamer.iphone15-dev-power-assertion.v1" and
        .phase == "stopped" and .pid == $pid and .ownerPid == $owner and
        .udid == $udid and .assertionType == "PreventUserIdleSystemSleep" and
        (.sequence | type == "number" and . >= 1 and floor == .) and
        .leaseExpiresAt == null and
        (.residualLeaseExpiresAt | type == "number" and floor == . and
          . <= ($now + 45)) and
        .maximumResidualLeaseSeconds == 45 and
        .serviceClosed == true and .tunnelClosed == true and .errorType == null
      ' "$POWER_ASSERTION_HEARTBEAT" >/dev/null 2>&1
  fi
}

function start_device_power_assertion() {
  [[ -z "$POWER_ASSERTION_PID" && ! -e "$POWER_ASSERTION_HEARTBEAT" \
      && ! -L "$POWER_ASSERTION_HEARTBEAT" && ! -e "$POWER_ASSERTION_STOP" \
      && ! -L "$POWER_ASSERTION_STOP" ]] \
    || fail 'device power-assertion paths are unsafe or already used'
  OWNED_CHILD_PUBLICATION_PENDING=1
  /usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
    PATH='/usr/bin:/bin:/usr/sbin:/sbin' \
    "$IPHONE_CONTROL_PYTHON" -I -S -B "$POWER_ASSERTION_HELPER" \
    --udid "$HARDWARE_UDID" --owner-pid "$$" \
    --heartbeat "$POWER_ASSERTION_HEARTBEAT" --stop-file "$POWER_ASSERTION_STOP" \
    > "${ARTIFACT_DIR}/device-power-assertion.stdout.log" \
    2> "${ARTIFACT_DIR}/device-power-assertion.stderr.log" &
  POWER_ASSERTION_PID=$!
  finish_owned_child_publication
  [[ "$POWER_ASSERTION_PID" != *[^0-9]* ]] \
    || fail 'device power-assertion PID is invalid'
  local attempt
  for (( attempt = 0; attempt < 1000; attempt++ )); do
    if owned_child_is_alive "$POWER_ASSERTION_PID" \
        && power_assertion_status_is_valid active; then
      POWER_ASSERTION_PHASE=active
      POWER_ASSERTION_SEQUENCE=$(jq -er '.sequence' "$POWER_ASSERTION_HEARTBEAT")
      return
    fi
    owned_child_is_alive "$POWER_ASSERTION_PID" \
      || fail 'device power assertion exited during startup'
    /bin/sleep 0.05
  done
  fail 'device power assertion did not establish its exact-UDID lease'
}

function require_device_power_assertion_healthy() {
  local prefix=$1
  local first second
  owned_child_is_alive "$POWER_ASSERTION_PID" \
    || fail "device power assertion exited at ${prefix}"
  power_assertion_status_is_valid active \
    || fail "device power assertion is stale or mismatched at ${prefix}"
  first=$(jq -er '.sequence' "$POWER_ASSERTION_HEARTBEAT") \
    || fail "device power-assertion sequence is unavailable at ${prefix}"
  /bin/sleep 0.60
  power_assertion_status_is_valid active \
    || fail "device power assertion became unhealthy at ${prefix}"
  second=$(jq -er '.sequence' "$POWER_ASSERTION_HEARTBEAT") \
    || fail "device power-assertion sequence is unavailable at ${prefix}"
  (( second > first )) \
    || fail "device power-assertion heartbeat stalled at ${prefix}"
  POWER_ASSERTION_PHASE=active
  POWER_ASSERTION_SEQUENCE=$second
}

function stop_device_power_assertion() {
  local prefix=$1
  local child_pid child_status=0 attempt forced=0 residual_lease now clean_stop=1
  [[ -n "$POWER_ASSERTION_PID" ]] || return 0
  child_pid=$POWER_ASSERTION_PID
  if /usr/bin/touch "$POWER_ASSERTION_STOP" 2>/dev/null; then
    for (( attempt = 0; attempt < 500; attempt++ )); do
      owned_child_is_alive "$child_pid" || break
      /bin/sleep 0.05
    done
  else
    clean_stop=0
  fi
  if owned_child_is_alive "$child_pid"; then
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
  for (( attempt = 0; attempt < 100; attempt++ )); do
    owned_child_is_alive "$child_pid" || break
    /bin/sleep 0.05
  done
  if owned_child_is_alive "$child_pid"; then
    kill -KILL "$child_pid" 2>/dev/null || true
    forced=1
  fi
  if wait "$child_pid" 2>/dev/null; then
    child_status=0
  else
    child_status=$?
  fi
  if [[ -f "$POWER_ASSERTION_HEARTBEAT" ]]; then
    POWER_ASSERTION_PHASE=$(jq -r '.phase // empty' \
      "$POWER_ASSERTION_HEARTBEAT" 2>/dev/null || true)
    POWER_ASSERTION_SEQUENCE=$(jq -r '.sequence // empty' \
      "$POWER_ASSERTION_HEARTBEAT" 2>/dev/null || true)
  fi
  if (( forced != 0 || child_status != 0 )) \
      || ! power_assertion_status_is_valid stopped; then
    clean_stop=0
  fi
  now=$(/bin/date '+%s') || {
    POWER_ASSERTION_PID=''
    return 1
  }
  if (( clean_stop != 0 )); then
    residual_lease=$(jq -er '.residualLeaseExpiresAt' \
      "$POWER_ASSERTION_HEARTBEAT") || clean_stop=0
  fi
  if (( clean_stop == 0 )) \
      || (( residual_lease > now + 45 )); then
    # If the helper could not publish a trusted stopped record, killing it is still a hard upper
    # bound: no later renewal can occur, and any unacknowledged device assertion expires in 45s.
    residual_lease=$(( now + 45 ))
    clean_stop=0
  fi
  # The assertion agent has no release acknowledgement. Its device-side timeout is the ultimate
  # bound, so do not report clean stop until the last 45-second lease has certainly expired.
  while (( now <= residual_lease )); do
    /bin/sleep 0.25
    now=$(/bin/date '+%s') || {
      POWER_ASSERTION_PID=''
      return 1
    }
  done
  POWER_ASSERTION_PID=''
  if (( clean_stop == 0 )); then
    return 1
  fi
  POWER_ASSERTION_STOPPED=1
  POWER_ASSERTION_PHASE=stopped
  return 0
}

function capture_installed_dev_app() {
  local prefix=$1
  local apps="${ARTIFACT_DIR}/${prefix}-apps.json"
  local observed_url
  xcrun devicectl device info apps \
    --device "$DEVICE_ID" --include-all-apps --bundle-id "$APP_BUNDLE_ID" \
    --timeout 30 --json-output "$apps" >/dev/null \
    || fail "development app metadata unavailable at ${prefix}"
  jq -e --arg bundle "$APP_BUNDLE_ID" --arg build "$LOCAL_APP_BUILD" '
    (.info.outcome == "success") and
    ([.result.apps[] | select(.bundleIdentifier == $bundle)] | length == 1) and
    ([.result.apps[] | select(.bundleIdentifier == $bundle)][0] |
      .bundleVersion == $build and .name == "Beluga" and
      .appClip == false and .internalApp == false and .removable == true)
  ' "$apps" >/dev/null \
    || fail "expected installed development bundle/build missing at ${prefix}"
  jq -S --arg bundle "$APP_BUNDLE_ID" \
    '[.result.apps[] | select(.bundleIdentifier == $bundle)][0]' "$apps" \
    > "${ARTIFACT_DIR}/${prefix}-dev-app.json"
  observed_url=$(jq -er --arg bundle "$APP_BUNDLE_ID" \
    '[.result.apps[] | select(.bundleIdentifier == $bundle)][0].url' "$apps") \
    || fail "development app URL is unavailable at ${prefix}"
  [[ "$observed_url" == file:///private/var/containers/Bundle/Application/*/Beluga.app/ ]] \
    || fail "development app URL is malformed at ${prefix}"
  if [[ -z "$LOCAL_APP_URL" ]]; then
    LOCAL_APP_URL=$observed_url
  fi
  [[ "$observed_url" == "$LOCAL_APP_URL" ]] \
    || fail 'installed development app identity changed during validation'
}

function dev_app_processes_are_absent() {
  local prefix=$1
  local processes="${ARTIFACT_DIR}/${prefix}-device-processes.json"
  [[ -n "$LOCAL_APP_URL" ]] || return 1
  xcrun devicectl device info processes \
    --device "$DEVICE_ID" --timeout 20 --json-output "$processes" \
    >/dev/null 2>&1 || return 1
  jq -e --arg device "$DEVICE_ID" --arg appRoot "${LOCAL_APP_URL%/}" '
    def normalized_url:
      if type == "string" then sub("/+$"; "") else "" end;
    (.info.outcome == "success") and
    (.result.deviceIdentifier == $device) and
    (.result.runningProcesses | type == "array") and
    ([.result.runningProcesses[]
      | select((.executable? | normalized_url) | startswith($appRoot + "/"))]
      | length == 0)
  ' "$processes" >/dev/null 2>&1
}

function verify_device_secret_cleanup_receipt() {
  local nonce=$1
  local prefix=$2
  local receipt_name="${DEVICE_CLEANUP_RECEIPT_PREFIX}${nonce}"
  local proof_directory="${ARTIFACT_DIR}/${prefix}-device-cleanup-proof"
  local copied_receipt="${proof_directory}/${receipt_name}"
  local copy_json="${ARTIFACT_DIR}/${prefix}-device-cleanup-copy.json"
  local files_json="${ARTIFACT_DIR}/${prefix}-device-files.json"
  [[ "$nonce" =~ '^[0-9a-f]{32}$' \
      && "$prefix" =~ '^[a-z0-9-]+$' \
      && ! -e "$proof_directory" && ! -L "$proof_directory" ]] || return 1
  /bin/mkdir -m 700 "$proof_directory" || return 1
  xcrun devicectl device copy from \
    --device "$DEVICE_ID" \
    --source "Documents/${receipt_name}" \
    --destination "$copied_receipt" \
    --domain-type appDataContainer \
    --domain-identifier "$APP_BUNDLE_ID" \
    --timeout 20 --quiet --json-output "$copy_json" \
    > "${ARTIFACT_DIR}/${prefix}-device-cleanup-copy.stdout.log" 2>&1 \
    || return 1
  jq -e '.info.outcome == "success"' "$copy_json" >/dev/null 2>&1 \
    || return 1
  [[ -f "$copied_receipt" && ! -L "$copied_receipt" \
      && "$(/usr/bin/stat -f '%u' "$copied_receipt")" == "$UID" \
      && "$(<"$copied_receipt")" \
        == "OPENSTEAMER_IPHONE15_DEV_SECRET_CLEANUP_V1 nonce=${nonce}" ]] \
    || return 1
  xcrun devicectl device info files \
    --device "$DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$APP_BUNDLE_ID" \
    --subdirectory Documents --no-recurse \
    --timeout 20 --json-output "$files_json" >/dev/null 2>&1 \
    || return 1
  jq -e --arg device "$DEVICE_ID" --arg bundle "$APP_BUNDLE_ID" \
    --arg seed "$INVITATION_DESTINATION_NAME" --arg receipt "$receipt_name" '
      (.info.outcome == "success") and
      (.result.deviceIdentifier == $device) and
      (.result.domain == "appDataContainer") and
      (.result.domainIdentifier == $bundle) and
      (.result.files | type == "array") and
      ([.result.files[] | .. | strings
        | select(. == $seed or endswith("/" + $seed))] | length == 0) and
      ([.result.files[] | .. | strings
        | select(. == $receipt or endswith("/" + $receipt))] | length >= 1)
    ' "$files_json" >/dev/null 2>&1
}

function run_device_secret_cleanup() {
  local prefix=$1
  local cleanup_nonce launch_json terminate_json cleanup_pid=''
  local cleanup_ok=1
  [[ "$prefix" =~ '^[a-z0-9-]+$' ]] || return 1
  cleanup_nonce=$(openssl rand -hex 16 2>/dev/null) || return 1
  [[ "$cleanup_nonce" =~ '^[0-9a-f]{32}$' ]] || return 1
  launch_json="${ARTIFACT_DIR}/${prefix}-device-cleanup-launch.json"
  terminate_json="${ARTIFACT_DIR}/${prefix}-device-cleanup-terminate.json"
  if xcrun devicectl device process launch \
      --device "$DEVICE_ID" --terminate-existing --no-activate \
      --timeout 20 --json-output "$launch_json" \
      "$APP_BUNDLE_ID" \
      "$DEVICE_CLEANUP_LAUNCH_ARGUMENT" \
      "$DEVICE_CLEANUP_RECEIPT_ARGUMENT" "$cleanup_nonce" \
      > "${ARTIFACT_DIR}/${prefix}-device-cleanup-launch.stdout.log" 2>&1; then
    cleanup_pid=$(jq -er '
      [.result | .. | objects | .processIdentifier?
        | select(type == "number" and . > 0 and floor == .)] | unique
      | if length == 1 then .[0] | tostring
        else error("ambiguous cleanup process") end
    ' "$launch_json" 2>/dev/null) || cleanup_ok=0
  else
    cleanup_ok=0
  fi
  if (( cleanup_ok != 0 )); then
    local receipt_attempt receipt_wait_json
    for (( receipt_attempt = 0; receipt_attempt < 30; receipt_attempt++ )); do
      receipt_wait_json="${ARTIFACT_DIR}/${prefix}-device-cleanup-wait-${receipt_attempt}.json"
      if xcrun devicectl device info files \
          --device "$DEVICE_ID" --domain-type appDataContainer \
          --domain-identifier "$APP_BUNDLE_ID" --subdirectory Documents \
          --no-recurse --timeout 20 --json-output "$receipt_wait_json" \
          >/dev/null 2>&1 \
          && jq -e --arg receipt \
            "${DEVICE_CLEANUP_RECEIPT_PREFIX}${cleanup_nonce}" '
              (.info.outcome == "success") and
              (.result.files | type == "array") and
              ([.result.files[] | .. | strings
                | select(. == $receipt or endswith("/" + $receipt))]
                | length >= 1)
            ' "$receipt_wait_json" >/dev/null 2>&1; then
        break
      fi
      /bin/sleep 0.10
    done
    verify_device_secret_cleanup_receipt "$cleanup_nonce" "$prefix" \
      || cleanup_ok=0
  fi
  if [[ -n "$cleanup_pid" ]]; then
    if ! xcrun devicectl device process terminate \
        --device "$DEVICE_ID" --pid "$cleanup_pid" --timeout 20 \
        --json-output "$terminate_json" \
        > "${ARTIFACT_DIR}/${prefix}-device-cleanup-terminate.stdout.log" 2>&1 \
        || ! jq -e '.info.outcome == "success"' "$terminate_json" \
          >/dev/null 2>&1; then
      cleanup_ok=0
    fi
  else
    cleanup_ok=0
  fi
  dev_app_processes_are_absent "${prefix}-after-cleanup" || cleanup_ok=0
  if (( cleanup_ok != 0 )); then
    DEVICE_SECRET_CLEANUP_REQUIRED=0
    DEVICE_SECRET_CLEANUP_CONFIRMED=1
    return 0
  fi
  return 1
}

function clean_development_test_cache_with_xcode() {
  local log_path=$1
  xcodebuild clean \
    -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
    -scheme opensteamerUITests -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    > "$log_path" 2>&1
}

function build_development_test_products_with_xcode() {
  local log_path=$1
  xcodebuild build-for-testing \
    -project "${PROJECT_DIR}/opensteamer.xcodeproj" \
    -scheme opensteamerUITests -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -maximum-test-execution-time-allowance 240 \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    OPENSTEAMER_RENDEZVOUS_URL="$DEVELOPMENT_RENDEZVOUS_URL" \
    "-only-testing:${TEST_ID}" \
    > "$log_path" 2>&1
}

function build_current_development_test_products() {
  local cached_runner="${DERIVED_DATA}/Build/Products/Debug-iphoneos/opensteamerUITests-Runner.app"
  local requires_clean=0
  if [[ -e "$cached_runner" ]]; then
    if [[ ! -d "$cached_runner" || -L "$cached_runner" ]] \
        || ! codesign --verify --deep --strict "$cached_runner" \
          > "${ARTIFACT_DIR}/cached-ui-runner-codesign-verify.log" 2>&1; then
      requires_clean=1
    fi
  fi
  if (( requires_clean != 0 )); then
    STAGE=repair-development-test-cache
    write_run_status preparing 'repairing-invalid-incremental-development-runner-signature'
    clean_development_test_cache_with_xcode "${ARTIFACT_DIR}/cache-repair.log" \
      || fail 'invalid incremental development UI-test cache could not be cleaned by Xcode'
  fi

  STAGE=build-current-development-test-products
  write_run_status preparing
  build_development_test_products_with_xcode "${ARTIFACT_DIR}/build.log" \
    || fail 'current-source development UI-test build failed; see build.log'

  if [[ ! -d "$cached_runner" || -L "$cached_runner" ]] \
      || ! codesign --verify --deep --strict "$cached_runner" \
        > "${ARTIFACT_DIR}/built-ui-runner-codesign-verify.log" 2>&1; then
    STAGE=repair-development-test-cache-after-build
    write_run_status preparing 'repairing-post-build-development-runner-signature'
    clean_development_test_cache_with_xcode \
      "${ARTIFACT_DIR}/post-build-cache-repair.log" \
      || fail 'post-build development UI-test cache could not be cleaned by Xcode'
    build_development_test_products_with_xcode \
      "${ARTIFACT_DIR}/post-build-rebuild.log" \
      || fail 'development UI-test rebuild failed after bounded Xcode cache repair'
  fi
  [[ -d "$cached_runner" && ! -L "$cached_runner" ]] \
    || fail 'current-source development UI-test runner is unavailable'
  codesign --verify --deep --strict "$cached_runner" \
    > "${ARTIFACT_DIR}/built-ui-runner-final-codesign-verify.log" 2>&1 \
    || fail 'Xcode produced an invalid development UI-test runner after bounded repair'
}

function prepare_signed_products() {
  local source_products="${DERIVED_DATA}/Build/Products"
  [[ -d "$source_products" && ! -L "$source_products" ]] \
    || fail 'current-source development test products are unavailable'
  /usr/bin/ditto "$source_products" "$PREPARED_PRODUCTS" \
    > "${ARTIFACT_DIR}/prepared-products-copy.log" 2>&1 \
    || fail 'failed to seal the current-source development test products'
  if /usr/bin/find "$PREPARED_PRODUCTS" -type l -print -quit \
      | /usr/bin/grep -q .; then
    fail 'prepared development test products contain an unsafe symbolic link'
  fi
  local local_app="${PREPARED_PRODUCTS}/Debug-iphoneos/Beluga.app"
  [[ -d "$local_app" && ! -L "$local_app" && -f "${local_app}/Info.plist" ]] \
    || fail 'prepared development app is missing'
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "${local_app}/Info.plist")" \
      == "$APP_BUNDLE_ID" ]] \
    || fail 'prepared app is not the dedicated development bundle'
  [[ "$(plutil -extract OpensteamerRendezvousURL raw -o - \
      "${local_app}/Info.plist")" == "$DEVELOPMENT_RENDEZVOUS_URL" ]] \
    || fail 'prepared development app does not bind the deployed rendezvous endpoint'
  LOCAL_APP_BUILD=$(plutil -extract CFBundleVersion raw -o - \
    "${local_app}/Info.plist") || fail 'prepared development build is unavailable'
  [[ -n "$LOCAL_APP_BUILD" && "$LOCAL_APP_BUILD" != *[^0-9]* ]] \
    || fail 'prepared development build is malformed'
  codesign --verify --deep --strict "$local_app" \
    > "${ARTIFACT_DIR}/debug-app-codesign-verify.log" 2>&1 \
    || fail 'prepared development app signature verification failed'
  codesign -dv --verbose=4 "$local_app" \
    > /dev/null 2> "${ARTIFACT_DIR}/debug-app-codesign.txt" \
    || fail 'prepared development app signature metadata is unavailable'
  /usr/bin/grep -Fxq "Identifier=${APP_BUNDLE_ID}" \
    "${ARTIFACT_DIR}/debug-app-codesign.txt" \
    && /usr/bin/grep -Fxq "TeamIdentifier=${DEVELOPMENT_TEAM_ID}" \
      "${ARTIFACT_DIR}/debug-app-codesign.txt" \
    || fail 'prepared development app signature identity is unexpected'

  typeset -a runner_apps xctestrun_files
  runner_apps=("${PREPARED_PRODUCTS}"/Debug-iphoneos/*UITests-Runner.app(N/))
  (( ${#runner_apps[@]} == 1 )) || fail 'expected one prepared UI test runner app'
  [[ "$(plutil -extract CFBundleIdentifier raw -o - \
      "${runner_apps[1]}/Info.plist")" == "$RUNNER_BUNDLE_ID" ]] \
    || fail 'prepared UI test runner bundle identity is unexpected'
  codesign --verify --deep --strict "${runner_apps[1]}" \
    > "${ARTIFACT_DIR}/ui-runner-codesign-verify.log" 2>&1 \
    || fail 'prepared UI test runner signature verification failed'
  codesign -dv --verbose=4 "${runner_apps[1]}" \
    > /dev/null 2> "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
    || fail 'prepared UI test runner signature metadata is unavailable'
  /usr/bin/grep -Fxq "Identifier=${RUNNER_BUNDLE_ID}" \
    "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
    && /usr/bin/grep -Fxq "TeamIdentifier=${DEVELOPMENT_TEAM_ID}" \
      "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
    || fail 'prepared UI test runner signature identity is unexpected'
  xctestrun_files=("${PREPARED_PRODUCTS}"/opensteamerUITests_*.xctestrun(N))
  (( ${#xctestrun_files[@]} == 1 )) \
    || fail 'expected one exact prepared development UI-test xctestrun file'
  XCTESTRUN_FILE=${xctestrun_files[1]}
  plutil -convert json -o "${ARTIFACT_DIR}/xctestrun.json" "$XCTESTRUN_FILE" \
    || fail 'prepared development UI-test xctestrun metadata is unavailable'
  jq -e --arg runner "$RUNNER_BUNDLE_ID" --arg app "$APP_BUNDLE_ID" '
    (keys | sort) == ["__xctestrun_metadata__", "opensteamerUITests"] and
    .opensteamerUITests.TestHostBundleIdentifier == $runner and
    .opensteamerUITests.TestHostPath ==
      "__TESTROOT__/Debug-iphoneos/opensteamerUITests-Runner.app" and
    .opensteamerUITests.TestBundlePath ==
      "__TESTHOST__/PlugIns/opensteamerUITests.xctest" and
    .opensteamerUITests.UITargetAppPath ==
      "__TESTROOT__/Debug-iphoneos/Beluga.app" and
    .opensteamerUITests.ProductModuleName == "opensteamerUITests" and
    ([.. | strings | select(. == "com.elamin.opensteamer")] | length) == 0 and
    ([.. | strings | select(. == $app)] | length) >= 1
  ' "${ARTIFACT_DIR}/xctestrun.json" >/dev/null \
    || fail 'prepared xctestrun is not pinned to the development app and UI runner'
  (
    cd "$PREPARED_PRODUCTS"
    /usr/bin/find -s . -type f -exec /usr/bin/shasum -a 256 {} +
  ) > "$PREPARED_PRODUCTS_MANIFEST" \
    || fail 'prepared development product manifest could not be sealed'
  [[ -s "$PREPARED_PRODUCTS_MANIFEST" ]] \
    || fail 'prepared development product manifest is empty'
}

function verify_prepared_products_unchanged() {
  local prefix=$1
  local current="${ARTIFACT_DIR}/${prefix}-prepared-test-products.sha256"
  (
    cd "$PREPARED_PRODUCTS"
    /usr/bin/find -s . -type f -exec /usr/bin/shasum -a 256 {} +
  ) > "$current" || fail "prepared products could not be rehashed at ${prefix}"
  /usr/bin/cmp -s "$PREPARED_PRODUCTS_MANIFEST" "$current" \
    || fail "prepared development products changed at ${prefix}"
}

function compile_audio_route_reader() {
  xcrun --sdk macosx swiftc -parse-as-library \
    -framework CoreAudio -framework Foundation \
    -o "$AUDIO_ROUTE_READER" - \
    > "${ARTIFACT_DIR}/audio-route-reader-build.log" 2>&1 <<'SWIFT'
import CoreAudio
import Darwin
import Foundation

private enum ReaderFailure: Error {
    case defaultDevice
    case deviceUID
    case invalidUID
    case listenerRegistration
    case signalIsolation
    case usage
}

private struct Routes: Codable, Equatable {
    let defaultInputUID: String
    let defaultOutputUID: String
    let defaultSystemOutputUID: String
}

private struct MonitorStatus: Codable {
    let schema: String
    let phase: String
    let pid: Int32
    let heartbeat: UInt64
    let listenersInstalled: Int
    let listenersRemoved: Bool
    let notificationCount: UInt64
    let firstSelectors: [UInt32]
    let baseline: Routes?
    let current: Routes?
    let clean: Bool
}

private final class MonitorState: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationCount: UInt64 = 0
    private var firstSelectors: [UInt32] = []

    func record(
        _ count: UInt32,
        _ addresses: UnsafePointer<AudioObjectPropertyAddress>?
    ) {
        lock.lock()
        notificationCount &+= count == 0 ? 1 : UInt64(count)
        if firstSelectors.isEmpty, let addresses {
            firstSelectors = (0..<Int(count)).map { addresses[$0].mSelector }
        }
        lock.unlock()
    }

    func recordReadFailureOrMismatch() {
        lock.lock()
        notificationCount &+= 1
        lock.unlock()
    }

    func snapshot() -> (count: UInt64, selectors: [UInt32]) {
        lock.lock()
        defer { lock.unlock() }
        return (notificationCount, firstSelectors)
    }
}

private func deviceUID(_ selector: AudioObjectPropertySelector) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
    ) == noErr,
    size == UInt32(MemoryLayout<AudioDeviceID>.size),
    device != kAudioObjectUnknown else {
        throw ReaderFailure.defaultDevice
    }
    address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
          size == UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
          let value else {
        throw ReaderFailure.deviceUID
    }
    let uid = value.takeUnretainedValue() as String
    guard !uid.isEmpty,
          uid.utf8.count <= 512,
          uid.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
        throw ReaderFailure.invalidUID
    }
    return uid
}

private func routes() throws -> Routes {
    Routes(
        defaultInputUID: try deviceUID(kAudioHardwarePropertyDefaultInputDevice),
        defaultOutputUID: try deviceUID(kAudioHardwarePropertyDefaultOutputDevice),
        defaultSystemOutputUID: try deviceUID(
            kAudioHardwarePropertyDefaultSystemOutputDevice
        )
    )
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func writeStatus(_ value: MonitorStatus, to path: String) throws {
    try encodedJSON(value).write(to: URL(fileURLWithPath: path), options: [.atomic])
}

private func monitor(statusPath: String, stopPath: String) throws {
    if getpgrp() != getpid(), setsid() == -1 {
        throw ReaderFailure.signalIsolation
    }
    let ownerPID = getppid()
    let system = AudioObjectID(kAudioObjectSystemObject)
    let queue = DispatchQueue(label: "opensteamer.iphone15-dev.default-route-monitor")
    let state = MonitorState()
    let listener: AudioObjectPropertyListenerBlock = { count, addresses in
        state.record(count, addresses)
    }
    let selectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]
    var installed: [AudioObjectPropertyAddress] = []
    for selector in selectors {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectAddPropertyListenerBlock(
            system, &address, queue, listener
        ) == noErr else {
            var removalSucceeded = true
            for stored in installed.reversed() {
                var installedAddress = stored
                if AudioObjectRemovePropertyListenerBlock(
                    system, &installedAddress, queue, listener
                ) != noErr {
                    removalSucceeded = false
                }
            }
            queue.sync {}
            let observed = state.snapshot()
            try writeStatus(
                MonitorStatus(
                    schema: "opensteamer.default-route-monitor.v1",
                    phase: "startup-failed", pid: getpid(), heartbeat: 0,
                    listenersInstalled: installed.count,
                    listenersRemoved: removalSucceeded,
                    notificationCount: observed.count,
                    firstSelectors: observed.selectors, baseline: nil,
                    current: try? routes(), clean: false
                ),
                to: statusPath
            )
            throw ReaderFailure.listenerRegistration
        }
        installed.append(address)
    }
    queue.sync {}
    let baseline1 = try routes()
    queue.sync {}
    let baseline2 = try routes()
    queue.sync {}
    let startupState = state.snapshot()
    guard baseline1 == baseline2, startupState.count == 0 else {
        var removalSucceeded = true
        for stored in installed.reversed() {
            var installedAddress = stored
            if AudioObjectRemovePropertyListenerBlock(
                system, &installedAddress, queue, listener
            ) != noErr {
                removalSucceeded = false
            }
        }
        queue.sync {}
        let observed = state.snapshot()
        try writeStatus(
            MonitorStatus(
                schema: "opensteamer.default-route-monitor.v1",
                phase: "startup-unstable", pid: getpid(), heartbeat: 0,
                listenersInstalled: installed.count,
                listenersRemoved: removalSucceeded,
                notificationCount: observed.count,
                firstSelectors: observed.selectors, baseline: baseline1,
                current: try? routes(), clean: false
            ),
            to: statusPath
        )
        Darwin.exit(71)
    }
    var heartbeat: UInt64 = 0
    while !FileManager.default.fileExists(atPath: stopPath), getppid() == ownerPID {
        heartbeat &+= 1
        let current = try? routes()
        if current != baseline1 { state.recordReadFailureOrMismatch() }
        let observed = state.snapshot()
        try writeStatus(
            MonitorStatus(
                schema: "opensteamer.default-route-monitor.v1",
                phase: observed.count == 0 ? "monitoring" : "violated",
                pid: getpid(), heartbeat: heartbeat,
                listenersInstalled: installed.count, listenersRemoved: false,
                notificationCount: observed.count,
                firstSelectors: observed.selectors, baseline: baseline1,
                current: current, clean: false
            ),
            to: statusPath
        )
        Thread.sleep(forTimeInterval: 0.20)
    }
    let beforeRemoval = try? routes()
    var removalSucceeded = true
    for stored in installed.reversed() {
        var installedAddress = stored
        if AudioObjectRemovePropertyListenerBlock(
            system, &installedAddress, queue, listener
        ) != noErr {
            removalSucceeded = false
        }
    }
    queue.sync {}
    let afterRemoval = try? routes()
    let finalState = state.snapshot()
    let clean = removalSucceeded && finalState.count == 0
        && beforeRemoval == baseline1 && afterRemoval == baseline1
    try writeStatus(
        MonitorStatus(
            schema: "opensteamer.default-route-monitor.v1",
            phase: "stopped", pid: getpid(), heartbeat: heartbeat,
            listenersInstalled: installed.count,
            listenersRemoved: removalSucceeded,
            notificationCount: finalState.count,
            firstSelectors: finalState.selectors, baseline: baseline1,
            current: afterRemoval, clean: clean
        ),
        to: statusPath
    )
    if !clean { Darwin.exit(1) }
}

@main
private struct Main {
    static func main() throws {
        if CommandLine.arguments.count == 1 {
            FileHandle.standardOutput.write(try encodedJSON(routes()))
            FileHandle.standardOutput.write(Data([0x0a]))
            return
        }
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments[1] == "monitor" else {
            throw ReaderFailure.usage
        }
        try monitor(
            statusPath: CommandLine.arguments[2],
            stopPath: CommandLine.arguments[3]
        )
    }
}
SWIFT
}

function capture_audio_routes() {
  local prefix=$1
  local raw="${ARTIFACT_DIR}/${prefix}-audio-routes.raw.json"
  local canonical="${ARTIFACT_DIR}/${prefix}-audio-routes.json"
  "$AUDIO_ROUTE_READER" > "$raw" \
    || fail "CoreAudio default routes are unavailable at ${prefix}"
  jq -eS '
    select(
      (keys == ["defaultInputUID", "defaultOutputUID", "defaultSystemOutputUID"]) and
      (all(.[]; type == "string" and length > 0 and length <= 512))
    )
  ' "$raw" > "$canonical" \
    || fail "CoreAudio default route snapshot is malformed at ${prefix}"
  if [[ -z "$DEFAULT_INPUT_UID" ]]; then
    DEFAULT_INPUT_UID=$(jq -er '.defaultInputUID' "$canonical") \
      || fail 'default input UID is unavailable'
    DEFAULT_OUTPUT_UID=$(jq -er '.defaultOutputUID' "$canonical") \
      || fail 'default output UID is unavailable'
    DEFAULT_SYSTEM_OUTPUT_UID=$(jq -er '.defaultSystemOutputUID' "$canonical") \
      || fail 'default system-output UID is unavailable'
  else
    /usr/bin/cmp -s "${ARTIFACT_DIR}/before-audio-routes.json" "$canonical" \
      || fail "CoreAudio default routes changed at ${prefix}"
  fi
}

function start_audio_route_monitor() {
  OWNED_CHILD_PUBLICATION_PENDING=1
  "$AUDIO_ROUTE_READER" monitor \
    "$AUDIO_ROUTE_MONITOR_STATUS" "$AUDIO_ROUTE_MONITOR_STOP" \
    > "${ARTIFACT_DIR}/audio-route-monitor.stdout.log" \
    2> "${ARTIFACT_DIR}/audio-route-monitor.stderr.log" &
  AUDIO_ROUTE_MONITOR_PID=$!
  finish_owned_child_publication
  [[ -n "$AUDIO_ROUTE_MONITOR_PID" \
      && "$AUDIO_ROUTE_MONITOR_PID" != *[^0-9]* ]] \
    || fail 'CoreAudio route monitor PID is invalid'
  local attempt
  for (( attempt = 0; attempt < 100; attempt++ )); do
    if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
        && jq -e --argjson pid "$AUDIO_ROUTE_MONITOR_PID" '
          .schema == "opensteamer.default-route-monitor.v1" and
          .phase == "monitoring" and .pid == $pid and
          .listenersInstalled == 3 and .listenersRemoved == false and
          .notificationCount == 0 and .clean == false and
          (.heartbeat | type == "number" and . >= 1) and .current == .baseline
        ' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; then
      return
    fi
    kill -0 "$AUDIO_ROUTE_MONITOR_PID" 2>/dev/null \
      || fail 'CoreAudio route monitor exited during startup'
    /bin/sleep 0.05
  done
  fail 'CoreAudio route monitor did not establish a stable listener baseline'
}

function require_audio_route_monitor_healthy() {
  local prefix=$1
  local first second
  kill -0 "$AUDIO_ROUTE_MONITOR_PID" 2>/dev/null \
    || fail "CoreAudio route monitor exited at ${prefix}"
  first=$(jq -er --argjson pid "$AUDIO_ROUTE_MONITOR_PID" \
    --arg input "$DEFAULT_INPUT_UID" --arg output "$DEFAULT_OUTPUT_UID" \
    --arg system "$DEFAULT_SYSTEM_OUTPUT_UID" '
      select(
        .schema == "opensteamer.default-route-monitor.v1" and
        .phase == "monitoring" and .pid == $pid and
        .listenersInstalled == 3 and .listenersRemoved == false and
        .notificationCount == 0 and .clean == false and
        .baseline.defaultInputUID == $input and
        .baseline.defaultOutputUID == $output and
        .baseline.defaultSystemOutputUID == $system and
        .current == .baseline and (.heartbeat | type == "number")
      ) | .heartbeat
    ' "$AUDIO_ROUTE_MONITOR_STATUS") \
    || fail "CoreAudio route monitor reported a violation at ${prefix}"
  /bin/sleep 0.30
  second=$(jq -er --argjson pid "$AUDIO_ROUTE_MONITOR_PID" '
      select(
        .schema == "opensteamer.default-route-monitor.v1" and
        .phase == "monitoring" and .pid == $pid and
        .notificationCount == 0 and .current == .baseline and
        (.heartbeat | type == "number")
      ) | .heartbeat
    ' "$AUDIO_ROUTE_MONITOR_STATUS") \
    || fail "CoreAudio route monitor became unhealthy at ${prefix}"
  (( second > first )) \
    || fail "CoreAudio route monitor heartbeat stalled at ${prefix}"
}

function stop_audio_route_monitor_verified() {
  local monitor_status=0 attempt
  /usr/bin/touch "$AUDIO_ROUTE_MONITOR_STOP" \
    || fail 'CoreAudio route monitor stop request failed'
  for (( attempt = 0; attempt < 100; attempt++ )); do
    if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
        && jq -e '.phase == "stopped"' "$AUDIO_ROUTE_MONITOR_STATUS" \
          >/dev/null 2>&1; then
      break
    fi
    kill -0 "$AUDIO_ROUTE_MONITOR_PID" 2>/dev/null || break
    /bin/sleep 0.05
  done
  [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
    && jq -e '.phase == "stopped"' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null \
    || fail 'CoreAudio route monitor did not stop cleanly'
  if wait "$AUDIO_ROUTE_MONITOR_PID"; then
    monitor_status=0
  else
    monitor_status=$?
  fi
  AUDIO_ROUTE_MONITOR_PID=''
  (( monitor_status == 0 )) \
    || fail 'CoreAudio route monitor observed a route violation'
  jq -e --arg input "$DEFAULT_INPUT_UID" --arg output "$DEFAULT_OUTPUT_UID" \
    --arg system "$DEFAULT_SYSTEM_OUTPUT_UID" '
      .schema == "opensteamer.default-route-monitor.v1" and
      .phase == "stopped" and .listenersInstalled == 3 and
      .listenersRemoved == true and .notificationCount == 0 and .clean == true and
      .baseline.defaultInputUID == $input and
      .baseline.defaultOutputUID == $output and
      .baseline.defaultSystemOutputUID == $system and .current == .baseline
    ' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null \
    || fail 'CoreAudio route monitor teardown proof is invalid'
  AUDIO_ROUTE_MONITOR_PHASE=$(jq -er '.phase' "$AUDIO_ROUTE_MONITOR_STATUS")
  AUDIO_ROUTE_NOTIFICATION_COUNT=$(jq -er \
    '.notificationCount' "$AUDIO_ROUTE_MONITOR_STATUS")
}

STAGE=production-observer-preflight
require_no_production_observer
STAGE=audio-route-reader-build
compile_audio_route_reader \
  || fail 'read-only CoreAudio route reader failed to compile'
STAGE=challenge-build
swiftc -parse-as-library "$CHALLENGE_PROTOCOL_SOURCE" "$CHALLENGE_SOURCE" \
  -o "$CHALLENGE_BINARY" \
  > "${ARTIFACT_DIR}/challenge-build.log" 2>&1 \
  || fail 'visual challenge failed to compile'
STAGE=power-assertion-runtime-preflight
/usr/bin/env -i HOME="$HOME" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
  PATH='/usr/bin:/bin:/usr/sbin:/sbin' \
  "$IPHONE_CONTROL_PYTHON" -I -S -B "$POWER_ASSERTION_HELPER" --verify-runtime \
  > "${ARTIFACT_DIR}/power-assertion-runtime.log" 2>&1 \
  || fail 'verified iPhone power-assertion runtime is unavailable'
STAGE=current-source-build
build_current_development_test_products
STAGE=signed-product-sealing
prepare_signed_products
verify_prepared_products_unchanged before-device
STAGE=audio-route-monitor
capture_audio_routes before
start_audio_route_monitor
require_audio_route_monitor_healthy before-host-baseline
STAGE=host-preflight
capture_host_baseline
STAGE=locked-device-preflight
capture_device_identity before-unlock any

STAGE=unlock-gate-preparation
NONCE=$(openssl rand -hex 16) || fail 'failed to generate a fresh nonce'
[[ "$NONCE" =~ '^[0-9a-f]{32}$' ]] || fail 'invalid fresh nonce'
wait_for_exact_device_unlocked_state_acknowledgement

STAGE=live-device-power-assertion
start_device_power_assertion
capture_device_identity power-assertion-start unlocked
require_device_power_assertion_healthy after-unlock
require_no_production_observer
require_same_host
verify_prepared_products_unchanged after-unlock
capture_audio_routes after-unlock
require_audio_route_monitor_healthy after-unlock

STAGE=host-identity-before-challenge
require_same_host
verify_sealed_host_identity before-challenge

STAGE=challenge
OWNED_CHILD_PUBLICATION_PENDING=1
"$CHALLENGE_BINARY" "$CHALLENGE_HEARTBEAT" "$NONCE" \
  > "${ARTIFACT_DIR}/challenge.log" 2>&1 &
CHALLENGE_PID=$!
finish_owned_child_publication
for (( attempt = 0; attempt < 100; attempt++ )); do
  if [[ -s "$CHALLENGE_HEARTBEAT" ]] \
      && /usr/bin/grep -Fxq "nonce=${NONCE}" "$CHALLENGE_HEARTBEAT" \
      && /usr/bin/grep -Eq '^index=[0-3]$' "$CHALLENGE_HEARTBEAT" \
      && /usr/bin/grep -Eq '^counter=[0-9]+$' "$CHALLENGE_HEARTBEAT"; then
    break
  fi
  kill -0 "$CHALLENGE_PID" 2>/dev/null \
    || fail 'visual challenge exited before heartbeat'
  /bin/sleep 0.1
done
[[ -s "$CHALLENGE_HEARTBEAT" ]] \
  && /usr/bin/grep -Fxq "nonce=${NONCE}" "$CHALLENGE_HEARTBEAT" \
  || fail 'visual challenge heartbeat was not authenticated'

STAGE=dev-app-install
require_no_production_observer
require_same_host
require_device_power_assertion_healthy before-install
capture_audio_routes before-install
require_audio_route_monitor_healthy before-install
verify_prepared_products_unchanged before-install
xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "${PREPARED_PRODUCTS}/Debug-iphoneos/Beluga.app" \
  --timeout 60 --json-output "${ARTIFACT_DIR}/dev-app-install.json" \
  > "${ARTIFACT_DIR}/dev-app-install.stdout.log" 2>&1 \
  || fail 'current-source development app could not be installed on the iPhone 15'
jq -e '.info.outcome == "success"' "${ARTIFACT_DIR}/dev-app-install.json" \
  >/dev/null || fail 'development app install did not report success'
capture_installed_dev_app before-test

STAGE=dev-secret-preclean
run_device_secret_cleanup pre-mint-cleanup \
  || fail 'the inert development app could not prove stale secret cleanup before mint'
require_device_power_assertion_healthy after-pre-mint-cleanup
require_audio_route_monitor_healthy after-pre-mint-cleanup

STAGE=invitation-mint
require_no_production_observer
require_same_host
capture_host_generation_identity before-invitation-mint
capture_device_identity before-invitation-mint
require_device_power_assertion_healthy before-invitation-mint
capture_installed_dev_app before-invitation-mint
/usr/bin/cmp -s "${ARTIFACT_DIR}/before-test-dev-app.json" \
  "${ARTIFACT_DIR}/before-invitation-mint-dev-app.json" \
  || fail 'installed development app metadata changed before invitation mint'
capture_audio_routes before-invitation-mint
require_audio_route_monitor_healthy before-invitation-mint
verify_prepared_products_unchanged before-invitation-mint
require_no_host_lifecycle_delta before-invitation-mint-initial
capture_primary_continuity premint
capture_secondary_manager_idle_probe premint
require_no_host_lifecycle_delta before-invitation-mint-final
[[ -d "$ARTIFACT_DIR" && ! -L "$ARTIFACT_DIR" \
    && "$(/usr/bin/stat -f '%u' "$ARTIFACT_DIR")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$ARTIFACT_DIR")" == 700 \
    && ! -e "$INVITATION_SOURCE" && ! -L "$INVITATION_SOURCE" \
    && ! -e "$HOST_GENERATION_RECEIPT" \
    && ! -L "$HOST_GENERATION_RECEIPT" ]] \
  || fail 'private invitation or generation-receipt path is unsafe or already exists'
INVITATION_SOURCE_MINT_ATTEMPTED=1
typeset -i invitation_request_status=0
if run_sealed_host_management_child invitation-mint \
    "${ARTIFACT_DIR}/invitation-request.stdout.log" \
    "${ARTIFACT_DIR}/invitation-request.stderr.log" 0 \
    --request-secondary-test-viewer-invitation "$INVITATION_SOURCE"; then
  invitation_request_status=0
else
  invitation_request_status=$?
fi
(( invitation_request_status == 0 )) \
  || fail 'the running host did not mint a fresh secondary-viewer invitation'
[[ ! -s "${ARTIFACT_DIR}/invitation-request.stdout.log" \
    && ! -s "${ARTIFACT_DIR}/invitation-request.stderr.log" ]] \
  || fail 'the invitation client unexpectedly emitted process output'
require_same_host
capture_audio_routes after-invitation-mint
require_audio_route_monitor_healthy after-invitation-mint
validate_host_generation_receipt \
  || fail 'the renewable host did not persist an exact-generation cleanup receipt'
validate_invitation_source

STAGE=invitation-copy
require_no_production_observer
require_same_host
require_device_power_assertion_healthy before-invitation-copy
capture_audio_routes before-invitation-copy
require_audio_route_monitor_healthy before-invitation-copy
/usr/bin/cmp -s "$INVITATION_SOURCE" "$STAGED_INVITATION" \
  || fail 'secondary invitation changed before device copy'
DEVICE_SECRET_CLEANUP_REQUIRED=1
DEVICE_SECRET_CLEANUP_CONFIRMED=0
xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --source "$STAGED_INVITATION_DIR" \
  --destination . \
  --domain-type appDataContainer \
  --domain-identifier "$APP_BUNDLE_ID" \
  --timeout 30 --quiet \
  --json-output "${ARTIFACT_DIR}/invitation-copy.json" \
  > "${ARTIFACT_DIR}/invitation-copy.stdout.log" 2>&1 \
  || fail 'secondary invitation could not be copied to the development app container'
jq -e '.info.outcome == "success"' "${ARTIFACT_DIR}/invitation-copy.json" \
  >/dev/null || fail 'secondary invitation device copy did not report success'
INVITATION_COPIED=1
delete_invitation_source \
  || fail 'secondary invitation source remained on the Mac after device copy'
delete_staged_invitation \
  || fail 'staged secondary invitation remained on the Mac after device copy'

STAGE=physical-final-pixels
write_run_status observing
require_device_power_assertion_healthy before-test
verify_prepared_products_unchanged before-test
export TEST_RUNNER_OPENSTEAMER_SCREEN_ORACLE_NONCE="$NONCE"
export TEST_RUNNER_OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"
export TEST_RUNNER_OPENSTEAMER_DEV_COREDEVICE_ID="$DEVICE_ID"
export TEST_RUNNER_OPENSTEAMER_DEV_HARDWARE_UDID="$HARDWARE_UDID"
export TEST_RUNNER_OPENSTEAMER_DEV_SECONDARY_INVITATION_PRESEEDED=1
[[ -f "$XCTESTRUN_FILE" && ! -L "$XCTESTRUN_FILE" ]] \
  || fail 'prepared development UI-test xctestrun identity changed'
typeset -i test_status=0
OWNED_CHILD_PUBLICATION_PENDING=1
xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN_FILE" \
  -destination "platform=iOS,id=${HARDWARE_UDID}" \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 \
  "-only-testing:${TEST_ID}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  > "${ARTIFACT_DIR}/test.log" 2>&1 &
PHYSICAL_TEST_PID=$!
finish_owned_child_publication
[[ "$PHYSICAL_TEST_PID" != *[^0-9]* ]] \
  || fail 'physical iPhone test PID is invalid'
while owned_child_is_alive "$PHYSICAL_TEST_PID"; do
  if ! power_assertion_status_is_valid active; then
    stop_physical_test_process power-assertion-heartbeat-failure \
      || append_failure_reason \
        'physical test required forced termination after power-assertion failure'
    fail 'device power assertion became stale while the physical test was active'
  fi
  POWER_ASSERTION_PHASE=active
  POWER_ASSERTION_SEQUENCE=$(jq -er '.sequence' "$POWER_ASSERTION_HEARTBEAT") \
    || fail 'device power-assertion sequence disappeared during the physical test'
  /bin/sleep 0.50
done
if wait "$PHYSICAL_TEST_PID"; then
  test_status=0
else
  test_status=$?
fi
PHYSICAL_TEST_PID=''

capture_physical_test_result "$test_status"
STAGE=post-test-safety
require_no_production_observer
require_same_host
require_device_power_assertion_healthy after-test
capture_audio_routes after
require_audio_route_monitor_healthy after
verify_prepared_products_unchanged after-test
verify_device_secret_cleanup_receipt "$NONCE" viewer-import \
  || fail 'the development app did not prove nonce-bound seed deletion'
run_device_secret_cleanup post-test-cleanup \
  || fail 'the development app could not prove final secret cleanup'
require_device_power_assertion_healthy after-device-secret-cleanup
require_audio_route_monitor_healthy after-device-secret-cleanup
capture_device_identity after-device-secret-cleanup unlocked
capture_installed_dev_app after-test
/usr/bin/cmp -s "${ARTIFACT_DIR}/before-test-dev-app.json" \
  "${ARTIFACT_DIR}/after-test-dev-app.json" \
  || fail 'installed development app metadata changed during the physical test'
stop_device_power_assertion after-device-secret-cleanup \
  || fail 'exact-device power assertion did not stop cleanly after secret cleanup'
wait_for_host_delta
STAGE=secondary-generation-cleanup
stop_secondary_generation \
  || fail 'the exact secondary-viewer generation did not confirm teardown'
require_audio_route_monitor_healthy after-secondary-generation-cleanup
(( test_status == 0 )) \
  || fail "$PHYSICAL_TEST_FAILURE_REASON"

typeset -a visual_markers
visual_markers=("${(@f)$(rg -o \
  'OPENSTEAMER_IPHONE15_DEV_SCREEN_VISUAL_ORACLE_V1 nonce=[0-9a-f]{32} session=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} renderer=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} decodedSamples=[1-9][0-9]* maximumUndecodableRun=[0-3] maximumSameSymbolHold=[0-9]+\.[0-9]{2} symbols=[0-3](,[0-3])*' \
  "${ARTIFACT_DIR}/test.log" | /usr/bin/sort -u)}")
(( ${#visual_markers[@]} == 1 )) \
  || fail 'test output did not contain one unique iPhone 15 final-pixel marker'
VISUAL_MARKER=${visual_markers[1]}
[[ "$VISUAL_MARKER" == *" nonce=${NONCE} "* ]] \
  || fail 'iPhone 15 final-pixel evidence marker is not bound to this nonce'

STAGE=xcresult-proof
(( XCRESULT_SUMMARY_CAPTURED )) \
  || fail 'xcresult summary unavailable'
(( XCRESULT_TESTS_CAPTURED )) \
  || fail 'xcresult test result unavailable'
jq -e --arg udid "$HARDWARE_UDID" '
  (.result == "Passed") and (.totalTestCount == 1) and
  (.passedTests == 1) and (.failedTests == 0) and (.skippedTests == 0) and
  (.expectedFailures == 0) and ((.testFailures | length) == 0) and
  ([.devicesAndConfigurations[] | select(.device.deviceId == $udid and
    .passedTests == 1 and .failedTests == 0 and .skippedTests == 0)] | length == 1)
' "${ARTIFACT_DIR}/xcresult-summary.json" >/dev/null \
  || fail 'xcresult summary does not prove exactly one pass on the pinned iPhone 15'
jq -e --arg test "$TEST_NODE" '
  ([.. | objects | select(.nodeType? == "Test Case")] | length == 1) and
  ([.. | objects | select(.nodeType? == "Test Case")][0] |
    .nodeIdentifier == $test and .result == "Passed")
' "${ARTIFACT_DIR}/xcresult-tests.json" >/dev/null \
  || fail 'xcresult did not pass the exact iPhone 15 development oracle method'

STAGE=postflight
require_no_production_observer
require_same_host
verify_sealed_host_identity after-challenge
capture_audio_routes final
require_audio_route_monitor_healthy final
capture_primary_continuity after
capture_secondary_manager_idle_probe after
host_delta_is_complete \
  || fail 'final host lifecycle fence no longer proves the exact closed secondary presentation'
[[ -s "$CHALLENGE_HEARTBEAT" ]] \
  && /usr/bin/grep -Fxq "nonce=${NONCE}" "$CHALLENGE_HEARTBEAT" \
  && kill -0 "$CHALLENGE_PID" 2>/dev/null \
  || fail 'visual challenge stopped during the physical test'
(( DEVICE_SECRET_CLEANUP_REQUIRED == 0 \
    && DEVICE_SECRET_CLEANUP_CONFIRMED == 1 \
    && UNLOCK_ACK_VALIDATED == 1 \
    && POWER_ASSERTION_STOPPED == 1 \
    && HOST_GENERATION_STOPPED == 1 )) \
  || fail 'unlock, keep-awake, secret, or exact generation cleanup proof is incomplete'
STAGE=audio-route-monitor-teardown
stop_audio_route_monitor_verified
VERIFIED=1
STAGE=complete
