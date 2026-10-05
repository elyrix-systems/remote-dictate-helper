# Release review: 1.0.0

The owner authorized public source and a stable 1.0 release on 2026-10-05.
Neither CI nor the packaging workflow changes repository visibility.

## What is included

| Location | Contents |
| --- | --- |
| `Sources/` | Native menu bar app, paste interception, clipboard coordination, settings, first-run permissions and icon drawing. |
| `Tests/` | Regression tests for the current paste protocol, cancellation, restoration, formatting, key guards, settings and first-use readiness. |
| `scripts/` | Source installation, signing, DMG packaging, artifact verification, privacy checks and their tests. |
| `.github/` | Read-only PR checks, draft release packaging, maintainer ownership, contribution and issue templates. |
| `assets/` | Application icon. The menu bar icon is drawn by the app. |
| `docs/` | Architecture, test plan, distribution instructions and accepted recovery baselines. |
| Root documents | English README, changelog, contribution, maintenance, security and privacy policies, and MIT license. |

The current app contains no donor application, transcript database reader,
Backspace cleanup, experimental paste selector or diagnostic menu. Earlier development snapshots are kept in private archives outside this repository.

## Privacy review

At the owner's request, this repository starts from one maintained product
snapshot on `main`. Earlier development, pull requests, draft releases and
recovery tags are kept in separate private archives. They are not branches,
tags or pull-request references in this repository. Do not merge archived
history back into the active repository.

Git authorship and copyright notices are retained. Public project identities
include the primary maintainer's GitHub profile `@pradaev` and the organization
`elyrix-systems`. Git authors use public GitHub noreply addresses.

No local settings, transcript databases, operational logs, certificates, private
keys, screenshots or local backup directories are tracked or packaged. Automated
source/history privacy checks and a redacted secret scan are required, alongside
the owner's review of the contents. Scanner results do not replace that review.

## Distribution status

- Apple silicon only; macOS 26 or later.
- Source installation: `make install`.
- Download: drag-to-Applications DMG with a SHA-256 checksum.
- Release executables have debug records stripped before signing; DMG verification
  rejects embedded home paths and unexpected files.
- The app is ad-hoc signed and **not Apple notarized**. First launch may require
  Open Anyway, and managed Macs may block it.
- One Settings window covers Accessibility and dictation-source selection. It does
  not ask users to manage the helper's clipboard synchronization.
- Future Developer ID signing and notarization are prepared but still require a
  company Apple Developer membership, credentials and a real signed-release test.

The owner accepted the 0.8.0 settings/setup layout. The installed 0.8.0
preview passed user-confirmed checks with Flow, superwhisper and Valis, including
clipboard preservation; Accessibility remained usable after normal Quit/relaunch.
See the [physical acceptance record](behavior-baseline.md#installed-preview-080).
These checks do not prove a clean browser-download installation on a new account.
That remaining check should follow the
[physical release checklist](distribution.md#physical-release-checklist).

Version 1.0 keeps the accepted transfer modules unchanged. Local checks passed
the native/Python regression suites, source/history privacy scan, redacted secret
scan and workflow validation. The single Settings window was inspected on the
local Mac: missing permission opens it, all three app icons are visible, and
Cancel discards a temporary list removal without changing saved settings.
The owner re-granted Accessibility after the ad-hoc update and confirmed that
this same window changed to **Allowed ✓**.
First-use readiness and permission-loss reopening have automated coverage.
After publication, the owner reported a successful reinstall, renewed Accessibility
grant and stable local operation. See [the 1.0 acceptance record](behavior-baseline.md#stable-release-100).
No claim of clean-account Gatekeeper acceptance is made.

## Publication controls

Require approval for all external-fork workflow runs and keep branch protections.
Review each draft DMG before publication. Automation only creates release drafts,
with bounded GitHub-hosted jobs and no secrets available to PRs. Stable release
status does not imply Developer ID signing or notarization.
