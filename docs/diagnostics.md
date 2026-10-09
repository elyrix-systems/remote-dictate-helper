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
- Windows clipboard preparation records `clipboard-read-start` and
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
accepted record. AX queries run outside the input tap and main actor. Diagnostics add
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

## Windows paste stages

Normal builds read the current local text representation through the isolated
reader, check modifiers, refresh Windows App focus and send one native paste.
Diagnostics do not enable or change that protocol. `focus-refresh-start`,
`focus-refresh-owned`, `focus-refresh-returned` and `focus-refresh-ready` identify
progress; `focus-refresh-failed` includes the failed phase and window state.
The transparent window has `windowAlpha=0`; `windowVisible` means ordered, not
visible pixels. The one-second activation deadline is a failure bound, not a wait.
Clipboard revision and input guards remain active while the helper owns focus.
A source restoring its clipboard early cancels the operation instead of causing
a repeat or a clipboard rewrite. `remoteReceipt=unverified` still applies.

The [experiment archive](experiments/windows-clipboard-2026-10-09.md) preserves
the retired diagnostic commands, build flags, trial procedures and outcomes.
They are not available in current builds. For provider isolation and evidence
limits see [architecture](architecture.md#clipboard-provider-isolation).
