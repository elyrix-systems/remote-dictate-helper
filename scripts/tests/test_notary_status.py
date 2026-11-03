from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("notary_status", Path(__file__).parents[1] / "ci-notary-status.py")
status = importlib.util.module_from_spec(spec)
spec.loader.exec_module(status)
SUBMISSION = "11111111-1111-4111-8111-111111111111"


class NotaryStatusTests(unittest.TestCase):
    def test_history_filters_project_and_time_and_omits_other_fields(self):
        current = {"id": SUBMISSION, "createdDate": "2026-11-03T20:16:00Z",
                   "status": "In Progress", "name": "app.zip", "other": "not-for-output"}
        payload = {"history": [current, dict(current, name="another-product.dmg"),
                               dict(current, createdDate="2026-11-02T20:16:00Z")]}
        result = status.summarize(payload, since=status.timestamp("2026-11-03T20:13:33Z"))
        self.assertEqual(len(result["submissions"]), 1)
        self.assertEqual(set(result["submissions"][0]), {"id", "createdDate", "status"})
        self.assertNotIn("not-for-output", json.dumps(result))
        self.assertNotIn("app.zip", json.dumps(result))

    def test_specific_submission_is_checked_even_if_older_than_history_cutoff(self):
        record = {"id": SUBMISSION, "createdDate": "2026-11-02T20:16:00Z", "status": "Accepted"}
        result = status.summarize(record, SUBMISSION, status.timestamp("2026-11-03T00:00:00Z"))
        self.assertEqual(result["submissions"][0]["status"], "Accepted")
        with self.assertRaises(status.StatusError):
            status.summarize(dict(record, id="22222222-2222-4222-8222-222222222222"), SUBMISSION)

    def test_history_without_artifact_names_keeps_status_metadata(self):
        record = {"id": SUBMISSION, "createdDate": "2026-11-03T20:16:00Z", "status": "In Progress"}
        self.assertEqual(status.summarize({"history": [record]})["submissions"][0]["id"], SUBMISSION)

    def test_history_output_is_bounded_and_reports_truncation(self):
        item = {"id": SUBMISSION, "createdDate": "2026-11-03T20:16:00Z",
                "status": "In Progress", "name": "Remote-Dictate-Helper-2.0.0-arm64.dmg"}
        result = status.summarize({"history": [item] * 21})
        self.assertEqual(len(result["submissions"]), 20)
        self.assertTrue(result["truncated"])

    def test_invalid_inputs_and_responses_fail_without_echoing_values(self):
        for function, value in [(status.identifier, "sensitive-invalid-input"),
                                (status.timestamp, "sensitive-invalid-input"),
                                (status.timestamp, "2026-11-03T20:00:00")]:
            with self.assertRaises(status.StatusError) as error:
                function(value)
            self.assertNotIn(value, str(error.exception))
        with self.assertRaises(status.StatusError):
            status.summarize({"history": "unexpected"})

    def test_local_invocation_never_calls_notarytool(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(status, "command") as command:
            with self.assertRaises(status.StatusError):
                status.main()
            command.assert_not_called()

    def test_command_errors_and_timeouts_do_not_disclose_credentials(self):
        """Subprocess diagnostics must not echo credential-bearing arguments."""
        arguments = ["/usr/bin/xcrun", "notarytool", "history", "--password", "private-password"]
        failed = subprocess.CompletedProcess(arguments, 1, "", "private-password")
        for result, exception in [(failed, None), (None, subprocess.TimeoutExpired(arguments, 90))]:
            with patch.object(status.subprocess, "run", return_value=result, side_effect=exception):
                with self.assertRaises(status.StatusError) as error:
                    status.command(arguments)
                self.assertNotIn("private-password", str(error.exception))

    def test_status_operations_without_real_credentials_or_keychain_changes(self):
        """Only a single read-only Apple operation is allowed, even on failure."""
        for requested in (False, True):
            for fail in (False, True):
                with self.subTest(requested=requested, fail=fail), tempfile.TemporaryDirectory() as directory:
                    environment = {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": directory,
                                   "GITHUB_REPOSITORY": "elyrix-systems/remote-dictate-helper",
                                   "GITHUB_REF": "refs/heads/main", "APPLE_ID": "test@example.com",
                                   "APPLE_APP_PASSWORD": "sample-app-password", "APPLE_TEAM_ID": "EXAMPLETEAM",
                                   "NOTARY_SUBMISSION_ID": SUBMISSION if requested else "",
                                   "NOTARY_SINCE_UTC": "2026-11-03T00:00:00Z"}
                    calls = []
                    record = {"id": SUBMISSION, "name": "app.zip", "status": "In Progress",
                              "createdDate": "2026-11-03T20:16:00Z"}

                    def command(arguments):
                        calls.append([str(arg) for arg in arguments])
                        if arguments[1:3] in (["notarytool", "history"], ["notarytool", "info"]):
                            if fail:
                                raise status.StatusError("Expected diagnostic failure.")
                            return json.dumps(record if requested else {"history": [record]})
                        return ""

                    output = io.StringIO()
                    with patch.dict(os.environ, environment, clear=True), patch.object(status, "command", side_effect=command), redirect_stdout(output):
                        if fail:
                            with self.assertRaises(status.StatusError):
                                status.main()
                        else:
                            status.main()
                            self.assertEqual(json.loads(output.getvalue())["submissions"][0]["id"], SUBMISSION)
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(calls[0][:3], ["/usr/bin/xcrun", "notarytool", "info" if requested else "history"])
                    self.assertNotIn("sample-app-password", output.getvalue())
