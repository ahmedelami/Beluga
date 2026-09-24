#!/usr/bin/env python3
"""Execute the production result classifier and post-test safety block without devices."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "validate-iphone15-dev-screen-visual-oracle.sh"
UDID = "00008120-0000242E3E32201E"
TEST_NODE = (
    "IPhone15SecondaryViewerDevelopmentPhysicalUITests/"
    "testTemporaryViewerFinalPixelsTrackFreshMacChallenge()"
)
INITIALIZATION_ERROR = (
    "The test runner failed to initialize for UI testing. "
    "(Underlying Error: Timed out while enabling automation mode.)"
)


class PhysicalTestFailureReportingTests(unittest.TestCase):
    def run_case(
        self, *, exit_status=65, selected=False, receipt=False,
        initialization=True, bad_result=None, started_log=False,
    ):
        source = RUNNER.read_text()
        helpers = source[source.index("\nfunction fail() {\n"):
                         source.index("\nfunction owned_child_is_alive() {\n")]
        post_test = source[source.index("\nSTAGE=post-test-safety\n"):
                           source.index("\ntypeset -a visual_markers\n")]
        summary = {
            "result": "Failed" if exit_status else "Passed",
            "totalTestCount": 1,
            "devicesAndConfigurations": [{"device": {"deviceId": UDID}}],
            "testFailures": [{
                "targetName": "opensteamerUITests",
                "failureText": INITIALIZATION_ERROR if initialization else "black final pixels",
            }] if exit_status else [],
        }
        tests = {
            "devices": [{"deviceId": UDID}],
            "testNodes": [{
                "nodeType": "Test Case",
                "nodeIdentifier": TEST_NODE if selected else
                    "opensteamerUITests-Runner (1617) encountered an error",
                "result": "Failed" if exit_status else "Passed",
            }],
        }
        if bad_result == "wrong-device":
            tests["devices"][0]["deviceId"] = "wrong"
        if bad_result == "missing-tree":
            del tests["testNodes"]
        with tempfile.TemporaryDirectory(prefix="iphone15-failure-reporting-") as directory:
            root = Path(directory)
            (root / "summary.fixture.json").write_text(json.dumps(summary))
            (root / "tests.fixture.json").write_text(
                "{" if bad_result == "malformed" else json.dumps(tests)
            )
            (root / "test.log").write_text(
                "Test Case '-[opensteamerUITests."
                "IPhone15SecondaryViewerDevelopmentPhysicalUITests "
                "testTemporaryViewerFinalPixelsTrackFreshMacChallenge]' started.\n"
                if started_log else INITIALIZATION_ERROR + "\n"
            )
            for name in ["before-test-dev-app.json", "after-test-dev-app.json"]:
                (root / name).write_text("{}")
            script = r'''
set -euo pipefail
ARTIFACT_DIR=$FIXTURE_ROOT
RESULT_BUNDLE=$FIXTURE_ROOT/result.xcresult
FAILURE_REASON=''
PHYSICAL_TEST_EXIT_STATUS=''
PHYSICAL_TEST_FAILURE_CLASS=''
PHYSICAL_TEST_FAILURE_REASON=''
SELECTED_TEST_RECORD=unavailable
XCRESULT_SUMMARY_CAPTURED=0
XCRESULT_TESTS_CAPTURED=0
DEVICE_SECRET_CLEANUP_REQUIRED=1
DEVICE_SECRET_CLEANUP_CONFIRMED=0
VERIFIED=0
NONCE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
test_status=$FIXTURE_EXIT_STATUS
function xcrun() {
  [[ "$1 $2 $3" == 'xcresulttool get test-results' ]] || return 91
  if [[ "$FIXTURE_BAD_RESULT" == unavailable ]]; then
    print -u2 -- 'fixture result bundle unavailable'
    return 1
  fi
  /bin/cat "$FIXTURE_ROOT/$4.fixture.json"
}
function rg() {
  [[ "$FIXTURE_BAD_RESULT" != log-scan-error ]] || return 2
  command rg "$@"
}
function require_no_production_observer() { : }
function require_same_host() { : }
function require_device_power_assertion_healthy() { : }
function capture_audio_routes() { : }
function require_audio_route_monitor_healthy() { : }
function verify_prepared_products_unchanged() { : }
function verify_device_secret_cleanup_receipt() {
  [[ "$1 $2" == "$NONCE viewer-import" ]] || return 92
  [[ "$FIXTURE_RECEIPT" == yes ]]
}
function run_device_secret_cleanup() {
  DEVICE_SECRET_CLEANUP_REQUIRED=0
  DEVICE_SECRET_CLEANUP_CONFIRMED=1
}
function capture_device_identity() { : }
function capture_installed_dev_app() { : }
function stop_device_power_assertion() { : }
function wait_for_host_delta() { : }
function stop_secondary_generation() { : }
function record_exit() {
  local exit_code=$?
  jq -n --arg reason "$FAILURE_REASON" --arg kind "$PHYSICAL_TEST_FAILURE_CLASS" \
    --arg selected "$SELECTED_TEST_RECORD" --arg testStatus "$PHYSICAL_TEST_EXIT_STATUS" \
    --argjson exitCode "$exit_code" --argjson cleanupRequired "$DEVICE_SECRET_CLEANUP_REQUIRED" \
    --argjson cleanupConfirmed "$DEVICE_SECRET_CLEANUP_CONFIRMED" --argjson verified "$VERIFIED" \
    '{reason:$reason,kind:$kind,selected:$selected,testStatus:$testStatus,exitCode:$exitCode,
      cleanupRequired:$cleanupRequired,cleanupConfirmed:$cleanupConfirmed,verified:$verified}'
}
trap record_exit EXIT
'''
            process = subprocess.run(
                ["/bin/zsh", "-f", "-c", script + helpers +
                 '\ncapture_physical_test_result "$test_status"\n' + post_test],
                env={
                    "PATH": os.environ.get("PATH", "/opt/homebrew/bin:/usr/bin:/bin"),
                    "FIXTURE_ROOT": directory,
                    "FIXTURE_EXIT_STATUS": str(exit_status),
                    "FIXTURE_RECEIPT": "yes" if receipt else "no",
                    "FIXTURE_BAD_RESULT": bad_result or "",
                    "HARDWARE_UDID": UDID,
                    "TEST_NODE": TEST_NODE,
                }, text=True, capture_output=True, timeout=10,
            )
            self.assertIn(process.returncode, (0, 1), process.stderr)
            evidence = json.loads(process.stdout)
            self.assertEqual(evidence["exitCode"], process.returncode)
            self.assertEqual(evidence["verified"], 0)
            return evidence

    def test_initialization_is_primary_and_missing_receipt_is_retained(self):
        evidence = self.run_case()
        self.assertEqual(evidence["kind"], "xctestInitializationFailure")
        self.assertEqual(evidence["selected"], "absent")
        self.assertEqual(evidence["testStatus"], "65")
        self.assertTrue(evidence["reason"].startswith("XCTest initialization failed before"))
        self.assertTrue(evidence["reason"].endswith(
            "; the development app did not prove nonce-bound seed deletion"
        ))
        self.assertEqual(evidence["cleanupRequired"], 1)
        self.assertEqual(evidence["cleanupConfirmed"], 0)
        self.assertEqual(evidence["exitCode"], 1)

    def test_executed_product_failure_is_not_reclassified_as_initialization(self):
        evidence = self.run_case(selected=True, initialization=False)
        self.assertEqual(evidence["kind"], "xctestExecutionFailure")
        self.assertEqual(evidence["selected"], "present")
        self.assertIn("final-pixel test failed", evidence["reason"])
        self.assertIn("nonce-bound seed deletion", evidence["reason"])

    def test_selected_test_evidence_prevents_false_initialization_diagnosis(self):
        for arguments in [{"selected": True}, {"started_log": True}]:
            with self.subTest(arguments=arguments):
                evidence = self.run_case(**arguments)
                self.assertEqual(evidence["kind"], "xctestExecutionFailure")

    def test_unavailable_malformed_or_wrong_device_results_remain_unclassified(self):
        for invalid in ["unavailable", "malformed", "wrong-device", "missing-tree"]:
            with self.subTest(invalid=invalid):
                evidence = self.run_case(bad_result=invalid)
                self.assertEqual(evidence["kind"], "xctestExecutionFailure")
                self.assertEqual(evidence["selected"], "unavailable")
                self.assertEqual(evidence["exitCode"], 1)

    def test_missing_receipt_is_still_fatal_after_successful_xcodebuild(self):
        evidence = self.run_case(exit_status=0, selected=True)
        self.assertEqual(evidence["kind"], "")
        self.assertEqual(evidence["reason"],
                         "the development app did not prove nonce-bound seed deletion")
        self.assertEqual(evidence["cleanupRequired"], 1)
        self.assertEqual(evidence["exitCode"], 1)

    def test_test_log_scan_error_is_not_proof_the_selected_test_never_started(self):
        evidence = self.run_case(bad_result="log-scan-error")
        self.assertEqual(evidence["kind"], "xctestExecutionFailure")
        self.assertEqual(evidence["selected"], "absent")
        self.assertEqual(evidence["exitCode"], 1)

    def test_receipt_success_does_not_override_test_failure(self):
        evidence = self.run_case(receipt=True)
        self.assertEqual(evidence["kind"], "xctestInitializationFailure")
        self.assertEqual(evidence["reason"].count("XCTest initialization failed"), 1)
        self.assertEqual(evidence["cleanupRequired"], 0)
        self.assertEqual(evidence["cleanupConfirmed"], 1)
        self.assertEqual(evidence["exitCode"], 1)

    def test_successful_post_test_safety_does_not_claim_pixel_oracle_pass(self):
        evidence = self.run_case(exit_status=0, selected=True, receipt=True)
        self.assertEqual(evidence["kind"], "")
        self.assertEqual(evidence["reason"], "")
        self.assertEqual(evidence["exitCode"], 0)
        self.assertEqual(evidence["cleanupConfirmed"], 1)


if __name__ == "__main__":
    unittest.main()
