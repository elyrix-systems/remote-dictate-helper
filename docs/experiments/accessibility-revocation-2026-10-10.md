# Accessibility revocation and input-tap teardown

The owner reported that removing the running helper from Accessibility left
keyboard and mouse input unresponsive until the helper was killed over SSH.
This is an existing-account incident report, not a controlled reproduction.

Local metadata on 2026-10-10 from 10:06 to 10:16 UTC contained repeated
`tapDisabledByTimeout` events for the Screen Sharing filter, with responsive
main-queue heartbeats between them. The Windows filter reported shutdown once.
The process had already been stopped before investigation, so no stalled-stack
sample or live WindowServer state was captured. No raw logs or dictated text
are included here.

Code inspection found that Screen Sharing marked its monitor unhealthy and
reported an error, but left its event tap/run-loop source installed and its
baseline sampler running. The tap callback itself did not retire the native
connection. A repeated disabled event could therefore keep notifying the UI
without ever invalidating that connection. The old log claim that input was
passing through was not proof of native disconnection.

The fix makes native retirement immediate and one-shot, before logging or UI
notification. It disables/invalidates the port, cancels pending decisions,
discards suppressed-key pairing and stops the worker. Setup that finishes after
stop is immediately torn down. The worker never re-enables an existing tap.
Trust polling runs separately from the input and UI threads and provides a
second shutdown path. Both client monitors and pending replay are cancelled;
the UI retains an error until verified setup creates fresh filters. Clipboard
ownership and restoration rules are unchanged.

**External proof:** Apple documents disabled-tap notifications and Mach-port
invalidation, including invalidation of its run-loop source; see the architecture
references. There is no documented immediate AX trust-change notification used
here, so a cached trust result is not relied on as the sole shutdown path.

**Local proof:** a disposable real Mach port/source is invalidated on a worker
while the main actor is held, before the simulated UI callback. Both
disabled-event types are tested, each followed by
1,000 repeated signals and keyboard/mouse events. Tests exercise trust loss
during admission, rejection of late acceptance and late resource installation,
and stopped Screen Sharing sampling. These tests do not post input or modify
Accessibility. The full regression suite passes, including Windows cancellation
and key-release checks.

**Remaining integration check:** actual grant removal/toggle with the installed
candidate, continued physical input, status reporting, regrant and ordinary
dictation. Perform only as a coordinated local test with recovery access. This
change addresses the demonstrated teardown defect; the automated checks alone
do not establish every macOS revocation behavior.

The signed local candidate **1.1.3 / build 113.1.1** was installed after normal
Quit, using the saved local certificate. The replaced public ad-hoc copy was
backed up privately. On launch it observed no Accessibility access, created no
input filters and logged the paused/error state. It did not request access in
the background.

The owner then removed the stale Accessibility entry and granted access to the
installed candidate. Settings showed `Allowed`, and physical keyboard/mouse
input remained responsive. At 10:34:19 UTC both client filters were installed
successfully. This confirms recovery from an initially untrusted installation;
it does not yet test revoking access while the candidate's filters are active.

## First physical revocation test failed

The owner removed the permission with **113.1.1** running and SSH recovery
available. Keyboard/mouse input froze again. At 11:38:16 UTC the Windows tap
reported timeout retirement, followed by the application's cleanup of both
monitors. A main-queue heartbeat at 11:38:20 UTC still completed without delay.
The process was no longer running when the report was inspected; no frozen
process sample or native tap inventory was captured. The user-visible failure
invalidates any inference that those successful teardown calls alone restore
system input. No additional permission removal was performed automatically.
The owner subsequently clarified the order: terminate the helper over SSH,
recover physical input, then report the failure. The absent process was the
result of manual recovery, not evidence of automatic protection.

A separate developer reported the same system-wide symptom with a minimal
pass-through tap in [Apple's developer forum](https://developer.apple.com/forums/thread/844416).
Apple DTS asked for a system diagnostic; the thread does not establish the exact
cause on this Mac or supply a verified workaround.

The next candidate adds proactive suspension before the helper opens System
Settings and on external System Settings activation. Startup and reconfiguration
cannot create taps while guarded. Leaving checks trust before resuming; ordinary
local/remote focus changes retain the established paste path. Background status
polling cannot rearm during pane launch. Native diagnostics now distinguish port
invalidation from worker completion instead of claiming physical input delivery.

Automated checks cover those transitions without changing TCC or posting input.
The next native check is deliberately non-destructive: enumerate the helper's
taps before and during System Settings and require zero while paused. Actual
revocation remains unverified for this follow-up. Revocation without entering
System Settings is outside the pre-entry safeguard.

## Non-destructive native check of 113.1.2

The signed **1.1.3 / build 113.1.2** candidate was installed with the same local
designated signing requirement. The complete regression suite and privacy scan
passed. Access was available, and `CGGetEventTapList` initially reported exactly
two enabled taps owned by the helper. Activating System Settings removed both;
the query reported zero owned taps, and worker logs reported invalid ports and
sources followed by loop completion.

Three further local-application/System Settings round trips each reported
**two → zero** owned taps, with no accumulation. The first local foreground
snapshot was a different local app than requested, so it is counted only as a
non-Settings foreground check. No permission changes or keystrokes were made by
the diagnostic. These results establish proactive removal in the actual native
tap table. They do not yet establish successful permission revocation or
post-regrant dictation on this candidate.

## Owner's revocation trial of 113.1.2

The owner subsequently tried multiple permission-removal scenarios and reported
that physical input remained responsive. This is local evidence for proactive
tap removal, limited to the reported scenarios. Two UI defects remained: deleting
the entire permission row left Settings showing Allowed, and its button did not
request a new row. Native tap creation also failed while the earlier AX check
still reported trust. This is not evidence of a signature change.

The next candidate replaces the cached AX query with a bounded asynchronous HID
check. A deleted row and a disabled row have separate navigation paths; the
explicit request uses Apple's HID access API. Expired or invalidated results
fail closed. Tests exercise stalled IPC with an injected checker, not the user's
privacy settings. See the architecture readiness gate for external evidence and
the remaining signed-installation test.

The signed **1.1.3 / build 113.1.3** candidate was installed after normal Quit,
with the same designated signing requirement. The full regression suite and
privacy scan passed. Its first live HID check reported granted; native inventory
showed exactly two taps. Opening System Settings removed both and the inventory
reported zero. The deleted-entry status/request/regrant trial remains pending.

## Live HID query trial failed: 113.1.3

The owner then removed the row. Input stayed usable, but Settings showed
`Preparing input`: HID checks continued returning granted while native tap
creation failed. The Settings timer incorrectly retried creation every second.
After the owner restarted the helper and used its request dialog to grant access,
HID checks instead remained denied and Settings remained `Not granted`. This
invalidates the claim that the HID preflight is a live authority on this Mac.
The retained request API was also the HID/PostEvent API, not an AX trust request.

The next candidate uses a fresh process of the same signed executable to check
AX trust and a separate explicit mode to request it. Each check is bounded and
reaped, with no child UI initialization or clipboard access. Only state changes
or an explicit Settings visit may retry setup; UI status polling is read-only.
Tests cover subprocess failure/reaping, fresh state transitions, invalidation,
navigation and the absence of repeated native setup on unchanged permission.
The installed app's identity attribution and full revoke/regrant cycle require
physical validation; another app's or a command-line tool's result is not proof.

The signed **113.1.4** candidate then checked the permission from its own child
process. It reported granted, created both native taps and remained responsive,
with no new permission change requested from the owner. This repairs the
reported inability to recognize the already regranted access. It does not yet
establish a full revoke/regrant cycle without restarting the parent. The next
build adds an independent one-second child exit deadline so a parent quit cannot
leave a blocked permission checker indefinitely alive. Tests cover this deadline
separately from parent-enforced timeout and reaping.

The final local **113.1.5** build passed the complete tests and privacy scan and
was installed with the same certificate. It read the existing grant and created
two native taps; opening System Settings removed both. Native inventory confirmed
zero while that pane was foreground. No additional permission grant was needed
for this installation.

## Owner's no-restart permission cycle accepted: 113.1.5

The owner removed the helper's Accessibility row, requested it again from the
helper's Settings and regranted access without restarting the helper. They
reported that the cycle worked and ordinary input remained responsive. The
same parent process recorded denied at 12:21:12 UTC and granted at 12:21:22 UTC,
while System Settings was still foreground. Monitoring remained paused there;
after leaving System Settings, exactly two fresh taps were created. Subsequent
main-queue heartbeats remained responsive.

The remaining UI defect was `Input unavailable` during that intentional pause.
Build **113.1.6** separates permission presentation from input readiness: granted
access always displays green `Allowed ✓`, including while System Settings is
foreground. The existing one-second status refresh remains; there is no need to
close the permission pane to update the label. Initial setup completion still
requires actual input readiness. This presentation change does not modify tap
lifetimes or the accepted paste and clipboard protocols.

The 113.1.6 UI change compiled and passed the privacy scan. It was installed after
normal Quit with the same designated signing requirement. The new process read
the existing grant and created both taps without requesting permission again.
The full regression suite had passed on the preceding 113.1.5 runtime; this
follow-up changes only the label/color and records that physical trial. The
revoke/regrant cycle was not repeated during installation.
