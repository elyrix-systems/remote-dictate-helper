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
| `ClipboardBaselineHistory` | Up to eight snapshots / 64 MiB in RAM, sampled only while Screen Sharing is active and the helper is idle. |
| `CapturedClipboard` | Actual clipboard formats and text; an encoding marker only for unlabelled, valid non-ASCII UTF-8 HTML sent remotely. |
| `ScreenSharingClipboardMenu` / `ExplicitClipboardTransfer` | Validate the original connection and clipboard revision; sharing off, captured snapshot write, Send Clipboard. |
| `ExplicitPasteShortcut` / `GuardedPaste` | One private native Command+V, with target, trust, modifier and clipboard guards; no Backspace or retry. |
| `LocalClipboardRestoration` / `DeferredClipboardCompletion` | Restore only the owned revision, send the original clipboard before sharing-on, then finish. |
| `LaunchAtLogin` | One-time registration of the installed main app through `SMAppService`; macOS owns subsequent enable/disable choices. |
| `DictationSourceSettings` | Commit source-list edits immediately after persistence/application succeeds; retain the previous selection on failure. |

The event filter has an 80 ms capture-decision queue budget and a 100 ms clipboard
capture budget. Late capture passes the original input through. Accepted V-down
and V-up are filtered; ordinary Command flag events, manual input, other apps and
the helper's replay are not removed. A disabled tap reports an error. An input
sequence counter prevents delayed main-thread callbacks from hiding a new click
or key press before replay.

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

## Windows App transaction

`idle → captured → modifiers released → one native paste → idle`

`WindowsAppPasteMonitor` accepts the same configured source identities only when
`com.microsoft.rdc.macos` is frontmost. It reads the pasteboard revision counter,
not payloads, and never writes to the pasteboard or invokes Screen Sharing menus.
The source's `clipboardReturn` policy applies only to Screen Sharing. In Windows
App the source must keep its current result available until native paste finishes.

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

## Integration evidence and limits

| Risky assumption | Evidence | Scope |
| --- | --- | --- |
| A complete native modifier sequence fixes the observed Windows App `v` | Physical comparison of Flow/keyboard events and accepted local Flow trial | Windows App 11.4.3 on the tested Mac; not all RDP endpoints/sources |
| An active event tap can suppress an event | Apple's Core Graphics callback contract | External API proof only |
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
