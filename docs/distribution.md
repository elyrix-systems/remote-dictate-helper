# Distribution and release maintenance

Supported platform: **Apple silicon, macOS 26 or later**. Both the app bundle and
compiled executable declare macOS 26.0 as their minimum version.

## Installation paths

End users download an Apple silicon DMG from GitHub Releases, drag the app to
Applications, eject the image and open the installed copy. The single Settings window
requests Accessibility only after a click and watches for the grant. It provides
an app list with local application icons. Adding/removing an app saves immediately;
close Settings when finished. Clipboard coordination is automatic;
there is no separate setup dialog or shared-clipboard checkbox. Permissions cannot be pre-granted
by an installer. No helper or microphone
configuration is installed on the remote Mac.

The installed app automatically registers itself to launch at login on first use,
using Apple's main-app login service. Settings shows its current status and opens
macOS Login Items for approval or changes. Disabling it there survives updates.
Running from a mounted DMG or build folder does not create a login item. This
registration requires a signed bundle; it does not grant Accessibility or replace
Gatekeeper/notarization checks.

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

To reuse a differently named certificate for local installs, save its exact name
on one line in `.local-audit/signing-identity.txt` in the checkout. This ignored
preference contains only the certificate name, never a private key. An explicit
`REMOTE_DICTATE_CODESIGN_IDENTITY` overrides it; CI and DMG packaging explicitly
select their own signing mode. Missing certificates fail instead of silently
falling back to ad-hoc signing.

Ad-hoc code identity is tied to the build's code hash. A replaced bundle can
therefore appear enabled in macOS Accessibility while the new process has no
access. In that case, remove the old helper entry with **−**, click the helper's
**Open Accessibility Settings…**, and grant the newly listed installed copy.
The helper does not clear privacy decisions. Keeping the same certificate and
bundle identifier avoids changing identity on local rebuilds; the initial move
from ad-hoc to certificate signing still requires renewed access. Public ad-hoc
downloads retain this limitation until Developer ID signing is available.
See Apple's [code identity requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

For the 0.8.0 tooling replacement, local checks cover a real ad-hoc build and
DMG verification, installation guards/rollback with disposable app fixtures,
and OpenSSL certificate/export generation and cleanup. Keychain import/trust
was simulated in that spike. The new local signing identity still needs a real
setup check. Separately, the installed ad-hoc preview passed physical dictation
checks on the user's Mac and retained Accessibility after a normal relaunch;
see the [acceptance record](behavior-baseline.md#installed-preview-080).
This does not establish production signing or universal remote compatibility.

## Trust model

| Download | What the user should expect |
| --- | --- |
| Unnotarized download | Ad-hoc signed. Gatekeeper can block launch; a per-app Open Anyway override may be available. Managed Macs may forbid it. Updates may require Accessibility approval again. |
| Developer ID + notarization | Normal downloaded-app confirmation, then explicit Accessibility approval. Requires a paid Apple Developer Program membership and signing credentials. |
| Locally built | User reviews/builds source and creates a local signing identity for their own rebuilds. That certificate is never distributed to other users. |

Self-signing does not substitute for Apple notarization. Never advise disabling
Gatekeeper, stripping quarantine, or trusting a publisher's self-signed root.
See [Apple distribution](https://developer.apple.com/developer-id/) and
[opening downloaded apps](https://support.apple.com/en-us/102445).

## Build an unnotarized DMG

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
   with the corresponding changelog section. Tag builds default to ad-hoc signing
   (the internal `preview` mode). Signing mode does not determine release stability.
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

The owner authorized public source and version 1.0 on 2026-10-05. External-fork
workflow approval and repository protections must remain enabled. Release
automation creates drafts and never changes repository visibility.

Use standard GitHub-hosted runners only. Standard runner compute is free for
public repositories; private runs, larger runners and storage have separate
limits. [GitHub billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).

- Require approval for **all external fork contributors** before running CI.
- Pin actions to full commit hashes; allow GitHub-owned actions only.
- Default workflow token is read-only and cannot approve PRs.
- PR jobs have no secrets, release environment or write-token build steps.
- Keep bounded job timeouts, cancel superseded PR runs and short artifact retention.
- Protect `main`: require CI, review and resolved discussions; prohibit force-push
  and deletion. Only `@pradaev` may update or merge into `main`; teams and apps have
  no push allowance. Protection applies to administrators too. Only `@pradaev`
  may bypass the PR-review requirement for their own maintenance changes; CI
  remains required.
- Review shell scripts, workflows and dependencies before approving external jobs.

There is no `pull_request_target` build, self-hosted runner or secret-bearing
workflow that downloads/executes untrusted PR artifacts. Controls reduce abuse;
they cannot guarantee that every malicious contribution will be detected.

## Physical release checklist

On a clean local Mac account, using a **browser-downloaded** DMG:

1. Check the Apple silicon build on a supported Mac. Intel is not supported.
2. Install via Finder, eject the DMG, and confirm first launch opens Settings.
3. Grant Accessibility manually; verify Settings detects it and the filter starts.
4. Verify ordinary shared clipboard paste before testing dictation.
5. Test actual remote insertion and local clipboard restoration, including toggle
   dictation, push-to-talk and leaving/returning before stopping recording.
6. Test a normal Quit/update and persistence of settings/permissions.
7. Inspect light/dark menu icon and Settings; use keyboard navigation.
8. Verify the installed copy appears in Login Items and launches at the next
   login. Check that a system opt-out survives a manual relaunch and update.

Do not simulate a clean Gatekeeper/TCC installation by clearing the maintainer's
permissions. Local signed installation is not proof of the downloaded preview flow.
