# Screen Sharing baseline recovery — 2026-11-02

The owner reported intermittent single `v`/`м` characters instead of a Flow
transcript in Apple Screen Sharing with release 1.1.5 / build 32. An ordinary
fresh local copy and physical remote paste succeeded once. The owner matched
the latest failed dictation to the operational log's `originalUnknown` refusal.

The preceding successful operation restored the local clipboard and re-enabled
sharing. Screen Sharing later advertised remote promised formats. The helper's
isolated baseline reader requested HTML and timed out. Its failed revision was
excluded from all later sampling, even if that provider subsequently became
readable. About twelve minutes later, the next source paste was refused because
no original snapshot had been observed. The original source key was allowed
through; a single character is consistent with the known remote shortcut issue.
These observations identify this refusal path, not every possible single-letter
failure or the reason the remote provider was slow.

Separate source-release timeouts were also present: the helper intercepted the
paste, but the source did not change clipboard ownership within five seconds.
Those events did not replay. They are distinct from the baseline refusal and are
not addressed by this change.

## Candidate and readiness gate

The risky assumption is that a transient delayed-provider failure can recover
under the same ownership revision. Local evidence comes from a disposable named
pasteboard with a separate delayed provider: the first bounded reader times out,
the provider finishes later, and another bounded reader captures the same
revision successfully. It does not rely on a fabricated remote acknowledgement.

The candidate permits three idle retries after 0.5, 2 and 5 seconds, each using
the unchanged isolated-reader deadline. It stops after four failures, suspends
outside Screen Sharing, and resets for a new revision or foreground scope.
Deterministic size refusal is not retried. A read must still produce every
original format before capture. Unknown originals are never guessed, late
captures are never replayed, and no Backspace is sent.

Automated checks cover actual delayed-provider recovery and the finite budget,
context/new-revision gates, and a subsequent capture preserving the original.
The accepted paste, restoration and Windows protocols remain unchanged.
Operational logs now distinguish retry scheduling, exhausted budgets, recovery
and a passed-through paste with no baseline, without storing clipboard contents.

Physical acceptance of this candidate is pending. Requires the local Mac,
Accessibility, Flow, Apple Screen Sharing and a remote disposable field. After
the normal-copy gate, perform consecutive dictations with an original local
marker and verify one insertion without a leading character, plus restoration
of the marker. Repeat after sharing has returned remote clipboard formats and
after leaving/returning to the client. Never introduce an artificial hung
provider on the general clipboard. Raw logs remain in ignored local audit
storage and are not published.
