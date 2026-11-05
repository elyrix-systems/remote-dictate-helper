# Screen Sharing post-paste retention experiment — 2026-11-05

Status: local investigation branch, not an accepted production fix or release.

The owner reported stale remote text over a slow connection after extended use
of Screen Sharing, including a failed paste that inserted a message from the
previous day. A fresh local copy and physical remote paste worked. The owner
confirmed the failed operation around 10:02 local time, before the following
dictation reporting the problem. Unlike an earlier uncertain timestamp, this
operation was captured by the helper.

Local metadata distinguished a 486-byte UTF-8 source payload from a 166-byte
returned original. The helper posted one paste, restored the original after
about 200 ms and sent that original through Screen Sharing. Native client logs
recorded the two Send Clipboard actions about 210 ms apart. The remote field's
contents and actual consumption time are not recorded. The owner had already
copied something else, so the inserted text could not be compared with the
preserved original afterward.

The older text could therefore be either the previous remote buffer or the
original sent back during cleanup. Its age alone is not evidence of a queue of
old transcripts. A new source revision does not establish textual freshness.

## Readiness gate and single-variable trial

Risky assumption: restoring after 200 ms can replace the remote payload before
the receiving app consumes a posted paste. A slow link is supporting context,
not proof of that ordering. Successful AX menu activation is not a remote
clipboard or paste acknowledgement. The current code has no such receipt.

Local proof: a named-board test uses the production restoration class and a
synthetic remote consumer at 500 ms. A 200 ms retention returns the original
before consumption; two seconds keeps the current payload available. The
remote delivery in this model is assumed, not exercised. Existing tests still
check exact original formats, zero-item originals, one restoration, newer-copy
protection and the five-second fallback for incomplete input.

Production evidence: the captured operation and two local send times above,
plus the owner's stale-result report. No causal fix has been established.

The initial candidate changes only the successful post-paste retention allowance from
200 ms to two seconds. It does not add a delay before Paste, an extra paste,
Backspace, client activation, a source-specific path or a Windows clipboard
write. Newer local copies retain ownership and are never overwritten. The
helper can remain busy longer, so wait for Done between diagnostic attempts.
Metadata diagnostics are enabled in the local candidate; clipboard text logging
remains disabled. Preserve the installed Developer ID identity for the update.

## Physical procedure (local Mac and remote disposable field required)

Keep the same Screen Sharing connection. The ordinary-copy gate has passed.
Use distinct short phrases and preserve a known original local marker. Dictate
three times without another manual copy, waiting for Done between attempts.
Record whether each current phrase appears once and whether the original marker
is restored locally. Do not send the test text as a message.

If a stale paste recurs with this longer hold, the pre-paste delivery path still
needs a separate controlled test; do not blindly extend the same delay. Capture
the source operation, remote result and available client/remote timing before
resetting the connection. A successful short trial does not establish stability
after an hour or solve every failure. Roll back the local candidate if it adds
regressions. Raw logs remain private and are not included in this document.

## 200.1.1 trial: third dictation stopped before replay

The owner reported two successful short phrases, one missing third phrase, and
a successful repeat of that third phrase. The local original marker remained
correct. The failed attempt was captured, but it never reached Send Clipboard
or native replay, so the two-second post-paste hold had not started.

Detailed metadata and native logs established this sequence:

- The source paste was accepted and its key-up observed.
- Screen Sharing published a delayed remote clipboard promise about 140 ms later.
- Reading that intermediate return exhausted the 250 ms isolated-reader limit.
  The helper aborted the entire operation about 419 ms after capture.
- Flow published the original approximately 60 ms after the abort; the remote
  promise itself completed later. The repeated dictation then succeeded.

The missing phrase is thus a premature source-return read failure, distinct
from the earlier stale-text symptom. This short trial does not establish that
the longer post-paste hold fixes stale remote text.

## 200.1.2: bounded recovery while waiting for source return

Risky assumption: an unreadable or changing intermediate clipboard can be
followed by the actual source return while the accepted paste remains valid.
The native sequence above is production evidence for that order. Local tests
use real delayed named-board providers and a subsequent original revision;
they recover without posting input or touching the general clipboard.

The candidate permits at most four read attempts for an accepted operation,
with at most 250 ms per attempt and a 50 ms pause only if the failed revision
is unchanged. All attempts share the original five-second release deadline.
The deadline is checked before accepting a matching result as well as before
each read, so a late successful provider cannot authorize delayed replay.
Input, focus, stopped-monitor and task-cancellation guards remain active.
An unknown readable return or oversized data still fails immediately; the
original is never guessed. No clipboard write or key retry is added.

Regression checks cover delayed same-revision data, a replacement return,
revision changes between read and validation, permanently blocked providers,
input/focus cancellation, deadline expiry and unrelated new copies.
Two-second post-paste retention remains in this investigation build, keeping
the next physical comparison focused on source-return recovery. Physical
acceptance of 200.1.2 is pending.
