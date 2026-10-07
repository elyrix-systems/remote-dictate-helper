import AppKit

enum ExplicitPasteShortcutError: Error, CustomStringConvertible {
    case permissionNeeded, targetChanged, eventCreationFailed
    case modifiersHeld(session: CGEventFlags, hardware: CGEventFlags)

    var description: String {
        switch self {
        case .permissionNeeded: "Accessibility is not enabled for Remote Dictate Helper."
        case .targetChanged: "The remote window lost focus; paste shortcut stopped."
        case let .modifiersHeld(session, hardware):
            "Input modifier state is busy; paste not sent. Session: \(Self.describe(session)); HID: \(Self.describe(hardware))."
        case .eventCreationFailed: "Could not create paste shortcut events."
        }
    }

    private static func describe(_ flags: CGEventFlags) -> String {
        let names: [(String, CGEventFlags)] = [
            ("Command", .maskCommand), ("Shift", .maskShift), ("Control", .maskControl),
            ("Option", .maskAlternate), ("Fn", .maskSecondaryFn)
        ]
        let held = names.filter { flags.contains($0.1) }.map { $0.0 }.joined(separator: "+")
        return "\(held.isEmpty ? "none" : held) (0x\(String(flags.rawValue, radix: 16)))"
    }
}

/// Never reads the clipboard or injects dictated text; sends only Command+V.
final class ExplicitPasteShortcut {
    private static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]
    let usesIsolatedSource: Bool
    private let interceptedPaste: Bool
    private let isTrusted: () -> Bool
    private let targetIsFrontmost: (pid_t) -> Bool
    private let flags: () -> CGEventFlags
    private let hardwareFlags: () -> CGEventFlags
    private let sessionCommandKeyDown: () -> Bool
    private let post: (CGEvent) -> Void
    private let report: (String) -> Void
    private var reportedHIDCompatibility = false

    init(
        isolatedSoftwareCommand: Bool = false,
        interceptedPaste: Bool = false,
        isTrusted: @escaping () -> Bool = { AccessibilityPermission.isTrusted() },
        targetIsFrontmost: @escaping (pid_t) -> Bool = { pid in
            let app = NSWorkspace.shared.frontmostApplication
            return pid > 0 && app?.processIdentifier == pid && app?.bundleIdentifier == "com.apple.ScreenSharing"
        },
        flags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
        hardwareFlags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
        sessionCommandKeyDown: @escaping () -> Bool = {
            CGEventSource.keyState(.combinedSessionState, key: 55)
                || CGEventSource.keyState(.combinedSessionState, key: 54)
        },
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        report: @escaping (String) -> Void = { _ in }
    ) {
        self.usesIsolatedSource = isolatedSoftwareCommand
        self.interceptedPaste = interceptedPaste
        self.isTrusted = isTrusted
        self.targetIsFrontmost = targetIsFrontmost
        self.flags = flags
        self.hardwareFlags = hardwareFlags
        self.sessionCommandKeyDown = sessionCommandKeyDown
        self.post = post
        self.report = report
    }

    func checkTargetReadiness(targetPID: pid_t) throws {
        guard isTrusted() else { throw ExplicitPasteShortcutError.permissionNeeded }
        guard targetIsFrontmost(targetPID) else { throw ExplicitPasteShortcutError.targetChanged }
    }

    func checkReadiness(targetPID: pid_t) throws {
        try checkTargetReadiness(targetPID: targetPID)
        let session = flags()
        let hardware = hardwareFlags()
        let clear = session.union(hardware).intersection(Self.modifiers).isEmpty
        let isolatedCommand = usesIsolatedSource && Self.permitsIsolatedSoftwareCommand(session: session, hardware: hardware)
        // A captured source's synthetic paste can leave Command in the HID
        // source table while the session table is clear. That table is not a
        // direct physical-key measurement. Only an already-intercepted paste
        // may use this additional private-source case, and only without any
        // device Command bits, other modifiers, or a session Command key down.
        let interceptedHIDCommand = usesIsolatedSource && interceptedPaste
            && session.intersection(Self.modifiers).isEmpty
            && hardware.intersection(Self.modifiers) == .maskCommand
            && (session.rawValue | hardware.rawValue) & 0x18 == 0
            && !sessionCommandKeyDown()
        guard clear || isolatedCommand || interceptedHIDCommand else {
            throw ExplicitPasteShortcutError.modifiersHeld(session: session, hardware: hardware)
        }
        if interceptedHIDCommand && !reportedHIDCompatibility {
            reportedHIDCompatibility = true
            report("private input for intercepted HID Command residue; session keys clear")
        }
    }

    /// Narrow compatibility case observed locally: software Command only,
    /// without left/right Command device bits and with all HID modifiers clear.
    /// Other software modifiers and any physical modifier still block input.
    static func permitsIsolatedSoftwareCommand(session: CGEventFlags, hardware: CGEventFlags) -> Bool {
        hardware.intersection(modifiers).isEmpty
            && session.intersection(modifiers) == .maskCommand
            && session.rawValue & 0x18 == 0 // NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
    }

    /// Wait for an observed clear state before any clipboard/menu mutation.
    /// No key-up injection, no fixed "Flow completed" delay, no retry of input.
    /// Focus/window, trust and cancellation remain checked during the wait.
    @MainActor
    func waitUntilReady(
        targetPID: pid_t,
        validateTarget: () throws -> Void = {},
        onWaiting: (String) -> Void = { _ in },
        timeoutSeconds: TimeInterval = 5,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async throws -> TimeInterval {
        let started = now()
        var lastReportedState: String?
        while true {
            try Task.checkCancellation()
            try validateTarget()
            do {
                try checkReadiness(targetPID: targetPID)
                return max(0, now() - started)
            } catch let error as ExplicitPasteShortcutError {
                guard case .modifiersHeld = error else { throw error }
                if error.description != lastReportedState {
                    onWaiting(error.description)
                    lastReportedState = error.description
                }
                let remaining = timeoutSeconds - (now() - started)
                guard remaining > 0 else { throw error }
                try await pause(min(0.02, remaining))
            }
        }
    }

    func send(targetPID: pid_t) throws {
        try checkReadiness(targetPID: targetPID)
        guard let source = CGEventSource(stateID: usesIsolatedSource ? .privateState : .combinedSessionState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw ExplicitPasteShortcutError.eventCreationFailed
        }
        // The constructor includes the left-Command device flag as well as
        // maskCommand. Preserve both: replacing them with maskCommand alone
        // loses which physical modifier changed for remote-control clients.
        vDown.flags = commandDown.flags
        vUp.flags = commandDown.flags

        guard targetIsFrontmost(targetPID) else { throw ExplicitPasteShortcutError.targetChanged }
        post(commandDown)
        // Always release our Command, including when focus changes mid-sequence.
        defer { post(commandUp) }
        guard targetIsFrontmost(targetPID) else { throw ExplicitPasteShortcutError.targetChanged }
        post(vDown)
        post(vUp)
    }
}
