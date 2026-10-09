# Windows clipboard experiments — 2026-10-09

This is an archive, not instructions for the current app. The temporary runtime
probes and their tests were removed for 1.1.2; their code remains in the commits
linked below. Do not restore an old build over a working installation merely to
follow these procedures. Current behavior and regression checks live in
[architecture](../architecture.md) and [test plan](../test-plan.md).

## Findings and decision

| Trial | Observed result | Conclusion and limits |
| --- | --- | --- |
| 111.1.2 single synthetic publications | Both 5-second and 650-ms lifetimes inserted NEW after returning from the helper dialog. | A single success included a focus switch; it did not reproduce repeated dictation. |
| Passive remote observer, five real Flow dictations | Each new local capture produced an older remote value; no remote clipboard sequence change was observed. Manual copy/paste worked, then dictation was stale again. | Redirection remained usable; local capture and posted keys did not establish remote delivery. |
| 111.1.3 six synthetic publications with uninterrupted focus | First value repeated in all six trials, including 5-second lifetime and a 1-second pre-paste delay. A physical paste with unchanged focus was also stale. | Longer lifetime and that delay did not fix the reproduced case; the dictation app was not required to reproduce it. |
| Manual focus control | Leaving and returning to Windows App made the current held marker paste correctly. | Justified a bounded activation spike, not a claim about Windows App internals. |
| 111.1.4 automatic activation | Failed before acquiring helper focus; no further paste. | NSPanel/activate was insufficient in this local setup. |
| 111.1.5 ordinary-window focus comparison | Results 1, 2, 2, 4, 4, 6: all three REFRESH trials were fresh; intervening DIRECT trials were stale. Round trips 42–52 ms. | Physical local evidence in the same failing client process; no Windows App restart during this comparison. |
| 111.1.6 actual Flow dictation | Three consecutive fresh remote phrases; original local marker preserved. Visible helper window flashed. | Owner-confirmed real-source operation. Windows App had restarted before this series; this alone is not proof about the old failing session. |
| 111.1.7 transparent window | Eight observed operations completed in 173–219 ms; focus took 55–103 ms. Owner accepted a slight remaining flicker. | Accepted local behavior promoted to 1.1.2. Not proof for every RDP endpoint, prolonged use or first paste after sleep. |

The production Windows path therefore retains the proven ordinary-window
activation sequence with opacity zero, makes one guarded return to the original
client window, and sends one paste. It never writes the clipboard, deletes a
character or retries. Every selected source uses that same path. Component tests
cover Flow, superwhisper, Valis and a custom source; the new physical refresh
trials used Flow. Historical acceptance of all default sources on 1.1.0 does not
constitute a new physical trial of each source with focus refresh.

The detailed sanitized chronology, evidence classification and limitations are
in [the behavior baseline](../behavior-baseline.md#local-windows-clipboard-timing-probe-11112).
Local and remote raw logs, actual transcripts and machine identifiers remain
private and are not part of this archive. Local logs never independently prove
what text a remote field consumed.

## Recovering historical implementations

| Commit | Archived implementation or evidence |
| --- | --- |
| [`0a95f3e`](https://github.com/elyrix-systems/remote-dictate-helper/commit/0a95f3e) | Synthetic OLD/NEW lifetime publisher and mocked regression tests. |
| [`a3a02ff`](https://github.com/elyrix-systems/remote-dictate-helper/commit/a3a02ff) | Controlled timing results. |
| [`0a5beb8`](https://github.com/elyrix-systems/remote-dictate-helper/commit/0a5beb8) | Guarded focus comparison. |
| [`53c3d38`](https://github.com/elyrix-systems/remote-dictate-helper/commit/53c3d38) | Ordinary-window activation and diagnostic phase checks. |
| [`a54d9ad`](https://github.com/elyrix-systems/remote-dictate-helper/commit/a54d9ad) | Opt-in focus refresh for real dictation. |
| [`b71174b`](https://github.com/elyrix-systems/remote-dictate-helper/commit/b71174b) | Transparent helper window. |
| [`6e18d39`](https://github.com/elyrix-systems/remote-dictate-helper/commit/6e18d39) | Local acceptance of 111.1.7. |

The following sections preserve the old design notes and trial procedures as
written during the investigation. Statements such as “candidate”, “off by default”
and “pending” describe those historical builds, not the 1.1.2 runtime.

## Archived design notes

### Explicit Windows clipboard timing probe

Diagnostic builds expose **Windows Clipboard Test…** for a controlled local
experiment; release builds do not show this command. It is never called by the
automatic dictation adapter. The user selects a mode and then focuses an empty
remote test field. The probe preserves the full original clipboard through the
bounded isolated reader, publishes an OLD marker before entering Windows App,
then publishes a unique NEW marker while the remote window remains focused.
Single trials use the production native sender exactly once. NEW remains
available for five seconds or 650 ms before an intentional synthetic OLD
restoration. The six-paste comparison repeats three profiles twice without
changing focus: 650 ms lifetime, five-second lifetime, and five-second lifetime
with a one-second pre-paste delay. Each trial publishes a unique numbered marker
and posts one paste. The original clipboard is preserved once for the series.

The probe reuses the existing input-filter counters. Focus/window/input or
clipboard changes prevent a delayed paste. New copies prevent original-buffer
restoration. Normal Quit cancels input, balances keys and allows pending clipboard
cleanup to finish. There are no additional taps, background polling sessions,
Screen Sharing menu operations or synchronous provider reads. Logs contain the
synthetic markers and timings, never the saved original payload. The test records
`remoteReceipt=unverified`; the visible remote result must be checked separately.

Readiness gate: the risky assumption is that the transient lifetime of dictation
data, rather than missed clipboard publication, causes stale RDP pastes. The RDP
delayed-rendering contract is external evidence; controlled lifetime, balanced
input, cancellation and exact restoration have local component tests. Physical
single trials passed, but the repeated comparison reproduced stale remote text
even with a five-second lifetime and one-second pre-paste delay. See the
[behavior baseline](../behavior-baseline.md) for evidence and limits. This probe
does not establish a fix. The ordinary Windows adapter still never writes the
clipboard. See the test plan for the trial procedures.

Diagnostic builds also expose **Windows Focus Test…**, explicitly started by the
user. It alternates DIRECT and REFRESH three times, holding each distinct marker
for five seconds. REFRESH briefly activates a transparent, owned helper window and
requests activation of the original Windows App process once. It checks actual
foreground/key-window state, then validates the original remote window before
posting any paste. It never invokes private Windows App methods or fabricates
internal window notifications.

The existing input and clipboard guards remain unchanged across the round trip;
they are not reset to accept user input. Unexpected focus, a newer copy, input,
permission/readiness failure, cancellation or a one-second activation polling
deadline stops the experiment. The window is closed on every exit and activation
is never retried. This does not make synchronous AppKit calls preemptible or
prove that Windows App has advertised fresh remote clipboard contents.

The first automatic trial stopped before acquiring helper focus. The diagnostic
now uses an ordinary window with the existing Settings activation request and
yields activation to the original target before requesting its return. Phase and
window-state logs distinguish failure to acquire helper focus from failure to
return; unchanged polling state is not repeatedly logged. Activation remains an
OS request, not a guaranteed transition or remote clipboard acknowledgement.
The window is fully transparent, shadowless and mouse-transparent before its
first ordering. Its ordinary key-window activation path is retained. The logged
`windowVisible` means ordered, not visible pixels; `windowAlpha` records opacity.

The readiness gate now includes the successful manual focus control and the
automatic six-marker comparison in the behavior baseline, plus mocked
phase/cancellation checks. The separate `RDWindowsFocusRefreshExperiment` build
flag also requires diagnostic logging and is off by default. Only that local
experimental build calls the same refresher after a real source's clipboard read
and modifier readiness, before the existing single native paste.

While the owned helper window holds focus, the captured input/modifier counters,
generation, trust and clipboard revision stay guarded. The refresher itself only
permits the original target and its owned key window; third-party focus aborts.
After return, the original target PID and remote-client window are checked again
before any keys. Source restoration or new input cancels instead of republishing
or retrying. Every configured source uses this same opt-in path. The separate
flag is visible in the diagnostic menu and does not persist in user settings.
Ordinary builds never change focus during dictation. Real source timing, warnings
and long-running stability are still integration checks, not established by the
synthetic marker comparison or component tests.


## Archived physical procedures

### Controlled Windows clipboard lifetime experiment

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
4. **Compare 6 pastes** runs SHORT, HOLD and WAIT twice in the same field,
   with one focus acquisition and one immutable input/window guard. SHORT holds
   NEW for 650 ms and begins paste after 25 ms; HOLD changes only the lifetime
   to five seconds; WAIT additionally waits one second before beginning paste.
   Allow 35 seconds after clicking the empty field. Each trial has a different
   numbered marker and one paste, with OLD between trials. Record all six
   results, including missing, old or previous-trial markers. This isolates
   lifetime and pre-paste delay without a focus refresh between individual
   trials; it does not emulate every source format or establish remote receipt.
   A new copy, input, window change or cancellation must prevent remaining trials.

For a separate physical-key control, explicitly repeat the comparison but press
physical Command+V once immediately after the second automatic line appears.
Do not switch focus or copy anything. The second trial keeps its NEW marker for
five seconds. This deliberate input should stop subsequent automatic trials;
wait 15 seconds for cleanup. Accept the comparison only when the diagnostic
input timestamp falls after trial two's paste and before its OLD restoration.
Otherwise repeat or mark it inconclusive. Record whether the physical paste
inserted trial two's marker or the earlier value. This distinguishes physical
from synthetic input without the focus switch present in ordinary copy/paste
checks. Use only an empty test field and do not send its contents.

Automatic tests use named pasteboards and mocked input. They verify both payload
lifetimes, all-format and empty restoration, one sequence, cancellation before
input, balanced keys/protected cleanup on Quit, target timeout and newer-copy
protection. They do not exercise native Windows App or prove remote receipt.
The comparison tests also verify distinct markers, all six bounded timings,
exact restoration and cancellation between trials without a later replay.

### Controlled Windows focus refresh experiment

Requires the local Mac, Windows App, Accessibility and an empty remote test
field. In a diagnostic build choose **Windows Focus Test… → Start focus test**,
then click that field within 20 seconds. Do not type, dictate, copy or switch
windows for 45 seconds. If all steps run, the explicit test briefly activates its
own transparent helper window three times. No popup should appear and no messages
should be sent from the field.
If the test stops early, inspect the failure phase and
foreground, key-window, visibility and active-Space metadata. An activation
timeout is not a completed clipboard comparison; do not count unrun trials.

Six numbered markers alternate DIRECT and REFRESH, with identical five-second
publication lifetimes. Record each visible marker. In the previously failing
session, the discriminating expectation is fresh REFRESH markers even when
DIRECT reuses an older marker. Compare focus-return elapsed times, errors and
clipboard revisions. Success is established by the visible remote text, never
solely by local input or focus logs. Check original local restoration separately.

Automatic tests mock all activation APIs and use only named pasteboards. They
cover activation refusal/timeout, cancellation, unexpected third-party focus,
another helper window, original target-window validation, changed input/revision,
one activation request, window cleanup and no later paste after failure. A
construction check verifies key eligibility without displaying a window;
it does not prove that macOS will grant an activation request. Source
dictation timing/warnings and long-running native client stability remain separate
integration checks before enabling any automatic focus workaround.

### Real dictation with experimental Windows focus refresh

Requires a local bundle explicitly built with diagnostics and
`REMOTE_DICTATE_WINDOWS_FOCUS_REFRESH=1`, a local source app, Accessibility,
Windows App and an empty remote field. This flag is absent from normal builds.

1. Confirm the menu's **Windows focus refresh experiment enabled** label. Keep
   Windows App in its current session; do not restart it to erase the stale state.
2. Copy a distinct original marker locally, then focus the empty remote field.
3. Make three distinct numbered dictations into that field without an intervening
   local focus switch, copy or manual paste. Do not send the resulting text.
4. Check that all three current phrases arrived exactly once, no `v` appeared,
   and neither the source nor remote input hung. Record any source warning or
   visual flash. The transparent window must still acquire key status and return
   to the original client window before paste; opacity is not evidence of focus.
5. Paste into an empty local field after all three operations and confirm that
   the source preserved the original local marker. Record the actual result;
   helper completion alone cannot establish remote receipt or source restoration.
6. Correlate each operation's captured revision, focus phases and one native paste
   with native text-read metadata. A source revision change during refresh must
   stop the operation before V, with no repeat or clipboard rewrite.

Then repeat relevant hold/toggle modes for the other configured sources and
observe normal extended use/sleep. Component tests mock focus for all default and
custom source identities, repeated revisions, changed input/modifiers/revision,
window/target/trust changes, timeout, disabled filter and Quit. These do not prove
native client stability or compatibility with every source's clipboard lifetime.


## Archived build and diagnostic notes

### Windows clipboard-read experiment

The current local candidate adds a bounded, read-only preparation step to the
Windows adapter, independently of the diagnostic flag. This is a protocol change
under evaluation, not an effect of enabling logging. It does not change the Apple
Screen Sharing transaction. It neither republishes the clipboard nor inserts
locally, activates another app, retries a paste or retains/logs text.
The separate opt-in above can retain a bounded diagnostic copy of already read
plain text; ordinary builds still discard it.

Risky assumption: requesting the source's text representation before replay may
materialize data that Windows App otherwise obtains too late. Apple's
[pasteboard data-provider contract](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider)
is external evidence for deferred data. A separate-process local spike using only
a disposable named board verified materialization with an unchanged revision;
component tests cover refusal, cancellation, timing bounds and unchanged formats.
None of this proves that a remote Windows clipboard is ready. Physical repeated
dictation and post-sleep trials are still required; this experiment has not been
published as a release.

### Opt-in Windows focus refresh for real dictation

`REMOTE_DICTATE_WINDOWS_FOCUS_REFRESH=1` additionally requires
`REMOTE_DICTATE_DIAGNOSTICS=1`. Both are off in ordinary builds. Logging alone
does not enable it. The menu shows **Windows focus refresh experiment enabled**;
the setting belongs to the local bundle, not saved user preferences.

This experiment adds one guarded helper-window/Windows App focus round trip
after the source's local clipboard data and physical modifiers are ready, before
the existing native paste. The helper window is transparent and shadowless;
`windowAlpha=0` records that mode, while `windowVisible` only means ordered.
It never writes or restores the Windows-path clipboard;
the dictation source and RDP keep those responsibilities. Changed clipboard,
input, modifiers, trust or target stop the operation; there is no retry.
`experimental-focus-refresh-start`, phase/window-state logs and
`experimental-focus-refresh-ready` describe the attempt. `remoteReceipt=unverified`
still applies. The one-second activation deadline is a failure bound, not a wait.

Readiness evidence: the controlled six-marker test delivered current values for
all three REFRESH trials (42–52 ms round trips), while the intervening DIRECT
trials repeated previous values. This does not yet prove compatibility with a
real source's transient clipboard lifetime or focus detection. Check three actual
dictations without an intervening focus change, copy or manual paste. Verify
fresh remote text, source restoration of the original local buffer, source
warnings and responsiveness. Then check the other configured dictation sources.
No public release should enable this flag based only on synthetic tests.

### Local provider-isolation candidate

The next candidate isolates payload reads for both clients. Baseline and returned
clipboard reads are asynchronous with a 250 ms failure deadline; candidate capture
uses up to 60 ms within the existing 80 ms decision deadline. These are upper
bounds, not fixed waits. Exact prepared snapshots and revision guards replace
synchronous provider calls during replay and restoration. See the
[architecture](../architecture.md#clipboard-provider-isolation) for proof and limits.

A physical Windows trial of the preceding materialization-only candidate still
inserted old remote text despite a fast successful local read. That experiment
does not establish a fix for stale RDP clipboard data. Isolation addresses helper
responsiveness first; no remote acknowledgement or automatic paste retry is added.
