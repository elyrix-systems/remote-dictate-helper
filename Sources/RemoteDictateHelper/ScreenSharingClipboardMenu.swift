import AppKit
import RemoteDictateCore

enum ScreenSharingClipboardMenuError: Error, CustomStringConvertible {
    case targetChanged, emptyClipboard, clipboardChanged, menuUnavailable
    case accessibility(operation: String, code: Int32)
    case restoredSendUnavailable
    case commandDisabled(String)

    var description: String {
        switch self {
        case .targetChanged: "Screen Sharing connection changed; operation stopped."
        case .emptyClipboard: "The captured clipboard has no text."
        case .clipboardChanged: "Local clipboard changed during transfer; no paste shortcut sent."
        case .menuUnavailable: "Screen Sharing clipboard menu is not exposed through Accessibility."
        case .restoredSendUnavailable: "Send Clipboard is unavailable for the restored local snapshot."
        case let .commandDisabled(command): "Screen Sharing command is disabled: \(command)."
        case let .accessibility(operation, code): "Screen Sharing Accessibility \(operation) failed (\(code))."
        }
    }
}

/// Uses existing Accessibility access, scoped to one Screen Sharing window.
/// No activation, System Events, donor or Wispr history access. An explicit
/// transcript is written only after automatic clipboard sharing is off.
final class ScreenSharingClipboardMenu: ExplicitClipboardTransferDriver {
    private let pid: pid_t
    private let application: AXUIElement
    private let window: AXUIElement
    private let clipboardText: String
    private let initialClipboardChangeCount: Int
    private let writeTranscript: (String) throws -> Void
    private let validateTranscript: () throws -> Void
    private var preparedTranscript = false
    private var preparedRevision: Int?
    private let pasteboard = NSPasteboard.general
    private let input: ExplicitPasteShortcut
    private let trace: (String) -> Void
    private var lastSharedCommandEnabled: Bool?

    init(
        target: NSRunningApplication,
        transcript: String,
        expectedWindow: AXUIElement? = nil,
        input: ExplicitPasteShortcut = ExplicitPasteShortcut(),
        writeTranscript: @escaping (String) throws -> Void,
        validateTranscript: @escaping () throws -> Void,
        trace: @escaping (String) -> Void = { _ in }
    ) throws {
        guard target.bundleIdentifier == "com.apple.ScreenSharing", target.processIdentifier > 0 else {
            throw ScreenSharingClipboardMenuError.targetChanged
        }
        try input.checkReadiness(targetPID: target.processIdentifier)
        self.input = input
        self.trace = trace
        pid = target.processIdentifier
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.75)
        window = try Self.elementAttribute(application, kAXFocusedWindowAttribute)
        if let expectedWindow, !CFEqual(window, expectedWindow) {
            DiagnosticLog.shared.record("screen-sharing.window_changed stage=driver-init pid=\(pid) expectedRef=\(CFHash(expectedWindow)) actualRef=\(CFHash(window)) front=\(DiagnosticLog.front)")
            throw ScreenSharingClipboardMenuError.targetChanged
        }
        let count = NSPasteboard.general.changeCount
        let text = transcript
        guard !text.isEmpty else {
            throw ScreenSharingClipboardMenuError.emptyClipboard
        }
        guard count == NSPasteboard.general.changeCount else {
            throw ScreenSharingClipboardMenuError.clipboardChanged
        }
        clipboardText = text
        initialClipboardChangeCount = count
        self.writeTranscript = writeTranscript
        self.validateTranscript = validateTranscript
        // Resolve both commands before allowing any preference mutation.
        _ = try menuItems()
    }

    /// Capture the connection before waiting for modifier state to clear.
    /// Only reads AX; clipboard contents and modifier readiness are not needed.
    static func captureWindow(target: NSRunningApplication) throws -> AXUIElement {
        guard target.bundleIdentifier == "com.apple.ScreenSharing", target.processIdentifier > 0 else {
            throw ScreenSharingClipboardMenuError.targetChanged
        }
        try ExplicitPasteShortcut().checkTargetReadiness(targetPID: target.processIdentifier)
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.75)
        return try elementAttribute(application, kAXFocusedWindowAttribute)
    }

    static func validateWindow(target: NSRunningApplication, expected: AXUIElement) throws {
        let actual = try captureWindow(target: target)
        guard CFEqual(expected, actual) else {
            DiagnosticLog.shared.record("screen-sharing.window_changed stage=validate pid=\(target.processIdentifier) expectedRef=\(CFHash(expected)) actualRef=\(CFHash(actual)) front=\(DiagnosticLog.front)")
            throw ScreenSharingClipboardMenuError.targetChanged
        }
    }

    func validateTargetAndClipboard() throws {
        try validateConnection()
        try input.checkReadiness(targetPID: pid)
        let count = pasteboard.changeCount
        if !preparedTranscript {
            guard count == initialClipboardChangeCount else {
                throw ScreenSharingClipboardMenuError.clipboardChanged
            }
            return
        }
        guard count == (preparedRevision ?? initialClipboardChangeCount),
              pasteboard.changeCount == count else {
            throw ScreenSharingClipboardMenuError.clipboardChanged
        }
        try validateTranscript()
    }

    func prepareClipboard() throws {
        try validateTargetAndClipboard()
        let state = try readState()
        guard !state.sharedClipboardEnabled else {
            throw SharedClipboardSettingError.unconfirmed(expected: false, observed: state)
        }
        trace("prepare before revision=\(pasteboard.changeCount)")
        preparedTranscript = true
        try writeTranscript(clipboardText)
        preparedRevision = pasteboard.changeCount
        try validateTargetAndClipboard()
        trace("prepare after revision=\(pasteboard.changeCount)")
    }

    func readState() throws -> SharedClipboardMenuState {
        let items = try menuItems()
        // Completion needs command availability as well as the checkmark.
        // A missing attribute must not block the transfer transition itself.
        let sharedEnabled = (try? Self.attribute(items.shared, kAXEnabledAttribute)) as? NSNumber
        lastSharedCommandEnabled = sharedEnabled?.boolValue
        var mark: CFTypeRef?
        AXUIElementSetMessagingTimeout(items.shared, 0.75)
        let result = AXUIElementCopyAttributeValue(items.shared, kAXMenuItemMarkCharAttribute as CFString, &mark)
        let checked: Bool
        if result == .noValue {
            checked = false
        } else if result == .success, let mark = mark as? String {
            checked = !mark.isEmpty
        } else {
            throw ScreenSharingClipboardMenuError.accessibility(operation: "read checkmark", code: result.rawValue)
        }
        guard let enabled = try Self.attribute(items.send, kAXEnabledAttribute) as? NSNumber else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        return SharedClipboardMenuState(sharedClipboardEnabled: checked, sendClipboardEnabled: enabled.boolValue)
    }

    func setSharedClipboardEnabled(_ enabled: Bool) throws {
        // Restoration may run after the user switched apps, but only if this
        // application's selected connection is still the captured window.
        try validateConnection()
        trace("setting requested=\(enabled) revision=\(pasteboard.changeCount) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        try SharedClipboardSettingTransition().run(
            enabled: enabled,
            readState: { try self.readState() },
            toggleOnce: {
                if !enabled { try self.validateTargetAndClipboard() }
                try Self.press(self.menuItems().shared, command: "Use Shared Clipboard")
                self.trace("setting press returned requested=\(enabled)")
            },
            onState: { state in
                self.trace("setting observed=\(state.sharedClipboardEnabled) sharedCommandEnabled=\(self.lastSharedCommandEnabled.map(String.init) ?? "unknown") sendEnabled=\(state.sendClipboardEnabled) revision=\(self.pasteboard.changeCount)")
            }
        )
        trace("setting confirmed=\(enabled) revision=\(pasteboard.changeCount)")
    }

    func sendClipboard() throws {
        try validateTargetAndClipboard()
        let state = try readState()
        trace("send check shared=\(state.sharedClipboardEnabled) enabled=\(state.sendClipboardEnabled) revision=\(pasteboard.changeCount)")
        guard !state.sharedClipboardEnabled, state.sendClipboardEnabled else {
            throw ExplicitClipboardTransferError.sendUnavailable
        }
        // A failed/ambiguous press is never retried automatically.
        try Self.press(menuItems().send, command: "Send Clipboard")
        trace("send press returned revision=\(pasteboard.changeCount)")
    }

    func sendRestoredClipboard(validating validateClipboard: () throws -> Void) throws {
        // This is completion of an already captured connection, possibly after
        // the user changed local apps. It must not activate a window or send keys.
        try validateConnection()
        try validateClipboard()
        let state = try readState()
        trace("restore send check shared=\(state.sharedClipboardEnabled) sharedCommandEnabled=\(lastSharedCommandEnabled.map(String.init) ?? "unknown") enabled=\(state.sendClipboardEnabled) revision=\(pasteboard.changeCount) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)")
        guard !state.sharedClipboardEnabled, state.sendClipboardEnabled else {
            throw ScreenSharingClipboardMenuError.restoredSendUnavailable
        }
        let item = try menuItems().send
        try Self.press(item, command: "Send Clipboard", validateBeforePress: {
            try self.validateConnection()
            try validateClipboard()
        })
        trace("restore send press returned revision=\(pasteboard.changeCount); remote completion unverified")
        try validateClipboard()
    }

    /// Read-only gate for completion after the local clipboard is restored.
    /// Background Screen Sharing disables these menu commands on this Mac.
    /// Do not read its focused window until the app is active again.
    func restorationReadiness() throws -> ClipboardCompletionReadiness {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.ScreenSharing" else {
            throw ScreenSharingClipboardMenuError.targetChanged
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .waitingForTarget
        }
        try validateConnection()
        let state = try readState()
        // Send availability/receipt validity are checked by the one attempt.
        // An empty/newer clipboard must not postpone recovery indefinitely.
        return state.sharedClipboardEnabled || lastSharedCommandEnabled == true ? .ready : .waitingForMenu
    }

    private func validateConnection() throws {
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.ScreenSharing" else {
            DiagnosticLog.shared.record("screen-sharing.connection_changed reason=process_identity pid=\(pid) actual=\(DiagnosticLog.app(pid))")
            throw ScreenSharingClipboardMenuError.targetChanged
        }
        let actual = try Self.elementAttribute(application, kAXFocusedWindowAttribute)
        guard CFEqual(window, actual) else {
            DiagnosticLog.shared.record("screen-sharing.window_changed stage=connection pid=\(pid) expectedRef=\(CFHash(window)) actualRef=\(CFHash(actual)) front=\(DiagnosticLog.front)")
            throw ScreenSharingClipboardMenuError.targetChanged
        }
    }

    private func menuItems() throws -> (shared: AXUIElement, send: AXUIElement) {
        try validateConnection()
        let bar = try Self.elementAttribute(application, kAXMenuBarAttribute)
        // English titles are the observed UI on this Mac. Other localizations
        // fail visibly rather than guessing another command or menu position.
        guard let edit = try Self.children(bar).first(where: { Self.title($0) == "Edit" }),
              let menu = try Self.children(edit).first else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        let children = try Self.children(menu)
        guard let shared = children.first(where: { Self.title($0) == "Use Shared Clipboard" }),
              let send = children.first(where: { Self.title($0) == "Send Clipboard" }) else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        return (shared, send)
    }

    private static func title(_ element: AXUIElement) -> String? {
        (try? attribute(element, kAXTitleAttribute)) as? String
    }

    private static func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let elements = try attribute(element, kAXChildrenAttribute) as? [AXUIElement], elements.count <= 100 else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        return elements
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) throws -> AXUIElement {
        let value = try attribute(element, name)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        return value as! AXUIElement
    }

    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.75)
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success, let value else {
            DiagnosticLog.shared.record("screen-sharing.ax_failed attribute=\(name) code=\(result.rawValue) elementRef=\(CFHash(element))")
            throw ScreenSharingClipboardMenuError.accessibility(operation: "read \(name)", code: result.rawValue)
        }
        return value
    }

    private static func press(_ element: AXUIElement, command: String, validateBeforePress: () throws -> Void = {}) throws {
        AXUIElementSetMessagingTimeout(element, 0.75)
        guard let enabled = try attribute(element, kAXEnabledAttribute) as? NSNumber else {
            throw ScreenSharingClipboardMenuError.menuUnavailable
        }
        guard enabled.boolValue else { throw ScreenSharingClipboardMenuError.commandDisabled(command) }
        try validateBeforePress()
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw ScreenSharingClipboardMenuError.accessibility(operation: "press menu item", code: result.rawValue)
        }
    }
}
