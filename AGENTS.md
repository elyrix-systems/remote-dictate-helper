# Agent Notes

This project is Remote Dictate Helper: local clipboard-based dictation through Apple Screen Sharing or Microsoft Windows App on macOS.

Important boundaries:

- Supported platform: Apple silicon running macOS 26 or later. Keep SwiftPM, app metadata, packaging, CI and user-facing requirements aligned; do not restore older macOS support.

- The owner authorized public source and the stable 1.0 release on 2026-10-05 after source/history review. Release automation still creates drafts for review and must not change repository visibility.
- The owner authorized a fresh main history from the maintained product snapshot on 2026-10-05. Earlier development and recovery tags are preserved in separate private archives, not imported into this repository. Do not reconnect archived history or rewrite published releases without explicit owner authorization.
- Read `docs/behavior-baseline.md` before behavior changes. Preserve the accepted paste interception and clipboard restoration protocol; the app does not send Backspace.
- Every ready pull request into `main` must receive CodeRabbit review of its latest changes before merge, in addition to CI and maintainer review. A successful status that says the review was skipped does not count. Address actionable findings and resolve review conversations before merging; only the owner may merge.
- Windows App repairs native paste input while RDP and the dictation app own clipboard redirection/restoration. Do not apply Screen Sharing clipboard-menu operations to this target.
- Every time you ask the user to run a command, put a one-line shell no-op at the top of the command block with only the computer and account, for example: `: "Computer: Local Mac | Account: $USER"`. Keep it simple, make it copy-paste safe in interactive `zsh`, and do this even when it feels obvious.
- Treat clipboard sharing as the first gate. Verify plain local copy/paste into the remote computer before debugging dictation.
- Keep dictation apps local unless the remote Mac has a real microphone input path.
- The fallback is keystroke injection from the local clipboard into the active remote-control window.
- Development may happen on a remote computer while final real-world testing happens on the user's local Mac. Maximize tests that can run in the repo/remote environment, and explicitly label tests that require the local Mac, Wispr Flow, Apple Screen Sharing or Windows App, microphone/hotkey input, Accessibility permissions, or the shared clipboard bridge.
- If a preferred tool is missing or blocked, explain the tool gap and tradeoff before switching. Use an alternate tool only when it is truly a better fit or clearly labeled as a temporary fallback.
- The runtime has no database or donor integration. Never add those dependencies or modify dictation-app data as a fallback.
- The user authorizes the agent to quit and relaunch the Remote Dictate Helper menu bar app whenever needed for installation, debugging, or testing, without asking again. Announce the restart and use normal Quit so pending clipboard restoration can finish before replacing the app. This standing authorization applies to this helper, not Wispr Flow, superwhisper, Screen Sharing, or unrelated apps.
- Do not silently terminate or modify other external processes. If a separate donor or another helper blocks installation, fail visibly and ask the user to close it; do not force-stop it under the helper restart authorization.
- Preserve the installed helper's signing identity for local updates. Build tools read an optional certificate name from ignored `.local-audit/signing-identity.txt`; do not override it with ad-hoc signing for an installation. Ad-hoc CI/package verification is separate from installation. A deliberate identity change may require renewed Accessibility access; never reset the user's privacy database to simulate a clean installation.
- The current target is a small local macOS menu bar app with independently testable modules. Use `docs/architecture.md`, `docs/test-plan.md`, and `docs/implementation-roadmap.md` as the planning baseline.
- Use the implementation readiness gate before accepting OS-level, permission, external-app, or integration designs: name the risky assumption, classify proof as external/local/production, and run a small spike when proof is weak or generic.
- Prefer simple macOS-native components and clear operational docs. If building code, keep modules separately testable instead of adding timing behavior to the prototype.
- Do not imply there is a special Wispr remote-desktop integration. The reliable mechanism is clipboard redirection or typed keystrokes.
