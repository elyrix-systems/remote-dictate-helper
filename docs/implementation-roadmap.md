# Project scope

The current product is a source-built local macOS menu bar app for clipboard
paste interception in Apple Screen Sharing. The maintained behavior is documented
in [architecture.md](architecture.md) and [test-plan.md](test-plan.md).

Keep future work small and independently testable:

- New dictation apps require physical evidence for their source events and
  clipboard lifecycle before they are listed as compatible.
- Other remote desktop clients require a separate target adapter and validation;
  they must not inherit an Apple Screen Sharing compatibility claim.
- Source installation and Apple silicon DMG packaging are maintained in
  [distribution.md](distribution.md). Current downloads are
  unnotarized; Developer ID distribution requires an Apple Developer account.

Do not bring back transcript databases, donor apps, recording-hotkey detection,
Backspace cleanup or menu-based experiments. Preserve release tags and keep
archived development history separate from this repository.
