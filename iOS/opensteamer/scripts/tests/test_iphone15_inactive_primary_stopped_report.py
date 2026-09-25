#!/usr/bin/env python3
"""Exercise the actual inactive-primary reader, lifecycle, and final fences offline."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "validate-iphone15-dev-screen-visual-oracle.sh"
SESSION = "f5b7bf73-5a6f-4140-a795-9034570f7665"
PRIMARY_MARKERS = (
    "A fresh encrypted media rendezvous is ready for the paired iPhone",
    "The paired iPhone left the availability exchange",
    "Worldwide screen host is waiting for the paired iPhone media session",
    "Fresh paired media rendezvous expires in about 60 seconds",
    "Loaded the paired iPhone and started worldwide availability",
    "Worldwide paired-device availability is online pid=322 nonce=" + "a" * 64,
    "Worldwide paired-device availability is online pid=321 nonce=" + "b" * 64,
    "Worldwide paired-device availability is online pid=321 nonce=" + "a" * 64 + " extra=true",
)
AUDIO = (
    "Worldwide audio client diagnostics pid=321 status=renderingSilent "
    f"session={SESSION} build=0.1.0(85) peerGeneration=1 negotiationEpoch=1 "
    "sequence=938 appActive=false"
)
TERMINAL = (
    "Worldwide media ended; keeping paired availability alive\n"
    "Worldwide availability is waiting for the paired iPhone\n"
)
SECONDARY = (
    "Worldwide WebRTC peer state: connected pid=321\n"
    "Starting screen video capture\n"
    "Worldwide viewer disconnected; stopping screen video capture\n"
    "Stopping screen video capture\n"
)


def production_function(source, name):
    start = source.index(f"function {name}() {{\n")
    end = source.find("\nfunction ", start + 1)
    return source[start:end if end >= 0 else len(source)]


class InactivePrimaryStoppedReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = RUNNER.read_text()
        cls.functions = "\n".join(production_function(source, name) for name in (
            "diagnostic_field", "primary_audio_diagnostic_is_current_healthy",
            "primary_audio_diagnostic_is_terminal_inactive", "primary_audio_operational_fields_are_exact",
            "parse_inactive_primary_audio_diagnostic", "inactive_primary_lifecycle_is_terminal",
            "inactive_primary_lifecycle_suffix_is_quiescent", "inactive_primary_online_announcements_are_exact",
            "stopped_audio_report_directory_identity", "stopped_audio_report_descriptor_identity",
            "read_private_stopped_audio_report", "stopped_audio_report_matches_logged_identity",
            "inactive_primary_report_lifecycle_is_terminal", "stopped_report_current_host_start",
            "capture_inactive_primary_stopped_report", "recheck_inactive_primary_stopped_report",
            "record_inactive_primary_stopped_report_baseline", "never_connected_primary_baseline_is_exact",
            "record_never_connected_primary_baseline", "write_host_baseline_snapshot",
            "write_inactive_primary_append_window", "inactive_primary_append_has_no_primary_activity",
            "capture_inactive_primary_continuity", "capture_host_baseline", "write_host_delta",
            "require_no_host_lifecycle_delta", "host_delta_is_complete",
        ))

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iphone15-stopped-report-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.report = self.root / "support/opensteamer/diagnostics/audio-client-v1.json"
        for directory in (self.root / "support", self.report.parent.parent, self.report.parent):
            directory.mkdir(mode=0o700)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir(mode=0o700)
        self.host_log = self.root / "host.log"
        self.host_log.write_text(AUDIO + "\n" + TERMINAL)
        self.host_start = int(time.time()) - 1000
        received = (self.host_start + 100) * 1000
        self.value = {
            "schemaVersion": 1, "kind": "opensteamer.audio-client.v1", "hostPID": 321,
            "generatedAtUnixMilliseconds": received + 5000,
            "receivedAtUnixMilliseconds": received,
            "freshUntilUnixMilliseconds": received + 5000,
            "status": "unavailable.stopped", "acousticAudibility": "unverified",
            "peerGeneration": 1, "negotiationEpoch": 1,
            "heartbeat": {"i": SESSION.upper(), "s": 938,
                          "b": {"a": 0, "b": 1, "c": 0, "d": 85}, "n": {"l": False}},
        }
        self.write_report(self.value)

    def write_report(self, value):
        self.report.write_text(json.dumps(value))
        self.report.chmod(0o600)

    def run_shell(self, commands, *, expect=0, prelude=""):
        script = r'''
set -euo pipefail
umask 077
ARTIFACT_DIR=$FIXTURE_ROOT/artifacts
HOST_LOG=$FIXTURE_ROOT/host.log
HOST_AUDIO_CLIENT_REPORT=$FIXTURE_ROOT/support/opensteamer/diagnostics/audio-client-v1.json
HOST_PID=321
HOST_GENERATION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EXPECTED_PRIMARY_BUILD=85
SECONDARY_MANAGER_GENERATION_BASELINE=0
HOST_BASELINE_TAIL_BYTES=1048576
HOST_LOG_DEVICE=$(/usr/bin/stat -f '%d' "$HOST_LOG")
HOST_LOG_INODE=$(/usr/bin/stat -f '%i' "$HOST_LOG")
HOST_LOG_BASE_SIZE=$(/usr/bin/stat -f '%z' "$HOST_LOG")
HOST_LOG_CONTINUITY_CURSOR=$HOST_LOG_BASE_SIZE
HOST_LOG_CONTINUITY_PENDING_CURSOR=$HOST_LOG_BASE_SIZE
PRIMARY_BASELINE_MODE=''
PRIMARY_INACTIVE_EVIDENCE=log
PRIMARY_STOPPED_REPORT_HOST_START=$FIXTURE_HOST_START
IPHONE_CONTROL_PYTHON=$FIXTURE_PYTHON
function fail() { print -u2 -r -- "$1"; exit 41 }
'''
        # Only unavailable live process/readiness probes are replaced. All filesystem,
        # structured report, lifecycle, cursor, baseline, and final fence code is production.
        probes = r'''
function require_same_host() { : }
function capture_host_generation_identity() { : }
function capture_secondary_manager_idle_probe() { : }
function host_elapsed_seconds() { print 1000 }
function stopped_report_current_host_start() { print -r -- "$FIXTURE_HOST_START" }
'''
        result = subprocess.run(
            ["/bin/zsh", "-f", "-c", script + self.functions + probes + prelude + commands],
            env={**os.environ, "FIXTURE_ROOT": str(self.root),
                 "FIXTURE_HOST_START": str(self.host_start), "FIXTURE_PYTHON": sys.executable},
            text=True, capture_output=True, timeout=8,
        )
        if expect == 0:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def test_rate_limited_log_uses_completed_lifecycle_and_private_report(self):
        # Same-generation online reannouncements are normal availability reconnects.
        with self.host_log.open("a") as stream:
            stream.write("[info] Worldwide paired-device availability is online pid=321 nonce=" + "a" * 64 + "\n")
        self.run_shell(r'''
capture_host_baseline
[[ "$PRIMARY_BASELINE_MODE" == inactivePrimary && "$PRIMARY_INACTIVE_EVIDENCE" == stoppedReport ]]
[[ "$PRIMARY_SESSION_ID" == f5b7bf73-5a6f-4140-a795-9034570f7665 ]]
[[ "$PRIMARY_AUDIO_SEQUENCE_BEFORE" == 938 && "$PRIMARY_CONTINUITY_ASSURANCE" == inactivePrimaryNoAudioProof ]]
capture_inactive_primary_continuity premint
print -r -- "[info] Worldwide paired-device availability is online pid=321 nonce=${HOST_GENERATION}" >> "$HOST_LOG"
require_no_host_lifecycle_delta final-premint
print -r -- 'Worldwide WebRTC peer state: connected pid=321' >> "$HOST_LOG"
print -r -- 'Starting screen video capture' >> "$HOST_LOG"
print -r -- 'Worldwide viewer disconnected; stopping screen video capture' >> "$HOST_LOG"
print -r -- 'Stopping screen video capture' >> "$HOST_LOG"
capture_inactive_primary_continuity after
host_delta_is_complete
''')
        proof = json.loads((self.artifacts / "before-primary-audio-continuity.json").read_text())
        self.assertFalse(proof["audioProof"])
        self.assertFalse(proof["microphoneProof"])
        self.assertEqual(proof["retainedSequence"], 938)
        self.assertNotIn("unavailable.stopped", (self.artifacts / "before-host-baseline.log").read_text())

    def test_original_exact_log_path_does_not_require_report(self):
        self.host_log.write_text("Worldwide viewer disconnected; stopping capture\n" +
                                 AUDIO.replace("renderingSilent", "unavailable.stopped") + "\n" + TERMINAL)
        self.report.unlink()
        self.run_shell('capture_host_baseline\n[[ "$PRIMARY_INACTIVE_EVIDENCE" == log ]]\n')

    def test_report_without_completed_matching_lifecycle_is_rejected(self):
        for log in (AUDIO + "\n", TERMINAL + AUDIO + "\n",
                    AUDIO + "\nWorldwide media ended; stopped\n",
                    AUDIO + "\n" + TERMINAL + "Starting screen video capture\n"):
            with self.subTest(log=log):
                self.host_log.write_text(log)
                self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n', expect=1)

    def test_primary_or_generation_start_cannot_borrow_terminal_report(self):
        for marker in PRIMARY_MARKERS:
            for before_terminal in (True, False):
                with self.subTest(marker=marker, before_terminal=before_terminal):
                    self.host_log.write_text(AUDIO + "\n" +
                                             (marker + "\n" + TERMINAL if before_terminal else TERMINAL + marker + "\n"))
                    # Availability departure can cause this exact teardown. It is not a
                    # reactivation when the completed lifecycle still follows afterward.
                    expected = 0 if before_terminal and marker == "The paired iPhone left the availability exchange" else 1
                    self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n', expect=expected)

    def test_report_identity_schema_and_lifetime_are_exact(self):
        changes = [
            ("hostPID", 322), ("schemaVersion", True), ("kind", "wrong"),
            ("status", "renderingSilent"), ("peerGeneration", 2), ("negotiationEpoch", 2),
            ("generatedAtUnixMilliseconds", int(time.time() + 60) * 1000),
            ("receivedAtUnixMilliseconds", (self.host_start - 1) * 1000),
            ("freshUntilUnixMilliseconds", self.value["receivedAtUnixMilliseconds"] - 1),
            ("generatedAtUnixMilliseconds", str(self.value["generatedAtUnixMilliseconds"])),
            ("extra", 1), ("heartbeat.i", "0" * 36), ("heartbeat.s", 937),
            ("heartbeat.s", True), ("heartbeat.b.d", 86), ("heartbeat.b.a", False),
            ("heartbeat.n.l", True),
        ]
        for key, item in changes:
            with self.subTest(key=key, value=item):
                value = copy.deepcopy(self.value)
                target = value
                parts = key.split(".")
                for part in parts[:-1]:
                    target = target[part]
                target[parts[-1]] = item
                self.write_report(value)
                self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n', expect=1)
        for key in self.value:
            with self.subTest(missing=key):
                value = copy.deepcopy(self.value)
                del value[key]
                self.write_report(value)
                self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n', expect=1)

    def test_duplicate_container_and_leaf_keys_and_malformed_json_are_rejected(self):
        encoded = json.dumps(self.value)
        malformed = ["{", "[]", encoded + encoded, encoded.replace('"hostPID": 321', '"hostPID": 1, "hostPID": 321'),
                     encoded.replace('"heartbeat": {', '"heartbeat": {"unexpected": 1}, "heartbeat": {'),
                     encoded.replace('"n": {"l": false}', '"n": {"l": true}, "n": {"l": false}')]
        for value in malformed:
            with self.subTest(value=value[:60]):
                self.report.write_text(value)
                self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n', expect=1)

    def test_private_storage_rejects_links_permissions_and_oversized_files(self):
        cases = (
            'chmod 644 "$HOST_AUDIO_CLIENT_REPORT"',
            'chmod 755 "${HOST_AUDIO_CLIENT_REPORT:h}"',
            'ln "$HOST_AUDIO_CLIENT_REPORT" "$FIXTURE_ROOT/extra-link"',
            'mv "$HOST_AUDIO_CLIENT_REPORT" "$FIXTURE_ROOT/real-report"; ln -s "$FIXTURE_ROOT/real-report" "$HOST_AUDIO_CLIENT_REPORT"',
            'mv "${HOST_AUDIO_CLIENT_REPORT:h}" "$FIXTURE_ROOT/real-directory"; ln -s "$FIXTURE_ROOT/real-directory" "${HOST_AUDIO_CLIENT_REPORT:h}"',
            'head -c 32769 /dev/zero > "$HOST_AUDIO_CLIENT_REPORT"',
        )
        for command in cases:
            with self.subTest(command=command):
                # Each destructive operation is confined to its own disposable fixture.
                fixture = InactivePrimaryStoppedReportTests()
                fixture.setUp()
                try:
                    fixture.run_shell(command + '\nread_private_stopped_audio_report "$ARTIFACT_DIR/readback.json"\n', expect=1)
                finally:
                    fixture.doCleanups()

    def test_acl_inspection_failure_is_not_treated_as_empty_acl(self):
        self.run_shell('read_private_stopped_audio_report "$ARTIFACT_DIR/readback.json"\n', expect=1,
                       prelude='function /bin/ls() { return 73 }\n')

    def test_no_follow_nonblocking_open_rejects_leaf_type_race(self):
        for replacement in ('/usr/bin/mkfifo "$HOST_AUDIO_CLIENT_REPORT"',
                            '/bin/ln -s "$FIXTURE_ROOT/original-report" "$HOST_AUDIO_CLIENT_REPORT"'):
            with self.subTest(replacement=replacement):
                fixture = InactivePrimaryStoppedReportTests()
                fixture.setUp()
                try:
                    fixture.run_shell('read_private_stopped_audio_report "$ARTIFACT_DIR/readback.json"\n', expect=1,
                                      prelude='function sysopen() {\n/bin/mv "$HOST_AUDIO_CLIENT_REPORT" "$FIXTURE_ROOT/original-report"\n' +
                                      replacement + '\nbuiltin sysopen "$@"\n}\n')
                finally:
                    fixture.doCleanups()

    def test_report_replacement_or_drift_is_rejected_at_every_fence(self):
        for phase in ("before", "premint", "after"):
            for replacement in (False, True):
                with self.subTest(phase=phase, replacement=replacement):
                    mutation = ('cp "$HOST_AUDIO_CLIENT_REPORT" "$FIXTURE_ROOT/replacement"; '
                                'mv "$FIXTURE_ROOT/replacement" "$HOST_AUDIO_CLIENT_REPORT"' if replacement else
                                'print -n -- " " >> "$HOST_AUDIO_CLIENT_REPORT"')
                    self.run_shell('capture_inactive_primary_stopped_report "$HOST_LOG"\n' + mutation +
                                   f'\nrecheck_inactive_primary_stopped_report {phase}\n', expect=1)
                    self.write_report(self.value)

    def test_late_primary_marker_cannot_escape_final_filtered_lifecycle_fence(self):
        for marker in PRIMARY_MARKERS:
            for mode in ("inactivePrimary", "neverConnectedPrimary"):
                for phase in ("premint", "after"):
                    with self.subTest(marker=marker, mode=mode, phase=phase):
                        self.host_log.write_text(AUDIO + "\n" + TERMINAL)
                        commands = 'capture_host_baseline\n' if mode == "inactivePrimary" else (
                            'PRIMARY_BASELINE_MODE=neverConnectedPrimary\n'
                            'PRIMARY_CONTINUITY_ASSURANCE=neverConnectedPrimaryNoAudioProof\n')
                        if phase == "after":
                            commands += 'print -r -- "$FIXTURE_SECONDARY" >> "$HOST_LOG"\n'
                        commands += f'capture_inactive_primary_continuity {phase}\n'
                        commands += 'print -r -- "$FIXTURE_MARKER" >> "$HOST_LOG"\n'
                        commands += 'require_no_host_lifecycle_delta final-premint\n' if phase == "premint" else 'host_delta_is_complete\n'
                        prelude = 'FIXTURE_MARKER=' + json.dumps(marker) + '\nFIXTURE_SECONDARY=' + json.dumps(SECONDARY.rstrip()).replace('\\n', '\n') + '\n'
                        result = self.run_shell(commands, expect=1, prelude=prelude)
                        self.assertIn("final host lifecycle fence", result.stderr)

    def test_incomplete_or_additional_secondary_lifecycle_still_rejects(self):
        for events in (SECONDARY.replace("Stopping screen video capture\n", ""), SECONDARY + SECONDARY):
            with self.subTest(events=events):
                self.host_log.write_text(AUDIO + "\n" + TERMINAL)
                self.run_shell('capture_host_baseline\nprint -r -- "$FIXTURE_EVENTS" >> "$HOST_LOG"\n'
                               'capture_inactive_primary_continuity after\n', expect=1,
                               prelude='FIXTURE_EVENTS=' + json.dumps(events.rstrip()).replace('\\n', '\n') + '\n')


if __name__ == "__main__":
    unittest.main()
