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
