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
- `clipboard.read_begin` / `read_ready` / `read_failed`: baseline, candidate or
  source-return stage, revision and context. A provider timeout abandons the read;
  it cannot schedule late input. Payload reads run only in an owned child process.
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

With the ordinary diagnostic flag, no transcript, clipboard bytes, ordinary typed characters/scan codes, window
titles, document paths, URLs, connection host names or screenshots are recorded.
Bundle identifiers still describe app usage: keep diagnostic logs local unless
the owner explicitly chooses to share them.

## Optional local transcript capture

Only enable this after the owner explicitly requests recording dictated text.
`REMOTE_DICTATE_DIAGNOSTIC_TEXT=1` additionally requires
`REMOTE_DICTATE_DIAGNOSTICS=1`. Both flags are off in ordinary builds; metadata
diagnostics alone never retain text. The menu explicitly shows **Diagnostic text
logging enabled** when both are enabled. This is a build setting, not a change
to the normal installation or release configuration.

For each accepted operation with a valid captured revision, `local-text-captured`
records the local source text, operation UUID, client, revision and format. The
`payload` suffix is JSON: Russian, line breaks, quotes and control characters
round-trip without creating extra log lines. The text is limited to 64 KiB of
UTF-8 per operation, ending on a scalar boundary; `truncated` explicitly marks a
longer result. Invalid UTF-8 or a rich-only Windows representation is recorded as
unavailable, without attempting to decode RTF/HTML or changing paste eligibility.
Reads that fail or lose their context before acceptance have metadata only.

This uses bytes already read by the isolated reader for Windows, or the already
captured Screen Sharing text. There are no additional provider reads, clipboard
writes or polls for contents. Original clipboard snapshots and ordinary manual
copies are not recorded. At most eight text records may be queued; overflow is
dropped, never allowed to block input. JSON encoding and file I/O use the existing
writer queue. Text goes only to the private rotating debug log, never the
operational log. Opening that log also enforces mode 0600 on an existing file.

**This is not the text observed in the remote field.** `remoteReceipt=unverified`
is intentional: local AX exposes the Windows App container, not the remote
Codex input, and the Mac pasteboard is not an independent view of the Windows
clipboard. Follow the operation UUID to see whether input was sent or cancelled;
a captured text record can precede cancellation. Actual receipt requires the
owner's observation or a separately arranged observer on Windows. Do not publish
these logs in an issue or PR: they now contain dictated content.

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

## Opt-in Windows focus refresh for real dictation

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

## Local provider-isolation candidate

The next candidate isolates payload reads for both clients. Baseline and returned
clipboard reads are asynchronous with a 250 ms failure deadline; candidate capture
uses up to 60 ms within the existing 80 ms decision deadline. These are upper
bounds, not fixed waits. Exact prepared snapshots and revision guards replace
synchronous provider calls during replay and restoration. See the
[architecture](architecture.md#clipboard-provider-isolation) for proof and limits.

A physical Windows trial of the preceding materialization-only candidate still
inserted old remote text despite a fast successful local read. That experiment
does not establish a fix for stale RDP clipboard data. Isolation addresses helper
responsiveness first; no remote acknowledgement or automatic paste retry is added.
