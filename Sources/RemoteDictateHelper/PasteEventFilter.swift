import AppKit
import RemoteDictateCore

struct PasteInputEvent: Sendable {
    enum Kind: Sendable { case down, up, mouse }
    let kind: Kind
    let key: UInt16
    let command: Bool
    let pid: pid_t
    let fromDictation: Bool
    var clipboardReturn: ClipboardReturnPolicy = .restoresPrevious
    var autorepeat = false
    var sequence: UInt64?
    var sourceBundle: String?
    var flags: UInt64 = 0
    var eventUptime: TimeInterval = 0
}

/// A bounded handoff, not a retained CGEvent. If the main thread cannot prepare
/// a capture promptly, the original paste passes through and late work is inert.
final class PasteCaptureDecision: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let deadline: TimeInterval
    private var completed = false
    private var accepted = false
    init(wait: TimeInterval = 0.08) { deadline = ProcessInfo.processInfo.systemUptime + wait }
    func evaluate(_ body: () -> Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !completed, ProcessInfo.processInfo.systemUptime < deadline else { return }
        accepted = body(); completed = true; ready.signal()
    }
    func wait() -> Bool {
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        _ = ready.wait(timeout: .now() + remaining)
        lock.lock(); defer { lock.unlock() }
        if !completed { completed = true; accepted = false }
        return accepted
    }
}

/// The tap runs on its own run loop. Slow Screen Sharing AX/menu transitions on
/// the main thread cannot stall ordinary keys or the helper's replay. Only a
/// configured source's candidate V-down uses a short main-thread handoff.
final class PasteEventFilter: @unchecked Sendable {
    private let sources: [DictationSource]
    private let onEvent: @Sendable (PasteInputEvent, PasteCaptureDecision?) -> Void
    private let onDisabled: @Sendable () -> Void
    private let trackPhysicalModifiers: Bool
    private let sourceIdentifier: @Sendable (pid_t) -> String?
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?
    private var port: CFMachPort?
    private var stopped = false
    private var suppressedPID: pid_t?
    private var suppressedAt: TimeInterval = 0
    private var sequence: UInt64 = 0
    private var modifiers: UInt64 = 0
    private var lastInput = "none"
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(sources: [DictationSource], onEvent: @escaping @Sendable (PasteInputEvent, PasteCaptureDecision?) -> Void,
         onDisabled: @escaping @Sendable () -> Void, trackPhysicalModifiers: Bool = false,
         sourceIdentifier: @escaping @Sendable (pid_t) -> String? = {
             NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
         }) {
        self.sources = sources; self.onEvent = onEvent; self.onDisabled = onDisabled
        self.trackPhysicalModifiers = trackPhysicalModifiers
        self.sourceIdentifier = sourceIdentifier
    }
    func start() -> Bool {
        let worker = Thread { [self] in run() }
        worker.name = "Remote Dictate paste filter"; worker.start()
        guard ready.wait(timeout: .now() + 2) == .success else { stop(); return false }
        lock.lock(); defer { lock.unlock() }
        return port != nil && !stopped
    }
    func stop() {
        lock.lock(); stopped = true; suppressedPID = nil; let current = loop; lock.unlock()
        if let current { CFRunLoopStop(current); CFRunLoopWakeUp(current) }
    }
    var inputSequence: UInt64 {
        lock.lock(); defer { lock.unlock() }; return sequence
    }
    var physicalModifierSequence: UInt64 {
        lock.lock(); defer { lock.unlock() }; return modifiers
    }
    var lastInputMetadata: String {
        lock.lock(); defer { lock.unlock() }; return lastInput
    }
    private func run() {
        var types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        if trackPhysicalModifiers { types.append(.flagsChanged) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<PasteEventFilter>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            ready.signal(); return
        }
        let current = CFRunLoopGetCurrent()
        lock.lock(); port = tap; loop = current; let cancelled = stopped; lock.unlock()
        CFRunLoopAddSource(current, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: !cancelled)
        ready.signal()
        if !cancelled { CFRunLoopRun() }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(current, source, .commonModes); CFMachPortInvalidate(tap)
        lock.lock(); port = nil; loop = nil; lock.unlock()
    }
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DiagnosticLog.shared.record("filter.disabled type=\(type.rawValue) physicalModifiers=\(trackPhysicalModifiers)")
            lock.lock(); suppressedPID = nil; lock.unlock()
            onDisabled(); return false
        }
        lock.lock(); let inactive = stopped; lock.unlock()
        guard !inactive else { return false }
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        if type == .flagsChanged {
            // Pass every modifier through. Only the physical/system source
            // advances this guard; our private replay must not cancel itself.
            if trackPhysicalModifiers && pid == 0 {
                lock.lock(); modifiers &+= 1; lock.unlock()
            }
            return false
        }
        guard pid != ownPID else { return false }
        let identifier = pid > 0 ? sourceIdentifier(pid) : nil
        let source = sources.first { $0.matches(identifier) }
        var input = PasteInputEvent(kind: type == .keyDown ? .down : type == .keyUp ? .up : .mouse,
            key: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
            command: event.flags.contains(.maskCommand), pid: pid, fromDictation: source != nil,
            clipboardReturn: source?.clipboardReturn ?? .restoresPrevious,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        input.sourceBundle = identifier; input.flags = event.flags.rawValue
        input.eventUptime = Double(event.timestamp) / 1_000_000_000
        lock.lock()
        if ProcessInfo.processInfo.systemUptime - suppressedAt > 5 { suppressedPID = nil }
        let paired = suppressedPID == pid && input.key == 9 &&
            (input.kind == .up || (input.kind == .down && input.autorepeat))
        if paired && input.kind == .up { suppressedPID = nil }
        lock.unlock()
        if paired { onEvent(input, nil); return true }
        lock.lock()
        if input.kind == .down || input.kind == .mouse { sequence &+= 1 }
        input.sequence = sequence
        if DiagnosticLog.shared.enabled, input.kind == .down || input.kind == .mouse {
            lastInput = input.diagnosticMetadata
        }
        lock.unlock()
        guard input.fromDictation, input.kind == .down, input.key == 9, input.command, !input.autorepeat else {
            onEvent(input, nil); return false
        }
        let decision = PasteCaptureDecision()
        let decisionStarted = ProcessInfo.processInfo.systemUptime
        onEvent(input, decision)
        let accepted = decision.wait()
        DiagnosticLog.shared.record("filter.decision physicalModifiers=\(trackPhysicalModifiers) accepted=\(accepted) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - decisionStarted) * 1000)) \(input.diagnosticMetadata)")
        if accepted {
            lock.lock(); suppressedPID = pid; suppressedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
        }
        return accepted
    }
}
