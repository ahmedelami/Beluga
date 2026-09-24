#!/bin/zsh

# Run the one final-pixel oracle on an already installed production-bundle candidate by observing
# an already-connected user session. Device metadata proves the exact bundle/build identity, not
# TestFlight receipt provenance; App Store Connect/TestFlight must establish that separately.
# Usage: validate-testflight-screen-visual-oracle.sh COREDEVICE_ID HARDWARE_UDID BUILD
#
# This driver never installs, launches, connects, disconnects, or terminates the production
# app, restarts the Mac host, or changes an audio route. The user must connect normally first
# and leave its Mac screen already visible in the foreground. The UI test only reads that existing
# app's accessibility state and final-composite screenshots; it never changes app lifecycle or UI.
# Xcode's Debug dependency has a separate .dev bundle identifier. Signed build products use an
# incremental T7 cache so compilation happens outside the short unlocked-screen observation gate.
# Set OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS as high as 604800 to arm one observer for up to
# a week; it will remain entirely passive until the user naturally has this exact app, build, and
# Mac screen visible. Every run still writes private evidence and fails unless identity, session
# continuity, route preservation, and final pixels are all proven.
# OPENSTEAMER_SCREEN_ORACLE_SELF_TEST is reserved for the hardcoded non-device signal harness;
# ordinary and armed production runs must leave it unset.
set -euo pipefail
umask 077

readonly APP_BUNDLE_ID=com.elamin.opensteamer
readonly DEBUG_APP_BUNDLE_ID=org.example.AudioStreamer.dev
readonly DEBUG_RUNNER_BUNDLE_ID=org.example.AudioStreamerUITests.xctrunner
readonly DEVELOPMENT_TEAM_ID=MSMG8CJLB3
readonly PRODUCTION_DEVICE_ID=7694F11E-D66D-5632-9A0D-462C980130A5
readonly PRODUCTION_HARDWARE_UDID=00008150-0002581C3E3A401C
readonly PRODUCTION_DEVICE_MODEL_NAME='iPhone 17 Pro'
readonly HOST_SERVICE="gui/${UID}/org.example.opensteamer.worldwide"
readonly HOST_APP='/Applications/opensteamer Host.app'
readonly HOST_EXECUTABLE='/Applications/opensteamer Host.app/Contents/MacOS/CaptureServer'
readonly HOST_MEDIA_FRAMEWORK_EXECUTABLE='/Applications/opensteamer Host.app/Contents/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC'
readonly HOST_LOG=/var/tmp/opensteamer-worldwide-host.log
readonly SCRIPT_DIR=${0:A:h}
readonly PROJECT_DIR=${SCRIPT_DIR:h}
readonly REPOSITORY_ROOT=${PROJECT_DIR:h:h}
readonly SEALED_HOST_IDENTITY_VERIFIER="${REPOSITORY_ROOT}/macOS/scripts/verify-sealed-live-mac-host-identity.sh"
readonly HOST_IDENTITY_MANIFEST=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST:-}
readonly HOST_IDENTITY_MANIFEST_SHA256_PATH=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH:-}
readonly HOST_IDENTITY_MANIFEST_SHA256=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256:-}
readonly CHALLENGE_SOURCE="${SCRIPT_DIR}/physical-screen-sequence-challenge.swift"
readonly CHALLENGE_PROTOCOL_SOURCE="${PROJECT_DIR}/OracleTestSupport/PhysicalScreenSequenceProtocol.swift"
readonly UI_TEST_SOURCE="${PROJECT_DIR}/UITests/ScreenVisualOraclePhysicalUITests.swift"
readonly TEST_ID='opensteamerUITests/ScreenVisualOraclePhysicalUITests/testInstalledProductionBundleFinalPixelsTrackFreshMacChallenge'
readonly TEST_NODE='ScreenVisualOraclePhysicalUITests/testInstalledProductionBundleFinalPixelsTrackFreshMacChallenge()'
readonly DERIVED_DATA=/Volumes/t7/opensteamer-screen-oracle-device-prebuild
readonly PRODUCTION_RUN_STATE_ROOT=/Volumes/t7/opensteamer-screen-oracle-state
readonly PRODUCTION_ARTIFACT_ROOT=/Volumes/t7
readonly SELF_TEST_MODE=${OPENSTEAMER_SCREEN_ORACLE_SELF_TEST:-}
readonly SELF_TEST_ROOT_INPUT=${OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT:-}
readonly SELF_TEST_DEVICE_ID=00000000-0000-4000-8000-000000000000
readonly SELF_TEST_HARDWARE_UDID=00000000-0000000000000000
readonly SELF_TEST_BUILD=0

if (( $# != 3 )) \
    || [[ ! "$1" =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] \
    || [[ -z "$2" || "$2" == *[^0-9A-Fa-f-]* ]] \
    || [[ -z "$3" || "$3" == *[^0-9]* ]]; then
  print -u2 -- "usage: $0 COREDEVICE_ID HARDWARE_UDID EXPECTED_TESTFLIGHT_BUILD"
  exit 2
fi
readonly DEVICE_ID=$1
readonly HARDWARE_UDID=$2
readonly EXPECTED_BUILD=$3
if [[ -n "$SELF_TEST_MODE" \
    && "$SELF_TEST_MODE" != signal-cleanup \
    && "$SELF_TEST_MODE" != signal-no-monitor \
    && "$SELF_TEST_MODE" != forced-challenge-cleanup \
    && "$SELF_TEST_MODE" != final-status-failure ]]; then
  print -u2 -- "Unsupported OPENSTEAMER_SCREEN_ORACLE_SELF_TEST: ${SELF_TEST_MODE}"
  exit 2
fi
if [[ -n "$SELF_TEST_MODE" ]] \
    && [[ "$DEVICE_ID" != "$SELF_TEST_DEVICE_ID" \
      || "$HARDWARE_UDID" != "$SELF_TEST_HARDWARE_UDID" \
      || "$EXPECTED_BUILD" != "$SELF_TEST_BUILD" ]]; then
  print -u2 -- 'Visual-oracle self-test requires its reserved non-device identity.'
  exit 2
fi
if [[ -z "$SELF_TEST_MODE" ]] \
    && [[ "$DEVICE_ID" != "$PRODUCTION_DEVICE_ID" \
      || "$HARDWARE_UDID" != "$PRODUCTION_HARDWARE_UDID" ]]; then
  print -u2 -- \
    'Production visual oracle requires the exact pinned iPhone 17 Pro CoreDevice and hardware UDID.'
  exit 2
fi
if [[ -z "$SELF_TEST_MODE" ]]; then
  if [[ -z "$HOST_IDENTITY_MANIFEST" \
      || -z "$HOST_IDENTITY_MANIFEST_SHA256" \
      || "$HOST_IDENTITY_MANIFEST_SHA256_PATH" != "${HOST_IDENTITY_MANIFEST}.sha256" \
      || ! "$HOST_IDENTITY_MANIFEST_SHA256" =~ '^[0-9a-f]{64}$' \
      || ! -f "$HOST_IDENTITY_MANIFEST" || -L "$HOST_IDENTITY_MANIFEST" \
      || ! -f "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
      || -L "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
      || ! -f "$SEALED_HOST_IDENTITY_VERIFIER" \
      || -L "$SEALED_HOST_IDENTITY_VERIFIER" ]]; then
    print -u2 -- \
      'A release-sealed Mac host identity manifest, committed SHA-256 sidecar, and external SHA-256 are required.'
    exit 2
  fi
fi
typeset RUN_STATE_ROOT ARTIFACT_PARENT
if [[ -n "$SELF_TEST_MODE" ]]; then
  if [[ -z "$SELF_TEST_ROOT_INPUT" || "$SELF_TEST_ROOT_INPUT" != /* \
      || "${SELF_TEST_ROOT_INPUT:A}" != "$SELF_TEST_ROOT_INPUT" \
      || ! -d "$SELF_TEST_ROOT_INPUT" || -L "$SELF_TEST_ROOT_INPUT" ]]; then
    print -u2 -- 'Visual-oracle self-test root must be an existing canonical directory.'
    exit 2
  fi
  typeset self_test_root_owner self_test_root_mode
  self_test_root_owner=$(/usr/bin/stat -f '%u' "$SELF_TEST_ROOT_INPUT")
  self_test_root_mode=$(/usr/bin/stat -f '%Lp' "$SELF_TEST_ROOT_INPUT")
  if [[ "$self_test_root_owner" != "$EUID" || "$self_test_root_mode" != 700 ]]; then
    print -u2 -- 'Visual-oracle self-test root must be owner-only with mode 0700.'
    exit 2
  fi
  RUN_STATE_ROOT="${SELF_TEST_ROOT_INPUT}/state"
  ARTIFACT_PARENT=$SELF_TEST_ROOT_INPUT
else
  if [[ -n "$SELF_TEST_ROOT_INPUT" ]]; then
    print -u2 -- 'OPENSTEAMER_SCREEN_ORACLE_SELF_TEST_ROOT is self-test-only.'
    exit 2
  fi
  RUN_STATE_ROOT=$PRODUCTION_RUN_STATE_ROOT
  ARTIFACT_PARENT=$PRODUCTION_ARTIFACT_ROOT
fi
readonly RUN_STATE_ROOT ARTIFACT_PARENT
readonly LIVE_GATE_WAIT_SECONDS=${OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS:-600}
if [[ -z "$LIVE_GATE_WAIT_SECONDS" || "$LIVE_GATE_WAIT_SECONDS" == *[^0-9]* \
    || "$LIVE_GATE_WAIT_SECONDS" == 0 \
    || "$LIVE_GATE_WAIT_SECONDS" -gt 604800 ]]; then
  print -u2 -- \
    'OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS must be 1...604800.'
  exit 2
fi

# Hold one nonblocking kernel lock for this physical device/app across preparation, waiting, and
# observation. The shell retains the locked file descriptor for its full lifetime, so direct calls
# and automation races can never queue or create a second runner.
if [[ ! -d "$ARTIFACT_PARENT" || -L "$ARTIFACT_PARENT" ]]; then
  print -u2 -- 'Visual-oracle artifact root is unavailable.'
  exit 2
fi
if [[ -e "$RUN_STATE_ROOT" && ( ! -d "$RUN_STATE_ROOT" || -L "$RUN_STATE_ROOT" ) ]]; then
  print -u2 -- 'Visual-oracle state root is unsafe.'
  exit 2
fi
/bin/mkdir -p -m 700 "$RUN_STATE_ROOT"
/bin/chmod 700 "$RUN_STATE_ROOT"
# One production app on one physical device can have only one trustworthy observation owner,
# regardless of which build a racing caller expects.
readonly RUN_KEY="${DEVICE_ID}-${APP_BUNDLE_ID}"
readonly RUN_LOCK_FILE="${RUN_STATE_ROOT}/${RUN_KEY}.lock"
readonly RUN_STATUS="${RUN_STATE_ROOT}/${RUN_KEY}.json"
if [[ -e "$RUN_LOCK_FILE" && ( ! -f "$RUN_LOCK_FILE" || -L "$RUN_LOCK_FILE" ) ]]; then
  print -u2 -- 'Visual-oracle lock file is unsafe.'
  exit 2
fi
if [[ -e "$RUN_STATUS" && ( ! -f "$RUN_STATUS" || -L "$RUN_STATUS" ) ]]; then
  print -u2 -- 'Visual-oracle status file is unsafe.'
  exit 2
fi
/usr/bin/touch "$RUN_LOCK_FILE"
/bin/chmod 600 "$RUN_LOCK_FILE"
typeset -gi RUN_LOCK_FD
exec {RUN_LOCK_FD}>>"$RUN_LOCK_FILE"
if ! /usr/bin/lockf -s -t 0 "$RUN_LOCK_FD"; then
  print -u2 -- "A screen visual oracle is already active for ${DEVICE_ID} ${APP_BUNDLE_ID}."
  exit 75
fi
readonly RUN_LOCK_FD

for tool in xcrun xcodebuild swiftc jq rg openssl launchctl ps cmp plutil codesign lockf ditto shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 -- "Missing required tool: $tool"
    exit 2
  fi
done
if [[ ! -d "$ARTIFACT_PARENT" || -L "$ARTIFACT_PARENT" \
    || ! -f "$CHALLENGE_SOURCE" || ! -f "$CHALLENGE_PROTOCOL_SOURCE" \
    || ! -f "$UI_TEST_SOURCE" \
    || ( -z "$SELF_TEST_MODE" && -e "$DERIVED_DATA" \
      && ( ! -d "$DERIVED_DATA" || -L "$DERIVED_DATA" ) ) ]]; then
  print -u2 -- 'T7 or the versioned visual challenge source is unavailable.'
  exit 2
fi
readonly ARTIFACT_DIR=$(/usr/bin/mktemp -d \
  "${ARTIFACT_PARENT}/opensteamer-screen-visual-oracle.XXXXXX")
readonly SUMMARY="${ARTIFACT_DIR}/summary.json"
readonly RESULT_BUNDLE="${ARTIFACT_DIR}/screen-visual-oracle.xcresult"
readonly CHALLENGE_BINARY="${ARTIFACT_DIR}/screen-visual-challenge"
readonly CHALLENGE_HEARTBEAT="${ARTIFACT_DIR}/challenge-heartbeat.txt"
readonly AUDIO_ROUTE_READER="${ARTIFACT_DIR}/coreaudio-default-route-reader"
readonly AUDIO_ROUTE_MONITOR_STATUS="${ARTIFACT_DIR}/audio-route-monitor-status.json"
readonly AUDIO_ROUTE_MONITOR_STOP="${ARTIFACT_DIR}/audio-route-monitor.stop"
readonly HOST_IDENTITY_BEFORE_CHALLENGE="${ARTIFACT_DIR}/host-identity-before-challenge.txt"
readonly PREPARED_PRODUCTS="${ARTIFACT_DIR}/prepared-test-products"
readonly PREPARED_PRODUCTS_MANIFEST="${ARTIFACT_DIR}/prepared-test-products.sha256"
readonly RUN_STARTED_AT=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
readonly RUN_EXPIRES_AT=$(/bin/date -u -v+"${LIVE_GATE_WAIT_SECONDS}"S \
  '+%Y-%m-%dT%H:%M:%SZ')
readonly RUN_DEADLINE_SECONDS=$(( SECONDS + LIVE_GATE_WAIT_SECONDS ))
typeset -g STAGE=preflight
typeset -g FAILURE_REASON=''
typeset -g CHALLENGE_PID=''
typeset -g AUDIO_ROUTE_MONITOR_PID=''
typeset -g AUDIO_ROUTE_MONITOR_PHASE=''
typeset -g AUDIO_ROUTE_NOTIFICATION_COUNT=''
typeset -g HOST_PID=''
typeset -g CONNECTED_PEER_PID=''
typeset -g CONNECTED_EVENT_COUNT=''
typeset -g CAPTURE_START_COUNT=''
typeset -g CAPTURE_STOP_COUNT=''
typeset -g CAPTURE_LOG_LINE=''
typeset -g DEFAULT_INPUT_UID=''
typeset -g DEFAULT_OUTPUT_UID=''
typeset -g DEFAULT_SYSTEM_OUTPUT_UID=''
typeset -g NONCE=''
typeset -g VISUAL_MARKER=''
typeset -g LIVE_GATE_REASON='preparing'
typeset -g SIGNAL_NAME=''
typeset -g PENDING_SIGNAL_NAME=''
typeset -gi PENDING_SIGNAL_STATUS=0
typeset -gi OWNED_CHILD_PUBLICATION_PENDING=0
typeset -g MINIMUM_CAPTURE_START_COUNT=0
typeset -g VERIFIED=0
typeset -gi FINISHING=0

function write_run_status() {
  local phase=$1
  local reason=${2:-}
  local updated_at temporary_status
  if [[ "$SELF_TEST_MODE" == final-status-failure && "$phase" == passed ]]; then
    return 1
  fi
  updated_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
  temporary_status=$(/usr/bin/mktemp "${RUN_STATUS}.tmp.XXXXXX")
  jq -n \
    --arg schema 'opensteamer.screen-visual-oracle-run.v1' \
    --arg phase "$phase" \
    --arg pid "$$" \
    --arg startedAt "$RUN_STARTED_AT" \
    --arg expiresAt "$RUN_EXPIRES_AT" \
    --arg updatedAt "$updated_at" \
    --arg stage "$STAGE" \
    --arg reason "$reason" \
    --arg deviceId "$DEVICE_ID" \
    --arg hardwareUDID "$HARDWARE_UDID" \
    --arg deviceModelName "$PRODUCTION_DEVICE_MODEL_NAME" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg build "$EXPECTED_BUILD" \
    --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" \
    --arg hostIdentityBeforeChallenge "$HOST_IDENTITY_BEFORE_CHALLENGE" \
    --arg artifactDir "$ARTIFACT_DIR" \
    --arg summary "$SUMMARY" \
    '{schema:$schema,phase:$phase,pid:($pid | tonumber),
      startedAt:$startedAt,expiresAt:$expiresAt,updatedAt:$updatedAt,
      stage:$stage,reason:$reason,
      deviceId:$deviceId,hardwareUDID:$hardwareUDID,
      deviceModelName:$deviceModelName,bundleId:$bundleId,build:$build,
      hostIdentityManifestSHA256Path:$hostIdentityManifestSHA256Path,
      hostIdentityManifestSHA256:$hostIdentityManifestSHA256,
      hostIdentityBeforeChallenge:$hostIdentityBeforeChallenge,
      artifactDir:$artifactDir,summary:$summary}' > "$temporary_status"
  /bin/chmod 600 "$temporary_status"
  /bin/mv "$temporary_status" "$RUN_STATUS"
}

function fail() {
  FAILURE_REASON=$1
  print -u2 -- "Screen visual oracle: ${FAILURE_REASON} (artifacts: ${ARTIFACT_DIR})"
  exit 1
}

function append_failure_reason() {
  local reason=$1
  if [[ -n "$FAILURE_REASON" ]]; then
    FAILURE_REASON="${FAILURE_REASON}; ${reason}"
  else
    FAILURE_REASON=$reason
  fi
}

function owned_child_is_alive() {
  local child_pid=$1
  local parent_pid
  kill -0 "$child_pid" 2>/dev/null || return 1
  # A waitable zombie is already stopped and must be reaped, not mistaken for a sticky process
  # and escalated to SIGKILL. The PPID check also prevents signaling a recycled unrelated PID.
  parent_pid=$(ps -p "$child_pid" -o ppid=,state= 2>/dev/null \
    | /usr/bin/awk '$2 !~ /^Z/ { print $1; exit }') || return 1
  [[ "$parent_pid" == "$$" ]]
}

function finish() {
  local prior_status=$?
  local result=${1:-$prior_status}
  if (( FINISHING != 0 )); then
    return
  fi
  FINISHING=1
  # A second ordinary termination signal must not cut through teardown and leave a stale active
  # status or sticky CoreAudio listener. SIGKILL remains intentionally outside shell control.
  trap - EXIT
  trap '' HUP INT TERM
  local monitor_was_active=0
  local monitor_teardown_clean=1
  local child_attempt
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
        monitor_teardown_clean=0
        result=1
      fi
    else
      append_failure_reason 'visual challenge was not live at finalizer entry'
      monitor_teardown_clean=0
      result=1
    fi
    wait "$CHALLENGE_PID" 2>/dev/null || true
  fi
  if [[ -n "$AUDIO_ROUTE_MONITOR_PID" ]]; then
    local monitor_pid=$AUDIO_ROUTE_MONITOR_PID
    local monitor_wait_status=0
    local monitor_forced=0
    monitor_was_active=1
    /usr/bin/touch "$AUDIO_ROUTE_MONITOR_STOP" 2>/dev/null || true
    for (( monitor_attempt = 0; monitor_attempt < 100; monitor_attempt++ )); do
      if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
          && jq -e '.phase == "stopped"' \
            "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; then
        break
      fi
      owned_child_is_alive "$monitor_pid" || break
      /bin/sleep 0.05
    done
    if owned_child_is_alive "$monitor_pid" \
        && ! jq -e '.phase == "stopped"' \
          "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; then
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
      .listenersRemoved == true and .notificationCount == 0 and
      .clean == true and
      (.baseline.defaultInputUID | type == "string" and length > 0) and
      (.baseline.defaultOutputUID | type == "string" and length > 0) and
      (.baseline.defaultSystemOutputUID | type == "string" and length > 0) and
      .current == .baseline
  ' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; }; then
    monitor_teardown_clean=0
    result=1
    append_failure_reason \
      'CoreAudio route monitor finalizer teardown was not clean with zero notifications'
  fi
  local verdict=failed
  local run_phase=failed
  if (( result == 0 && VERIFIED == 1 && monitor_teardown_clean == 1 )); then
    verdict=passed
    run_phase=passed
  elif [[ -n "$SIGNAL_NAME" ]] && (( monitor_teardown_clean == 1 )); then
    # An operator-stopped passive observer is parked, not a product-oracle failure. It remains
    # nonzero and unverified, and only a fresh physical run can ever produce `passed`.
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
    --arg schema 'opensteamer.screen-visual-oracle.v1' \
    --arg status "$verdict" \
    --arg stage "$STAGE" \
    --arg reason "$FAILURE_REASON" \
    --arg signal "$SIGNAL_NAME" \
    --arg deviceId "$DEVICE_ID" \
    --arg hardwareUDID "$HARDWARE_UDID" \
    --arg deviceModelName "$PRODUCTION_DEVICE_MODEL_NAME" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg build "$EXPECTED_BUILD" \
    --arg distributionProvenance 'unverified-by-device-metadata' \
    --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" \
    --arg hostIdentityBeforeChallenge "$HOST_IDENTITY_BEFORE_CHALLENGE" \
    --arg hostPid "$HOST_PID" \
    --arg connectedPeerPid "$CONNECTED_PEER_PID" \
    --arg connectedEventCount "$CONNECTED_EVENT_COUNT" \
    --arg captureStartCount "$CAPTURE_START_COUNT" \
    --arg captureStopCount "$CAPTURE_STOP_COUNT" \
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
    '{schema:$schema,status:$status,stage:$stage,reason:$reason,signal:$signal,
      deviceId:$deviceId,hardwareUDID:$hardwareUDID,
      deviceModelName:$deviceModelName,bundleId:$bundleId,
      build:$build,distributionProvenance:$distributionProvenance,
      hostIdentityManifestSHA256Path:$hostIdentityManifestSHA256Path,
      hostIdentityManifestSHA256:$hostIdentityManifestSHA256,
      hostIdentityBeforeChallenge:$hostIdentityBeforeChallenge,
      hostPid:$hostPid,connectedPeerPid:$connectedPeerPid,
      connectedEventCount:$connectedEventCount,
      captureStartCount:$captureStartCount,captureStopCount:$captureStopCount,
      defaultInputUID:$defaultInputUID,defaultOutputUID:$defaultOutputUID,
      defaultSystemOutputUID:$defaultSystemOutputUID,
      audioRouteMonitorPhase:$audioRouteMonitorPhase,
      audioRouteNotificationCount:$audioRouteNotificationCount,
      audioRouteMonitorStatus:$audioRouteMonitorStatus,
      nonce:$nonce,visualMarker:$visualMarker,testId:$testId,
      resultBundle:$resultBundle}' > "${SUMMARY}.tmp"; then
    summary_staged=1
  else
    /bin/rm -f "${SUMMARY}.tmp"
    result=1
    verdict=failed
    run_phase=failed
    FAILURE_REASON=${FAILURE_REASON:-"verified run could not persist its summary"}
    print -u2 -- \
      "Screen visual oracle failed: could not write verified summary at ${SUMMARY}"
  fi

  # A passing summary and success line are not published until the atomic run-status update has
  # committed `phase=passed`. If that final commit fails, rewrite the private staged summary as a
  # failure before publishing it and leave no pass-bearing artifact behind.
  if [[ "$verdict" == passed && "$summary_staged" == 1 ]]; then
    if write_run_status passed "$FAILURE_REASON"; then
      if /bin/mv "${SUMMARY}.tmp" "$SUMMARY"; then
        print -- "Screen visual oracle passed: ${SUMMARY}"
      else
        result=1
        verdict=failed
        run_phase=failed
        append_failure_reason 'verified run status committed but its passing summary could not be published'
        /bin/rm -f "${SUMMARY}.tmp"
        write_run_status failed "$FAILURE_REASON" >/dev/null 2>&1 || true
        print -u2 -- \
          "Screen visual oracle failed: could not publish ${SUMMARY}"
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
        print -u2 -- "Screen visual oracle failed: ${SUMMARY}"
      else
        /bin/rm -f "${SUMMARY}.tmp" "${SUMMARY}.failed.tmp"
      fi
      if ! write_run_status failed "$FAILURE_REASON"; then
        print -u2 -- "Screen visual oracle failed: could not update ${RUN_STATUS}"
      fi
    fi
  else
    if (( summary_staged )); then
      if /bin/mv "${SUMMARY}.tmp" "$SUMMARY"; then
        print -- "Screen visual oracle ${verdict}: ${SUMMARY}"
      else
        result=1
        verdict=failed
        run_phase=failed
        append_failure_reason 'run summary could not be published'
        /bin/rm -f "${SUMMARY}.tmp"
        print -u2 -- "Screen visual oracle failed: could not publish ${SUMMARY}"
      fi
    fi
    if ! write_run_status "$run_phase" "$FAILURE_REASON"; then
      result=1
      print -u2 -- "Screen visual oracle failed: could not update ${RUN_STATUS}"
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
  # Call the complete finalizer directly. Relying on zsh to run a second EXIT trap after `exit`
  # from a signal trap left an armed status behind in the real detached-screen runner.
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

function require_observer_only_ui_test_source() {
  local forbidden='\.(launch|activate|tap|press|swipeDown|swipeUp|swipeLeft|swipeRight|terminate|typeText|typeKey)\(|XCUIDevice|coordinate\(withNormalizedOffset:'
  if rg -n "$forbidden" "$UI_TEST_SOURCE" \
      > "${ARTIFACT_DIR}/forbidden-ui-mutation.txt"; then
    fail 'screen visual UI test contains a production-app/device mutation API'
  fi
  : > "${ARTIFACT_DIR}/forbidden-ui-mutation.txt"
}

function capture_device_state() {
  local prefix=$1
  local lock_requirement=${2:-unlocked}
  [[ "$lock_requirement" == unlocked || "$lock_requirement" == any ]] \
    || fail "invalid lock requirement at ${prefix}"
  local details="${ARTIFACT_DIR}/${prefix}-device.json"
  local lock="${ARTIFACT_DIR}/${prefix}-lock.json"
  local apps="${ARTIFACT_DIR}/${prefix}-apps.json"
  xcrun devicectl device info details \
    --device "$PRODUCTION_DEVICE_ID" --timeout 20 --json-output "$details" >/dev/null \
    || fail "CoreDevice details unavailable at ${prefix}"
  jq -e --arg device "$PRODUCTION_DEVICE_ID" \
    --arg udid "$PRODUCTION_HARDWARE_UDID" \
    --arg model "$PRODUCTION_DEVICE_MODEL_NAME" '
    (.info.outcome == "success") and (.result.identifier == $device) and
    (.result.hardwareProperties.udid == $udid) and
    (.result.hardwareProperties.platform == "iOS") and
    (.result.hardwareProperties.reality == "physical") and
    (.result.hardwareProperties.marketingName == $model) and
    (.result.deviceProperties.bootState == "booted") and
    (.result.connectionProperties.pairingState == "paired")
  ' "$details" >/dev/null || fail "wrong or unavailable physical iPhone at ${prefix}"

  xcrun devicectl device info lockState \
    --device "$PRODUCTION_DEVICE_ID" --timeout 20 --json-output "$lock" >/dev/null \
    || fail "iPhone lock state unavailable at ${prefix}"
  jq -e '(.info.outcome == "success") and (.result.passcodeRequired | type == "boolean")' \
    "$lock" >/dev/null || fail "iPhone lock state is malformed at ${prefix}"
  if [[ "$lock_requirement" == unlocked ]]; then
    jq -e '.result.passcodeRequired == false' "$lock" >/dev/null \
      || fail "iPhone requires an unlock at ${prefix}"
  fi

  xcrun devicectl device info apps \
    --device "$PRODUCTION_DEVICE_ID" --include-all-apps --bundle-id "$APP_BUNDLE_ID" \
    --timeout 30 --json-output "$apps" >/dev/null \
    || fail "installed app metadata unavailable at ${prefix}"
  jq -e --arg bundle "$APP_BUNDLE_ID" --arg build "$EXPECTED_BUILD" '
    (.info.outcome == "success") and
    ([.result.apps[] | select(.bundleIdentifier == $bundle)] | length == 1) and
    ([.result.apps[] | select(.bundleIdentifier == $bundle)][0] |
      .bundleVersion == $build and .name == "Beluga" and
      .appClip == false and .internalApp == false and .removable == true)
  ' "$apps" >/dev/null || fail "expected installed production bundle/build missing at ${prefix}"
  jq -S --arg bundle "$APP_BUNDLE_ID" \
    '[.result.apps[] | select(.bundleIdentifier == $bundle)][0]' "$apps" \
    > "${ARTIFACT_DIR}/${prefix}-candidate.json"
}

function require_device_unlocked() {
  local prefix=$1
  local lock="${ARTIFACT_DIR}/${prefix}-lock.json"
  xcrun devicectl device info lockState \
    --device "$PRODUCTION_DEVICE_ID" --timeout 20 --json-output "$lock" >/dev/null \
    || fail "iPhone lock state unavailable at ${prefix}"
  jq -e '(.info.outcome == "success") and (.result.passcodeRequired == false)' \
    "$lock" >/dev/null || fail "iPhone requires an unlock at ${prefix}"
}

function current_host_pid() {
  launchctl print "$HOST_SERVICE" 2>/dev/null \
    | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

function require_same_host() {
  local actual_pid
  actual_pid=$(current_host_pid) || fail 'Mac host launch agent is unavailable'
  [[ -n "$actual_pid" && "$actual_pid" != *[^0-9]* ]] \
    || fail 'Mac host PID cannot be verified'
  if [[ -z "$HOST_PID" ]]; then HOST_PID=$actual_pid; fi
  [[ "$actual_pid" == "$HOST_PID" ]] || fail 'Mac host changed during visual validation'
  local executable
  executable=$(ps -p "$HOST_PID" -o comm= 2>/dev/null) \
    || fail 'Mac host process is unavailable'
  [[ "$executable" == "$HOST_EXECUTABLE" ]] \
    || fail 'Mac host executable identity is unexpected'
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
  if [[ "$prefix" == before-challenge ]]; then
    /bin/cp "$snapshot" "$HOST_IDENTITY_BEFORE_CHALLENGE" \
      || fail 'sealed Mac host identity baseline could not be retained'
    /bin/chmod 600 "$HOST_IDENTITY_BEFORE_CHALLENGE"
  else
    [[ -f "$HOST_IDENTITY_BEFORE_CHALLENGE" \
        && ! -L "$HOST_IDENTITY_BEFORE_CHALLENGE" ]] \
      && /usr/bin/cmp -s "$HOST_IDENTITY_BEFORE_CHALLENGE" "$snapshot" \
      || fail "sealed Mac host identity changed after challenge launch at ${prefix}"
  fi
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
    try encodedJSON(value).write(
        to: URL(fileURLWithPath: path),
        options: [.atomic]
    )
}

private func monitor(statusPath: String, stopPath: String) throws {
    // Detached shells and interactive terminals can deliver HUP/INT/TERM to their entire process
    // group. Keep the listener outside the runner's group so the runner alone owns the bounded,
    // evidence-producing stop-file teardown. If already a group leader, it is already isolated.
    if getpgrp() != getpid(), setsid() == -1 {
        throw ReaderFailure.signalIsolation
    }
    let ownerPID = getppid()
    let system = AudioObjectID(kAudioObjectSystemObject)
    let queue = DispatchQueue(
        label: "opensteamer.screen-oracle.default-route-monitor"
    )
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
                    phase: "startup-failed",
                    pid: getpid(),
                    heartbeat: 0,
                    listenersInstalled: installed.count,
                    listenersRemoved: removalSucceeded,
                    notificationCount: observed.count,
                    firstSelectors: observed.selectors,
                    baseline: nil,
                    current: try? routes(),
                    clean: false
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
                phase: "startup-unstable",
                pid: getpid(),
                heartbeat: 0,
                listenersInstalled: installed.count,
                listenersRemoved: removalSucceeded,
                notificationCount: observed.count,
                firstSelectors: observed.selectors,
                baseline: baseline1,
                current: try? routes(),
                clean: false
            ),
            to: statusPath
        )
        Darwin.exit(71)
    }

    var heartbeat: UInt64 = 0
    // If the shell suffers an untrappable exit, do not leave detached CoreAudio listeners behind.
    while !FileManager.default.fileExists(atPath: stopPath), getppid() == ownerPID {
        heartbeat &+= 1
        let current = try? routes()
        if current != baseline1 {
            state.recordReadFailureOrMismatch()
        }
        let observed = state.snapshot()
        try writeStatus(
            MonitorStatus(
                schema: "opensteamer.default-route-monitor.v1",
                phase: observed.count == 0 ? "monitoring" : "violated",
                pid: getpid(),
                heartbeat: heartbeat,
                listenersInstalled: installed.count,
                listenersRemoved: false,
                notificationCount: observed.count,
                firstSelectors: observed.selectors,
                baseline: baseline1,
                current: current,
                clean: false
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
    let clean = removalSucceeded
        && finalState.count == 0
        && beforeRemoval == baseline1
        && afterRemoval == baseline1
    try writeStatus(
        MonitorStatus(
            schema: "opensteamer.default-route-monitor.v1",
            phase: "stopped",
            pid: getpid(),
            heartbeat: heartbeat,
            listenersInstalled: installed.count,
            listenersRemoved: removalSucceeded,
            notificationCount: finalState.count,
            firstSelectors: finalState.selectors,
            baseline: baseline1,
            current: afterRemoval,
            clean: clean
        ),
        to: statusPath
    )
    if !clean {
        Darwin.exit(1)
    }
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
      || fail "CoreAudio default input/output/system-output route changed at ${prefix}"
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

  for (( monitor_attempt = 0; monitor_attempt < 100; monitor_attempt++ )); do
    if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
        && jq -e --argjson pid "$AUDIO_ROUTE_MONITOR_PID" '
          .schema == "opensteamer.default-route-monitor.v1" and
          .phase == "monitoring" and .pid == $pid and
          .listenersInstalled == 3 and .listenersRemoved == false and
          .notificationCount == 0 and .clean == false and
          (.heartbeat | type == "number" and . >= 1) and
          (.baseline.defaultInputUID | type == "string" and length > 0) and
          (.baseline.defaultOutputUID | type == "string" and length > 0) and
          (.baseline.defaultSystemOutputUID | type == "string" and length > 0) and
          .current == .baseline
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
  local first_heartbeat second_heartbeat
  kill -0 "$AUDIO_ROUTE_MONITOR_PID" 2>/dev/null \
    || fail "CoreAudio route monitor exited at ${prefix}"
  first_heartbeat=$(jq -er --argjson pid "$AUDIO_ROUTE_MONITOR_PID" \
    --arg input "$DEFAULT_INPUT_UID" \
    --arg output "$DEFAULT_OUTPUT_UID" \
    --arg system "$DEFAULT_SYSTEM_OUTPUT_UID" '
      select(
        .schema == "opensteamer.default-route-monitor.v1" and
        .phase == "monitoring" and .pid == $pid and
        .listenersInstalled == 3 and .listenersRemoved == false and
        .notificationCount == 0 and .clean == false and
        .baseline.defaultInputUID == $input and
        .baseline.defaultOutputUID == $output and
        .baseline.defaultSystemOutputUID == $system and
        .current == .baseline and
        (.heartbeat | type == "number")
      ) | .heartbeat
    ' "$AUDIO_ROUTE_MONITOR_STATUS") \
    || fail "CoreAudio route monitor reported a violation at ${prefix}"
  /bin/sleep 0.30
  second_heartbeat=$(jq -er --argjson pid "$AUDIO_ROUTE_MONITOR_PID" '
      select(
        .schema == "opensteamer.default-route-monitor.v1" and
        .phase == "monitoring" and .pid == $pid and
        .notificationCount == 0 and .current == .baseline and
        (.heartbeat | type == "number")
      ) | .heartbeat
    ' "$AUDIO_ROUTE_MONITOR_STATUS") \
    || fail "CoreAudio route monitor became unhealthy at ${prefix}"
  (( second_heartbeat > first_heartbeat )) \
    || fail "CoreAudio route monitor heartbeat stalled at ${prefix}"
}

function stop_audio_route_monitor_verified() {
  local monitor_status=0
  /usr/bin/touch "$AUDIO_ROUTE_MONITOR_STOP" \
    || fail 'CoreAudio route monitor stop request failed'
  for (( monitor_attempt = 0; monitor_attempt < 100; monitor_attempt++ )); do
    if [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
        && jq -e '.phase == "stopped"' \
          "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1; then
      break
    fi
    kill -0 "$AUDIO_ROUTE_MONITOR_PID" 2>/dev/null || break
    /bin/sleep 0.05
  done
  [[ -f "$AUDIO_ROUTE_MONITOR_STATUS" ]] \
    && jq -e '.phase == "stopped"' \
      "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null 2>&1 \
    || fail 'CoreAudio route monitor did not stop cleanly'
  if wait "$AUDIO_ROUTE_MONITOR_PID"; then
    monitor_status=0
  else
    monitor_status=$?
  fi
  AUDIO_ROUTE_MONITOR_PID=''
  (( monitor_status == 0 )) \
    || fail 'CoreAudio route monitor observed a route violation'
  jq -e --arg input "$DEFAULT_INPUT_UID" \
    --arg output "$DEFAULT_OUTPUT_UID" \
    --arg system "$DEFAULT_SYSTEM_OUTPUT_UID" '
      .schema == "opensteamer.default-route-monitor.v1" and
      .phase == "stopped" and .listenersInstalled == 3 and
      .listenersRemoved == true and .notificationCount == 0 and
      .clean == true and
      .baseline.defaultInputUID == $input and
      .baseline.defaultOutputUID == $output and
      .baseline.defaultSystemOutputUID == $system and
      .current == .baseline
    ' "$AUDIO_ROUTE_MONITOR_STATUS" >/dev/null \
    || fail 'CoreAudio route monitor teardown proof is invalid'
  AUDIO_ROUTE_MONITOR_PHASE=$(jq -er '.phase' "$AUDIO_ROUTE_MONITOR_STATUS")
  AUDIO_ROUTE_NOTIFICATION_COUNT=$(jq -er \
    '.notificationCount' "$AUDIO_ROUTE_MONITOR_STATUS")
}

# Exercise the finalizer without querying a device, app, session, or host. The full signal mode uses
# the real read-only CoreAudio listener; the no-monitor mode covers the passive-wait lifecycle that
# previously left a stale `armed` status. The forced-challenge mode uses only a private, synthetic
# child that ignores ordinary termination so the fail-closed forced-teardown result is executable.
if [[ "$SELF_TEST_MODE" == forced-challenge-cleanup ]]; then
  STAGE=self-test-forced-challenge-cleanup
  readonly SELF_TEST_CHALLENGE_READY="${ARTIFACT_DIR}/self-test-challenge.ready"
  /bin/zsh -c '
    trap "" HUP INT TERM
    print -r -- ready > "$1"
    while true; do
      /bin/sleep 1
    done
  ' zsh "$SELF_TEST_CHALLENGE_READY" &
  CHALLENGE_PID=$!
  for (( self_test_attempt = 0; self_test_attempt < 100; self_test_attempt++ )); do
    [[ -f "$SELF_TEST_CHALLENGE_READY" ]] && owned_child_is_alive "$CHALLENGE_PID" \
      && break
    /bin/sleep 0.01
  done
  [[ -f "$SELF_TEST_CHALLENGE_READY" ]] && owned_child_is_alive "$CHALLENGE_PID" \
    || fail 'forced-challenge self-test child did not become ready'
  VERIFIED=1
  write_run_status armed 'forced-challenge finalizer self-test entering normal exit'
  exit 0
fi

if [[ "$SELF_TEST_MODE" == final-status-failure ]]; then
  STAGE=self-test-final-status-failure
  VERIFIED=1
  exit 0
fi

if [[ "$SELF_TEST_MODE" == signal-cleanup \
    || "$SELF_TEST_MODE" == signal-no-monitor ]]; then
  if [[ "$SELF_TEST_MODE" == signal-cleanup ]]; then
    STAGE=self-test-audio-route-monitor
    compile_audio_route_reader \
      || fail 'self-test CoreAudio route reader failed to compile'
    start_audio_route_monitor
    capture_audio_routes self-test-before
    require_audio_route_monitor_healthy self-test-before
  fi
  STAGE=self-test-awaiting-signal
  write_run_status armed 'signal-cleanup self-test awaiting signal'
  while true; do
    /bin/sleep 1
  done
fi

function require_existing_connected_session() {
  local prefix=$1
  local allow_inactive=${2:-0}
  [[ "$allow_inactive" == 0 || "$allow_inactive" == 1 ]] \
    || fail "invalid inactive-session policy at ${prefix}"
  require_same_host
  [[ -f "$HOST_LOG" && ! -L "$HOST_LOG" ]] || fail 'Mac host log is unavailable'
  local lifecycle_events="${ARTIFACT_DIR}/${prefix}-host-lifecycle.log"
  local peer_record capture_record peer_event capture_event peer_line capture_line
  local peer_pid connected_count capture_start_count capture_stop_count
  rg -n 'Worldwide WebRTC peer state:|Starting screen video capture|Stopping screen video capture' \
    "$HOST_LOG" > "$lifecycle_events" \
    || fail 'Mac host lifecycle state cannot be determined'
  peer_record=$(rg 'Worldwide WebRTC peer state:' \
    "$lifecycle_events" | /usr/bin/tail -n 1) \
    || fail 'Mac host peer state cannot be determined'
  capture_record=$(rg 'Starting screen video capture|Stopping screen video capture' \
    "$lifecycle_events" | /usr/bin/tail -n 1) \
    || fail 'Mac host screen capture state cannot be determined'
  [[ "$peer_record" =~ '^([1-9][0-9]*):(.*)$' ]] \
    || fail 'Mac host peer log record is malformed'
  peer_line=${match[1]}
  peer_event=${match[2]}
  [[ "$capture_record" =~ '^([1-9][0-9]*):(.*)$' ]] \
    || fail 'Mac host capture log record is malformed'
  capture_line=${match[1]}
  capture_event=${match[2]}
  if [[ ! "$peer_event" =~ 'Worldwide WebRTC peer state: connected pid=([0-9]+)$' ]]; then
    if (( allow_inactive == 1 )); then
      return 1
    fi
    fail 'no active viewer; connect normally first and leave the Mac screen visible'
  fi
  peer_pid=${match[1]}
  if [[ "$peer_pid" != "$HOST_PID" ]]; then
    if (( allow_inactive == 1 )) && [[ -z "$CONNECTED_PEER_PID" ]]; then
      return 1
    fi
    fail 'latest connected peer evidence belongs to a different Mac host process'
  fi
  connected_count=$(rg -c \
    "Worldwide WebRTC peer state: connected pid=${peer_pid}$" "$lifecycle_events") \
    || fail 'connected peer event count cannot be determined'
  [[ -n "$connected_count" && "$connected_count" != *[^0-9]* \
      && "$connected_count" -gt 0 ]] \
    || fail 'connected peer event count is invalid'
  capture_start_count=$(rg -c 'Starting screen video capture' "$lifecycle_events") \
    || fail 'screen-capture start count cannot be determined'
  capture_stop_count=$(rg -c 'Stopping screen video capture' "$lifecycle_events" || true)
  capture_stop_count=${capture_stop_count:-0}
  [[ -n "$capture_start_count" && "$capture_start_count" != *[^0-9]* \
      && "$capture_start_count" -gt 0 \
      && -n "$capture_stop_count" && "$capture_stop_count" != *[^0-9]* ]] \
    || fail 'screen-capture lifecycle counts are invalid'
  if [[ -n "$CONNECTED_PEER_PID" ]]; then
    [[ "$peer_pid" == "$CONNECTED_PEER_PID" ]] \
      || fail "connected peer PID changed at ${prefix}"
    [[ "$connected_count" == "$CONNECTED_EVENT_COUNT" ]] \
      || fail "viewer reconnected or was replaced at ${prefix}"
    [[ "$capture_start_count" == "$CAPTURE_START_COUNT" ]] \
      || fail "screen presentation restarted at ${prefix}"
    [[ "$capture_stop_count" == "$CAPTURE_STOP_COUNT" ]] \
      || fail "screen presentation stopped at ${prefix}"
  fi
  if [[ "$capture_event" != *'Starting screen video capture'* ]]; then
    if (( allow_inactive == 1 )); then
      return 1
    else
      fail 'screen is not visible; open the connected Mac screen in Beluga and retry'
    fi
  fi
  if (( capture_line <= peer_line )); then
    if (( allow_inactive == 1 )); then
      return 1
    fi
    fail 'visible-screen evidence predates the latest connected viewer; reopen the screen'
  fi
  if [[ -z "$CONNECTED_PEER_PID" ]]; then
    CONNECTED_PEER_PID=$peer_pid
    CONNECTED_EVENT_COUNT=$connected_count
    CAPTURE_START_COUNT=$capture_start_count
    CAPTURE_STOP_COUNT=$capture_stop_count
    CAPTURE_LOG_LINE=$capture_line
  fi
  jq -n \
    --arg hostPid "$HOST_PID" \
    --arg connectedPeerPid "$peer_pid" \
    --arg connectedEventCount "$connected_count" \
    --arg captureStartCount "$capture_start_count" \
    --arg captureStopCount "$capture_stop_count" \
    --arg peerLogLine "$peer_line" \
    --arg captureLogLine "$capture_line" \
    --arg latestPeerEvent "$peer_event" \
    --arg latestCaptureEvent "$capture_event" \
    '{hostPid:$hostPid,connectedPeerPid:$connectedPeerPid,
      connectedEventCount:$connectedEventCount,latestPeerEvent:$latestPeerEvent,
      captureStartCount:$captureStartCount,captureStopCount:$captureStopCount,
      peerLogLine:$peerLogLine,captureLogLine:$captureLogLine,
      latestCaptureEvent:$latestCaptureEvent}' \
    > "${ARTIFACT_DIR}/${prefix}-host-session.json"
}

function live_screen_gate_is_open() {
  local lock_state="${ARTIFACT_DIR}/waiting-lock.json"
  local recent_log="${ARTIFACT_DIR}/waiting-host-tail.log"
  local latest_capture=''

  # Screen lifecycle is a cheap local gate. Avoid touching CoreDevice every two seconds while the
  # user is elsewhere or the phone is asleep.
  if ! /usr/bin/tail -n 20000 "$HOST_LOG" > "$recent_log" 2>/dev/null; then
    LIVE_GATE_REASON='host-log-unavailable'
    return 1
  fi
  latest_capture=$(rg -n \
    'Starting screen video capture|Stopping screen video capture' \
    "$recent_log" | /usr/bin/tail -n 1 || true)
  if [[ "$latest_capture" != *'Starting screen video capture'* ]]; then
    LIVE_GATE_REASON='mac-screen-not-visible'
    return 1
  fi
  if (( MINIMUM_CAPTURE_START_COUNT > 0 )); then
    local current_capture_start_count
    current_capture_start_count=$(rg -c 'Starting screen video capture' "$HOST_LOG" || true)
    if [[ -z "$current_capture_start_count" \
        || "$current_capture_start_count" == *[^0-9]* \
        || "$current_capture_start_count" -le "$MINIMUM_CAPTURE_START_COUNT" ]]; then
      LIVE_GATE_REASON='awaiting-fresh-screen-presentation'
      return 1
    fi
    MINIMUM_CAPTURE_START_COUNT=0
  fi
  if ! xcrun devicectl device info lockState \
      --device "$PRODUCTION_DEVICE_ID" --timeout 10 --json-output "$lock_state" \
      >/dev/null 2>&1; then
    LIVE_GATE_REASON='device-lock-state-unavailable'
    return 1
  fi
  if ! jq -e '(.info.outcome == "success") and \
      (.result.passcodeRequired | type == "boolean")' \
      "$lock_state" >/dev/null 2>&1; then
    LIVE_GATE_REASON='device-lock-state-malformed'
    return 1
  fi
  if ! jq -e '.result.passcodeRequired == false' \
      "$lock_state" >/dev/null 2>&1; then
    LIVE_GATE_REASON='device-locked'
    return 1
  fi
  LIVE_GATE_REASON='ready'
  return 0
}

function wait_for_live_screen_gate() {
  local next_status_at=0

  while true; do
    if (( SECONDS >= RUN_DEADLINE_SECONDS )); then
      fail 'timed out waiting for the unlocked iPhone with its Mac screen already visible'
    fi
    if live_screen_gate_is_open; then
      return
    fi
    if (( SECONDS >= next_status_at )); then
      write_run_status armed "$LIVE_GATE_REASON"
      next_status_at=$(( SECONDS + 30 ))
    fi
    /bin/sleep 2
  done
}

function clean_ui_test_cache_with_xcode() {
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

function build_ui_test_products_with_xcode() {
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
    "-only-testing:${TEST_ID}" \
    > "$log_path" 2>&1
}

STAGE=build-preparation
require_observer_only_ui_test_source
capture_device_state before-build any
STAGE=audio-route-reader
compile_audio_route_reader \
  || fail 'read-only CoreAudio route reader failed to compile'
STAGE=challenge-build
swiftc -parse-as-library "$CHALLENGE_PROTOCOL_SOURCE" "$CHALLENGE_SOURCE" \
  -o "$CHALLENGE_BINARY" \
  > "${ARTIFACT_DIR}/challenge-build.log" 2>&1 \
  || fail 'visual challenge failed to compile'

# Build and sign only the separate development app and UI test runner against a generic iOS
# destination. This step cannot install, launch, or change the production app/session, and using
# the incremental cache keeps it outside the short unlocked-screen observation window.
# Xcode can incrementally relink and re-sign the nested .xctest without re-signing an older outer
# XCTest runner app. Detect that exact cache state before the real build and let Xcode clean its
# own generated products once; never repair or ad-hoc-sign a test product ourselves.
cached_runner_app="${DERIVED_DATA}/Build/Products/Debug-iphoneos/opensteamerUITests-Runner.app"
typeset -gi cached_runner_requires_clean=0
if [[ -e "$cached_runner_app" ]]; then
  if [[ ! -d "$cached_runner_app" || -L "$cached_runner_app" ]] \
      || ! codesign --verify --strict "$cached_runner_app" \
        > "${ARTIFACT_DIR}/cached-ui-runner-codesign-verify.log" 2>&1; then
    cached_runner_requires_clean=1
  fi
fi
if (( cached_runner_requires_clean )); then
  STAGE=repair-ui-test-cache
  write_run_status preparing 'repairing-invalid-incremental-ui-runner-signature'
  clean_ui_test_cache_with_xcode "${ARTIFACT_DIR}/cache-repair.log" \
    || fail 'invalid incremental UI test cache could not be cleaned by Xcode'
fi
STAGE=build-ui-test
write_run_status preparing
build_ui_test_products_with_xcode "${ARTIFACT_DIR}/build.log" \
  || fail 'screen-only UI test build failed; see build.log'

# A cache may be valid before this run, then become invalid when Xcode updates the nested test
# bundle without re-signing the outer runner. Verify after the build too. One Xcode-owned clean and
# identical rebuild is the bounded repair; a still-invalid product is terminal preparation failure.
if [[ ! -d "$cached_runner_app" || -L "$cached_runner_app" ]] \
    || ! codesign --verify --strict "$cached_runner_app" \
      > "${ARTIFACT_DIR}/built-ui-runner-codesign-verify.log" 2>&1; then
  STAGE=repair-ui-test-cache-after-build
  write_run_status preparing 'repairing-post-build-ui-runner-signature'
  clean_ui_test_cache_with_xcode "${ARTIFACT_DIR}/post-build-cache-repair.log" \
    || fail 'post-build UI test cache could not be cleaned by Xcode'
  build_ui_test_products_with_xcode "${ARTIFACT_DIR}/post-build-rebuild.log" \
    || fail 'screen-only UI test rebuild failed after cache repair'
fi
[[ -d "$cached_runner_app" && ! -L "$cached_runner_app" ]] \
  || fail 'built UI test runner is unavailable after cache repair'
codesign --verify --strict "$cached_runner_app" \
  > "${ARTIFACT_DIR}/built-ui-runner-final-codesign-verify.log" 2>&1 \
  || fail 'Xcode produced an invalid UI test runner after bounded cache repair'
[[ -d "${DERIVED_DATA}/Build/Products" \
    && ! -L "${DERIVED_DATA}/Build/Products" ]] \
  || fail 'built UI test products are unavailable'
/usr/bin/ditto "${DERIVED_DATA}/Build/Products" "$PREPARED_PRODUCTS" \
  > "${ARTIFACT_DIR}/prepared-products-copy.log" 2>&1 \
  || fail 'failed to seal the prepared UI test products into this run'
if /usr/bin/find "$PREPARED_PRODUCTS" -type l -print -quit \
    | /usr/bin/grep -q .; then
  fail 'prepared UI test products contain an unsafe symbolic link'
fi
local_debug_app="${PREPARED_PRODUCTS}/Debug-iphoneos/Beluga.app"
local_debug_bundle="${local_debug_app}/Info.plist"
[[ -d "$local_debug_app" && ! -L "$local_debug_app" \
    && -f "$local_debug_bundle" ]] || fail 'Debug app product is missing'
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$local_debug_bundle")" \
    == "$DEBUG_APP_BUNDLE_ID" ]] \
  || fail 'UI test build could replace the installed production identity'
codesign --verify --strict "$local_debug_app" \
  > "${ARTIFACT_DIR}/debug-app-codesign-verify.log" 2>&1 \
  || fail 'Debug app signature verification failed'
codesign -dv --verbose=4 "$local_debug_app" \
  > /dev/null 2> "${ARTIFACT_DIR}/debug-app-codesign.txt" \
  || fail 'Debug app signature metadata is unavailable'
/usr/bin/grep -Fxq "Identifier=${DEBUG_APP_BUNDLE_ID}" \
  "${ARTIFACT_DIR}/debug-app-codesign.txt" \
  && /usr/bin/grep -Fxq "TeamIdentifier=${DEVELOPMENT_TEAM_ID}" \
    "${ARTIFACT_DIR}/debug-app-codesign.txt" \
  || fail 'Debug app signature identity is unexpected'
typeset -a local_runner_apps
local_runner_apps=("${PREPARED_PRODUCTS}"/Debug-iphoneos/*UITests-Runner.app(N/))
(( ${#local_runner_apps[@]} == 1 )) || fail 'expected one signed UI test runner app'
local_runner_app=${local_runner_apps[1]}
[[ "$(plutil -extract CFBundleIdentifier raw -o - "${local_runner_app}/Info.plist")" \
    == "$DEBUG_RUNNER_BUNDLE_ID" ]] \
  || fail 'UI test runner bundle identity is unexpected'
codesign --verify --strict "$local_runner_app" \
  > "${ARTIFACT_DIR}/ui-runner-codesign-verify.log" 2>&1 \
  || fail 'UI test runner signature verification failed'
codesign -dv --verbose=4 "$local_runner_app" \
  > /dev/null 2> "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
  || fail 'UI test runner signature metadata is unavailable'
/usr/bin/grep -Fxq "Identifier=${DEBUG_RUNNER_BUNDLE_ID}" \
  "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
  && /usr/bin/grep -Fxq "TeamIdentifier=${DEVELOPMENT_TEAM_ID}" \
    "${ARTIFACT_DIR}/ui-runner-codesign.txt" \
  || fail 'UI test runner signature identity is unexpected'
typeset -a xctestrun_files
xctestrun_files=("${PREPARED_PRODUCTS}"/*.xctestrun(N))
(( ${#xctestrun_files[@]} == 1 )) || fail 'expected one exact xctestrun bundle'
(
  cd "$PREPARED_PRODUCTS"
  /usr/bin/find -s . -type f -exec /usr/bin/shasum -a 256 {} +
) > "$PREPARED_PRODUCTS_MANIFEST" \
  || fail 'prepared UI test product manifest could not be sealed'
[[ -s "$PREPARED_PRODUCTS_MANIFEST" ]] \
  || fail 'prepared UI test product manifest is empty'

STAGE=device-after-build
capture_device_state after-build any
/usr/bin/cmp -s "${ARTIFACT_DIR}/before-build-candidate.json" \
  "${ARTIFACT_DIR}/after-build-candidate.json" \
  || fail 'installed production app metadata changed during build'

# From this point onward preparation is complete. Stay armed while the phone is locked or the
# user is elsewhere in the app. A short-lived unlock/capture pulse that closes before identity
# binding is a missed observation window, not a failed product oracle, so return to the same
# prepared wait without rebuilding or asking the user to hold the phone open.
while true; do
  STAGE=waiting-for-live-screen
  write_run_status armed
  wait_for_live_screen_gate

  STAGE=device-before
  capture_device_state before any
  /usr/bin/cmp -s "${ARTIFACT_DIR}/before-build-candidate.json" \
    "${ARTIFACT_DIR}/before-candidate.json" \
    || fail 'installed production app metadata changed before live observation'
  if ! jq -e '.result.passcodeRequired == false' \
      "${ARTIFACT_DIR}/before-lock.json" >/dev/null; then
    MINIMUM_CAPTURE_START_COUNT=$(rg -c \
      'Starting screen video capture' "$HOST_LOG" || true)
    MINIMUM_CAPTURE_START_COUNT=${MINIMUM_CAPTURE_START_COUNT:-0}
    HOST_PID=''
    CONNECTED_PEER_PID=''
    CONNECTED_EVENT_COUNT=''
    CAPTURE_START_COUNT=''
    CAPTURE_STOP_COUNT=''
    CAPTURE_LOG_LINE=''
    write_run_status armed 'observation window relocked before device binding'
    continue
  fi

  STAGE=connected-session-before
  if ! require_existing_connected_session before 1; then
    MINIMUM_CAPTURE_START_COUNT=$(rg -c \
      'Starting screen video capture' "$HOST_LOG" || true)
    MINIMUM_CAPTURE_START_COUNT=${MINIMUM_CAPTURE_START_COUNT:-0}
    HOST_PID=''
    CONNECTED_PEER_PID=''
    CONNECTED_EVENT_COUNT=''
    CAPTURE_START_COUNT=''
    CAPTURE_STOP_COUNT=''
    CAPTURE_LOG_LINE=''
    write_run_status armed 'observation window closed before session binding'
    continue
  fi
  if ! live_screen_gate_is_open; then
    MINIMUM_CAPTURE_START_COUNT=$(rg -c \
      'Starting screen video capture' "$HOST_LOG" || true)
    MINIMUM_CAPTURE_START_COUNT=${MINIMUM_CAPTURE_START_COUNT:-0}
    HOST_PID=''
    CONNECTED_PEER_PID=''
    CONNECTED_EVENT_COUNT=''
    CAPTURE_START_COUNT=''
    CAPTURE_STOP_COUNT=''
    CAPTURE_LOG_LINE=''
    write_run_status armed 'observation window closed before safety monitors'
    continue
  fi
  break
done
write_run_status gate-open
start_audio_route_monitor
capture_audio_routes before
require_audio_route_monitor_healthy before

STAGE=host-identity-before-challenge
require_same_host
verify_sealed_host_identity before-challenge

STAGE=challenge
NONCE=$(openssl rand -hex 16) || fail 'failed to generate a fresh nonce'
[[ "$NONCE" =~ '^[0-9a-f]{32}$' ]] \
  || fail 'invalid fresh nonce'
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

STAGE=pre-test-session
require_device_unlocked before-test
require_existing_connected_session before-test
capture_audio_routes before-test
require_audio_route_monitor_healthy before-test

STAGE=physical-final-pixels
write_run_status observing
# The shared incremental cache may be rebuilt by other work while this observer waits. Only the
# private, hashed product snapshot prepared above is allowed to cross the live-device gate.
(
  cd "$PREPARED_PRODUCTS"
  /usr/bin/find -s . -type f -exec /usr/bin/shasum -a 256 {} +
) > "${ARTIFACT_DIR}/prepared-test-products-before-test.sha256" \
  || fail 'prepared UI test products could not be rehashed before observation'
/usr/bin/cmp -s "$PREPARED_PRODUCTS_MANIFEST" \
  "${ARTIFACT_DIR}/prepared-test-products-before-test.sha256" \
  || fail 'prepared UI test products changed while the observer was armed'
# xcodebuild strips TEST_RUNNER_ and forwards the remainder to the XCTest runner process.
export TEST_RUNNER_OPENSTEAMER_SCREEN_ORACLE_NONCE="$NONCE"
export TEST_RUNNER_OPENSTEAMER_SCREEN_ORACLE_EXPECTED_BUILD="$EXPECTED_BUILD"
export TEST_RUNNER_OPENSTEAMER_EXPECTED_APP_BUNDLE_IDENTIFIER="$APP_BUNDLE_ID"
export TEST_RUNNER_OPENSTEAMER_SCREEN_ORACLE_OBSERVE_EXISTING_SCREEN=1
typeset -i test_status=0
if xcodebuild test-without-building \
  -xctestrun "${xctestrun_files[1]}" \
  -destination "platform=iOS,id=${PRODUCTION_HARDWARE_UDID}" \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 \
  "-only-testing:${TEST_ID}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  > "${ARTIFACT_DIR}/test.log" 2>&1; then
  test_status=0
else
  test_status=$?
fi

# Preserve the safety proof even when the pixel assertion fails. A black/stalled screen is a
# useful oracle result, but it must not obscure a peer reconnect, host restart, route change, or
# screen-presentation replacement.
STAGE=post-test-safety
require_same_host
verify_sealed_host_identity after-challenge
capture_device_state after any
/usr/bin/cmp -s "${ARTIFACT_DIR}/before-candidate.json" \
  "${ARTIFACT_DIR}/after-candidate.json" \
  || fail 'installed production app metadata changed during test'
require_existing_connected_session after
capture_audio_routes after
require_audio_route_monitor_healthy after
(
  cd "$PREPARED_PRODUCTS"
  /usr/bin/find -s . -type f -exec /usr/bin/shasum -a 256 {} +
) > "${ARTIFACT_DIR}/prepared-test-products-after-test.sha256" \
  || fail 'prepared UI test products could not be rehashed after observation'
/usr/bin/cmp -s "$PREPARED_PRODUCTS_MANIFEST" \
  "${ARTIFACT_DIR}/prepared-test-products-after-test.sha256" \
  || fail 'prepared UI test products changed during physical observation'
(( test_status == 0 )) \
  || fail 'physical final-pixel test failed; see test.log and xcresult'

typeset -a visual_markers
visual_markers=("${(@f)$(rg -o \
  'OPENSTEAMER_SCREEN_VISUAL_ORACLE_V1 build=[1-9][0-9]* nonce=[0-9a-f]{32} session=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} renderer=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12} decodedSamples=[1-9][0-9]* maximumUndecodableRun=[0-3] maximumSameSymbolHold=[0-9]+\.[0-9]{2} symbols=[0-3](,[0-3])*' \
  "${ARTIFACT_DIR}/test.log" | /usr/bin/sort -u)}")
(( ${#visual_markers[@]} == 1 )) \
  || fail 'test output did not contain one unique final-pixel evidence marker'
VISUAL_MARKER=${visual_markers[1]}
[[ "$VISUAL_MARKER" == *" build=${EXPECTED_BUILD} nonce=${NONCE} "* ]] \
  || fail 'final-pixel evidence marker is not bound to this build and nonce'

STAGE=postflight
require_existing_connected_session final
verify_sealed_host_identity final
capture_audio_routes final
require_audio_route_monitor_healthy final
[[ -s "$CHALLENGE_HEARTBEAT" ]] \
  && /usr/bin/grep -Fxq "nonce=${NONCE}" "$CHALLENGE_HEARTBEAT" \
  && kill -0 "$CHALLENGE_PID" 2>/dev/null \
  || fail 'visual challenge stopped during physical test'

xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" --compact > "${ARTIFACT_DIR}/xcresult-summary.json" \
  || fail 'xcresult summary unavailable'
xcrun xcresulttool get test-results tests \
  --path "$RESULT_BUNDLE" --compact > "${ARTIFACT_DIR}/xcresult-tests.json" \
  || fail 'xcresult test result unavailable'
jq -e --arg udid "$PRODUCTION_HARDWARE_UDID" \
  --arg model "$PRODUCTION_DEVICE_MODEL_NAME" '
  (.result == "Passed") and (.totalTestCount == 1) and
  (.passedTests == 1) and (.failedTests == 0) and (.skippedTests == 0) and
  (.expectedFailures == 0) and ((.testFailures | length) == 0) and
  (.devicesAndConfigurations | type == "array" and length == 1) and
  (.devicesAndConfigurations[0] |
    .device.deviceId == $udid and .device.modelName == $model and
    .passedTests == 1 and .failedTests == 0 and .skippedTests == 0)
' "${ARTIFACT_DIR}/xcresult-summary.json" >/dev/null \
  || fail 'xcresult summary does not prove exactly one pass on the pinned iPhone 17 Pro'
jq -e --arg test "$TEST_NODE" '
  ([.. | objects | select(.nodeType? == "Test Case")] | length == 1) and
  ([.. | objects | select(.nodeType? == "Test Case")][0] |
    .nodeIdentifier == $test and .result == "Passed")
' "${ARTIFACT_DIR}/xcresult-tests.json" >/dev/null \
  || fail 'xcresult did not pass the exact screen oracle method'

STAGE=audio-route-monitor-teardown
stop_audio_route_monitor_verified
VERIFIED=1
STAGE=complete
