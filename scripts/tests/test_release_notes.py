import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_notes", Path(__file__).parents[1] / "release-notes.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


class ReleaseNotesTests(unittest.TestCase):
    def test_only_requested_section(self):
        text = "# Changelog\n\n## 0.7.0 — Distribution\n\n- New.\n\n## 0.6.3\n\n- Old.\n"
        self.assertEqual(notes.section(text, "0.7.0"), "- New.")

    def test_missing_or_invalid_version_cannot_ship(self):
        for version in ["0.8.0", "0.7.0;echo bad", "v0.7.0"]:
            with self.assertRaises(ValueError):
                notes.section("## 0.7.0\n\n- New.\n", version)
