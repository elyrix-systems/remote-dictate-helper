# Distribution and release maintenance

Supported platform: **Apple silicon, macOS 26 or later**. Both the app bundle and
compiled executable declare macOS 26.0 as their minimum version.

## Installation paths

End users download an Apple silicon DMG from GitHub Releases, drag the app to
Applications, eject the image and open the installed copy. The first-run setup
requests Accessibility only after a click and watches for the grant. It provides
an app list with local application icons. Clipboard coordination is automatic;
there is no shared-clipboard checkbox in setup. Permissions cannot be pre-granted
by an installer. No helper or microphone
configuration is installed on the remote Mac.

Source users install Apple Command Line Tools (Swift 6+) and Python 3, then run `make install`
from their checkout. This prepares a local signing identity and installs an
optimized arm64 app in `~/Applications`. The tools use Python's standard library.
The installer refuses running helpers, saves a backup and rolls back a failed replacement.

Starting with 0.8.0, the bundle identifier is `systems.elyrix.RemoteDictateHelper`
and the default local certificate is `Remote Dictate Helper Local Code Signing`.
Earlier installations need a fresh Accessibility grant. The existing product
settings file is retained, but pre-product settings are no longer imported.
Build customization uses `REMOTE_DICTATE_*` environment variables. Select `-`
explicitly as `REMOTE_DICTATE_CODESIGN_IDENTITY` for ad-hoc builds; an unavailable
named certificate is an error.

For the 0.8.0 tooling replacement, local checks cover a real ad-hoc build and
DMG verification, installation guards/rollback with disposable app fixtures,
and OpenSSL certificate/export generation and cleanup. Keychain import/trust
was simulated in that spike. The new local identity still needs a real setup
and permission-grant check on the installing Mac; these component checks do not
establish production signing or remote paste compatibility.

## Trust model

| Download | What the user should expect |
| --- | --- |
| Unnotarized preview | Ad-hoc signed. Gatekeeper can block launch; a per-app Open Anyway override may be available. Managed Macs may forbid it. Updates may require Accessibility approval again. |
| Developer ID + notarization | Normal downloaded-app confirmation, then explicit Accessibility approval. Requires a paid Apple Developer Program membership and signing credentials. |
| Locally built | User reviews/builds source and creates a local signing identity for their own rebuilds. That certificate is never distributed to other users. |

Self-signing does not substitute for Apple notarization. Never advise disabling
Gatekeeper, stripping quarantine, or trusting a publisher's self-signed root.
See [Apple distribution](https://developer.apple.com/developer-id/) and
[opening downloaded apps](https://support.apple.com/en-us/102445).

## Build a preview DMG

```zsh
: "Computer: Local Mac | Account: $USER"
make test
make privacy-scan
make package
```

Output is in `.build/package`: an explicitly `unnotarized` DMG and a matching
`.sha256` file. Packaging builds a release arm64 executable, verifies its architecture, verifies the bundle signature and checks the disk image. It does not
install or launch the app, touch the general clipboard or use the local signing
key. Existing output is not overwritten; move it aside before rebuilding.

The DMG contains only the app, an Applications shortcut, installation notes,
LICENSE. It excludes settings, logs, private keys and
build paths. The checksum detects changed bytes, not publisher authenticity.

## Release automation

1. Update `VERSION` and the matching section of `CHANGELOG.md` in a reviewed PR.
2. Pass CI and physical checks appropriate to the change, then merge to `main`.
3. Create and push an immutable annotated `vMAJOR.MINOR.PATCH` tag at that commit.
4. **Package release** runs tests, builds the Apple silicon DMG and creates a draft
   with the corresponding changelog section. Tag builds default to preview mode.
5. Review the draft and test a browser-downloaded copy on a clean Mac account.
   Publish only after its signature/permissions and actual remote paste work.

The workflow can also be dispatched on an exactly tagged `main`. It rejects
off-main commits, version/tag mismatch and arbitrary user-supplied refs. Release
artifacts expire after seven days; the published DMG is a GitHub Release asset.
Draft publication is deliberate so a green build is not mistaken for physical
acceptance. Older releases and recovery tags remain immutable.
Preview builds run in a separate environment without signing secrets or a manual
approval step. Developer ID builds use the protected `release` environment.

## Future Developer ID releases

Obtain a **Developer ID Application** certificate from an Apple Developer Program
account. Developer ID Installer is not needed for a drag-to-Applications DMG.
Keep the existing app bundle identifier for update continuity. The first move
from local/ad-hoc signing to Developer ID may require fresh Accessibility approval.

Configure the GitHub **release** environment to allow only `main` and `v*` tags,
with @pradaev as the reviewer. Store these as environment secrets, never repository
files or chat messages:

- `DEVELOPER_ID_P12_BASE64`: exported certificate and private key, base64 encoded.
- `DEVELOPER_ID_P12_PASSWORD`: password protecting that export.
- `DEVELOPER_ID_IDENTITY`: full Developer ID Application identity name.
- `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`: notarization credentials.

Dispatch **Package release** on the tagged `main`, choosing `notarized`. The
signing job imports keys into a temporary runner keychain, enables hardened
runtime and secure timestamps, submits to Apple, staples and validates the ticket,
and checks Gatekeeper. Credentials are removed on exit. Missing credentials or
rejected notarization fail the build; it never silently emits a preview instead.
The signed path must be validated with real credentials before claiming it works.

## Contribution and Actions controls

The repository is currently private pending the owner's source and history review.
Only the owner may authorize publication. The external-fork approval setting below
must be enabled and verified when the repository becomes public; GitHub does not
offer that setting for this private repository. Release automation creates drafts
and never changes repository visibility.

Use standard GitHub-hosted runners only. Standard runner compute is free for
public repositories; private runs, larger runners and storage have separate
limits. [GitHub billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

- Require approval for **all external fork contributors** before running CI.
- Pin actions to full commit hashes; allow GitHub-owned actions only.
- Default workflow token is read-only and cannot approve PRs.
- PR jobs have no secrets, release environment or write-token build steps.
- Keep bounded job timeouts, cancel superseded PR runs and short artifact retention.
- Protect `main`: require CI, review and resolved discussions; prohibit force-push
  and deletion. The primary maintainer has an explicit administration bypass.
- Review shell scripts, workflows and dependencies before approving external jobs.

There is no `pull_request_target` build, self-hosted runner or secret-bearing
workflow that downloads/executes untrusted PR artifacts. Controls reduce abuse;
they cannot guarantee that every malicious contribution will be detected.

## Physical release checklist

On a clean local Mac account, using a **browser-downloaded** DMG:

1. Check the Apple silicon build on a supported Mac. Intel is not supported.
2. Install via Finder, eject the DMG, and confirm first launch/setup.
3. Grant Accessibility manually; verify setup detects it and the filter starts.
4. Verify ordinary shared clipboard paste before testing dictation.
5. Test actual remote insertion and local clipboard restoration, including toggle
   dictation, push-to-talk and leaving/returning before stopping recording.
6. Test a normal Quit/update and persistence of settings/permissions.
7. Inspect light/dark menu icon, setup and Settings; use keyboard navigation.

Do not simulate a clean Gatekeeper/TCC installation by clearing the maintainer's
permissions. Local signed installation is not proof of the downloaded preview flow.
