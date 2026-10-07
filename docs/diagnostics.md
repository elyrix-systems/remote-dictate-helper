# Local diagnostic builds

Detailed logging is an explicit build opt-in (`REMOTE_DICTATE_DIAGNOSTICS=1`),
independent of the Swift optimization level. A release-optimized diagnostic build
keeps the normal paste protocol, deadlines, source policies and signing identity.
It displays **Diagnostic logging enabled** in the menu. Ordinary builds omit the
bundle flag and do not start the context observer or write the debug log.

The log is `~/Library/Logs/RemoteDictateHelper/debug.log`, with three numbered
archives. Each file rotates at approximately 2 MiB (at most one record over the
limit); total retention is approximately 8 MiB. New files are mode 0600, with
mode 0700 for a newly created parent. The existing operational log is unchanged.
No log is uploaded automatically or included in a bundle/package.

## Reading a failure

Every record has UTC wall time, monotonic uptime and a launch-session identifier.
Accepted pastes also have an operation UUID. Follow that UUID from capture through
source release, replay or cancellation. The restoration session is linked to the
operation separately. `operational` lines include clipboard menu and cleanup
progress; the app accepts only one transfer at a time.

- `input_event` / `input_sequence_changed`: a new key-down or mouse-down invalidated
  the captured destination. The first event/last observed sequence is described;
  a click can cancel without any change of foreground app.
- `foreground_target_changed`: expected and observed process IDs differ. The
  context observer records foreground transitions as PID and bundle identifier.
- `window_changed`: expected and actual AX window references differ, even when
  the foreground app is unchanged. AX errors retain attribute and numeric code.
- `clipboard_return_timeout`: V-up was seen, but the required clipboard return
  did not occur. A once-per-second wait record includes both revisions and policy.
- `source_v_up_timeout`: the intercepted source never supplied its paired release.
- `returned_clipboard_unmatched`: the returned revision did not match a saved
  original. Candidate revisions and returned format identifiers are recorded.
- Windows App additionally records native paste stages and distinct revision,
  physical modifier, foreground and input-sequence cancellation reasons.
- The local Windows clipboard-read candidate records `clipboard-read-start` and
  `clipboard-read-ready`, the captured revision, chosen format, byte count and
  read duration. Failure stops before the native sequence. These records establish
  only local data availability, not that RDP received the current clipboard.

The observer logs workspace activation, sleep/wake, session activity and observed
screen lock/unlock notifications. While a supported remote client is foreground,
and for ten seconds afterwards, it samples clipboard revision/format identifiers
and modifier flags at 250 ms. It does not read clipboard payloads. A serial worker
samples focused AX window/element references and element role at most once per
second, with 50 ms per-call timeouts and one outstanding probe. Only changed
states are logged. AX references are opaque, session-local comparison aids, not
remote window titles or proof of a remote text caret.

No transcript, clipboard bytes, ordinary typed characters/scan codes, window
titles, document paths, URLs, connection host names or screenshots are recorded.
Bundle identifiers still describe app usage: keep diagnostic logs local unless
the owner explicitly chooses to share them.

## Timing and evidence limits

Risk: diagnostic I/O or AX work could perturb the timing under investigation.
Disk writes use a separate serial queue with 512 outstanding records at most;
overflow never blocks input and is reported as `droppedSinceLast` on the next
accepted record. AX queries run outside the input tap and main actor. There are
no extra key events, clipboard writes, focus changes, retries or longer deadlines.
Polling and metadata preparation still have a small cost; this is not a claim of
zero measurement overhead. The observer cannot identify the clipboard writer,
prove RDP/Screen Sharing receipt, or see the remote text caret.

Proof classification: local component tests verify cause-specific diagnostics,
unchanged cancellation/key-release behavior, transcript exclusion, disabled logs,
rotation, private files and symlink refusal. They use named boards and mocked
input. Live observation on the signed local build verifies startup and log
activity separately; dictation, remote receipt and reproduction of intermittent
failures still require the owner's normal local usage. No public release is
created by enabling diagnostics.

## Windows clipboard-read experiment

The current local candidate adds a bounded, read-only preparation step to the
Windows adapter, independently of the diagnostic flag. This is a protocol change
under evaluation, not an effect of enabling logging. It does not change the Apple
Screen Sharing transaction. It neither republishes the clipboard nor inserts
locally, activates another app, retries a paste or retains/logs text.

Risky assumption: requesting the source's text representation before replay may
materialize data that Windows App otherwise obtains too late. Apple's
[pasteboard data-provider contract](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider)
is external evidence for deferred data. A separate-process local spike using only
a disposable named board verified materialization with an unchanged revision;
component tests cover refusal, cancellation, timing bounds and unchanged formats.
None of this proves that a remote Windows clipboard is ready. Physical repeated
dictation and post-sleep trials are still required; this experiment has not been
published as a release.
