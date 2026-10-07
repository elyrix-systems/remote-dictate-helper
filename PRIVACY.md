# Privacy

Remote Dictate Helper runs locally and has no network service, account,
telemetry or analytics. It does not open dictation history or databases and does
not start a donor application.

While Apple Screen Sharing is active and the helper is idle, it retains at most
eight clipboard snapshots / 64 MiB in RAM to identify the pre-dictation original.
A transfer keeps its captured payload/original until completion. Samples are
cleared on target changes, capture or stop; payloads never go to files or logs.

Input monitoring reads event type, key code, modifiers and source PID/bundle ID
so a selected app's paste can be distinguished from manual input. No typed text
is recorded. The paste filter can remove a selected source's V down/up
in Screen Sharing or Windows App; local dictation, manual shortcuts and other apps pass through.

In Apple Screen Sharing, the helper changes the local pasteboard temporarily, uses Screen Sharing's Send
Clipboard, then restores the original with exact revision checks. The receiving
Mac is the user's existing screen-sharing connection, not a new network service.
A newer copy prevents restoration. The helper never modifies a dictation app's
ordinary local paste or its data.

In Windows App, the helper reads only the clipboard revision counter and repairs
native paste input. It does not read clipboard payloads, write the clipboard or
change RDP preferences. The dictation app and the existing RDP connection manage
clipboard contents and restoration. Physical modifier changes advance an input
cancellation counter; their individual events are not logged.

Only the helper's settings and operational metadata are persisted:

- `~/Library/Application Support/RemoteDictateHelper/settings.json`
- `~/Library/Logs/RemoteDictateHelper/menu-bar.log`

Logs contain phase labels, counts, revisions, durations, booleans and errors;
not clipboard text, hashes, format names or screenshots. Settings list selected
app identifiers and preferences. Accessibility is used for monitoring/filtering,
native input and Screen Sharing menu access. No System Events automation is used.
