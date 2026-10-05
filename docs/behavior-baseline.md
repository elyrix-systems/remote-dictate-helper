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
