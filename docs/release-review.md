# Private release review: 0.8.0

This repository remains **private**. The owner will review the files, history and
downloaded application before making a separate publication decision. Neither CI
nor the packaging workflow changes repository visibility.

## What is included

| Location | Contents |
| --- | --- |
| `Sources/` | Native menu bar app, paste interception, clipboard coordination, settings, first-run permissions and icon drawing. |
| `Tests/` | Regression tests for the current paste protocol, cancellation, restoration, formatting, key guards, settings and setup readiness. |
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
- Downloadable preview: drag-to-Applications DMG with a SHA-256 checksum.
- Release executables have debug records stripped before signing; DMG verification
  rejects embedded home paths and unexpected files.
- Preview is ad-hoc signed and **not Apple notarized**. First launch may require
  Open Anyway, and managed Macs may block it.
- First-run setup covers Accessibility and dictation-source selection. It does
  not ask users to manage the helper's clipboard synchronization.
- Future Developer ID signing and notarization are prepared but still require a
  company Apple Developer membership, credentials and a real signed-release test.

The owner has accepted the revised settings/setup layout. Native tests and local
bundle/DMG checks do not prove a clean browser-download installation. That final
check, fresh Accessibility approval and actual remote dictation should follow the
[physical release checklist](distribution.md#physical-release-checklist).

## Before a later public launch

The owner first approves publication. Then enable and verify approval for all
external-fork workflow runs, confirm repository protections and test a draft DMG
download. Publish the reviewed release separately. Current automation only creates
release drafts, with bounded GitHub-hosted jobs and no secrets available to PRs.
