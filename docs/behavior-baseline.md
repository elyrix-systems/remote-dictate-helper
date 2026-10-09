# Accepted behavior and evidence

The maintained paste protocol was tested on the user's local Mac with Apple
Screen Sharing on 2026-10-04 and 2026-10-05. Recovery copies of those builds are
kept outside this repository. This record concerns behavior, not acceptance of
every later installer, signature or operating-system configuration.

Physical trials with Wispr Flow, superwhisper and Valis confirmed interception,
one remote insertion without a leading `v` or deleted character, and preservation
of the original local clipboard. Superwhisper's left Option push-to-talk also
passed in a remote Codex text field. Physical/device modifier guards remain in
place; the app handles only the specifically observed HID Command residue.

The user accepted this toggle-recording scenario on 2026-10-05:

1. Start recording with a double-tap of Fn while the remote field has focus.
2. Switch to other local windows while continuing to dictate.
3. Return to Screen Sharing, click the remote field and tap Fn to stop.
4. Wait for automatic insertion without a manual paste.

For two completed operations, local metadata showed source V-up after 17–21 ms,
clipboard release after 513–519 ms, one replay, original clipboard restoration
and shared clipboard re-enabled. The user's report established remote receipt;
local logs cannot establish receipt or the physical focus sequence independently.
An earlier timeout did not recur, but its root cause remains unconfirmed.

No clipboard contents are included here. These trials do not establish universal
compatibility across keyboards, dictation apps, remote fields or rich-text formats.
Use the [test plan](test-plan.md) for changes and broader integration checks.

## Installed preview: 0.8.0

On 2026-10-05, the GitHub-built ad-hoc preview **0.8.0 / build 1** was installed
on an Apple silicon Mac running **macOS 26.6.2**, replacing 0.7.1. The previous
bundle and settings were backed up locally; the saved source selection remained
unchanged after installation and relaunch.

The user confirmed these physical checks:

| Check | Result |
| --- | --- |
| Ordinary local copy and manual remote paste | The marker arrived exactly once. |
| Flow toggle recording, switching away and returning before stopping | One remote insertion; prefix intact; no leading `v`; original local clipboard marker restored. |
| Superwhisper left Option push-to-talk into remote Codex | One remote insertion; prefix intact; no leading `v`; original local clipboard marker restored. |
| Valis with its configured recording shortcut | One remote insertion; prefix intact; no leading `v`; original local clipboard marker restored. |

The Flow trial's local metadata independently recorded interception, a single
paste without Backspace and successful clipboard restoration. Remote receipt
and the named source-app scenarios are established by the user's report.
After an ordinary Quit and relaunch, a new helper process installed the active
paste filter without an Accessibility error. Setup completion and saved settings
were retained.

This validates the installed preview and the reported scenarios on this Mac.
It does not establish a clean browser-download/Gatekeeper experience on a new
account, creation of the new local signing certificate, Developer ID signing or
Apple notarization. Those distribution checks remain separate. No real dictated
text, clipboard payloads or machine-specific paths are included in this record.

## Stable release: 1.0.0

On 2026-10-05, after publication of the GitHub-built stable release, the owner
reported reinstalling the app, granting Accessibility again, and successful,
stable operation on the local Mac. This is user-reported acceptance of the
reinstall and permission flow on that existing Mac account. It does not establish
a clean-account installation or Developer ID signing/notarization.

## Local release candidate: 1.0.1

On 2026-10-05, the locally built ad-hoc 1.0.1 candidate replaced the installed
1.0.0. The owner renewed Accessibility and confirmed the following physical
checks in Apple Screen Sharing:

- Ordinary local copy and manual remote paste arrived exactly once.
- Two consecutive Flow dictations inserted once each without a leading `v`.
- The original local clipboard marker was preserved after the transfers.

The source changes remove retired paths and diagnostic polling while retaining
the accepted paste protocol. Automated regression, privacy and bundle checks
also passed. These trials validate the local candidate; they do not independently
retest superwhisper, Valis or a browser-downloaded GitHub package.

## Local launch-at-login integration

On 2026-10-06, an unreleased local ad-hoc build was installed on the same Apple
silicon Mac. Its first main-app login registration returned `.enabled`; Settings
showed **On ✓**, and the system **Open at Login** list contained Remote Dictate
Helper once. Registration required no administrator password. Accessibility was
renewed after the update and the active paste filter started.

The one-time registration preference was saved. Automated tests cover first
registration, a never-seen service, approval/failure handling, retained opt-out
across launches/updates and exclusion of uninstalled copies. No logout or reboot
was performed to test the new login item, and no physical system opt-out/update
trial was performed. These remain separate from the observed registration.

## Unreleased Settings autosave check

On 2026-10-06, the locally installed candidate was checked with a disposable app
entry. Adding it through the native picker wrote the settings file before the
window closed. Removing it also persisted immediately, restoring the original
settings exactly. Closing the window did not change the saved selection. The
compact window was visually checked with no Save/Cancel footer or clipped text.
Failure/busy rollback and retention of source clipboard policies passed automated
tests. The paste protocol was unchanged; this UI check is not a new remote-paste
or clean-account permission test.

## Local Accessibility navigation and signed update

On 2026-10-06, the unreleased candidate was installed with an existing local
code-signing certificate, replacing an ad-hoc copy. The old Accessibility entry
was renewed once for that deliberate identity transition. The helper showed
**Allowed ✓** and installed its active paste filter. The owner confirmed that
the native **Accessibility Access** alert disappeared after **Open System
Settings**. The helper now uses only the alert's navigation when untrusted.

A second build changed the executable while keeping the same bundle identifier
and certificate. The code hashes differed; the designated requirements matched,
and both builds passed verification against the other's requirement. After a
normal Quit, replacement and launch, the new process immediately installed its
active paste filter without another permission grant. This establishes local
update continuity on this Mac. It does not validate Developer ID distribution,
certificate creation, ad-hoc update continuity or a clean-account download.

## Release acceptance: 1.0.3

On 2026-10-06, the owner reported that the installed candidate worked correctly
and authorized merging and releasing it. This follows the Settings autosave,
native alert dismissal and certificate-signed update checks above. The candidate
still displayed 1.0.2; the 1.0.3 release preparation changes the version metadata
and release notes without changing its runtime code. This acceptance concerns
the local candidate, not a browser-downloaded ad-hoc DMG on a clean account.

## Windows App acceptance: 1.1.0 integration

On 2026-10-07, the owner tested Wispr Flow on the local Apple-silicon Mac running
macOS 26.6.2, connected through Microsoft Windows App 11.4.3. Ordinary physical
Command+V and Control+V worked. Flow's synthetic paste produced only `v`; a
physical paste then inserted the current transcript.

A bounded metadata-only observation distinguished the sequences: Flow emitted
V-down/up with generic Command flags, while the physical sequence included
left-Command flagsChanged events and device/non-coalesced flags. A one-paste
trial replaced the source events with a complete private native sequence, spaced
25 ms apart. The owner confirmed successful remote text insertion. A second
paste in that first trial passed through because it was intentionally single-use.

The subsequent repeated trial kept the same sender, added modifier-release
waiting with revision/context guards, and never wrote clipboard contents. The
owner reported successful insertion, then confirmed that operation was working
correctly in both Windows App and Apple Screen Sharing and authorized tests, PR
and release. A transient report of remote unresponsiveness was followed by
confirmation that the transcript had arrived; its cause was not established.

This is local integration evidence for Flow and this Windows App setup. The
owner's overall acceptance did not separately enumerate all clipboard-format,
warning, server or source-app cases. Remote receipt is established by the owner,
not by local key logs. Production regression tests protect the native sequence,
repeated admission, context/revision cancellation, physical modifiers and key
release during shutdown. The release removes temporary logging and time limits;
no diagnostic logs or real transcript contents are committed.

## Windows App: all default dictation sources

Later on 2026-10-07, with 1.1.0 installed, the owner separately tested Valis and
superwhisper and confirmed that both successfully inserted dictated text through
Windows App. Together with the earlier Flow trial, this establishes user-reported
remote insertion for all three default sources in this local Windows App setup.
They use the same selected-source handler; no vendor-specific change was needed.
This follow-up did not separately report clipboard restoration, recording modes
or additional remote endpoints.

## Local clipboard-isolation candidate: 110.7.3

On 2026-10-07, the owner tested Wispr Flow with the signed diagnostic candidate
**1.1.0 / build 110.7.3** in both Apple Screen Sharing and Windows App. The owner
confirmed both insertions completed and neither app hung. The local update kept
the existing signing requirement and both input filters started without a new
Accessibility grant.

Local metadata recorded a 28 ms Screen Sharing capture decision, source clipboard
release, one replay, local restoration and shared-clipboard re-enablement. The
Windows path read its text representation in 19 ms and completed one native paste
sequence in 104 ms. Remote insertion and absence of visible hangs are established
by the owner's report; the log does not establish remote receipt independently.
The owner did not separately verify every original clipboard format in this trial.

The complete regression suite, eight repeated isolation checks and a named-board
check using the signed app executable passed. Tests include a separate provider
blocked for 60 seconds, bounded timeout/cancellation, main-actor progress, reader
reaping, fresh reads after failure and refusal of a late capture. All artificial
provider failures used disposable named boards, never the general clipboard.

This is a local candidate, not a new GitHub release. A first dictation after sleep
and prolonged normal use remain to be observed. These checks do not establish a
fix for intermittent stale RDP contents or exclude independent source-app stalls.

## Local input-filter liveness candidate: 111.1.1

On 2026-10-09, another report of transient Flow/superwhisper hangs led to an
input-filter audit. The owner reported that the apps had already recovered;
read-only process samples did not capture the original hang. Source inspection
found an application lookup on the event-tap thread and a decision lock held
across admission checks. Either could bypass the intended capture deadline.

The candidate moves source lookup off the tap, bounds outstanding lookups across
both filters and restarts, and removes caller code from the decision lock. Both
adapters refuse an expired capture before committing or scheduling input. The
full regression suite, including injected blocked lookup/admission checks and
all source contracts, passed. These tests post no real input.

The signed **1.1.1 / build 111.1.1** candidate was installed after normal Quit.
Its signing requirement matched the previous copy; both active filters started
without renewed Accessibility permission. Physical dictation and prolonged use
remain to be checked. This establishes the deadline correction, not the cause of
an earlier source-app hang or a fix for stale remote Windows clipboard contents.

## Local Windows clipboard timing probe: 111.1.2

On 2026-10-09, the signed diagnostic build **1.1.1 / build 111.1.2** was installed
and launched with the previous signing requirement. Both existing paste filters
started without another Accessibility grant. Automatic dictation behavior is
unchanged. The new diagnostic-only command must be invoked explicitly.

The complete regression suite passed, including the probe's two synthetic data
lifetimes, exact full-format/empty restoration, one native sequence, newer-copy
protection, context/input cancellation and balanced keys during shutdown. These
checks used named pasteboards and mocked input.

Later that day, two explicitly started probes ran in a new remote Notepad
document. Each visually inserted its unique NEW marker exactly once. The first
held NEW for five seconds; the second restored OLD after 686 ms (650 ms requested).
V-down was posted 61 ms and 55 ms after NEW publication, respectively. Both logs
recorded original local clipboard restoration. Remote receipt was established
from the displayed document, not from the helper's key-event log.

Neither trial used a dictation app. Each also involved returning focus from the
test dialog to Windows App, which may refresh the client's clipboard state.
These two successful trials do not reproduce or exclude intermittent stale
remote contents, delayed rendering, or a problem during repeated dictation with
uninterrupted Windows App focus. No production timing change or stale-paste fix
is justified by these results alone.

## Stale Windows paste reproduced after the timing probe

Later on 2026-10-09, three actual Flow dictations ran while Windows App remained
the foreground Mac app. The third inserted the first transcript into remote
Codex instead of the newly captured text. The second transcript was visible in
remote Notepad, so this was not a controlled same-field repetition.

For the failed operation, the helper read the new local text in 23 ms and
completed one balanced native paste sequence in 113 ms. No context cancellation,
retry or clipboard write by the Windows adapter occurred. Flow restored the
original local clipboard roughly 550 ms after interception. The macOS log
recorded Windows App requesting text for both earlier dictations and both
synthetic probes, but contained no matching request for the failed dictation.
Absence of that log entry does not independently prove that no read occurred.

Post-report process samples did not capture a persistent hang. A later remote
clipboard read showed the restored original, which cannot establish its contents
at the failed paste instant. Additional remote desktop connections were present
inside the Windows session; their influence is unproven. Raw logs and transcript
contents remain in ignored local audit storage.

This reproduces stale remote insertion despite a fresh local capture. It does
not yet distinguish Windows App/RDP publication from cached data in the receiving
app. The next discriminating check should keep the remote field fixed and record
the remote clipboard sequence, owner and foreground process without reading data
until a failure, since a diagnostic read can itself trigger delayed rendering.
The two successful synthetic probes are not evidence that this bug is fixed.

## Same-field Windows failure with a passive remote observer

Later on 2026-10-09, five consecutive numbered Flow dictations into one remote
Codex field all inserted an older transcript. Local capture contained each new
phrase and each operation posted one balanced native paste in 105–115 ms.
A passive Windows observer recorded no clipboard notification or sequence change
during those five attempts; the owner remained the RDP clipboard process.
The receiving Codex process stayed foreground. No persistent Mac-side hang was
captured in the subsequent process samples.

An ordinary local copy and physical paste then inserted the new marker without
restarting Windows App. This produced a remote clipboard notification and a
Windows App native text-read log entry, neither of which appeared during the
five failed attempts. The next Flow dictation again inserted that manual marker.
Thus ordinary redirection remained usable while transient dictation data was
missed. This narrows the fault but does not establish the client's internal
publication timing or justify a production timeout.

The remote observer never read or wrote clipboard payloads. Its Ctrl+V polling
counter also missed the successful manual paste, so that counter cannot establish
native paste receipt. Sequence counters alone are not acknowledgements of text
delivery, especially with RDP delayed rendering. Raw local and remote diagnostic
files remain private. The next controlled experiment compares repeated short,
long and delayed-paste publications without changing focus between trials.

## Repeated synthetic Windows publications: 111.1.3

On 2026-10-09, the diagnostic comparison in signed build **111.1.3** published
six distinct numbered markers with Windows App continuously focused. The remote
field was Codex, verified visually. The first marker arrived, followed by five
copies of that same first marker. No dictation app participated in this test.

The sequence compared a 650 ms publication, a five-second publication and a
five-second publication with a one-second delay before paste, then repeated
those three profiles. All six local revisions differed; each native sequence
completed once without cancellation. Neither longer lifetime nor the added
pre-paste delay corrected the stale result. The native macOS log recorded one
Windows App text request, corresponding to the first paste. The helper recorded
restoration of the original local clipboard after the experiment.

This reproduces the fault independently of Flow and its restoration timing.
It does not prove that every possible delay fails or identify the client's
internal cause. The remote passive observer was not running for this series;
absence of a native log entry alone cannot prove absence of an internal read.
The first successful paste followed returning from the helper dialog. Earlier
manual controls also included a focus switch to copy locally, so a physical
paste while the same target remains focused is a separate outstanding control.

That physical control was then run in the same remote Codex field. After the
second automatic paste, the owner pressed physical Command+V without copying or
switching windows. The observed physical Command interval fell within trial
two's five-second NEW lifetime. The screen contained three copies of trial
one's marker: the two automatic pastes and the physical paste. The local revision
stayed on NEW2 until scheduled restoration. The extra input stopped the remaining
automatic trials, and the original clipboard was restored.

This failure therefore also affects physical paste while the local publication
changes without a focus transition. It is not limited to Flow or to the helper's
synthetic shortcut. The individual physical V event was not logged; the control
is supported by the user's action, physical modifier interval, input counter and
visible result together. A real leave/return focus transition with the same
held NEW value remains to be compared before selecting a workaround.

The following manual focus control inserted NEW2 successfully. The owner left
Windows App for a local window and returned while the same NEW2 revision was
still present, then pressed physical Command+V before scheduled restoration.
The remote field showed the first marker twice, followed by the correct second
marker. No intervening copy, new publication or client restart was needed.
The helper then cancelled the rest of the series and restored the original.

Together these controls establish a focus-dependent refresh workaround in the
tested session. They do not establish the safety or speed of automatic activation
during an actual dictation. The bounded native log collector had ended before
this later test; its empty output is not evidence of absent client reads. Source
warnings, transient source restoration and the previously sampled native
clipboard waits must be considered before applying a focus change automatically.
