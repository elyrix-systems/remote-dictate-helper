import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class ReleaseWorkflowTests(unittest.TestCase):
    """Execute the workflow's source gate against disposable Git histories."""

    @classmethod
    def setUpClass(cls):
        workflow = (Path(__file__).parents[2] / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Validate release source\n", 1)[1]
        step = step.split("\n      - ", 1)[0]
        cls.script = textwrap.dedent(step.split("        run: |\n", 1)[1])

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rdh-release-gate-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "outputs"
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release gate test")
        self.git("config", "user.email", "test@example.com")
        (self.root / "VERSION").write_text("2.0.0\n")
        self.git("add", "VERSION")
        self.git("commit", "-m", "Reviewed source")
        self.git("tag", "v2.0.0")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def git(self, *arguments):
        return subprocess.run(
            ["git", "-c", "commit.gpgSign=false", "-c", "tag.gpgSign=false",
             "-c", "core.hooksPath=/dev/null", *arguments],
            cwd=self.root, check=True, capture_output=True, text=True, timeout=10,
        )

    def check_gate(self, *, mode="notarized", draft=False, ref_type="branch",
                   ref_name="main", error=None):
        """Reject invalid requests before they can emit release version outputs."""
        previous = self.output.read_text() if self.output.exists() else ""
        environment = dict(os.environ, PACKAGE_MODE=mode, CREATE_DRAFT=str(draft).lower(),
                           GITHUB_REF_TYPE=ref_type, GITHUB_REF_NAME=ref_name,
                           GITHUB_OUTPUT=str(self.output))
        result = subprocess.run(["/bin/bash", "-c", self.script], cwd=self.root,
                                env=environment, capture_output=True, text=True, timeout=10)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.output.read_text(), previous + "version=2.0.0\n")
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stderr)
            self.assertEqual(self.output.read_text() if self.output.exists() else "", previous)

    def test_preview_is_artifact_only_even_on_an_exact_release_tag(self):
        self.check_gate(mode="preview")
        self.check_gate(mode="preview", draft=True,
                        error="Release drafts require notarized signing")

    def test_matching_notarized_tag_and_manual_draft_are_allowed(self):
        self.check_gate(draft=True, ref_type="tag", ref_name="v2.0.0")
        self.check_gate(draft=True)
        self.check_gate(draft=True, ref_type="tag", ref_name="v9.0.0",
                        error="Release tag must match VERSION")

    def test_untagged_main_allows_artifacts_but_not_drafts(self):
        self.git("commit", "--allow-empty", "-m", "New reviewed main")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.check_gate()
        self.check_gate(mode="preview")
        self.check_gate(draft=True, error="Release draft requires an exactly tagged main")

    def test_invalid_versions_and_non_main_sources_are_rejected(self):
        self.check_gate(ref_name="feature", error="Manual packaging requires main")
        (self.root / "VERSION").write_text("invalid\n")
        self.check_gate(error="VERSION must be a numeric semantic version")
        (self.root / "VERSION").write_text("2.0.0\n")
        self.git("checkout", "-b", "unreviewed")
        self.git("commit", "--allow-empty", "-m", "Unreviewed change")
        self.check_gate(draft=True, ref_type="tag", ref_name="v2.0.0",
                        error="Release source must be on main")
