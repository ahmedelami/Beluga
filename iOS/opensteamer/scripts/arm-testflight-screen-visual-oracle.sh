#!/bin/zsh

# Prepare the physical screen oracle while the iPhone may remain locked, then leave exactly one
# observer-only process waiting for the next natural unlocked + visible-screen interval.
# Usage: arm-testflight-screen-visual-oracle.sh COREDEVICE_ID HARDWARE_UDID BUILD
set -euo pipefail
umask 077

readonly APP_BUNDLE_ID=com.elamin.opensteamer
readonly PRODUCTION_DEVICE_ID=7694F11E-D66D-5632-9A0D-462C980130A5
readonly PRODUCTION_HARDWARE_UDID=00008150-0002581C3E3A401C
readonly PRODUCTION_DEVICE_MODEL_NAME='iPhone 17 Pro'
readonly SCRIPT_DIR=${0:A:h}
readonly RUNNER="${SCRIPT_DIR}/validate-testflight-screen-visual-oracle.sh"
readonly RUN_STATE_ROOT=/Volumes/t7/opensteamer-screen-oracle-state

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
if [[ "$DEVICE_ID" != "$PRODUCTION_DEVICE_ID" \
    || "$HARDWARE_UDID" != "$PRODUCTION_HARDWARE_UDID" ]]; then
  print -u2 -- \
    'Production visual-oracle arming requires the exact pinned iPhone 17 Pro CoreDevice and hardware UDID.'
  exit 2
fi
readonly RUN_KEY="${DEVICE_ID}-${APP_BUNDLE_ID}"
readonly RUN_STATUS="${RUN_STATE_ROOT}/${RUN_KEY}.json"
readonly RUN_LOG_ROOT=/Users/ahmed/Library/Logs/OpenSteamerScreenOracle
readonly RUN_LOG="${RUN_LOG_ROOT}/${RUN_KEY}.log"
readonly RUN_ERROR_LOG="${RUN_LOG_ROOT}/${RUN_KEY}.error.log"
readonly LABEL="org.example.opensteamer.screen-oracle.${DEVICE_ID:l}"
readonly JOB_TARGET="gui/${UID}/${LABEL}"
readonly LAUNCH_AGENT_ROOT=/Users/ahmed/Library/LaunchAgents
readonly LAUNCH_AGENT_PLIST="${LAUNCH_AGENT_ROOT}/${LABEL}.plist"
readonly SCREEN_SESSION="opensteamer-oracle-${DEVICE_ID:l}"
readonly LAUNCH_PATH='/Users/ahmed/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/ChatGPT.app/Contents/Resources'
readonly HOST_IDENTITY_MANIFEST=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST:-}
readonly HOST_IDENTITY_MANIFEST_SHA256_PATH=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH:-}
readonly HOST_IDENTITY_MANIFEST_SHA256=${OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256:-}

for tool in jq launchctl ps screen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print -u2 -- "Missing required tool: $tool"
    exit 2
  fi
done
[[ -x "$RUNNER" && ! -L "$RUNNER" ]] || {
  print -u2 -- "Visual-oracle runner is unavailable: ${RUNNER}"
  exit 2
}
if [[ -z "$HOST_IDENTITY_MANIFEST" || "$HOST_IDENTITY_MANIFEST" != /* \
    || "${HOST_IDENTITY_MANIFEST:A}" != "$HOST_IDENTITY_MANIFEST" \
    || ! -f "$HOST_IDENTITY_MANIFEST" || -L "$HOST_IDENTITY_MANIFEST" \
    || "$HOST_IDENTITY_MANIFEST_SHA256_PATH" != "${HOST_IDENTITY_MANIFEST}.sha256" \
    || "${HOST_IDENTITY_MANIFEST_SHA256_PATH:A}" != "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || ! -f "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || -L "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    || ! "$HOST_IDENTITY_MANIFEST_SHA256" =~ '^[0-9a-f]{64}$' ]]; then
  print -u2 -- \
    'Set the release-sealed Mac host identity manifest, committed SHA-256 sidecar, and independently transported SHA-256 before arming.'
  exit 2
fi
if [[ ! -d /Volumes/t7 || -L /Volumes/t7 ]]; then
  print -u2 -- 'T7 is unavailable.'
  exit 2
fi
if [[ ! -d "$LAUNCH_AGENT_ROOT" || -L "$LAUNCH_AGENT_ROOT" ]]; then
  print -u2 -- 'User LaunchAgents directory is unavailable or unsafe.'
  exit 2
fi
if [[ -e "$RUN_LOG_ROOT" && ( ! -d "$RUN_LOG_ROOT" || -L "$RUN_LOG_ROOT" ) ]]; then
  print -u2 -- 'Visual-oracle log root is unsafe.'
  exit 2
fi
if [[ -e "$RUN_STATE_ROOT" && ( ! -d "$RUN_STATE_ROOT" || -L "$RUN_STATE_ROOT" ) ]]; then
  print -u2 -- 'Visual-oracle state root is unsafe.'
  exit 2
fi
/bin/mkdir -p -m 700 "$RUN_STATE_ROOT"
/bin/chmod 700 "$RUN_STATE_ROOT"
/bin/mkdir -p -m 700 "$RUN_LOG_ROOT"
/bin/chmod 700 "$RUN_LOG_ROOT"
for state_path in "$RUN_STATUS" "$RUN_LOG" "$RUN_ERROR_LOG" "$LAUNCH_AGENT_PLIST"; do
  if [[ -e "$state_path" && ( ! -f "$state_path" || -L "$state_path" ) ]]; then
    print -u2 -- "Visual-oracle state path is unsafe: ${state_path}"
    exit 2
  fi
done

function active_runner_pid() {
  [[ -s "$RUN_STATUS" ]] || return 1
  local pid command
  pid=$(jq -er \
    --arg deviceId "$DEVICE_ID" \
    --arg hardwareUDID "$HARDWARE_UDID" \
    --arg deviceModelName "$PRODUCTION_DEVICE_MODEL_NAME" \
    --arg bundleId "$APP_BUNDLE_ID" \
    --arg build "$EXPECTED_BUILD" \
    --arg hostIdentityManifestSHA256Path "$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
    --arg hostIdentityManifestSHA256 "$HOST_IDENTITY_MANIFEST_SHA256" '
      select(
        .schema == "opensteamer.screen-visual-oracle-run.v1"
        and (.phase == "preparing" or .phase == "armed"
          or .phase == "gate-open" or .phase == "observing")
        and .deviceId == $deviceId
        and .hardwareUDID == $hardwareUDID
        and .deviceModelName == $deviceModelName
        and .bundleId == $bundleId
        and .build == $build
        and .hostIdentityManifestSHA256Path == $hostIdentityManifestSHA256Path
        and .hostIdentityManifestSHA256 == $hostIdentityManifestSHA256
        and ((.pid | type) == "number")
        and .pid > 1
        and .pid == (.pid | floor)
      )
      | .pid
    ' "$RUN_STATUS" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(ps -ww -p "$pid" -o command= 2>/dev/null || true)
  [[ "$command" == *"${RUNNER} ${DEVICE_ID} ${HARDWARE_UDID} ${EXPECTED_BUILD}" ]] \
    || return 1
  print -r -- "$pid"
}

function screen_session_is_live() {
  local listing
  listing=$(/usr/bin/screen -ls 2>/dev/null || true)
  [[ "$listing" == *".${SCREEN_SESSION}"* ]]
}

function launchd_job_snapshot_is_proven_inert() {
  local snapshot=$1
  print -r -- "$snapshot" | /usr/bin/awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^active count = /) active_count_fields++
      if (line == "active count = 0") inactive_count++
      if (line ~ /^state = /) state_fields++
      if (line == "state = not running") stopped_state++
      if (line ~ /^pid = /) pid_fields++
    }
    END {
      exit !(active_count_fields == 1 && inactive_count == 1 &&
        state_fields == 1 && stopped_state == 1 && pid_fields == 0)
    }
  '
}

typeset existing_pid=''
if existing_pid=$(active_runner_pid); then
  print -- "Screen visual oracle already armed: pid=${existing_pid} status=${RUN_STATUS}"
  exit 0
fi

# Retire the inert LaunchAgent used by the first implementation only when launchd itself reports one
# exact stopped state, zero active references, and no live PID. A mismatched or unpublished runner
# may still own this label, so ambiguous or live state is left intact for inspection.
typeset launchd_job_snapshot=''
if launchd_job_snapshot=$(launchctl print "$JOB_TARGET" 2>/dev/null); then
  if ! launchd_job_snapshot_is_proven_inert "$launchd_job_snapshot"; then
    print -u2 -- \
      "Visual-oracle LaunchAgent is live or not proven inert; left intact: job=${JOB_TARGET} status=${RUN_STATUS}"
    exit 1
  fi
  launchctl bootout "$JOB_TARGET" >/dev/null 2>&1 \
    || { print -u2 -- "Could not retire inactive visual-oracle job ${LABEL}"; exit 1; }
fi
if [[ -f "$LAUNCH_AGENT_PLIST" && ! -L "$LAUNCH_AGENT_PLIST" ]]; then
  /bin/rm -f "$LAUNCH_AGENT_PLIST"
fi

# A screen session without a matching live runner/status is not readiness evidence. It may be a
# stale shell or a different requested build, so never replace or terminate it without proof of
# ownership; fail closed and leave it available for inspection.
if screen_session_is_live; then
  print -u2 -- \
    "Screen visual oracle session has no matching live runner: session=${SCREEN_SESSION} status=${RUN_STATUS}"
  exit 1
fi

: > "$RUN_LOG"
: > "$RUN_ERROR_LOG"
/bin/chmod 600 "$RUN_LOG" "$RUN_ERROR_LOG"

OPENSTEAMER_SCREEN_ORACLE_GATE_WAIT_SECONDS=604800 \
OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST="$HOST_IDENTITY_MANIFEST" \
OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256_PATH="$HOST_IDENTITY_MANIFEST_SHA256_PATH" \
OPENSTEAMER_SCREEN_ORACLE_HOST_IDENTITY_MANIFEST_SHA256="$HOST_IDENTITY_MANIFEST_SHA256" \
PATH="$LAUNCH_PATH" \
  /usr/bin/screen -dmS "$SCREEN_SESSION" /bin/zsh -c \
    'exec "$1" "$2" "$3" "$4" >>"$5" 2>>"$6"' \
    opensteamer-screen-oracle \
    "$RUNNER" "$DEVICE_ID" "$HARDWARE_UDID" "$EXPECTED_BUILD" \
    "$RUN_LOG" "$RUN_ERROR_LOG"

for (( attempt = 0; attempt < 100; attempt++ )); do
  if existing_pid=$(active_runner_pid); then
    print -- "Screen visual oracle armed: pid=${existing_pid} status=${RUN_STATUS} log=${RUN_LOG}"
    exit 0
  fi
  if ! screen_session_is_live; then
    print -u2 -- "Screen visual oracle could not be armed; inspect ${RUN_ERROR_LOG}"
    exit 1
  fi
  /bin/sleep 0.1
done

print -u2 -- \
  "Screen visual oracle session did not publish a matching live runner: session=${SCREEN_SESSION} status=${RUN_STATUS} log=${RUN_LOG}"
exit 1
