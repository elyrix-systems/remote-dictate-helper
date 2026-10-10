# Local input liveness investigation — 2026-10-09

The owner reported that, after prolonged usage, clipboard-using dictation apps
could stall even when dictating locally. They sometimes recovered after quitting
the helper. The source/helper had already been restarted before investigation.
This report establishes a correlation, not a captured deadlock or memory leak.

The installed public 1.1.2 had detailed diagnostics disabled. Its operational log
contained completed Windows transfers; the existing debug log belonged to an
earlier diagnostic build. Read-only samples of the restarted helper, source native
process and pasteboard service showed ordinary idle waits, two helper tap threads
and no outstanding reader. They cannot explain the earlier stall. No clipboard
payload or raw process report is included in this document.

## Code findings and candidate

- The Screen Sharing filter dispatched one main-actor task for almost every
  global key/click, even during local work. Its cancellation sequence counter
  already recorded those events synchronously, making the queued copies redundant.
- Both taps resolved synthetic Command+V source identities and requested main
  admission before their adapters rejected local destinations. The source lookup
  and event wait were bounded, but expired main-queue admission callbacks could
  still accumulate if that queue stopped draining.
- Screen Sharing's 20 ms baseline timer continued querying the foreground app
  while local apps were active, even though it did not read their payloads.

The candidate removes ordinary-event callbacks, keeps synchronous cancellation
counters and accepted V-up pairing, and bounds queued admission across both
adapters/restarts. A workspace-driven RAM gate rejects off-target candidates
before lookup. Baseline sampling stops outside Screen Sharing and starts anew on
return. Actual target/window/revision checks remain authoritative; a stale gate
cannot itself permit capture or replay. No clipboard transfer/restoration, native
paste sequence, Backspace or dictation-source policy is introduced or changed.

A diagnostic-only heartbeat runs independently of the main queue, with one
outstanding ping and bounded log rates. It distinguishes a delayed helper main
queue from a responsive helper during a separately observed source-app stall.
It does not sample another app, read text or determine the cause by itself.

## Evidence and remaining checks

**External:** Apple's workspace activation notification contract.

**Local component:** 60,000 ordinary events produce zero observer callbacks while
preserving key/click sequence cancellation; 1,000 off-target synthetic pastes do
no identity lookup; accepted source release survives focus loss. Simulating a
blocked main queue with 20,000 expired admissions retains one callback, then
accepts fresh work after recovery. Scope lifecycle and baseline timer suspension
use fake notifications and a disposable named clipboard. The heartbeat also
retains one ping under 20,000 checks and reports delay/recovery without main-queue
progress. The complete source-contract, clipboard and native-input suites pass.

**Local usage:** on 2026-10-10, after a further period using the installed
112.1.2 candidate, the owner reported stable, predictable operation and no
recurring hangs, then authorized release 1.1.3. The report did not quantify the
duration or separately enumerate sleep, every source/client and every recording
mode. These changes remove demonstrated unbounded dispatch paths; this acceptance
does not prove which path caused the original stall or establish a fix for all
source-app hangs or stale RDP clipboard data.

## Local candidate installation

The diagnostic candidate **1.1.2 / build 112.1.2** was installed and launched on
the owner's Mac using the saved local signing certificate. The previous public
ad-hoc bundle was retained privately. The owner renewed Accessibility and
confirmed **Allowed ✓**; the log recorded both input filters starting and
responsive main-queue heartbeats. Transcript logging is disabled.

The first candidate's launch exposed an inherited Swift actor-isolation trap in
the new dispatch timer. Its handler is now explicitly Sendable, and a regression
check runs the actual timer/main-queue round trip in addition to the simulated
stall tests. The corrected installed process remains running. This startup check
does not establish physical paste correctness or prolonged source-app liveness.
