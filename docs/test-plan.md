# Test plan

## Automated regression checks

Run `make test`, `make privacy-scan` and `REMOTE_DICTATE_CODESIGN_IDENTITY=- make build`
on macOS 26 or later with Swift 6 and Python 3.
Tests use disposable named pasteboards and mocked key posting. Isolation tests additionally launch owned read-only reader/provider subprocesses.
They do not use the general clipboard, real keystrokes, a microphone, user apps
or permissions.
The custom native runner works with Command Line Tools without XCTest.

| Suite | Behavior protected |
| --- | --- |
| Settings | Defaults, exact/dotted source IDs, excluded apps, schema migration, retained clipboard policy/source selection, immediate add/remove persistence, failed/busy edit rollback, first-use readiness and reopening Settings after permission loss. |
| Launch at login | First registration, existing items, system opt-out across launches/updates, approval and failure handling, installation-path guards; mocked Service Management only. |
| Accessibility navigation | A click requests either the native access alert or opens the already-authorized pane, never both; cancellation permits another request. Mocked effects, no TCC changes. |
| Utilities | Settings round-trip and malformed-file preservation; append-only metadata logging, private new log files and refusal to follow a log symlink. |
| Build tools | Exact signing identity lookup, private local certificate preference and explicit override, missing-certificate refusal, explicit ad-hoc mode, credential-safe errors, running-app refusal and rollback after a failed installation replacement. |
| Capture | Empty results, same text in distinct revisions, original snapshot selection, zero-item original returned as empty UTF-8 text, refusal of unknown/nonempty returns, bounded history, focus/input cancellation, no queued or stale replay. |
| Release | Return to Screen Sharing before paste starts a fresh transaction; missing source key-up and clipboard return have distinct timeout diagnostics; logs omit clipboard contents. |
| Diagnostics | Explicit build opt-in, no file when disabled, bounded rotation/private files/symlink refusal, no transcript in failure logs, distinct click/key/foreground/clipboard/modifier reasons and unchanged cancellation/key release. Live context sampling and observer overhead require the local diagnostic app. |
| Diagnostic text opt-in | Two explicit build flags; metadata-only and disabled builds omit text. Isolated named-board UTF-8 capture, escaped Russian/multiline round-trip, size bounds and truncation, unavailable invalid UTF-8, unchanged formats/revisions, source-only capture in both adapters, operation linkage through cancellation, existing-file privacy and symlink refusal. These establish local capture, not remote receipt. |
| Interception | Manual/local/unknown input passes through; accepted down/up pairing; slow capture and disabled filter fail safely; no deletion. |
| Input-filter liveness | Blocked source lookup/admission returns within the capture budget, bounds outstanding work across filter restarts and cannot capture late; ordinary/manual/self input skips source lookup; stalled admission in both adapters cannot schedule input or a clipboard read after expiry. No real events posted. |
| Shared source contract | Real event classification into both client monitors for Flow, superwhisper, Valis and a custom source; main/helper bundle IDs, consecutive captures and both clipboard-return policies. Removed/disabled sources pass through. No running dictation apps required. |
| Clipboard | Full-format original restoration, UTF-8 HTML transport, empty originals, clipboard ownership, newer/equal-text copies and restoration deadlines. |
| Input | Exactly one private Command+V; permission/target/modifier refusal; mid-sequence release; HID residue guards and no retry. |
| Windows App | Consecutive source pastes, busy and revision guards, manual/local/self input exclusion, complete private Command+V flags/types, Fn release, target/window/input/clipboard cancellation, balanced release on Quit and disabled filter. No clipboard writes or real keystrokes. |
| Clipboard isolation | Real subprocess reads of rich/multiple-item and deferred named boards; a provider blocked for 60 seconds cannot block the main actor; timeout/cancellation reaps only the owned reader; following revisions remain readable; expired capture cannot replay. Full capture/release/restoration uses the production asynchronous reader. |
| Windows clipboard preparation | Read before all native keys; named-board text/rich formats unchanged, empty/missing/stale data refused, timeout and cancellation release the caller, one owned reader with reaping on timeout, late completion cannot replay, context changes during reading cancel input. |
| Completion | Deferred cleanup readiness, single completion attempt, busy refusal and errors. |
| Transfer | Clipboard menu order, exact setting transitions, failure recovery, original Send before sharing-on and receipt validation. |
| Core compatibility | Existing 1.0 library calls and conformers still compile, including fixed-clipboard validation and default preparation. |

GitHub Actions runs the native suite and bundle build on a standard macOS 26 Apple silicon runner,
plus privacy and secret checks. It does not install or launch the helper. A green
workflow establishes component behavior, not a successful physical remote paste.

Routine common-path changes run the shared source contract suite rather than
requiring a new manual matrix for every vendor. Repeat focused physical checks
when the remote-client protocol changes, a source changes its paste behavior or
a reported regression cannot be reproduced with the shared contract. The
integration record documents evidence; it is not an app-specific feature switch.

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
   When access is missing, click the Accessibility button and then the native
   alert's Open System Settings. Expect one pane with the alert dismissed. A
   trusted click should open the pane without an alert. Compare designated
   requirements across two certificate-signed rebuilds, then verify the second
   installed build retains access. A matching requirement alone is not a TCC trial.
   In Settings, add and remove a disposable app entry. Verify each edit reaches
   the settings file immediately and survives closing/reopening the window.
   First-use completion must no longer depend on Save; a failed edit must show
   an error and keep the previous selection.
8. After sleep, test the first dictation before making another local copy. Record
   source key-up, returned clipboard revision and the visible remote result.
   If the pre-dictation clipboard was empty, expect successful insertion and
   exact empty restoration even when the source returns an empty text item.
   A source that never returns a new clipboard revision must still time out
   without replay; this is a separate failure from empty-format matching.
9. Launch the installed app and check **Launch at login** in Settings and its
   entry in macOS Login Items. Log out and back in (or restart) to verify an
   actual automatic launch. Turn it off in macOS, manually reopen/update the app,
   and verify it stays off. Re-enable it afterward if wanted. Do not log out or
   restart the user's Mac without authorization; registration alone is not proof
   of a successful next-login launch.

Record app/OS versions, source clipboard settings, visible result, status and
whether each step actually ran. Never claim remote receipt based only on a local
log or replace physical integration checks with mocked events.

## Local hang-fix check

Use the signed diagnostic candidate on the local Mac. Confirm Settings and Quit
remain responsive while entering/leaving Screen Sharing, including after normal
sleep. Repeat ordinary clipboard paste and a synthetic dictation with exact local
clipboard restoration. Repeat a Windows App dictation; record stale remote data
separately, since isolation does not establish RDP readiness. Read-timeout logs
must name baseline/candidate/source-return, the revision and failure without text.
Do not trigger an artificial stall on the general clipboard or force-stop a source
app to test this. The deliberate hung-provider test uses a disposable named board.

For the input-filter liveness candidate, repeat Flow and superwhisper dictations
in both clients and check that the source, helper menu and normal keyboard input
remain responsive. Verify one insertion and the existing source/target clipboard
restoration behavior. A recovered process sample cannot establish the cause of a
previous hang. The deadline tests establish local refusal of late work, not remote
receipt or resolution of the separate stale RDP clipboard issue.

## Windows App physical checks

Requires the local Apple-silicon Mac, Accessibility, the native **Microsoft
Windows App for macOS**, an RDP connection and a remote Windows text field.
First verify ordinary local copy and physical Command+V/Control+V. Use synthetic
markers and select the dictation app in Settings; do not change administrator policy.

1. Copy a local original marker. Leave `START|` in the remote field and dictate
   three separate phrases without manual paste. Each must arrive once, without
   a leading `v` or deleted prefix. Test the same dictated text in a new operation.
2. Paste locally after completion and check the dictation app's configured
   restoration. The helper does not write the clipboard in Windows App; record
   the source setting and actual result, rather than attributing restoration to it.
3. Check hold/release and toggle dictation, including returning to the remote
   field before stopping. The physical modifier must be released before replay.
4. Change the target/window, click/type or copy new content during replay. Expect
   cancellation and no deferred insertion. Check local dictation/manual paste and
   repeat the Apple Screen Sharing baseline after switching clients.
5. Test repeated operations and Quit after installation. Record any source warning
   separately from remote text arrival. When investigating a source-specific issue,
   record its paste/clipboard settings and compare it with the shared contract.
6. For the local clipboard-read candidate, repeat distinct phrases and the first
   dictation after normal sleep/reconnection, without a preparatory local paste or
   recopy. Compare `clipboard-read-ready` timing/revision with native input and the
   actual remote result. Record stale text, missing input and any source warning
   separately. Successful reads alone do not validate RDP delivery or this fix.

## Controlled Windows clipboard lifetime experiment

Available only in a diagnostic build via **Windows Clipboard Test…**. Requires
the user's local Mac, Accessibility and an empty remote Notepad document. Run
when the remote screen is free. Do not use a real document, send a message,
dictate, type or manually paste during a trial.

1. Choose **Hold NEW for 5 seconds**, then click the empty Notepad field within
   20 seconds. The probe seeds OLD before focus enters Windows App, waits one
   second, publishes NEW with focus unchanged, and posts one native paste.
   Record the complete visible marker (NEW, OLD, neither or another value).
2. In a fresh empty field repeat **Restore OLD after 650 ms**. Native input is
   identical; only the NEW publication lifetime changes. Check the original
   local clipboard after cleanup without making a new copy first.
3. Match each observation to its `client=windows-probe` operation and marker.
   One success does not settle an intermittent failure. If the sustained mode
   still produces old data, the investigation must test publication/focus or RDP
   state rather than merely extend a source-restoration delay.

Automatic tests use named pasteboards and mocked input. They verify both payload
lifetimes, all-format and empty restoration, one sequence, cancellation before
input, balanced keys/protected cleanup on Quit, target timeout and newer-copy
protection. They do not exercise native Windows App or prove remote receipt.

## Validated baseline

The accepted physical paste behavior and its limits are recorded in
[behavior-baseline.md](behavior-baseline.md). Utility and packaging changes retain
that protocol; they do not replace a physical setup/permission test for a new
application identity or a clean browser download.
