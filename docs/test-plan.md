# Test plan

## Automated regression checks

Run `make test`, `make privacy-scan` and `REMOTE_DICTATE_CODESIGN_IDENTITY=- make build`
on macOS 26 or later with Swift 6 and Python 3.
Tests use disposable named pasteboards and mocked key posting. They do not use
the general clipboard, real keystrokes, a microphone, other apps or permissions.
The custom native runner works with Command Line Tools without XCTest.

| Suite | Behavior protected |
| --- | --- |
| Settings | Defaults, exact/dotted source IDs, excluded apps, schema migration, retained clipboard policy/source selection, first-use readiness and reopening Settings after permission loss. |
| Utilities | Settings round-trip and malformed-file preservation; append-only metadata logging, private new log files and refusal to follow a log symlink. |
| Build tools | Exact signing identity lookup, missing-certificate refusal, explicit ad-hoc mode, credential-safe errors, running-app refusal and rollback after a failed installation replacement. |
| Capture | Empty results, same text in distinct revisions, original snapshot selection, bounded history, focus/input cancellation, no queued or stale replay. |
| Release | Return to Screen Sharing before paste starts a fresh transaction; missing source key-up and clipboard return have distinct timeout diagnostics; logs omit clipboard contents. |
| Interception | Manual/local/unknown input passes through; accepted down/up pairing; slow capture and disabled filter fail safely; no deletion. |
| Clipboard | Full-format original restoration, UTF-8 HTML transport, empty originals, clipboard ownership, newer/equal-text copies and restoration deadlines. |
| Input | Exactly one private Command+V; permission/target/modifier refusal; mid-sequence release; HID residue guards and no retry. |
| Completion | Deferred cleanup readiness, single completion attempt, busy refusal and errors. |
| Transfer | Clipboard menu order, exact setting transitions, failure recovery, original Send before sharing-on and receipt validation. |

GitHub Actions runs the native suite and bundle build on a standard macOS 26 Apple silicon runner,
plus privacy and secret checks. It does not install or launch the helper. A green
workflow establishes component behavior, not a successful physical remote paste.

## Physical integration checklist

Requires a **local Mac**, a dictation app, microphone/recording shortcut,
Accessibility permission, **Apple Screen Sharing** and a remote Mac text field.
Use synthetic text only. Check ordinary clipboard sharing first.

1. Copy a disposable local marker. In the remote field, put `START|` and leave the
   cursor after it. Dictate; wait for RD Done without manual paste. Expect the
   prefix intact and the transcript once, with no `v` or deleted character.
2. Paste into a disposable local field. Expect the original marker, including
   its formats where supported. Repeat with a different marker and the same
   dictated text to test revision-based capture.
3. Test a multiline list and non-ASCII text. Repeat using hold/release and toggle
   recording. Test each supported source independently.
4. Test ordinary local dictation and manual remote Command+V; neither should be
   captured by the helper.
5. During toggle dictation, move to another local window, then return and click
   the remote text field before stopping recording. Expect normal insertion.
   Separately, move focus or click/type after capture and before replay. Expect cancellation and no later
   insertion when returning. Clipboard cleanup may still finish for the original
   Screen Sharing connection.
6. Copy newer content during restoration; the helper must not overwrite it.
7. Check Quit, relaunch, saved app selection and Accessibility after an upgrade.
   Normal Quit must allow pending restoration to finish.

Record app/OS versions, source clipboard settings, visible result, status and
whether each step actually ran. Never claim remote receipt based only on a local
log or replace physical integration checks with mocked events.

## Validated baseline

The accepted physical paste behavior and its limits are recorded in
[behavior-baseline.md](behavior-baseline.md). Utility and packaging changes retain
that protocol; they do not replace a physical setup/permission test for a new
application identity or a clean browser download.
