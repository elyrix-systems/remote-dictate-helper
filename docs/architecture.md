# Architecture

Remote Dictate Helper runs entirely on the local Mac. It captures an accepted
clipboard paste, transfers it through Apple Screen Sharing, pastes once and
restores the original clipboard. There is no database, donor process, microphone
capture, recording shortcut detector or fallback character deletion.

The SwiftPM core library retains its 1.0 public interfaces for source compatibility.
Retired convenience methods live in `LegacyCoreCompatibility.swift`; the helper
does not use them. Compatibility tests cover the old entry points separately
from the production transfer and restoration tests.

## Transaction

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

## Integration evidence and limits

| Risky assumption | Evidence | Scope |
| --- | --- | --- |
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
