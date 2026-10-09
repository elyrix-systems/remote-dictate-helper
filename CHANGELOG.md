# Changelog

## Unreleased

## 1.1.2 — 2026-10-09

- Refresh Windows App focus before dictation paste to address repeated insertion
  of an older clipboard value. Use a transparent helper window, return to the
  same remote-client window and paste once. A slight focus flicker may remain.
- Keep the input filter responsive when source-app lookup or admission stalls;
  expired capture decisions cannot schedule a late paste.
- Remove temporary clipboard/focus test menus, synthetic clipboard publishers
  and the experimental build switch. Preserve the investigation and results in
  the [experiment archive](https://github.com/elyrix-systems/remote-dictate-helper/blob/v1.1.2/docs/experiments/windows-clipboard-2026-10-09.md).
- Retain regression coverage for the shared dictation-source path, cancellation,
  clipboard ownership and restoration. Maintainer builds can explicitly opt in
  to private, bounded local transcript diagnostics; downloads leave them off.

Validation: the owner accepted repeated Flow dictations and preserved local
clipboard contents with the focus refresh, including its transparent-window
candidate. Automated checks cover all configured source identities and failure
guards with mocked input/activation. Long-running use, first paste after sleep
and all RDP endpoints are not established by these trials. Windows App still owns
RDP redirection and the dictation app owns restoration; the helper does not write
that clipboard. Apple Screen Sharing's transfer protocol is unchanged. Downloads
remain ad-hoc signed and not Apple notarized.

## 1.1.1 — 2026-10-07

- Prevent delayed or unavailable clipboard data from freezing the helper.
  Abandon timed-out reads without sending a late paste.
- Improve failure diagnostics, with optional local debug logging that excludes
  transcript contents and is disabled in release downloads.
- Expand regression coverage for clipboard reads, cancellation, restoration and
  the shared dictation-app handling in both supported remote clients.

Validation: automated checks include an intentionally unresponsive clipboard
provider. The owner confirmed successful local Flow dictations without hangs in
Apple Screen Sharing and Windows App. First dictation after sleep and intermittent
stale RDP clipboard data remain separate checks; this release does not claim a
fix for every remote clipboard issue. Downloads remain ad-hoc signed and not
Apple notarized.

## 1.1.0 — 2026-10-07

- Add Microsoft Windows App (formerly Microsoft Remote Desktop) as a supported
  remote client on macOS. Intercept a selected dictation app’s synthetic paste
  and send one complete native Command+V, avoiding the stray `v` observed with Flow.
- Preserve the existing Apple Screen Sharing transfer and clipboard restoration.
  Windows App uses RDP clipboard redirection; the helper does not rewrite its
  clipboard or change sharing settings. The dictation app owns restoration.
- Handle consecutive dictations, wait for physical modifier release while the
  clipboard is current, and cancel on focus, window, input or revision changes.
  Release owned keys on cancellation, disabled input monitoring and Quit. No
  Backspace, queued replay, automatic retry or diagnostic expiry is included.
- Update Settings, menu scope, installation notes and compatibility documentation.
  Show enabled launch-at-login status in green, matching Accessibility.
  Add native regression tests for the Windows App input path and its guards.

Validation: the owner accepted the local Windows App/Wispr Flow integration and
reported continued correct operation in Apple Screen Sharing. Automated tests
use mocked input; they do not establish universal RDP/server or dictation-app
compatibility. Downloads remain ad-hoc signed and not Apple notarized.

## 1.0.3 — 2026-10-06

- Save and apply dictation-app additions and removals immediately. Remove Save
  and Cancel from Settings and shrink the window to fit its contents. Closing
  the window keeps saved changes; a failed edit leaves the previous list intact.
- Complete first-use setup automatically when permissions and the app list are
  ready, without requiring a Save button.
- Avoid opening System Settings twice when requesting Accessibility. Let the
  native permission alert handle navigation; open the pane directly only when
  access is already granted.
- Allow a private checkout preference for an existing local signing certificate,
  so local installations can retain their code identity across rebuilds.

Validation: the owner confirmed the installed candidate works and the native
permission alert closes correctly. A second locally certificate-signed build
retained Accessibility after replacement and relaunch. Automated tests cover
immediate persistence, failed edits, permission navigation and signing selection.
Public downloads remain ad-hoc signed and may need renewed Accessibility access
after updates; local signing continuity does not change their trust model.

## 1.0.2 — 2026-10-06

- Automatically register the installed helper to launch at login on first use.
  Show its status and a link to macOS Login Items in Settings. Preserve system
  opt-out across launches and updates; never register disk-image or build copies.
- Recognize an empty local clipboard when the dictation app returns it as a
  single empty UTF-8 text item. This fixes an original-clipboard mismatch
  observed with Flow after sleep; the saved clipboard is still restored exactly.
  Keep refusal of unknown content and the deadline for missing source release.
- Add regression coverage for empty-clipboard return and exact restoration,
  first login-item registration, approval/failure handling and retained opt-out.

Validation: the installed local build registered successfully in macOS Open at
Login and started paste interception after Accessibility approval. Automatic
launch after an actual logout/reboot has not yet been verified. The empty-buffer
fix passed a reproduction test; a separate timeout when the dictation app does
not return its clipboard remains under investigation.

## 1.0.1 — 2026-10-05

- Add **Product Website** to the menu bar menu, opening the Remote Dictate Helper
  page on elyrix-systems.com in the default browser.
- Add website links to the README and DMG installation notes.
- Remove unused Settings callbacks and redundant capture flags. Isolate retired
  public core helpers as compatibility APIs for existing 1.0 library clients;
  the application uses the production transfer lease. Keep settings migration.
- Stop the extra diagnostic clipboard polling during and after restoration and
  remove detailed menu timing counters. Keep operational status and error logs.
- Require the captured source-release baseline for every replay; preserve
  revision ownership, single-paste safeguards and clipboard recovery tests.
- Record the owner's successful reinstall and renewed Accessibility grant for 1.0.
  The dictation, paste interception and clipboard restoration protocol is unchanged.

## 1.0.0 — 2026-10-05

- First stable release for Apple silicon and macOS 26+, using the locally
  accepted paste protocol with Wispr Flow, superwhisper and Valis.
- One Settings window for Accessibility and dictation apps, on first launch and
  from the menu bar. Remove the separate Setup and permission-check menu items.
- Keep app selection changes pending until Save; Cancel discards them. A failed
  save keeps the window open. Preserve existing settings and first-use completion.
- Preserve one intercepted paste, no Backspace, formatted multilingual content,
  local clipboard restoration and returning to Screen Sharing before dictation ends.
- Provide an Apple-silicon DMG and SHA-256 checksum built and tested by GitHub
  Actions. The download is ad-hoc signed and **not Apple notarized**; stable
  describes the accepted functionality, not Apple certification.

## 0.8.0 — maintained product snapshot

- Dictate locally with Wispr Flow, superwhisper or Valis and paste into a remote
  Mac through Apple Screen Sharing. Other remote desktop clients are not supported.
- Intercept an accepted source paste, transfer its formatted clipboard content,
  paste once without Backspace and restore the original local clipboard.
- Permit window switching during recording; require the intended Screen Sharing
  field to have focus when the dictation app finishes. Cancel replay if focus or
  input changes after capture.
- Provide a native menu bar icon, compact Settings and first-run Accessibility
  setup with a configurable list of dictation apps.
- Require Apple silicon and macOS 26 or later. Provide source installation and
  an ad-hoc-signed DMG preview; Developer ID notarization requires signing credentials.
- Use the product bundle identifier `systems.elyrix.RemoteDictateHelper` and
  product-specific local signing identity. Existing installations with a different
  identity need fresh Accessibility approval; current product settings are retained.
- Include regression tests, privacy and secret checks, protected contribution
  workflows and draft-only release packaging.

This repository starts with the maintained snapshot. Earlier development and
recovery builds remain in separate private archives.
