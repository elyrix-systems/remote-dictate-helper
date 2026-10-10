import Foundation

enum AccessibilityAccessState: Equatable, Sendable {
    case checking, granted, denied, unavailable
}

/// Permission IPC runs in one bounded child on a dedicated queue. UI/input
/// consumers read RAM and fail closed on stale data. Even the HID preflight
/// retained stale granted/denied answers in the signed local trial.
final class AccessibilityAccessMonitor: @unchecked Sendable {
    static let shared = AccessibilityAccessMonitor()
    private let queue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.access-check", qos: .utility)
    private let lock = NSLock()
    private let check: @Sendable () -> AccessibilityAccessState
    private let now: @Sendable () -> TimeInterval
    private let freshness: TimeInterval
    private var value: AccessibilityAccessState = .checking
    private var checkedAt: TimeInterval?
    private var generation = 0
    private var inFlight = false
    private var timer: DispatchSourceTimer?

    init(poll: Bool = true, freshness: TimeInterval = 2,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         check: @escaping @Sendable () -> AccessibilityAccessState = {
             AccessibilityProbeProcess.run()
         }) {
        self.freshness = freshness; self.now = now; self.check = check
        if poll {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { @Sendable [weak self] in self?.requestCheck() }
            self.timer = timer; timer.resume()
        }
    }
    deinit { timer?.cancel() }

    var state: AccessibilityAccessState {
        let time = now()
        lock.lock(); defer { lock.unlock() }
        guard let checkedAt else { return .checking }
        return time - checkedAt <= freshness ? value : .unavailable
    }

    /// A result begun before entering/leaving the permission pane cannot rearm
    /// input after that boundary. No direct OS call and no unbounded queue.
    func invalidate() {
        lock.lock(); generation &+= 1; checkedAt = nil; value = .checking; lock.unlock()
        requestCheck()
    }

    func requestCheck() {
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        inFlight = true; let token = generation; lock.unlock()
        queue.async { [self] in
            let next = check(), time = now()
            lock.lock()
            let current = token == generation
            let changed = current && (checkedAt == nil || value != next)
            if current { value = next; checkedAt = time }
            inFlight = false; lock.unlock()
            if changed { DiagnosticLog.shared.record("permission.live state=\(next)") }
            if !current { requestCheck() }
        }
    }

    func refreshedState(timeout: TimeInterval = 1) async -> AccessibilityAccessState {
        invalidate()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled {
            let current = state
            if current != .checking { return current }
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        return .unavailable
    }
}
