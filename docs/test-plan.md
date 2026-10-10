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
| Local-input isolation | 60,000 ordinary events enqueue no callback while preserving cancellation counters; 1,000 local synthetic pastes bypass identity/admission; accepted V-up remains paired after focus loss. 20,000 expired admissions retain one queued block and recover. Workspace scope start/stop/sleep/wake, baseline timer suspension and a bounded independent main-queue heartbeat use fake notifications/queues and a named board. |
| Permission revocation | Timeout/user-disabled callbacks synchronously invalidate an owned Mach port and source before notification. Duplicate callbacks, matched key-up and new keyboard/mouse events pass after retirement; injected trust loss withdraws pending acceptance. Late creation disconnects immediately. Screen Sharing sampling stops and reports once. No global input tap or TCC change. |
| Shared source contract | Real event classification into both client monitors for Flow, superwhisper, Valis and a custom source; main/helper bundle IDs, consecutive captures and both clipboard-return policies. Removed/disabled sources pass through. No running dictation apps required. |
| Clipboard | Full-format original restoration, UTF-8 HTML transport, empty originals, clipboard ownership, newer/equal-text copies and restoration deadlines. |
| Input | Exactly one private Command+V; permission/target/modifier refusal; mid-sequence release; HID residue guards and no retry. |
| Windows App | Consecutive source pastes, busy and revision guards, manual/local/self input exclusion, complete private Command+V flags/types, Fn release, target/window/input/clipboard cancellation, balanced release on Quit and disabled filter. No clipboard writes or real keystrokes. |
| Windows focus refresh | All selected sources and repeated pastes refresh before keys; both activation phases, deadline/refusal, window cleanup, other-app/window/input/modifier/revision/trust changes, Quit and disabled filters stop without a late paste. Transparent key-eligible window construction; no actual activation. |
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

Use a signed diagnostic build on the local Mac. Confirm Settings and Quit
remain responsive while entering/leaving Screen Sharing, including after normal
sleep. Repeat ordinary clipboard paste and a synthetic dictation with exact local
clipboard restoration. Repeat a Windows App dictation; record stale remote data
separately, since isolation does not establish RDP readiness. Read-timeout logs
must name baseline/candidate/source-return, the revision and failure without text.
Do not trigger an artificial stall on the general clipboard or force-stop a source
app to test this. The deliberate hung-provider test uses a disposable named board.

For input-filter liveness checks, repeat Flow and superwhisper dictations
in both clients and check that the source, helper menu and normal keyboard input
remain responsive. Verify one insertion and the existing source/target clipboard
restoration behavior. A recovered process sample cannot establish the cause of a
previous hang. The deadline tests establish local refusal of late work, not remote
receipt or resolution of the separate stale RDP clipboard issue.

For the foreground gate, check local dictation before and after remote use, then
return to a remote field before finishing toggle recording. Check both clients
and repeated operations. `filter.scope` should close in a local app; no candidate
lookup/read should follow local pastes. Screen Sharing baseline reads should
stop until returning to its window. Keep the diagnostic build through ordinary
extended use; if a stall recurs, preserve process samples **before** restarting
the source/helper when practical. Heartbeat delay alone is not a root-cause proof.

## Accessibility revocation integration check

On an explicitly coordinated local test with recovery access available, revoke
the running helper's Accessibility grant. Ordinary mouse and keyboard input must
remain responsive, both filters must stop, and the menu must retain an error
directing the user to Settings. Check both removing the entry and turning it off.
Regrant access and reopen helper Settings; require fresh filters and a successful
ordinary copy/paste before a dictation. A mid-transfer test must also verify local
clipboard restoration and the original Screen Sharing connection's sharing state.
Do not revoke the user's permission unattended, reset TCC, or infer this physical
result from the automated disposable-port tests.

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
6. Repeat distinct phrases and the first
   dictation after normal sleep/reconnection, without a preparatory local paste or
   recopy. Compare local read/focus-return timing and revision with native input and the
   actual remote result. Record stale text, missing input and any source warning
   separately. Successful reads alone do not validate RDP delivery or this fix.

## Windows focus refresh regression check

The normal Windows App path now performs one guarded focus round trip before
paste. Keep Windows App in the same session and remote field for at least three
distinct dictations, without a local focus switch, copy or manual paste between
them. Check fresh text each time, the intact prefix, no duplicate/`v`, source
responsiveness and source restoration of the original local clipboard. Record
any warning or visual flash; a slight focus flicker was accepted on the tested Mac.
Repeat after ordinary sleep/reconnection and during extended use. Those scenarios
remain integration checks, not guarantees from the component suite.

The helper's transparent window must acquire foreground/key status and return to
the original Windows App window before keys are sent. Changing input, clipboard,
modifiers, permission or destination cancels instead of retrying. Component tests
mock activation for all default/custom sources, repeated revisions, both focus
phases, timeouts/refusal, Quit and disabled filters. Construction checks do not
show a window or prove macOS will grant activation. Local focus logs do not
acknowledge remote receipt.

Historical trial procedures and their results are preserved in the
[Windows experiment archive](experiments/windows-clipboard-2026-10-09.md).
The experimental menus and synthetic clipboard publisher are no longer shipped.

## Validated baseline

The accepted physical paste behavior and its limits are recorded in
[behavior-baseline.md](behavior-baseline.md). Utility and packaging changes retain
that protocol; they do not replace a physical setup/permission test for a new
application identity or a clean browser download.
