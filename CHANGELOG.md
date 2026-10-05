# Changelog

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
