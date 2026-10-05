import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("privacy_scan", Path(__file__).parents[1] / "privacy_scan.py")
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)


class PrivacyScanTests(unittest.TestCase):
    def test_detects_private_material_without_copying_it_into_results(self):
        samples = [
            "/" + "Users/" + "sample-account/source",
            "Account" + ": sample-account",
            "gh" + "p_" + "A" * 36,
            "https://" + "name:password@" + "example.com",
            "-----BEGIN " + "PRIVATE KEY-----",
            "10." + "20.30.40",
            "person@" + "private.invalid",
        ]
        for sample in samples:
            result = scan.findings("fixture.txt", sample.encode())
            self.assertTrue(result, sample)
            self.assertNotIn(sample, str(result))

    def test_safe_examples_and_intentional_public_identity(self):
        text = "\n".join([
            ': "Computer: Local Mac | Account: $USER"',
            '~/Applications', '@pradaev', 'icon_16x16@2x.png',
            'contributor@users.noreply.github.com',
        ])
        self.assertEqual(scan.findings("README.md", text.encode()), [])

    def test_sensitive_filenames_and_unknown_binary(self):
        self.assertTrue(scan.findings("settings.json", b"{}"))
        self.assertTrue(scan.findings("identity.p12", b"binary"))
        self.assertTrue(scan.findings("unknown.bin", b"\0"))
        self.assertEqual(scan.findings("assets/RemoteDictateHelper.icns", b"\0"), [])


if __name__ == "__main__":
    unittest.main()
