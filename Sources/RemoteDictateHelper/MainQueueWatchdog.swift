import Foundation

/// Diagnostic-only heartbeat. Its timer and logging run independently of AppKit;
/// at most one ping waits on the main queue, even during an indefinite stall.
final class MainQueueWatchdog: @unchecked Sendable {
    typealias Ping = @Sendable () -> Void
    private let lock = NSLock()
    private let enqueue: @Sendable (@escaping Ping) -> Void
    private let now: @Sendable () -> TimeInterval
    private let log: @Sendable (String) -> Void
    private var pending: (id: UUID, started: TimeInterval)?
    private var lastReport: TimeInterval = -.infinity
    // Only start/stop access the timer, from the main actor.
    @MainActor private var timer: DispatchSourceTimer?

    init(enqueue: @escaping @Sendable (@escaping Ping) -> Void = { DispatchQueue.main.async(execute: $0) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         log: @escaping @Sendable (String) -> Void = { DiagnosticLog.shared.record($0) }) {
        self.enqueue = enqueue; self.now = now; self.log = log
    }

    @MainActor func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.heartbeat", qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { @Sendable [weak self] in self?.tick() }
        self.timer = timer; timer.resume()
    }

    @MainActor func stop() { timer?.cancel(); timer = nil }

    func tick() {
        let time = now()
        lock.lock()
        if let pending {
            let elapsed = time - pending.started
            let report = elapsed >= 2 && time - lastReport >= 10
            if report { lastReport = time }
            lock.unlock()
            if report { log("liveness.main_queue_delayed elapsedMs=\(Int(elapsed * 1000)) queuedPings=1") }
            return
        }
        let id = UUID()
        pending = (id, time)
        lock.unlock()
        enqueue { [weak self] in self?.complete(id) }
    }

    private func complete(_ id: UUID) {
        let time = now()
        lock.lock()
        guard let pending, pending.id == id else { lock.unlock(); return }
        let elapsed = time - pending.started
        self.pending = nil
        let report = elapsed >= 2 || time - lastReport >= 30
        if report { lastReport = time }
        lock.unlock()
        if report {
            log("liveness.\(elapsed >= 2 ? "main_queue_recovered" : "heartbeat") elapsedMs=\(Int(elapsed * 1000)) queuedPings=0")
        }
    }
}
