# Architecture

Remote Dictate Helper runs entirely on the local Mac. It captures an accepted
clipboard paste and routes it to Apple Screen Sharing or Microsoft Windows App.
Screen Sharing transfers a snapshot and restores the original clipboard; Windows
App repairs native paste input while RDP and the dictation app own the clipboard. There is no database, donor process, microphone
capture, recording shortcut detector or fallback character deletion.

The SwiftPM core library retains its 1.0 public interfaces for source compatibility.
Retired convenience methods live in `LegacyCoreCompatibility.swift`; the helper
does not use them. Compatibility tests cover the old entry points separately
from the production transfer and restoration tests.

## Apple Screen Sharing transaction

`idle → captured → source released → clipboard sent → paste posted → restored`

A focus/caret change cancels insertion. Cleanup already in progress may wait for
the original Screen Sharing connection, but never activates it or retries input.
New dictations are not queued while a transaction is finishing.

| Component | Responsibility |
| --- | --- |
| `AppSettings` | Source app identifiers, explicit clipboard-return policies and settings migration. The app runs automatically; obsolete enable/method fields are discarded. |
| `PasteEventFilter` | Active session tap on its own run loop. Only a selected source's candidate Command+V requests a bounded capture decision. |
| `DictationPasteMonitor` | Source, foreground, revision, key-up and cancellation gates; per-paste transaction state. |
| `IsolatedClipboardReader` / `ClipboardAccess` | Read external provider data in a short-lived child; keep immutable, revision-bound snapshots for synchronous guards. |
| `ClipboardBaselineHistory` | Up to eight snapshots / 64 MiB in RAM, sampled only while Screen Sharing is active and the helper is idle. |
| `CapturedClipboard` | Actual clipboard formats and text; an encoding marker only for unlabelled, valid non-ASCII UTF-8 HTML sent remotely. |
| `ScreenSharingClipboardMenu` / `ExplicitClipboardTransfer` | Validate the original connection and clipboard revision; sharing off, captured snapshot write, Send Clipboard. |
| `ExplicitPasteShortcut` / `GuardedPaste` | One private native Command+V, with target, trust, modifier and clipboard guards; no Backspace or retry. |
| `LocalClipboardRestoration` / `DeferredClipboardCompletion` | Restore only the owned revision, send the original clipboard before sharing-on, then finish. |
| `LaunchAtLogin` | One-time registration of the installed main app through `SMAppService`; macOS owns subsequent enable/disable choices. |
| `DictationSourceSettings` | Commit source-list edits immediately after persistence/application succeeds; retain the previous selection on failure. |

The event filter has an 80 ms capture-decision budget, including source identity
lookup. A RAM-only `PasteTargetScope` gate, updated by workspace activation and
sleep/session notifications, refuses candidates outside the adapter's client
before identity lookup or main-queue admission. This cache only permits further
checks; the actual foreground/window guards still decide capture and replay.
Delayed/missed activation can pass original input through, never authorize a
paste into a different target. Screen Sharing baseline sampling is suspended
outside its client and starts fresh on return.

Only synthetic Command+V candidates in an active scope resolve a source, on a separate queue
with one outstanding lookup shared across filters and restarts; ordinary input performs no application
lookup. Candidate data is prepared asynchronously, with at most 60 ms of the
remaining budget for the reader. No caller code or OS query runs under the
decision lock. Each adapter must obtain acceptance before committing or replaying
the prepared transaction. A blocked lookup cannot queue more lookups. Late capture
passes the original input through and cannot schedule a deferred replay. Accepted V-down
and V-up are filtered; ordinary Command flag events, manual input, other apps and
the helper's replay are not removed. A disabled tap reports an error. An input
sequence counter prevents delayed main-thread callbacks from hiding a new click
or key press before replay. Ordinary keys/clicks update that counter directly and
enqueue no observer task; only an accepted V-up is delivered asynchronously.
`PasteAdmissionQueue` permits one waiting admission across both adapters and
restarts. An expired request keeps its slot until the main queue drains it, so
an indefinitely stalled main queue cannot collect expired capture callbacks.
Monitor epochs reject callbacks from a stopped filter.

Disabled taps are disconnected synchronously before diagnostics or UI callbacks:
disable and invalidate the Mach port/source, cancel the pending capture decision,
clear accepted-key pairing, and stop the worker run loop. Retirement is one-shot;
late native setup is disconnected immediately and never re-enabled. A 500 ms
permission check on a separate serial queue also retires a tap on observed trust
loss. Neither AX trust queries nor UI progress are required by the disabled-event
callback. Both adapters stop after a reported failure; Screen Sharing sampling
stops too. The status keeps the error through late cancellation/restoration
callbacks, until Settings verifies access and creates fresh filters. Existing
clipboard-ownership cleanup remains in force; no late paste is replayed.

Readiness gate for revocation: the risky assumption is that reporting a disabled
tap is sufficient to release the system event stream. The local incident disproved
that assumption for the old Screen Sharing path. Apple's
[port invalidation contract](https://developer.apple.com/documentation/corefoundation/cfmachportinvalidate(_:))
and [disabled-tap API](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable(tap:enable:))
provide external evidence for teardown. A local spike invalidates an owned real
Mach port and run-loop source before the UI callback, with no global tap or TCC
change. Regression tests cover pending admission, accepted key-up, duplicate
disabled events and stop-before-creation. The installed 113.1.1 candidate failed
the physical revocation test even after both native teardown calls returned.
Mocked trust and a disposable port are not proof of WindowServer recovery.

`PermissionMonitoringGuard` therefore retires both monitors **before** opening
System Settings, including activation from outside the helper. It also guards
startup, source changes and the hidden helper Settings timer against recreation
while the permission pane is active. A direct button request stays suspended
through launch. On leaving, permission is checked before fresh monitoring can
start; a missing grant retains the error. Ordinary local/remote focus changes do
not rebuild taps. A paused-state timer updates the permission status; it does not
poll on the event thread. Existing clipboard cleanup still owns any interrupted
Screen Sharing transfer.

The risky assumption for this precaution is that removing taps *before* an
interactive revocation avoids the failing WindowServer transition. There is a
matching [first-hand report on Apple's developer forum](https://developer.apple.com/forums/thread/844416);
Apple DTS requested a system diagnostic but did not publish a fix there. This is
external incident evidence, not an Apple guarantee about our workaround. Local
state-transition tests establish no recreation while guarded; a read-only native
tap inventory must confirm that the installed process owns zero taps in System
Settings before another coordinated revocation test. Revocation outside that UI,
for example by device management while a remote window stays active, is not
covered by the pre-entry guard. Do not claim it is universally freeze-proof.

Permission consumers read a short-lived RAM snapshot from
`AccessibilityAccessMonitor`. A utility queue starts one fresh copy of the
signed executable once per second. It runs `AXIsProcessTrusted` before any app
initialization and returns only an exit status. A 750 ms deadline kills/reaps
that owned child; a child-side one-second deadline also prevents an orphaned
check from waiting indefinitely if the parent exits. No OS permission IPC runs
on an input callback or the main actor. The snapshot expires after two seconds, and entering/leaving the
permission pane invalidates earlier generations. Unknown results never
authorize input. Only the user's button may spawn the request mode using
`AXIsProcessTrustedWithOptions`; the native alert owns navigation. AX does not
distinguish a disabled entry from a removed one, so both take this request path.
Already granted access opens the pane directly. Settings reads readiness without
creating taps; failed native setup is not retried by its status timer.

Readiness gate: AX/CG preflight queries were assumed to reflect a removed grant.
The 113.1.2 trial disproved this. A
[Chromium investigation](https://chromium.googlesource.com/chromium/src/+/7474294381a3b199f2ecc66ed892c1e48ee1f970)
suggested a HID query instead, but our installed 113.1.3 trial retained stale
positive and negative HID results as well. That local failure overrides the
generic external evidence. The next assumption is that a fresh signed process
observes current AX permission under the same app identity. Child lifecycle and
injected state transitions are tested; installed revoke/regrant and native alert
attribution must also be verified locally. Do not infer either from CLI trust or
the mocked tests. See the investigation record for actual trial outcomes.

Readiness gate: workspace activation notifications are Apple's external API
contract ([reference](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)).
Local component checks exercise cached refusal, foreground/sleep/wake/stop/restart,
timer suspension, 60,000 ordinary input events, 1,000 local pastes and 20,000
expired admissions without posting native input. Actual notification ordering,
return-before-finishing dictation and prolonged source-app liveness still need
local integration evidence. See the [investigation record](experiments/local-input-liveness-2026-10-09.md).

For `restoresPrevious` sources, V-up and a new clipboard revision matching a saved
original establish release. Unknown values stop replay; the five-second limit is
a failure deadline, not a fixed wait. A latest original with zero items may also
return as exactly one zero-byte UTF-8 plain-text item; restoration still uses the
saved zero-item original. Whitespace, other formats and older empty snapshots
do not qualify for this equivalence. `keepsTranscript` is an explicit advanced
source contract that permits the preceding snapshot after V-up. There is no
heuristic fallback between these protocols.

Successful input allows restoration after 200 ms; partial/failed input retains
the five-second protection interval. Those allowances do not establish remote
consumption. Revision checks, including equal-text copies, protect newer content.

## Clipboard provider isolation

`NSPasteboardItem.data(forType:)` and `string(forType:)` may synchronously ask
another application to materialize promised data. They have no application-level
cancellation deadline. Reading them on the main actor caused an observed
60-second helper freeze; a source app waiting for the same clipboard also stalled.
That correlation does not prove the helper caused the source app's stall.

All production payload reads now run in a short-lived, read-only invocation of
the same executable. It exits before main-app initialization: no window, login
registration, input tap, clipboard write or logging. Its bounded binary response
travels through an anonymous pipe and stays in RAM. There is one reader slot;
only this owned child can be terminated on timeout/cancellation. Other apps and
the system clipboard service are never terminated.

Baseline and source-return reads have a 250 ms failure deadline. Baseline polling
allows one asynchronous sample and does not retry a failed revision continuously.
The candidate read uses the shorter remaining capture budget. Each result checks
revision, cancellation and context again before use. Timeout is refusal, never
permission to paste old data. Source matching, formats, clipboard-return policy,
sharing transitions and the one-paste/no-Backspace sequence remain unchanged.

Synchronous replay/restoration guards use prepared RAM snapshots and the current
revision; they never request provider data. After a successful write of eager
items, the exact published bytes are remembered under that revision. Subsequent
guards validate that publication, rather than requesting our own lazy AppKit
provider from a blocked main thread. Even an equal-text copy with a new revision
invalidates ownership. This does not identify external writers or detect a
provider mutating data without changing its revision; clipboard revisions remain
the ownership boundary. Full-format tests independently read the resulting board.

Readiness gate: the risky assumption is that a blocked AppKit call can be confined
to a disposable child while the menu actor and event tap keep running. **Local
component proof** uses an external named-board provider that sleeps for 60 seconds:
the read times out, the main actor continues advancing, the child is reaped, and a
new revision reads successfully. Delayed-provider, rich/multiple-item, cancellation,
expired-decision and complete capture/release/restoration tests use the production
reader. This is not production proof that Flow can never stall independently on
a remote clipboard, or that Windows has received fresh RDP data. Real dictation,
sleep/reconnection and both remote clients still require physical validation.

## Windows App transaction

Source identification is shared by both remote adapters. `PasteEventFilter` maps
the event's process to its bundle identifier and matches the selected source or
its dotted helper identifier. It never switches algorithms by vendor name.
Flow, superwhisper, Valis and apps added in Settings use this same boundary.
The process lookup is injectable so regression tests can exercise the complete
classification/capture path without launching those apps or posting real input.

`idle → captured → local text readable → modifiers released → focus refreshed → one native paste → idle`

`WindowsAppPasteMonitor` accepts the same configured source identities only when
`com.microsoft.rdc.macos` is frontmost. It captures the pasteboard revision counter
and then asks `WindowsClipboardReader` to read one advertised text representation
in the isolated reader process, outside the event-tap decision and main actor. UTF-8 plain text
is preferred, with RTF or HTML as alternatives for rich-only sources. The bytes
are discarded after checking availability; no decoding, normalization, retention,
clipboard writes or Screen Sharing menu operations occur.
An additional explicit diagnostic-text build flag can retain a bounded UTF-8
prefix of those same bytes in the local debug log. It adds no provider read and
never treats the local text as remote receipt. Normal builds discard the bytes.
See [diagnostics](diagnostics.md#optional-local-transcript-capture) for limits.
The source's `clipboardReturn` policy applies only to Screen Sharing. In Windows
App the source must keep its current result available until native paste finishes.

The read completes as soon as the data is available; 250 ms is a failure deadline,
not a fixed delay. Missing/empty data, a changed revision, timeout or cancellation
stop the operation before any keys. At most one reader process may be outstanding; timeout or cancellation terminates
and reaps that owned child before the slot is reused. A slow external provider
cannot accumulate readers or cause late input. Target, window, trust, input sequence and revision are checked again
after reading. Local data availability does not acknowledge RDP delivery; there
is no blind retry or duplicate paste if Windows still holds old clipboard data.

`WindowsFocusRefresh` then briefly activates a transparent, shadowless,
mouse-transparent ordinary helper window and requests one return to the original
Windows App process. It confirms actual foreground/key-window state at both
phases; the one-second total failure deadline is not a fixed delay. The owned
window closes on every exit. There are no private Windows App APIs, synthetic
activation notifications or clipboard writes. A slight focus flicker can remain.

During this round trip, captured input/modifier counters, generation, permission
and clipboard revision remain guarded. Only the original target and the owned
helper key window are allowed; third-party focus or another helper window stops
the operation. The original client PID and AX window are checked again before
keys, so changing destinations cannot result in a deferred paste. A source that
restores its clipboard before readiness causes cancellation, not republishing.
There is one activation request per phase and no retry. Synchronous AppKit calls
are not made preemptible by the polling deadline.

A separate instance of `PasteEventFilter` pairs the accepted V-down/V-up and
tracks physical modifier changes. The existing Screen Sharing filter's event
scope is unchanged. Each adapter refuses capture while the other is busy. Source
settings apply to both; local/manual/unselected input remains unaffected.

`WindowsAppPasteShortcut` sends four events from one private source: Command
flagsChanged, V-down, V-up, Command flagsChanged release. It preserves left-Command
and non-coalesced flags, with 25 ms between events, as in the accepted local trial.
This spacing is not a transcription wait or proof of clipboard delivery. Only the
native API's posted events are observed; the remote application provides no receipt.

Replay waits for the existing physical-modifier readiness guard, validating target,
focused window, input sequence and the captured clipboard revision throughout.
Physical modifiers released during that wait are allowed. A new physical modifier
change after readiness cancels replay. Cancellation, permission loss, disabled
filter and Quit stop the task and release owned keys without retries. A completed
or failed revision is not automatically replayed. New dictations use fresh revisions.
No diagnostic sampler, expiry, per-key log or transcript copy is shipped.

Maintainer builds can explicitly enable [local diagnostic metadata](diagnostics.md).
This adds an independent context observer and detailed failure reasons, without
changing either client protocol. The normal build leaves it disabled.

## Integration evidence and limits

| Risky assumption | Evidence | Scope |
| --- | --- | --- |
| A complete native modifier sequence fixes the observed Windows App `v` | Physical comparison of Flow/keyboard events and accepted local Flow trial; subsequent owner-confirmed insertion with superwhisper and Valis on 1.1.0 | The tested local Windows App setup; additional RDP endpoints and recording modes are separate integration checks |
| Reading local text before the native sequence may help a deferred pasteboard provider | Apple's data-provider contract; a separate-process named-pasteboard spike materialized data without changing its revision; isolation/cancellation regression tests | External API + local component proof. Repeated physical trials remained stale with materialization alone; local availability is not remote readiness |
| A guarded focus round trip refreshes the tested stale Windows App state | Same-session DIRECT/REFRESH comparison and accepted repeated Flow dictation with a transparent window | Local physical integration evidence. Minor flicker accepted; long-running, post-sleep and other-source refresh trials remain separate checks. See the [experiment archive](experiments/windows-clipboard-2026-10-09.md) |
| An active event tap can suppress an event | Apple's Core Graphics callback contract | External API proof only |
| A blocked identity lookup or admission check cannot hold the input stream beyond the capture budget or commit late | Injected stalls in the real filter and both adapter admission paths; no native events posted | Local component proof. Source-app recovery and normal remote insertion still require physical integration checks; this does not prove the cause of an earlier hang |
| Filtering the source paste prevents the leaked `v` | Physical trials with Flow, superwhisper and Valis | Tested local Mac and Screen Sharing setup |
| Source clipboard return can identify the original | Snapshot/revision regression tests and physical clipboard checks | Component + local integration proof |
| A zero-item original may return as one empty UTF-8 text item | Local Flow/pasteboard metadata after wake and a named-pasteboard reproduction | Observed source behavior; automated capture/replay/restoration proof, pending physical verification of the fix |
| HID-only generic Command residue can be handled safely | Read-only flag/key-state measurements, refusal tests and successful superwhisper Option push-to-talk into remote Codex | The observed state, not all keyboards or sources |

The HID compatibility case requires a private event source, an intercepted paste,
clear session modifiers and Command key states, and HID generic Command without
left/right device Command bits or other modifiers. It posts no preliminary key
release. Ambiguous or physical-key states remain blocked.

These are local integration results, not universal production compatibility.
Changes to OS permissions, input routing or another app's protocol require a
small physical spike before expanding support. See [test-plan.md](test-plan.md).

## Launch at login

The first launch from `/Applications` or `~/Applications` registers
`SMAppService.mainApp`. Successful or approval-required registration records a
version-independent preference. Later launches and updates do not re-register,
so turning it off in macOS remains effective. Settings reads the system's current
status and opens Login Items for changes or approval. A registration failure
opens Settings, logs the error domain/code and may retry on the next launch.
Build, command-line, translocated and mounted-DMG copies do not register.

Risk to verify locally: registration must work with the distribution's ad-hoc
signature, and a login must launch the installed app. Apple's API contract is
external evidence; mocked tests protect first-use/opt-out behavior. System
registration and an actual subsequent login are separate integration checks.
There is no additional executable, launch-agent plist, daemon or root access.
On 2026-10-06, the installed ad-hoc build returned `.enabled` and appeared once in
macOS **Open at Login**, without an administrator password for registration.
The next-login launch remains pending; see [behavior-baseline.md](behavior-baseline.md).

Reference: Apple's [main app login item](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp)
and [registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).

Reference: Apple's [event tap callback](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)
and [event-source state tables](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid).

## Settings edits

Adding or removing a dictation app persists the proposed settings and applies
them to the monitor before the displayed list changes. A failed write or busy
transfer rejects the edit, keeps the previous list and presents an error. Closing
the window performs no write or rollback. Permission and login-item changes remain
managed by macOS. First-use completion is recorded once the installed app has
Accessibility, a ready input monitor and at least one saved source; no Save action
is required. Tests exercise persistence and rejection with a disposable settings
file; the native picker and window still require local UI verification.

An explicit Accessibility-button click takes one path: an untrusted process
requests the native access alert, whose **Open System Settings** action owns
navigation; a trusted process opens the pane directly. Background trust checks
never prompt. Apple's request is asynchronous, so opening the pane immediately
after requesting access can leave the alert over Settings. Injected-effect tests
protect the mutually exclusive paths; native alert dismissal needs local proof.
Reference: [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions).

Readiness evidence: the API's asynchronous prompt contract and code-signing
requirements are external proof. Local proof on 2026-10-06 includes owner-confirmed
alert dismissal and a changed executable retaining Accessibility after replacement
with the same certificate. Public ad-hoc downloads still have changing identities;
this is not production Developer ID evidence. See [the local record](behavior-baseline.md#local-accessibility-navigation-and-signed-update).
