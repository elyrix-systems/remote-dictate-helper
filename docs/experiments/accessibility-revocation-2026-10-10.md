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
