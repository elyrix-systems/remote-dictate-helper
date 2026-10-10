import AppKit

/// The tap reads only this RAM flag; it never queries AppKit to reject local
/// input. This is an early refusal gate, not authority to capture or replay.
final class PasteTargetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func setActive(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
}

/// Workspace notifications suspend both admission and baseline sampling outside
/// the client. Actual foreground/window checks still run at admission and replay.
@MainActor
final class PasteTargetScope {
    nonisolated let gate = PasteTargetGate()
    private let bundleIdentifier: String
    private let center: NotificationCenter
    private let front: () -> String?
    private var observers: [NSObjectProtocol] = []
    private var onChange: (Bool) -> Void = { _ in }

    init(bundleIdentifier: String, center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         front: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.bundleIdentifier = bundleIdentifier; self.center = center; self.front = front
    }

    func start(onChange: @escaping (Bool) -> Void = { _ in }) {
        stop()
        self.onChange = onChange
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name
                let identifier = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated { self?.receive(name, identifier: identifier) }
            })
        }
        update(front() == bundleIdentifier)
    }

    func stop() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        update(false)
        onChange = { _ in }
    }

    private func receive(_ name: Notification.Name, identifier: String?) {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification:
            update(false)
        case NSWorkspace.didDeactivateApplicationNotification:
            if identifier == bundleIdentifier { update(false) }
        default:
            update((identifier ?? front()) == bundleIdentifier)
        }
    }

    private func update(_ active: Bool) {
        guard gate.isActive != active else { return }
        gate.setActive(active)
        DiagnosticLog.shared.record("filter.scope target=\(bundleIdentifier) active=\(active)")
        onChange(active)
    }
}

/// One queued admission across both adapters and monitor restarts. Expiry does
/// not free the slot: only draining the queued block does. Otherwise a blocked
/// main queue could collect a fresh obsolete callback every 80 ms indefinitely.
final class PasteAdmissionQueue: @unchecked Sendable {
    static let shared = PasteAdmissionQueue()
    typealias Work = @MainActor @Sendable () -> Void
    private let slot = DispatchSemaphore(value: 1)
    private let enqueue: @Sendable (@escaping Work) -> Void

    init(enqueue: @escaping @Sendable (@escaping Work) -> Void = { work in
        DispatchQueue.main.async { work() }
    }) { self.enqueue = enqueue }

    func submit(_ decision: PasteCaptureDecision, work: @escaping Work) {
        guard slot.wait(timeout: .now()) == .success else { decision.resolve(false); return }
        enqueue { [self] in
            defer { slot.signal() }
            guard decision.remaining > 0 else { return }
            work()
        }
    }
}
