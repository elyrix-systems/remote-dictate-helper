import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("app_tools", Path(__file__).parents[1] / "app_tools.py")
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class AppToolsTests(unittest.TestCase):
    def test_diagnostics_require_explicit_build_opt_in(self):
        self.assertNotIn("RDDiagnosticLogging", tools.bundle_metadata("1.1.0", "110.7.1"))
        self.assertTrue(tools.bundle_metadata("1.1.0", "110.7.1", "1")["RDDiagnosticLogging"])
        with self.assertRaises(tools.ToolError):
            tools.bundle_metadata("1.1.0", "110.7.1", "yes")

    def test_local_signing_preference_retains_certificate_and_allows_explicit_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(tools, "ROOT", root), patch.dict(os.environ, {}, clear=True):
                self.assertEqual(tools.selected_identity(), tools.LOCAL_IDENTITY)
                preference = root / ".local-audit/signing-identity.txt"
                preference.parent.mkdir()
                preference.write_text("Example Local Certificate\n")
                self.assertEqual(tools.selected_identity(), "Example Local Certificate")
                with patch.dict(os.environ, {"REMOTE_DICTATE_CODESIGN_IDENTITY": "-"}):
                    self.assertEqual(tools.selected_identity(), "-")
                with patch.object(tools, "identity_hash", return_value=None), patch.object(tools, "invoke") as command:
                    with self.assertRaises(tools.ToolError):
                        tools.sign(Path("Example.app"), "example.app")
                    command.assert_not_called()
                for invalid in ("", "-", "First\nSecond"):
                    preference.write_text(invalid)
                    with self.assertRaises(tools.ToolError):
                        tools.selected_identity()

    def test_command_error_does_not_expose_credentials(self):
        result = subprocess.CompletedProcess([], 7, "", "")
        with patch.object(tools.subprocess, "run", return_value=result):
            with self.assertRaises(tools.ToolError) as error:
                tools.invoke(["security", "import", "-P", "private-password"])
        self.assertNotIn("private-password", str(error.exception))
        self.assertIn("exit 7", str(error.exception))

    def test_missing_distribution_certificate_never_falls_back(self):
        settings = {"REMOTE_DICTATE_DISTRIBUTION": "1", "REMOTE_DICTATE_CODESIGN_IDENTITY": "Developer ID Application: Example"}
        with patch.dict(os.environ, settings, clear=True), patch.object(tools, "identity_hash", return_value=None), patch.object(tools, "invoke") as command:
            with self.assertRaises(tools.ToolError):
                tools.sign(Path("Example.app"), "example.app")
            command.assert_not_called()

    def test_local_stable_identity_is_required_when_requested(self):
        with patch.dict(os.environ, {"REMOTE_DICTATE_CODESIGN_IDENTITY": "Missing Local Certificate"}, clear=True), patch.object(tools, "identity_hash", return_value=None), patch.object(tools, "invoke") as command:
            with self.assertRaises(tools.ToolError):
                tools.sign(Path("Example.app"), "example.app")
            command.assert_not_called()

    def test_preview_does_not_access_keychain(self):
        with patch.dict(os.environ, {"REMOTE_DICTATE_CODESIGN_IDENTITY": "-"}, clear=True), patch.object(tools, "identity_hash") as lookup, patch.object(tools, "invoke") as command:
            tools.sign(Path("Example.app"), "example.app")
            lookup.assert_not_called()
            self.assertEqual(command.call_count, 2)
            self.assertNotIn("--timestamp", command.call_args_list[0].args[0])

    def test_identity_lookup_requires_exact_valid_subject(self):
        fingerprint = "A" * 40
        listing = f'  1) {fingerprint} "Example Copy"\n  2) {fingerprint} "Example"\n     2 valid identities found\n'
        with patch.object(tools, "invoke", return_value=listing):
            self.assertEqual(tools.identity_hash("Example"), fingerprint)
            self.assertIsNone(tools.identity_hash("Exam"))

    def test_install_refuses_running_app_before_build_or_key_setup(self):
        running = subprocess.CompletedProcess([], 0)
        with patch.object(tools.subprocess, "run", return_value=running), patch.object(tools, "build") as build, patch.object(tools, "prepare_identity") as setup:
            with self.assertRaises(tools.ToolError):
                tools.install(setup=True)
            build.assert_not_called()
            setup.assert_not_called()

    def test_signing_setup_uses_selected_keychain_without_touching_default(self):
        selected = "/tmp/example-local.keychain-db"
        calls = []
        def command(arguments, **kwargs):
            calls.append(arguments)
            if arguments[0] == "/usr/bin/openssl":
                # Stand in for generated files only; no system keychain is used.
                for flag in ("-keyout", "-out"):
                    if flag in arguments:
                        Path(arguments[arguments.index(flag) + 1]).touch()
            return ""
        missing = subprocess.CompletedProcess([], 44)
        with patch.dict(os.environ, {"REMOTE_DICTATE_KEYCHAIN": selected}, clear=True), patch.object(tools, "identity_hash", side_effect=[None, "A" * 40]), patch.object(tools.subprocess, "run", return_value=missing) as lookup, patch.object(tools, "invoke", side_effect=command):
            tools.prepare_identity()
        self.assertEqual(lookup.call_args.args[0][-1], selected)
        keychain_changes = [args for args in calls if args[0] == "/usr/bin/security"]
        self.assertEqual([args[1] for args in keychain_changes], ["import", "add-trusted-cert"])
        for args in keychain_changes:
            self.assertEqual(args[args.index("-k") + 1], selected)

    def test_install_replacement_failure_restores_previous_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "build" / "Remote Dictate Helper.app"
            source.mkdir(parents=True)
            (source / "version").write_text("new")
            install = root / "Applications"
            target = install / source.name
            target.mkdir(parents=True)
            (target / "version").write_text("old")
            rename = Path.rename
            def fail_new_commit(path, destination):
                if path.name == source.name and path.parent.name.startswith(".rdh-update-"):
                    raise OSError("simulated replacement failure")
                return rename(path, destination)
            with patch.dict(os.environ, {"REMOTE_DICTATE_INSTALL_DIR": str(install), "REMOTE_DICTATE_RESTART_AFTER_INSTALL": "0"}, clear=True), patch.object(tools, "ROOT", root), patch.object(tools, "build", return_value=source), patch.object(tools, "ensure_stopped"), patch.object(tools, "invoke"), patch.object(Path, "rename", fail_new_commit):
                with self.assertRaises(OSError):
                    tools.install()
            self.assertEqual((target / "version").read_text(), "old")
            saved = list((root / ".local-audit/install-backups").glob("*/Remote Dictate Helper.app/version"))
            self.assertEqual(len(saved), 1)
            self.assertEqual(saved[0].read_text(), "old")


if __name__ == "__main__":
    unittest.main()
