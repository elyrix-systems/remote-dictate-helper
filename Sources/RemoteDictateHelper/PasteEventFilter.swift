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
    func cancel() {
        lock.lock(); accepted = false; completed = true; ready.signal(); lock.unlock()
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
    private let targetIsActive: @Sendable () -> Bool
    private let permissionCheck: @Sendable () -> Bool
    // Shared across both client filters and stop/start cycles. Even an OS call
    // that never returns cannot accumulate lookup workers as filters restart.
    private static let sourceQueue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.source-identity")
    private static let sourceSlot = DispatchSemaphore(value: 1)
    private static let permissionQueue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.permission")
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var disconnectTap: (@Sendable () -> Void)?
    private var activeDecision: PasteCaptureDecision?
    private var started = false
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
         targetIsActive: @escaping @Sendable () -> Bool = { true },
         permissionCheck: @escaping @Sendable () -> Bool = { AccessibilityPermission.isTrusted() },
         sourceIdentifier: @escaping @Sendable (pid_t) -> String? = {
             NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
         }) {
        self.sources = sources; self.onEvent = onEvent; self.onDisabled = onDisabled
        self.trackPhysicalModifiers = trackPhysicalModifiers
        self.sourceIdentifier = sourceIdentifier
        self.targetIsActive = targetIsActive
        self.permissionCheck = permissionCheck
    }
    func start() -> Bool {
        lock.lock()
        guard !started, !stopped else { lock.unlock(); return false }
        started = true; lock.unlock()
        let worker = Thread { [self] in run() }
        worker.name = "Remote Dictate paste filter"; worker.start()
        guard ready.wait(timeout: .now() + 2) == .success else { stop(); return false }
        lock.lock(); defer { lock.unlock() }
        return disconnectTap != nil && !stopped
    }
    func stop() { retire(reason: nil) }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Publish cleanup atomically with stop. Late native creation is torn down,
    /// never enabled again. Tests install an owned fake connection here.
    @discardableResult func installTap(disconnect: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        let accepted = !stopped && disconnectTap == nil
        if accepted { disconnectTap = disconnect }
        lock.unlock()
        if !accepted { disconnect() }
        return accepted
    }

    private func retire(reason: String?) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        suppressedPID = nil; suppressedSource = nil; resolvedSource = nil
        let disconnect = disconnectTap, decision = activeDecision
        disconnectTap = nil; activeDecision = nil
        lock.unlock()
        decision?.cancel()
        // Disconnect before logging or notifying the main actor. Neither UI
        // progress nor a future run-loop iteration may keep this tap installed.
        disconnect?()
        if let reason {
            DiagnosticLog.shared.record("filter.retired reason=\(reason) physicalModifiers=\(trackPhysicalModifiers)")
            onDisabled()
        }
    }

    /// Runs on the permission queue, never on the input callback or main actor.
    /// Disabled-tap callbacks remain the immediate path if trust is cached.
    func checkPermission() {
        guard !isStopped else { return }
        if !permissionCheck() { retire(reason: "accessibility_revoked") }
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
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            ready.signal(); return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
              let current = CFRunLoopGetCurrent() else {
            CFMachPortInvalidate(tap); ready.signal(); return
        }
        CFRunLoopAddSource(current, source, .commonModes)
        let permissionTimer = DispatchSource.makeTimerSource(queue: Self.permissionQueue)
        permissionTimer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        permissionTimer.setEventHandler { @Sendable [weak self] in self?.checkPermission() }
        permissionTimer.resume()
        let resources = NativeTapResources(tap: tap, loop: current, permissionTimer: permissionTimer)
        let installed = installTap { resources.disconnect() }
        ready.signal()
        // Creation already enables a tap. Never re-enable it after publication:
        // stop/revocation may race setup. A bounded run also handles stop-before-run.
        if installed {
            while !isStopped && CFMachPortIsValid(tap) {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }
            retire(reason: "native_port_invalidated")
        }
        CFRunLoopRemoveSource(current, source, .commonModes)
    }
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            retire(reason: "disabled_\(type.rawValue)"); return false
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
        if paired {
            guard !isStopped else { return false }
            // Only the accepted release needs an observer callback. Repeated
            // downs are suppressed without creating more main-actor work.
            if input.kind == .up { onEvent(input, nil) }
            return true
        }
        lock.lock()
        if input.kind == .down || input.kind == .mouse { sequence &+= 1 }
        input.sequence = sequence
        if DiagnosticLog.shared.enabled, input.kind == .down || input.kind == .mouse {
            lastInput = input.diagnosticMetadata
        }
        lock.unlock()
        guard pid > 0, input.kind == .down, input.key == 9, input.command, !input.autorepeat else {
            // The synchronous sequence counter is sufficient for cancellation.
            // Do not enqueue a task for every ordinary key/click on the Mac.
            return false
        }
        guard targetIsActive() else { return false }
        let decision = PasteCaptureDecision()
        lock.lock()
        guard !stopped else { lock.unlock(); return false }
        activeDecision = decision; lock.unlock()
        defer {
            lock.lock()
            if activeDecision === decision { activeDecision = nil }
            lock.unlock()
        }
        let decisionStarted = ProcessInfo.processInfo.systemUptime
        // Launch Services may block. Resolve only candidate pastes off the tap,
        // inside the same deadline. One outstanding lookup bounds resource use
        // even if the external service never replies. Ordinary input does no IPC.
        guard Self.sourceSlot.wait(timeout: .now()) == .success else {
            DiagnosticLog.shared.record("filter.source_lookup_busy physicalModifiers=\(trackPhysicalModifiers) originalInput=allowed \(input.diagnosticMetadata)")
            return false
        }
        let candidate = input
        Self.sourceQueue.async { [self] in
            let identifier: String? = {
                defer { Self.sourceSlot.signal() }
                guard decision.remaining > 0, targetIsActive() else { return nil }
                return sourceIdentifier(pid)
            }()
            // Release the lookup slot before dispatching admission. Otherwise a
            // quick refusal from one client could make the other client's tap
            // skip the same event while this worker was still releasing its slot.
            guard decision.remaining > 0 else { return }
            guard let source = sources.first(where: { $0.matches(identifier) }) else {
                decision.resolve(false); return
            }
            let classified = PasteInputEvent(kind: candidate.kind, key: candidate.key,
                command: candidate.command, pid: pid, fromDictation: true,
                clipboardReturn: source.clipboardReturn, autorepeat: candidate.autorepeat,
                sequence: candidate.sequence, sourceBundle: identifier,
                flags: candidate.flags, eventUptime: candidate.eventUptime)
            lock.lock(); let inactive = stopped; resolvedSource = inactive ? nil : classified; lock.unlock()
            guard !inactive, targetIsActive() else { decision.resolve(false); return }
            onEvent(classified, decision)
        }
        let resolved = decision.wait()
        lock.lock()
        let accepted = resolved && !stopped
        let classified = resolvedSource?.sequence == candidate.sequence ? resolvedSource : nil
        if accepted {
            suppressedPID = pid; suppressedSource = classified
            suppressedAt = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
        DiagnosticLog.shared.record("filter.decision physicalModifiers=\(trackPhysicalModifiers) accepted=\(accepted) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - decisionStarted) * 1000)) \((classified ?? input).diagnosticMetadata)")
        return accepted
    }
}

/// Native resources are released once by the filter's atomic retirement path.
/// Core Foundation invalidation is thread-safe and also invalidates its source.
private final class NativeTapResources: @unchecked Sendable {
    let tap: CFMachPort
    let loop: CFRunLoop
    let permissionTimer: DispatchSourceTimer
    init(tap: CFMachPort, loop: CFRunLoop, permissionTimer: DispatchSourceTimer) {
        self.tap = tap; self.loop = loop; self.permissionTimer = permissionTimer
    }
    func disconnect() {
        permissionTimer.cancel()
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        CFRunLoopStop(loop); CFRunLoopWakeUp(loop)
    }
}
