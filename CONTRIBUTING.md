# Contributing

Contributions are welcome. The primary maintainer is **@pradaev**. Preserve the
copyright and permission notices in the [MIT license](LICENSE) when adapting code.

## Pull requests

1. Open an issue before proposing a new remote desktop target or changing the
   clipboard protocol. Include a small reproduction using synthetic text.
2. Fork the repository, create a branch and make a focused change.
3. Run the checks below and add meaningful regression coverage for changed behavior.
4. Open a pull request against `main`. Explain the problem, resulting behavior
   and validation. Clearly separate automated tests from physical Mac testing.
5. Wait for CI, CodeRabbit and maintainer review. CodeRabbit automatically reviews
   ready pull requests and subsequent pushes. Its `CodeRabbit` status is a required
   check for `main`; a skipped review does not count as completed review. Address
   actionable findings and resolve review conversations before merging. Only
   **@pradaev** may merge. Contributors do not need direct write access.

```zsh
: "Computer: Local Mac | Account: $USER"
make test
make privacy-scan
REMOTE_DICTATE_CODESIGN_IDENTITY=- make build
```

The checks require macOS 26 or later, Swift 6 and Python 3. They use disposable named pasteboards
and mocked key posting; they do not request Accessibility, access your general
clipboard, control applications or start microphone recording. CI uses ordinary
GitHub-hosted macOS runners. Pull requests run with read-only repository access
and no project secrets. GitHub may require approval before a new contributor's
workflow runs.

## Behavior to preserve

- Handle configured dictation apps only in active Apple Screen Sharing or Windows App.
- Screen Sharing captures actual clipboard content; Windows App only repairs input and leaves clipboard redirection/restoration to RDP and the dictation app. Never use transcript databases or donor apps.
- Intercept only an accepted source paste; allow manual and local input through.
- Paste once, without Backspace, retries or replay after focus/caret changes.
- Preserve the original clipboard formats; never overwrite a newer copy.
- Keep capture, transfer, input and restoration independently testable.
- Log only operational metadata, never real transcripts or clipboard payloads.

For an OS or app integration change, name the risky assumption. Distinguish
external API documentation, local component tests, physical integration evidence
and broader production evidence. Run a small physical spike if the relevant
behavior has not been demonstrated. See [the test plan](docs/test-plan.md).

Do not include personal paths, private hostnames, local settings, clipboard
contents, certificates, keys or logs in commits. Use a GitHub noreply email if
you do not want your email address in public commit metadata. A clean current
tree does not remove data from earlier commits.

Preserve release tags. Do not rewrite published history or
silently terminate external apps. Installer changes must retain normal Quit and
pending clipboard cleanup.

Contributions are accepted under the project's MIT license. No CLA is required.
Be respectful, give useful reproduction steps and keep discussion focused on the
project. Report security issues as described in [SECURITY.md](SECURITY.md).

## CI and releases

All external fork workflows require maintainer approval before running. A delay
in CI does not mean your contribution was rejected. Maintainers should inspect
workflow/build-script changes before approving, then review the resulting checks.
PR jobs use standard GitHub-hosted runners, read-only tokens and no release
secrets. There is no `pull_request_target` build of contributor code.

Release packaging runs only for version tags reachable from `main` (or a manual
run on an exactly tagged `main`). It creates a draft DMG release for review.
A pull request never signs or publishes a release. See [distribution](docs/distribution.md).
