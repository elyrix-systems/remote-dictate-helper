# Security

Remote Dictate Helper is a macOS utility distributed as source and downloadable DMGs. Grant
Accessibility intentionally after reviewing the source and release provenance. It uses pasteboard APIs and native
input/menu access. There is no database access, donor process, System Events
service, network listener or transcript upload.

Treat these as security defects:

- Reading/writing dictation history or changing a dictation app's private data.
- Uploading clipboard contents, logs, screenshots or settings.
- Intercepting manual input, unselected apps or ordinary local dictation.
- Sending input without validating the captured remote-client target and window.
- Replaying a cancelled paste at a later caret or retrying partial input.
- Overwriting a newer clipboard copy during restoration.
- Silently force-stopping applications or broadening permissions.

The source PID/bundle filter distinguishes cooperating local apps; it is not an
OS-authenticated provenance guarantee against malicious event forgery. A selected
app must use the configured clipboard-paste protocol. Unrecognized protocols
must fail visibly rather than broadening interception to arbitrary shortcuts.

The app uses the product bundle identifier `systems.elyrix.RemoteDictateHelper`.
An upgrade from a different identity requires fresh Accessibility approval.
Installers preserve replaced helper bundles and refuse running helpers; they never stop Flow,
superwhisper, Screen Sharing or Windows App. Report vulnerabilities privately to the repository
owner (@pradaev) and omit real dictated text or clipboard contents from reports.
Use GitHub’s private vulnerability reporting when enabled (Security → Report a
vulnerability). If it is unavailable, open an issue asking for a private contact
channel without including vulnerability details. Do not post sensitive data in
a public issue. Security fixes target the current source version; archived
development snapshots are not maintained releases.


Current preview downloads use ad-hoc signing and are not Apple notarized.
Developer ID signing keys must exist only in the protected `release` environment,
never in repository files, PR workflows or build artifacts. Untrusted PRs require
approval, use ephemeral GitHub-hosted runners and receive no signing credentials.
No policy can guarantee that malicious code will never be proposed; human review
of executable build and workflow changes remains necessary.
