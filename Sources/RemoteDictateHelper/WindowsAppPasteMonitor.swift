import AppKit
import RemoteDictateCore

enum WindowsAppPasteError: Error, CustomStringConvertible {
    case unavailable, targetChanged, inputChanged, clipboardChanged
    var description: String {
        switch self {
        case .unavailable: "Windows App paste interception is unavailable. Check Accessibility and reopen the helper."
        case .targetChanged: "Windows App context changed; no deferred paste."
        case .inputChanged: "Input changed; Windows App paste cancelled."
        case .clipboardChanged: "The clipboard changed before Windows App paste completed; no retry."
        }
    }
}

/// Repairs the shortcut while RDP owns clipboard redirection. This adapter never
/// reads clipboard contents, writes the clipboard or changes sharing settings.
@MainActor
final class WindowsAppPasteMonitor {
    static let bundleIdentifier = "com.microsoft.rdc.macos"
    typealias WindowValidation = () throws -> Void
    private let sources: [DictationSource]
    private let targetPID: () -> pid_t?
    private let isAvailable: () -> Bool
    private let revision: () -> Int
    private let isTrusted: () -> Bool
    private let captureWindow: @MainActor (pid_t) throws -> WindowValidation
    private let readiness: ExplicitPasteShortcut
    private let post: (CGEvent) -> Void
    private let pause: () async throws -> Void
    private let inputSequenceOverride: (() -> UInt64?)?
    private let modifierSequenceOverride: (() -> UInt64)?
    private let onCaptured: () -> Void
    private let onCompleted: (Result<Void, Error>) -> Void
    private let report: (String) -> Void
    private let diagnostic: (String) -> Void
    private var filter: PasteEventFilter?
    private var filterHealthy = true
    private var task: Task<Void, Never>?
    private var releaseKeys: (() -> Void)?
    private var lastRevision: Int?
    private var generation = 0
    private(set) var isBusy = false

    init(sources: [DictationSource], isAvailable: @escaping () -> Bool,
         targetPID: @escaping () -> pid_t? = {
             let app = NSWorkspace.shared.frontmostApplication
             return app?.bundleIdentifier == bundleIdentifier ? app?.processIdentifier : nil
         }, revision: @escaping () -> Int = { NSPasteboard.general.changeCount },
         isTrusted: @escaping () -> Bool = { AccessibilityPermission.isTrusted() },
         captureWindow: @escaping @MainActor (pid_t) throws -> WindowValidation = WindowsAppPasteMonitor.windowValidation,
         readiness: ExplicitPasteShortcut? = nil,
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         pause: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(25)) },
         inputSequence: (() -> UInt64?)? = nil, modifierSequence: (() -> UInt64)? = nil,
         onCaptured: @escaping () -> Void = {}, onCompleted: @escaping (Result<Void, Error>) -> Void = { _ in },
         report: @escaping (String) -> Void = { _ in },
         diagnostic: @escaping (String) -> Void = { DiagnosticLog.shared.record($0) }) {
        self.sources = sources; self.isAvailable = isAvailable; self.targetPID = targetPID
        self.revision = revision; self.isTrusted = isTrusted; self.captureWindow = captureWindow
        self.readiness = readiness ?? ExplicitPasteShortcut(isolatedSoftwareCommand: true, interceptedPaste: true,
            targetIsFrontmost: { targetPID() == $0 })
        self.post = post; self.pause = pause; self.onCaptured = onCaptured
        self.onCompleted = onCompleted; self.report = report
        self.diagnostic = diagnostic
        self.inputSequenceOverride = inputSequence; self.modifierSequenceOverride = modifierSequence
    }

    func start() throws {
        guard isTrusted() else { throw WindowsAppPasteError.unavailable }
        filterHealthy = true
        let next = PasteEventFilter(sources: sources, onEvent: { [weak self] event, decision in
            guard let decision else {
                if event.fromDictation, event.kind == .up, event.key == 9, DiagnosticLog.shared.enabled {
                    DiagnosticLog.shared.record("windows.source_v_up \(event.diagnosticMetadata)")
                }
                return
            }
            DispatchQueue.main.async {
                decision.evaluate {
                    guard let self, self.filter != nil else { return false }
                    return self.observe(event)
                }
            }
        }, onDisabled: { [weak self] in
            DispatchQueue.main.async { self?.filterDisabled() }
        }, trackPhysicalModifiers: true)
        guard next.start() else { throw WindowsAppPasteError.unavailable }
        filter = next
        report("Windows App paste filter installed; no clipboard writes or Backspace")
    }

    func stop() {
        generation += 1; filterHealthy = false
        task?.cancel(); releaseKeys?(); releaseKeys = nil; task = nil; isBusy = false
        filter?.stop(); filter = nil
    }

    func filterDisabled() {
        stop()
        report("Windows App filter disabled; input passes through")
        onCompleted(.failure(WindowsAppPasteError.unavailable))
    }

    /// Component tests feed metadata here; native input goes through the bounded
    /// filter decision above. No late callback may capture after stop/restart.
    @discardableResult func observe(_ event: PasteInputEvent) -> Bool {
        guard filterHealthy, !isBusy, isAvailable(), isTrusted(),
              event.pid != ProcessInfo.processInfo.processIdentifier, event.fromDictation,
              event.kind == .down, event.key == 9, event.command, !event.autorepeat,
              let pid = targetPID(), pid > 0 else { return false }
        let capturedRevision = revision()
        guard lastRevision != capturedRevision else { return false }
        lastRevision = capturedRevision; isBusy = true
        let id = UUID(), started = ProcessInfo.processInfo.systemUptime
        diagnostic("op=\(id) client=windows stage=captured targetPID=\(pid) revision=\(capturedRevision) \(event.diagnosticMetadata)")
        let currentGeneration = generation
        onCaptured()
        task = Task { [weak self] in
            guard let self else { return }
            @MainActor func trace(_ message: String) {
                self.diagnostic("op=\(id) client=windows elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) targetPID=\(pid) front=\(DiagnosticLog.front) \(message)")
            }
            let result: Result<Void, Error>
            do {
                try Task.checkCancellation()
                let validateWindow = try self.captureWindow(pid)
                let validateContext = {
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, self.filterHealthy, self.isTrusted() else {
                        trace("cancel reason=unavailable generation=\(self.generation) expectedGeneration=\(currentGeneration) filterHealthy=\(self.filterHealthy)")
                        throw WindowsAppPasteError.unavailable
                    }
                    let actual = self.targetPID()
                    guard actual == pid else {
                        trace("cancel reason=foreground_target_changed observedPID=\(actual.map(String.init) ?? "none")")
                        throw WindowsAppPasteError.targetChanged
                    }
                    try validateWindow()
                    let sequence = self.currentInputSequence
                    guard sequence == event.sequence else {
                        trace("cancel reason=input_sequence_changed expected=\(event.sequence.map(String.init) ?? "none") actual=\(sequence.map(String.init) ?? "none") lastInput={\(self.filter?.lastInputMetadata ?? "unavailable")}")
                        throw WindowsAppPasteError.inputChanged
                    }
                    let actualRevision = self.revision()
                    guard actualRevision == capturedRevision else {
                        trace("cancel reason=clipboard_changed expected=\(capturedRevision) actual=\(actualRevision)")
                        throw WindowsAppPasteError.clipboardChanged
                    }
                }
                _ = try await self.readiness.waitUntilReady(targetPID: pid, validateTarget: validateContext,
                    onWaiting: { self.report("Windows App waiting: \($0)"); trace("stage=wait-modifiers \($0)") })
                let modifiers = self.currentModifierSequence
                try self.readiness.checkReadiness(targetPID: pid)
                try await WindowsAppPasteShortcut.send(validate: {
                    try validateContext()
                    guard self.currentModifierSequence == modifiers else {
                        trace("cancel reason=physical_modifiers_changed expected=\(modifiers) actual=\(self.currentModifierSequence)")
                        throw WindowsAppPasteError.inputChanged
                    }
                }, post: { event in
                    self.post(event)
                    trace("stage=native-paste type=\(event.type.rawValue) key=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=0x\(String(event.flags.rawValue, radix: 16))")
                }, registerCleanup: { self.releaseKeys = $0 }, pause: self.pause)
                result = .success(())
                trace("stage=complete remoteReceipt=unverified")
            } catch { trace("stage=stopped reason=\(error)"); result = .failure(error) }
            guard currentGeneration == self.generation else { return }
            self.releaseKeys = nil; self.task = nil; self.isBusy = false
            switch result {
            case .success: self.report("Windows App paste posted once; clipboard unchanged by helper; remote receipt unverified")
            case let .failure(error): self.report("Windows App paste stopped: \(error); no retry")
            }
            self.onCompleted(result)
        }
        report("Windows App captured revision=\(capturedRevision)")
        return true
    }

    private var currentInputSequence: UInt64? { inputSequenceOverride?() ?? filter?.inputSequence }
    private var currentModifierSequence: UInt64 { modifierSequenceOverride?() ?? filter?.physicalModifierSequence ?? 0 }

    static func windowValidation(pid: pid_t) throws -> WindowValidation {
        func focusedWindow() throws -> AXUIElement {
            let front = NSWorkspace.shared.frontmostApplication
            guard AccessibilityPermission.isTrusted(), front?.processIdentifier == pid,
                  front?.bundleIdentifier == bundleIdentifier else { throw WindowsAppPasteError.targetChanged }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WindowsAppPasteError.targetChanged }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
        let original = try focusedWindow()
        DiagnosticLog.shared.record("windows.window_captured pid=\(pid) windowRef=\(CFHash(original))")
        return {
            let actual = try focusedWindow()
            guard CFEqual(original, actual) else {
                DiagnosticLog.shared.record("windows.window_changed pid=\(pid) expectedRef=\(CFHash(original)) actualRef=\(CFHash(actual))")
                throw WindowsAppPasteError.targetChanged
            }
        }
    }
}
