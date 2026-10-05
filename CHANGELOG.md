# Changelog

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
