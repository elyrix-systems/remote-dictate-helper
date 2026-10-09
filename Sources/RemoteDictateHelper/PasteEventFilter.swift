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
    var remaining: TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }
    // No caller code runs under this lock. A slow admission check cannot extend
    // the tap deadline or commit a paste after the original input passed through.
    @discardableResult func resolve(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed, ProcessInfo.processInfo.systemUptime < deadline else { return false }
        accepted = value; completed = true; ready.signal()
        return true
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
/// the main thread cannot stall ordinary keys or the helper's replay. Synthetic
/// Command+V candidates share one deadline for source lookup and admission.
final class PasteEventFilter: @unchecked Sendable {
    private let sources: [DictationSource]
    private let onEvent: @Sendable (PasteInputEvent, PasteCaptureDecision?) -> Void
    private let onDisabled: @Sendable () -> Void
    private let trackPhysicalModifiers: Bool
    private let sourceIdentifier: @Sendable (pid_t) -> String?
    // Shared across both client filters and stop/start cycles. Even an OS call
    // that never returns cannot accumulate lookup workers as filters restart.
    private static let sourceQueue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.source-identity")
    private static let sourceSlot = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?
    private var port: CFMachPort?
    private var stopped = false
    private var suppressedPID: pid_t?
    private var suppressedAt: TimeInterval = 0
    private var suppressedSource: PasteInputEvent?
    private var resolvedSource: PasteInputEvent?
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
        var input = PasteInputEvent(kind: type == .keyDown ? .down : type == .keyUp ? .up : .mouse,
            key: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
            command: event.flags.contains(.maskCommand), pid: pid, fromDictation: false,
            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        input.flags = event.flags.rawValue
        input.eventUptime = Double(event.timestamp) / 1_000_000_000
        lock.lock()
        if ProcessInfo.processInfo.systemUptime - suppressedAt > 5 { suppressedPID = nil }
        let paired = suppressedPID == pid && input.key == 9 &&
            (input.kind == .up || (input.kind == .down && input.autorepeat))
        if paired, let source = suppressedSource {
            input = PasteInputEvent(kind: input.kind, key: input.key, command: input.command,
                pid: pid, fromDictation: true, clipboardReturn: source.clipboardReturn,
                autorepeat: input.autorepeat, sourceBundle: source.sourceBundle,
                flags: input.flags, eventUptime: input.eventUptime)
        }
        if paired && input.kind == .up { suppressedPID = nil; suppressedSource = nil }
        lock.unlock()
        if paired { onEvent(input, nil); return true }
        lock.lock()
        if input.kind == .down || input.kind == .mouse { sequence &+= 1 }
        input.sequence = sequence
        if DiagnosticLog.shared.enabled, input.kind == .down || input.kind == .mouse {
            lastInput = input.diagnosticMetadata
        }
        lock.unlock()
        guard pid > 0, input.kind == .down, input.key == 9, input.command, !input.autorepeat else {
            onEvent(input, nil); return false
        }
        let decision = PasteCaptureDecision()
        let decisionStarted = ProcessInfo.processInfo.systemUptime
        // Launch Services may block. Resolve only candidate pastes off the tap,
        // inside the same deadline. One outstanding lookup bounds resource use
        // even if the external service never replies. Ordinary input does no IPC.
        guard Self.sourceSlot.wait(timeout: .now()) == .success else {
            DiagnosticLog.shared.record("filter.source_lookup_busy physicalModifiers=\(trackPhysicalModifiers) originalInput=allowed \(input.diagnosticMetadata)")
            onEvent(input, nil); return false
        }
        let candidate = input
        Self.sourceQueue.async { [self] in
            let identifier: String? = {
                defer { Self.sourceSlot.signal() }
                guard decision.remaining > 0 else { return nil }
                return sourceIdentifier(pid)
            }()
            // Release the lookup slot before dispatching admission. Otherwise a
            // quick refusal from one client could make the other client's tap
            // skip the same event while this worker was still releasing its slot.
            guard decision.remaining > 0 else { return }
            guard let source = sources.first(where: { $0.matches(identifier) }) else {
                onEvent(candidate, nil); decision.resolve(false); return
            }
            let classified = PasteInputEvent(kind: candidate.kind, key: candidate.key,
                command: candidate.command, pid: pid, fromDictation: true,
                clipboardReturn: source.clipboardReturn, autorepeat: candidate.autorepeat,
                sequence: candidate.sequence, sourceBundle: identifier,
                flags: candidate.flags, eventUptime: candidate.eventUptime)
            lock.lock(); let inactive = stopped; resolvedSource = inactive ? nil : classified; lock.unlock()
            guard !inactive else { decision.resolve(false); return }
            onEvent(classified, decision)
        }
        let accepted = decision.wait()
        lock.lock(); let classified = resolvedSource?.sequence == candidate.sequence ? resolvedSource : nil; lock.unlock()
        DiagnosticLog.shared.record("filter.decision physicalModifiers=\(trackPhysicalModifiers) accepted=\(accepted) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - decisionStarted) * 1000)) \((classified ?? input).diagnosticMetadata)")
        if accepted {
            lock.lock(); suppressedPID = pid; suppressedSource = classified
            suppressedAt = ProcessInfo.processInfo.systemUptime; lock.unlock()
        }
        return accepted
    }
}
