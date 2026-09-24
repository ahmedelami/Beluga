#!/bin/zsh

# Acknowledge only the currently armed, exact iPhone 15 development run. This helper contains and
# reads no passcode. It proves a fresh exact-device unlocked-state observation and that no matching
# credential-holding controller is currently running. It does not attest screenshot history or prove
# that an unlock controller was previously launched and released.
set -euo pipefail
umask 077

readonly DEVICE_ID='10B6E5EE-D3B9-5334-99C1-EA12EFA34447'
readonly HARDWARE_UDID='00008120-0000242E3E32201E'
readonly APP_BUNDLE_ID='org.example.AudioStreamer.dev'
readonly RUN_STATE_ROOT=/Volumes/t7/opensteamer-screen-oracle-state
readonly RUN_STATUS="${RUN_STATE_ROOT}/${DEVICE_ID}-${APP_BUNDLE_ID}.json"
readonly RUN_LOCK="${RUN_STATE_ROOT}/${DEVICE_ID}-${APP_BUNDLE_ID}.lock"
readonly RUNNER_NAME='validate-iphone15-dev-screen-visual-oracle.sh'
readonly RUN_STATUS_HEARTBEAT_MAX_AGE_SECONDS=5
readonly UNLOCK_REQUEST_LIFETIME_SECONDS=1800

if (( $# != 0 )); then
  print -u2 -- "usage: $0"
  exit 2
fi
for tool in jq xcrun ps stat mktemp date lockf shasum awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    print -u2 -- "Missing required tool: ${tool}"
    exit 2
  }
done

function require_runner_lock_held() {
  typeset -gi probe_fd
  exec {probe_fd}>>"$RUN_LOCK"
  if /usr/bin/lockf -s -t 0 "$probe_fd"; then
    exec {probe_fd}>&-
    return 1
  fi
  exec {probe_fd}>&-
  return 0
}

function require_runner_lock_metadata() {
  jq -e --argjson pid "$runner_pid" \
    --arg runnerProcessStart "$runner_process_start" \
    --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
    --arg bundle "$APP_BUNDLE_ID" '
      (keys | sort) == ["bundleId","deviceId","hardwareUDID","pid",
        "runnerProcessStart","schema"] and
      .schema == "opensteamer.iphone15-dev-screen-visual-oracle-lock.v1" and
      .pid == $pid and .runnerProcessStart == $runnerProcessStart and
      .deviceId == $device and .hardwareUDID == $udid and .bundleId == $bundle
    ' "$RUN_LOCK" >/dev/null 2>&1
}

[[ -f "$RUN_STATUS" && ! -L "$RUN_STATUS" \
    && "$(/usr/bin/stat -f '%u' "$RUN_STATUS")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$RUN_STATUS")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$RUN_STATUS")" == 1 ]] \
  || { print -u2 -- 'No private iPhone 15 development run status is available.'; exit 1; }
[[ -f "$RUN_LOCK" && ! -L "$RUN_LOCK" \
    && "$(/usr/bin/stat -f '%u' "$RUN_LOCK")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$RUN_LOCK")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$RUN_LOCK")" == 1 \
    && "$(/usr/bin/stat -f '%z' "$RUN_LOCK")" -le 1024 ]] \
  || { print -u2 -- 'The development runner lock is unsafe.'; exit 1; }
require_runner_lock_held \
  || { print -u2 -- 'The development runner no longer owns its lock.'; exit 1; }

typeset runner_pid runner_process_start artifact_dir request_path now
now=$(/bin/date '+%s')
runner_pid=$(jq -er --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
  --arg bundle "$APP_BUNDLE_ID" --argjson now "$now" \
  --argjson maxAge "$RUN_STATUS_HEARTBEAT_MAX_AGE_SECONDS" '
    select(.schema == "opensteamer.iphone15-dev-screen-visual-oracle-run.v1" and
      .phase == "armed" and
      .stage == "awaiting-exact-device-unlocked-state-acknowledgement" and
      .deviceId == $device and .hardwareUDID == $udid and .bundleId == $bundle and
      (.pid | type == "number" and . > 1 and floor == .) and
      (.runnerProcessStart | type == "string" and length > 0) and
      (.updatedAtEpoch | type == "number" and floor == . and
        . >= ($now - $maxAge) and . <= ($now + 2)) and
      (.artifactDir | type == "string") and (.unlockRequest | type == "string"))
    | .pid
  ' "$RUN_STATUS") || { print -u2 -- 'The development run is not armed for unlock.'; exit 1; }
runner_process_start=$(jq -er '.runnerProcessStart' "$RUN_STATUS")
artifact_dir=$(jq -er '.artifactDir' "$RUN_STATUS")
request_path=$(jq -er '.unlockRequest' "$RUN_STATUS")
[[ "$artifact_dir" == /Volumes/t7/opensteamer-iphone15-dev-screen-oracle.* \
    && -d "$artifact_dir" && ! -L "$artifact_dir" \
    && "$(/usr/bin/stat -f '%u' "$artifact_dir")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$artifact_dir")" == 700 \
    && "$request_path" == "${artifact_dir}/unlock-request.json" ]] \
  || { print -u2 -- 'The armed run directory is unsafe.'; exit 1; }

typeset runner_command actual_runner_process_start
runner_command=$(ps -ww -p "$runner_pid" -o command= 2>/dev/null) \
  || { print -u2 -- 'The armed runner is no longer active.'; exit 1; }
[[ " $runner_command " == *"${RUNNER_NAME}"* ]] \
  || { print -u2 -- 'The armed PID is not the development runner.'; exit 1; }
actual_runner_process_start=$(LC_ALL=C ps -ww -p "$runner_pid" -o lstart= 2>/dev/null \
  | /usr/bin/awk '{$1=$1; print}') \
  || { print -u2 -- 'The armed runner process-start identity is unavailable.'; exit 1; }
[[ "$actual_runner_process_start" == "$runner_process_start" ]] \
  || { print -u2 -- 'The armed runner PID was reused.'; exit 1; }
require_runner_lock_metadata \
  || { print -u2 -- 'The development runner lock owner is mismatched.'; exit 1; }

[[ -f "$request_path" && ! -L "$request_path" \
    && "$(/usr/bin/stat -f '%u' "$request_path")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$request_path")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$request_path")" == 1 \
    && "$(/usr/bin/stat -f '%z' "$request_path")" -le 2048 ]] \
  || { print -u2 -- 'The unlock request is unsafe.'; exit 1; }

typeset nonce expires_at ack_path request_sha256
nonce=$(jq -er --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
  --arg bundle "$APP_BUNDLE_ID" --argjson pid "$runner_pid" \
  --arg artifact "$artifact_dir" --arg runnerProcessStart "$runner_process_start" \
  --argjson lifetime "$UNLOCK_REQUEST_LIFETIME_SECONDS" --argjson now "$now" '
    select((keys | sort) == ["artifactDir","bundleId","createdAt","deviceId",
      "expiresAt","hardwareUDID","runNonce","runnerPid","runnerProcessStart","schema"] and
      .schema == "opensteamer.iphone15-dev-unlock-request.v1" and
      .deviceId == $device and .hardwareUDID == $udid and .bundleId == $bundle and
      .runnerPid == $pid and .artifactDir == $artifact and
      .runnerProcessStart == $runnerProcessStart and
      (.runNonce | type == "string" and test("^[0-9a-f]{32}$")) and
      (.createdAt | type == "number") and
      (.createdAt | floor) == .createdAt and .createdAt <= ($now + 2) and
      (.expiresAt | type == "number") and
      (.expiresAt | floor) == .expiresAt and
      (.expiresAt - .createdAt) == $lifetime)
    | .runNonce
  ' "$request_path") || { print -u2 -- 'The unlock request is malformed.'; exit 1; }
expires_at=$(jq -er '.expiresAt' "$request_path")
(( now <= expires_at )) || { print -u2 -- 'The unlock request expired.'; exit 1; }
request_sha256=$(/usr/bin/shasum -a 256 "$request_path" \
  | /usr/bin/awk '{ print $1 }')
[[ "$request_sha256" =~ '^[0-9a-f]{64}$' ]] \
  || { print -u2 -- 'The unlock request identity is unavailable.'; exit 1; }
ack_path="${artifact_dir}/unlock-ack.json"
[[ ! -e "$ack_path" && ! -L "$ack_path" ]] \
  || { print -u2 -- 'An unlock acknowledgement already exists.'; exit 1; }
readonly ACK_PUBLICATION_LOCK="${ack_path}.publication.lock"
[[ ! -e "$ACK_PUBLICATION_LOCK" \
    || ( -f "$ACK_PUBLICATION_LOCK" && ! -L "$ACK_PUBLICATION_LOCK" \
      && "$(/usr/bin/stat -f '%u' "$ACK_PUBLICATION_LOCK")" == "$UID" \
      && "$(/usr/bin/stat -f '%Lp' "$ACK_PUBLICATION_LOCK")" == 600 \
      && "$(/usr/bin/stat -f '%l' "$ACK_PUBLICATION_LOCK")" == 1 ) ]] \
  || { print -u2 -- 'The unlock acknowledgement publication lock is unsafe.'; exit 1; }
/usr/bin/touch "$ACK_PUBLICATION_LOCK"
/bin/chmod 600 "$ACK_PUBLICATION_LOCK"
[[ -f "$ACK_PUBLICATION_LOCK" && ! -L "$ACK_PUBLICATION_LOCK" \
    && "$(/usr/bin/stat -f '%u' "$ACK_PUBLICATION_LOCK")" == "$UID" \
    && "$(/usr/bin/stat -f '%Lp' "$ACK_PUBLICATION_LOCK")" == 600 \
    && "$(/usr/bin/stat -f '%l' "$ACK_PUBLICATION_LOCK")" == 1 ]] \
  || { print -u2 -- 'The unlock acknowledgement publication lock is unsafe.'; exit 1; }
typeset -gi ACK_PUBLICATION_FD
exec {ACK_PUBLICATION_FD}>>"$ACK_PUBLICATION_LOCK"
/usr/bin/lockf -s -t 0 "$ACK_PUBLICATION_FD" \
  || { print -u2 -- 'Another unlock acknowledgement writer is active.'; exit 1; }
readonly ACK_PUBLICATION_FD
[[ ! -e "$ack_path" && ! -L "$ack_path" ]] \
  || { print -u2 -- 'An unlock acknowledgement already exists.'; exit 1; }

while read -r process_pid process_command; do
  [[ -n "$process_pid" ]] || continue
  if [[ "$process_command" == *'/iphone-usb-unlock/scripts/control_session.py'* \
      && " $process_command " == *" --udid ${HARDWARE_UDID} "* ]]; then
    print -u2 -- 'Exit the exact iPhone unlock controller before acknowledgement.'
    exit 1
  fi
done < <(ps -axo pid=,command=)

readonly DETAILS="${artifact_dir}/unlock-ack-device.json"
readonly LOCK_STATE="${artifact_dir}/unlock-ack-lock.json"
xcrun devicectl device info details --device "$DEVICE_ID" --timeout 20 \
  --json-output "$DETAILS" >/dev/null \
  || { print -u2 -- 'Exact development iPhone identity is unavailable.'; exit 1; }
jq -e --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" '
  (.info.outcome == "success") and (.result.identifier == $device) and
  (.result.hardwareProperties.udid == $udid) and
  (.result.hardwareProperties.platform == "iOS") and
  (.result.hardwareProperties.reality == "physical") and
  (.result.hardwareProperties.marketingName | startswith("iPhone 15")) and
  (.result.deviceProperties.bootState == "booted") and
  (.result.connectionProperties.pairingState == "paired")
' "$DETAILS" >/dev/null \
  || { print -u2 -- 'The connected device is not the dedicated iPhone 15.'; exit 1; }
xcrun devicectl device info lockState --device "$DEVICE_ID" --timeout 20 \
  --json-output "$LOCK_STATE" >/dev/null \
  || { print -u2 -- 'Development iPhone lock state is unavailable.'; exit 1; }
jq -e '.info.outcome == "success" and .result.passcodeRequired == false' \
  "$LOCK_STATE" >/dev/null \
  || { print -u2 -- 'The development iPhone is not unlocked.'; exit 1; }
typeset observed_unlocked_at
observed_unlocked_at=$(/bin/date '+%s')

# The identity and lock probes can each take up to twenty seconds. Re-read every mutable rendezvous
# boundary after those calls so an expired, parked, replaced, or controller-overlapped run can never
# publish an acknowledgement based on the earlier snapshot.
jq -e --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
  --arg bundle "$APP_BUNDLE_ID" --arg artifact "$artifact_dir" \
  --arg request "$request_path" --arg runnerProcessStart "$runner_process_start" \
  --argjson pid "$runner_pid" --argjson now "$observed_unlocked_at" \
  --argjson maxAge "$RUN_STATUS_HEARTBEAT_MAX_AGE_SECONDS" '
    .schema == "opensteamer.iphone15-dev-screen-visual-oracle-run.v1" and
    .phase == "armed" and
    .stage == "awaiting-exact-device-unlocked-state-acknowledgement" and
    .pid == $pid and .deviceId == $device and .hardwareUDID == $udid and
    .bundleId == $bundle and .artifactDir == $artifact and .unlockRequest == $request and
    .runnerProcessStart == $runnerProcessStart and
    (.updatedAtEpoch | type == "number" and floor == . and
      . >= ($now - $maxAge) and . <= ($now + 2))
  ' "$RUN_STATUS" >/dev/null \
  || { print -u2 -- 'The development run stopped being armed during verification.'; exit 1; }
runner_command=$(ps -ww -p "$runner_pid" -o command= 2>/dev/null) \
  || { print -u2 -- 'The armed runner exited during verification.'; exit 1; }
[[ " $runner_command " == *"${RUNNER_NAME}"* ]] \
  || { print -u2 -- 'The armed PID changed identity during verification.'; exit 1; }
actual_runner_process_start=$(LC_ALL=C ps -ww -p "$runner_pid" -o lstart= 2>/dev/null \
  | /usr/bin/awk '{$1=$1; print}') \
  || { print -u2 -- 'The runner process-start identity disappeared.'; exit 1; }
[[ "$actual_runner_process_start" == "$runner_process_start" ]] \
  || { print -u2 -- 'The armed runner PID was reused during verification.'; exit 1; }
require_runner_lock_held \
  || { print -u2 -- 'The development runner released its lock during verification.'; exit 1; }
require_runner_lock_metadata \
  || { print -u2 -- 'The development runner lock owner changed during verification.'; exit 1; }
jq -e --arg nonce "$nonce" --argjson pid "$runner_pid" \
  --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
  --arg bundle "$APP_BUNDLE_ID" --arg artifact "$artifact_dir" \
  --arg runnerProcessStart "$runner_process_start" \
  --argjson lifetime "$UNLOCK_REQUEST_LIFETIME_SECONDS" '
    (keys | sort) == ["artifactDir","bundleId","createdAt","deviceId",
      "expiresAt","hardwareUDID","runNonce","runnerPid","runnerProcessStart","schema"] and
    .schema == "opensteamer.iphone15-dev-unlock-request.v1" and
    .runNonce == $nonce and .runnerPid == $pid and .deviceId == $device and
    .hardwareUDID == $udid and .bundleId == $bundle and .artifactDir == $artifact and
    .runnerProcessStart == $runnerProcessStart and
    (.expiresAt - .createdAt) == $lifetime
  ' "$request_path" >/dev/null \
  || { print -u2 -- 'The private unlock request changed during verification.'; exit 1; }
[[ "$(/usr/bin/shasum -a 256 "$request_path" | /usr/bin/awk '{ print $1 }')" \
      == "$request_sha256" ]] \
  || { print -u2 -- 'The private unlock request bytes changed during verification.'; exit 1; }
while read -r process_pid process_command; do
  [[ -n "$process_pid" ]] || continue
  if [[ "$process_command" == *'/iphone-usb-unlock/scripts/control_session.py'* \
      && " $process_command " == *" --udid ${HARDWARE_UDID} "* ]]; then
    print -u2 -- 'The exact iPhone unlock controller restarted during verification.'
    exit 1
  fi
done < <(ps -axo pid=,command=)
now=$(/bin/date '+%s')
(( now <= expires_at )) || { print -u2 -- 'The unlock request expired during verification.'; exit 1; }
(( now - observed_unlocked_at <= RUN_STATUS_HEARTBEAT_MAX_AGE_SECONDS )) \
  || { print -u2 -- 'The observed unlocked state became stale before publication.'; exit 1; }

typeset temporary_ack
temporary_ack=$(/usr/bin/mktemp "${ack_path}.tmp.XXXXXX")
jq -n --arg schema 'opensteamer.iphone15-dev-unlock-ack.v1' \
  --arg nonce "$nonce" --arg device "$DEVICE_ID" --arg udid "$HARDWARE_UDID" \
  --arg bundle "$APP_BUNDLE_ID" --arg runnerProcessStart "$runner_process_start" \
  --arg requestSHA256 "$request_sha256" --argjson pid "$runner_pid" \
  --argjson observed "$observed_unlocked_at" \
  '{schema:$schema,runNonce:$nonce,runnerPid:$pid,
    runnerProcessStart:$runnerProcessStart,unlockRequestSHA256:$requestSHA256,deviceId:$device,
    hardwareUDID:$udid,bundleId:$bundle,observedUnlockedAt:$observed,
    matchingUnlockControllerAbsent:true}' > "$temporary_ack"
/bin/chmod 600 "$temporary_ack"
/bin/mv -n "$temporary_ack" "$ack_path"
[[ ! -e "$temporary_ack" && -f "$ack_path" && ! -L "$ack_path" ]] \
  || { /bin/rm -f "$temporary_ack"; print -u2 -- 'Unlock acknowledgement publication raced.'; exit 1; }
print -- 'Acknowledged the exact-device unlocked state for the armed iPhone 15 development run.'
