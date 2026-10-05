import AppKit
import Foundation
import RemoteDictateCore

// Compile with the menu-bar input controllers and RemoteDictateCore.
// No real history, clipboard writes, keystrokes, or permission requests.
final class InputTests {
    @MainActor func testNativeInput() async throws {
        var posted: [(Int64, CGEventFlags)] = []
        let record: (CGEvent) -> Void = { posted.append(($0.getIntegerValueField(.keyboardEventKeycode), $0.flags)) }
        func expectFailure(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected shortcut to refuse input") } catch {}
        }
        expectFailure { _ = try ScreenSharingClipboardMenu(target: NSRunningApplication.current, transcript: "fixture", writeTranscript: { _ in fatalError("Unexpected write") }) }
        let syntheticModifier = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { .maskCommand }, hardwareFlags: { [] }, post: record
        )
        do {
            try syntheticModifier.send(targetPID: 123)
            fatalError("Session modifier must still prevent input when HID is clear")
        } catch let error as ExplicitPasteShortcutError {
            precondition(error.description.contains("Session: Command (0x100000)"))
            precondition(error.description.contains("HID: none (0x0)"))
            precondition(posted.isEmpty)
        }
        for (trusted, focused, held): (Bool, Bool, CGEventFlags) in [
            (false, true, []), (true, false, []), (true, true, .maskCommand), (true, true, .maskSecondaryFn)
        ] {
            let shortcut = ExplicitPasteShortcut(isTrusted: { trusted }, targetIsFrontmost: { _ in focused }, flags: { held }, hardwareFlags: { [] }, post: record)
            expectFailure { try shortcut.send(targetPID: 123) }
            precondition(posted.isEmpty, "Rejected shortcuts must not post any keys")
        }
        let interrupted = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in posted.isEmpty }, flags: { [] }, hardwareFlags: { [] }, post: record
        )
        expectFailure { try interrupted.send(targetPID: 123) }
        precondition(posted.map { $0.0 } == [55, 55], "Focus loss must release Command without typing v")
        precondition(posted.last?.1.contains(.maskCommand) == false, "Command must not remain held")
        posted.removeAll()
        let complete = ExplicitPasteShortcut(isTrusted: { true }, targetIsFrontmost: { _ in true }, flags: { [] }, hardwareFlags: { [] }, post: record)
        try complete.send(targetPID: 123)
        precondition(posted.map { $0.0 } == [55, 9, 9, 55])
        precondition(posted.dropLast().allSatisfy { $0.1.contains(.maskCommand) })
        // NX_DEVICELCMDKEYMASK from the SDK's IOLLEvent.h. General maskCommand
        // alone is insufficient to represent the physical modifier change.
        let leftCommand = CGEventFlags(rawValue: 0x00000008)
        precondition(posted.dropLast().allSatisfy { $0.1.contains(leftCommand) })
        precondition(posted.last?.1.contains(.maskCommand) == false)
        precondition(posted.last?.1.contains(leftCommand) == false)
        posted.removeAll()
        var sourceIDs: [Int64] = []
        let isolated = ExplicitPasteShortcut(
            isolatedSoftwareCommand: true,
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { CGEventFlags(rawValue: 0x20100000) }, hardwareFlags: { [] },
            post: { event in record(event); sourceIDs.append(event.getIntegerValueField(.eventSourceStateID)) }
        )
        try isolated.send(targetPID: 123)
        precondition(posted.map { $0.0 } == [55, 9, 9, 55])
        precondition(posted.dropLast().allSatisfy { $0.1.contains(.maskCommand) && $0.1.contains(leftCommand) })
        precondition(posted.last?.1.contains(.maskCommand) == false)
        precondition(sourceIDs.count == 4 && Set(sourceIDs).count == 1 && sourceIDs[0] > 1, "All isolated events must use one private state table")
        posted.removeAll()
        let blockedStates: [(CGEventFlags, CGEventFlags)] = [
            (.maskCommand, .maskCommand), (.maskCommand, .maskSecondaryFn),
            ([.maskCommand, .maskAlternate], []), (.maskShift, []),
            (CGEventFlags(rawValue: 0x20100008), []), (CGEventFlags(rawValue: 0x20100010), [])
        ]
        for (session, hardware) in blockedStates {
            let refused = ExplicitPasteShortcut(
                isolatedSoftwareCommand: true, isTrusted: { true }, targetIsFrontmost: { _ in true },
                flags: { session }, hardwareFlags: { hardware }, post: record
            )
            expectFailure { try refused.send(targetPID: 123) }
            precondition(posted.isEmpty, "Compatibility must not bypass physical or other session modifiers")
        }
        let isolatedFocusLoss = ExplicitPasteShortcut(
            isolatedSoftwareCommand: true, isTrusted: { true }, targetIsFrontmost: { _ in posted.isEmpty },
            flags: { .maskCommand }, hardwareFlags: { [] }, post: record
        )
        expectFailure { try isolatedFocusLoss.send(targetPID: 123) }
        precondition(posted.map { $0.0 } == [55, 55] && posted.last?.1.contains(.maskCommand) == false)
        try await testInterceptedHIDCommand()
        try await testReadinessWait()
        testGuardedPaste()
        print("native safety tests passed: rejected invalid targets; paste sequence and release on focus loss verified with a mock event sink (no keys posted)")
    }

    @MainActor private func testInterceptedHIDCommand() async throws {
        // Replay the observed superwhisper failure without touching real input.
        var events: [CGEvent] = []
        var messages: [String] = []
        let shortcut = ExplicitPasteShortcut(isolatedSoftwareCommand: true, interceptedPaste: true,
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { CGEventFlags(rawValue: 0x100) },
            hardwareFlags: { CGEventFlags(rawValue: 0x20100000) },
            sessionCommandKeyDown: { false }, post: { events.append($0) }, report: { messages.append($0) })
        let waited = try await shortcut.waitUntilReady(targetPID: 123, now: { 0 }, pause: { _ in
            fatalError("Observed HID residue should not consume a timeout")
        })
        precondition(waited == 0 && events.isEmpty)
        try shortcut.send(targetPID: 123)
        precondition(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [55, 9, 9, 55],
                     "Exactly one paste, no preliminary key release or Backspace")
        let sources = events.map { $0.getIntegerValueField(.eventSourceStateID) }
        precondition(Set(sources).count == 1 && sources[0] > 1, "Residue handling must use a private source")
        precondition(events.dropLast().allSatisfy { $0.flags.contains(.maskCommand) && $0.flags.rawValue & 8 != 0 })
        precondition(!events.last!.flags.contains(.maskCommand))
        precondition(messages.count == 1)

        // Each ambiguous/physical state must remain refused even with opt-in.
        let blocked: [(CGEventFlags, CGEventFlags, Bool)] = [
            (.maskCommand, .maskCommand, false),
            (.maskShift, .maskCommand, false),
            ([], [.maskCommand, .maskShift], false),
            ([], [.maskCommand, .maskAlternate], false),
            ([], [.maskCommand, .maskControl], false),
            ([], [.maskCommand, .maskSecondaryFn], false),
            ([], CGEventFlags(rawValue: 0x20100008), false),
            ([], CGEventFlags(rawValue: 0x20100010), false),
            (CGEventFlags(rawValue: 0x8), .maskCommand, false),
            (CGEventFlags(rawValue: 0x10), .maskCommand, false),
            ([], .maskCommand, true)
        ]
        for (session, hid, keyDown) in blocked {
            let refused = ExplicitPasteShortcut(isolatedSoftwareCommand: true, interceptedPaste: true,
                isTrusted: { true }, targetIsFrontmost: { _ in true }, flags: { session }, hardwareFlags: { hid },
                sessionCommandKeyDown: { keyDown }, post: { _ in fatalError("Held/ambiguous state posted input") })
            do { try refused.send(targetPID: 123); fatalError("Held/ambiguous state accepted") }
            catch ExplicitPasteShortcutError.modifiersHeld {}
        }
        for (isolated, intercepted) in [(false, false), (false, true), (true, false)] {
            let refused = ExplicitPasteShortcut(isolatedSoftwareCommand: isolated, interceptedPaste: intercepted,
                isTrusted: { true }, targetIsFrontmost: { _ in true }, flags: { [] }, hardwareFlags: { .maskCommand },
                sessionCommandKeyDown: { false }, post: { _ in fatalError("Unqualified residue posted input") })
            do { try refused.send(targetPID: 123); fatalError("Unqualified residue accepted") }
            catch ExplicitPasteShortcutError.modifiersHeld {}
        }
        // A real Command press after a successful preflight must still block
        // the immediate recheck inside send; readiness is not a lasting grant.
        var down = false
        let changed = ExplicitPasteShortcut(isolatedSoftwareCommand: true, interceptedPaste: true,
            isTrusted: { true }, targetIsFrontmost: { _ in true }, flags: { [] }, hardwareFlags: { .maskCommand },
            sessionCommandKeyDown: { down }, post: { _ in fatalError("Changed key state posted input") })
        try changed.checkReadiness(targetPID: 123)
        down = true
        do { try changed.send(targetPID: 123); fatalError("New Command press accepted") }
        catch ExplicitPasteShortcutError.modifiersHeld {}
        print("intercepted HID residue passed: one private paste, no extra release/deletion; held/ambiguous/unqualified states rejected")
    }

    private func testGuardedPaste() {
        for failure in ["none", "first-check", "second-check", "permission", "focus-after-command"] {
            var keys: [Int64] = []
            var validations = 0
            let shortcut = ExplicitPasteShortcut(isolatedSoftwareCommand: true,
                isTrusted: { failure != "permission" },
                targetIsFrontmost: { _ in failure != "focus-after-command" || keys.isEmpty },
                flags: { [] }, hardwareFlags: { [] },
                post: { keys.append($0.getIntegerValueField(.keyboardEventKeycode)) })
            let result = GuardedPaste().run(targetPID: 123, shortcut: shortcut, validateBeforeInput: {
                validations += 1
                if failure == "first-check" || (failure == "second-check" && validations == 2) {
                    throw CancellationError()
                }
            })
            expectEqual(result.didRun, failure == "none")
            if failure == "none" { expectEqual(keys, [55, 9, 9, 55]); expectEqual(validations, 2) }
            else if failure == "focus-after-command" { expectEqual(keys, [55, 55], "Release our Command; never retry") }
            else { expectTrue(keys.isEmpty) }
            expectFalse(keys.contains(51), "No deletion in any outcome")
        }
    }

    @MainActor private func testReadinessWait() async throws {
        var clock: TimeInterval = 0
        var pauses = 0
        var messages: [String] = []
        let refusePost: (CGEvent) -> Void = { _ in fatalError("Readiness must never post an event") }
        let noModifiers = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { [] }, hardwareFlags: { [] }, post: refusePost
        )
        let immediate = try await noModifiers.waitUntilReady(targetPID: 123, now: { clock }, pause: { _ in
            fatalError("Clear modifiers must proceed without any fixed delay")
        })
        precondition(immediate == 0)

        // The transfer selects private input before the wait. The
        // observed software-only Command no longer burns the five-second
        // timeout, but physical modifiers and other software states still gate.
        let immediatePrivate = ExplicitPasteShortcut(
            isolatedSoftwareCommand: true, isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { CGEventFlags(rawValue: 0x20100000) }, hardwareFlags: { CGEventFlags(rawValue: 0x100) }, post: refusePost
        )
        let privateWait = try await immediatePrivate.waitUntilReady(targetPID: 123, now: { clock }, pause: { _ in
            fatalError("Accepted private-source state must proceed without waiting for a timeout")
        })
        precondition(privateWait == 0)
        let privateWithPhysicalFn = ExplicitPasteShortcut(
            isolatedSoftwareCommand: true, isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { .maskCommand }, hardwareFlags: { clock < 0.02 ? .maskSecondaryFn : [] }, post: refusePost
        )
        let privateFnWait = try await privateWithPhysicalFn.waitUntilReady(targetPID: 123, now: { clock }, pause: { clock += $0 })
        precondition(privateFnWait == 0.02, "Private source must still wait for physical Fn release")
        let blockedPrivateStates: [(CGEventFlags, CGEventFlags)] = [
            (.maskCommand, .maskCommand),
            ([.maskCommand, .maskShift], []),
            (CGEventFlags(rawValue: 0x100008), [])
        ]
        for (session, hardware) in blockedPrivateStates {
            clock = 0
            let blockedPrivate = ExplicitPasteShortcut(
                isolatedSoftwareCommand: true, isTrusted: { true }, targetIsFrontmost: { _ in true },
                flags: { session }, hardwareFlags: { hardware }, post: refusePost
            )
            do {
                _ = try await blockedPrivate.waitUntilReady(targetPID: 123, timeoutSeconds: 0.04, now: { clock }, pause: { clock += $0 })
                fatalError("Private source must not bypass held or ambiguous modifiers")
            } catch ExplicitPasteShortcutError.modifiersHeld {}
            precondition(clock == 0.04)
        }
        clock = 0

        // Replay the observed distinction: session Command with HID clear.
        let syntheticCommand = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { clock < 0.04 ? .maskCommand : [] }, hardwareFlags: { [] }, post: refusePost
        )
        let waited = try await syntheticCommand.waitUntilReady(
            targetPID: 123, onWaiting: { messages.append($0) }, now: { clock },
            pause: { seconds in clock += seconds; pauses += 1 }
        )
        precondition(waited == 0.04 && pauses == 2 && messages.count == 1)
        precondition(messages[0].contains("Session: Command") && messages[0].contains("HID: none"))

        clock = 0
        let physicalFn = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { [] }, hardwareFlags: { clock < 0.02 ? .maskSecondaryFn : [] }, post: refusePost
        )
        let fnWaited = try await physicalFn.waitUntilReady(targetPID: 123, now: { clock }, pause: { clock += $0 })
        precondition(fnWaited == 0.02, "Hardware Fn must be respected even when session Fn is clear")

        clock = 0
        let alwaysBusy = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in true },
            flags: { .maskCommand }, hardwareFlags: { [] }, post: refusePost
        )
        do {
            _ = try await alwaysBusy.waitUntilReady(targetPID: 123, timeoutSeconds: 0.04, now: { clock }, pause: { clock += $0 })
            fatalError("Persistent modifiers must time out")
        } catch ExplicitPasteShortcutError.modifiersHeld {}
        precondition(clock == 0.04)

        clock = 0
        let losesFocus = ExplicitPasteShortcut(
            isTrusted: { true }, targetIsFrontmost: { _ in clock == 0 },
            flags: { .maskCommand }, hardwareFlags: { [] }, post: refusePost
        )
        do {
            _ = try await losesFocus.waitUntilReady(targetPID: 123, now: { clock }, pause: { clock += $0 })
            fatalError("Changed foreground app must stop the wait")
        } catch ExplicitPasteShortcutError.targetChanged {}
        precondition(clock == 0.02)

        clock = 0
        do {
            _ = try await alwaysBusy.waitUntilReady(
                targetPID: 123,
                validateTarget: { if clock > 0 { throw ScreenSharingClipboardMenuError.targetChanged } },
                now: { clock }, pause: { clock += $0 }
            )
            fatalError("Changed Screen Sharing connection must stop the wait")
        } catch ScreenSharingClipboardMenuError.targetChanged {}
        precondition(clock == 0.02)

        clock = 0
        let losesTrust = ExplicitPasteShortcut(
            isTrusted: { clock == 0 }, targetIsFrontmost: { _ in true },
            flags: { .maskCommand }, hardwareFlags: { [] }, post: refusePost
        )
        do {
            _ = try await losesTrust.waitUntilReady(targetPID: 123, now: { clock }, pause: { clock += $0 })
            fatalError("Revoked trust must stop the wait")
        } catch ExplicitPasteShortcutError.permissionNeeded {}
        precondition(clock == 0.02)

        do {
            _ = try await alwaysBusy.waitUntilReady(targetPID: 123, pause: { _ in throw CancellationError() })
            fatalError("Cancellation during a wait must propagate")
        } catch is CancellationError {}
        let cancelled = Task { @MainActor in try await noModifiers.waitUntilReady(targetPID: 123) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled task must not proceed even if modifiers are clear")
        } catch is CancellationError {}
        print("modifier readiness tests passed: transient session Command, physical Fn, no fixed delay, timeout, focus/window/trust changes and cancellation; no real input")
    }
}
