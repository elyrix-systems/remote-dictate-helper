import AppKit
import RemoteDictateCore

private final class QueuedAdmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [PasteAdmissionQueue.Work] = []
    func append(_ job: @escaping PasteAdmissionQueue.Work) { lock.lock(); jobs.append(job); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
    func take() -> PasteAdmissionQueue.Work { lock.lock(); defer { lock.unlock() }; return jobs.removeFirst() }
}

func testLocalInputDoesNotQueueWork() throws {
    let gate = PasteTargetGate(), source = AppSettings().sources[0]
    let filter = PasteEventFilter(sources: [source], onEvent: { _, _ in
        fail("Local/ordinary input must not enqueue a monitor callback")
    }, onDisabled: {}, targetIsActive: { gate.isActive }, sourceIdentifier: { _ in
        fail("Local paste must not ask another process for its identity")
    })
    defer { filter.stop() }
    let key = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    key.setIntegerValueField(.eventSourceUnixProcessID, value: 202)
    // Ordinary events do not queue work even while a remote client is active.
    for active in [false, true] {
        gate.setActive(active)
        for _ in 0..<10_000 {
            expectFalse(filter.handle(type: .keyDown, event: key))
            expectFalse(filter.handle(type: .keyUp, event: key))
            expectFalse(filter.handle(type: .leftMouseDown, event: key))
        }
    }
    expectEqual(filter.inputSequence, 40_000, "Cancellation still sees every key-down/click immediately")
    gate.setActive(false)
    key.setIntegerValueField(.keyboardEventKeycode, value: 9); key.flags = .maskCommand
    for _ in 0..<1_000 { expectFalse(filter.handle(type: .keyDown, event: key)) }
    print("Local-input liveness: 60,000 ordinary events and 1,000 local pastes enqueue no work; cancellation counters retained")
}

func testTargetGateKeepsAcceptedRelease() throws {
    let gate = PasteTargetGate(), source = AppSettings().sources[0]
    let released = DispatchSemaphore(value: 0)
    let filter = PasteEventFilter(sources: [source], onEvent: { event, decision in
        if let decision { decision.resolve(true) }
        else { expectEqual(event.kind, .up); expectTrue(event.fromDictation); released.signal() }
    }, onDisabled: {}, targetIsActive: { gate.isActive }, sourceIdentifier: { _ in source.bundleIdentifier })
    defer { filter.stop() }
    let key = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
    key.setIntegerValueField(.eventSourceUnixProcessID, value: 202); key.flags = .maskCommand
    gate.setActive(true)
    expectTrue(filter.handle(type: .keyDown, event: key))
    let sequence = filter.inputSequence
    gate.setActive(false)
    key.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    for _ in 0..<1_000 { expectTrue(filter.handle(type: .keyDown, event: key)) }
    expectEqual(filter.inputSequence, sequence)
    expectEqual(released.wait(timeout: .now()), .timedOut, "Repeats do not enqueue callbacks")
    expectTrue(filter.handle(type: .keyUp, event: key), "Pair release survives focus loss")
    expectEqual(released.wait(timeout: .now()), .success)
    expectFalse(filter.handle(type: .keyUp, event: key), "Unpaired local release passes through")
    print("Target gate: accepted V-up survives focus loss; repeats do not queue; next local paste passes through")
}

@MainActor func testAdmissionQueueBound() {
    let pending = QueuedAdmissions()
    let queue = PasteAdmissionQueue(enqueue: { pending.append($0) })
    // Simulate a main queue that cannot run at all. Even expired requests occupy
    // its one slot until consumed; no real thread needs to be hung for this test.
    for _ in 0..<20_000 {
        queue.submit(PasteCaptureDecision(wait: 0)) { fail("Expired work cannot enter a monitor") }
    }
    expectEqual(pending.count, 1)
    pending.take()()
    var admitted = 0
    let decision = PasteCaptureDecision(wait: 1)
    queue.submit(decision) { admitted += 1; decision.resolve(true) }
    pending.take()()
    expectTrue(decision.wait()); expectEqual(admitted, 1); expectEqual(pending.count, 0)
    print("Admission queue: 20,000 expired requests retain one block; recovery accepts fresh work")
}

@MainActor func testTargetScopeLifecycle() {
    let center = NotificationCenter()
    var front: String? = "example.local", transitions: [Bool] = [], reads = 0
    let scope = PasteTargetScope(bundleIdentifier: "example.remote", center: center,
        front: { reads += 1; return front })
    scope.start { transitions.append($0) }
    expectFalse(scope.gate.isActive)
    let initialReads = reads
    for _ in 0..<10_000 { expectFalse(scope.gate.isActive) }
    expectEqual(reads, initialReads, "Tap gate never calls AppKit/front resolver")
    front = "example.remote"
    center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    expectTrue(scope.gate.isActive)
    center.post(name: NSWorkspace.willSleepNotification, object: nil)
    expectFalse(scope.gate.isActive)
    center.post(name: NSWorkspace.didWakeNotification, object: nil)
    expectTrue(scope.gate.isActive)
    front = "example.local"
    center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    expectFalse(scope.gate.isActive)
    expectEqual(transitions, [true, false, true, false])
    scope.stop(); front = "example.remote"
    center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    expectFalse(scope.gate.isActive, "Stopped observers cannot reactivate a stale filter")
    scope.start { transitions.append($0) }
    expectTrue(scope.gate.isActive)
    scope.stop()
    expectEqual(transitions, [true, false, true, false, true, false])
    print("Target scope: cached refusal, foreground/sleep/wake transitions and observer stop/restart")
}

@MainActor func testInactiveSamplingSuspends() async throws {
    let board = NSPasteboard(name: .init("rdh-inactive-sampling-\(UUID())"))
    defer { board.releaseGlobally() }
    board.clearContents(); board.setString("original", forType: .string)
    var queries = 0
    let monitor = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(),
        targetPID: { queries += 1; return 101 }, isAvailable: { true },
        onCaptured: { _ in fail("No input was posted") }, onError: { fail("Unexpected failure: \($0)") })
    defer { monitor.stop() }
    monitor.setSamplingActive(true)
    expectTrue(queries > 0, "Entry into Screen Sharing starts a baseline immediately")
    monitor.setSamplingActive(false)
    let stopped = queries
    try await Task.sleep(for: .milliseconds(100))
    expectEqual(queries, stopped, "Local focus cancels the reader and the 20 ms foreground timer")
    monitor.setSamplingActive(true)
    expectTrue(queries > stopped, "Returning to the client starts fresh observation")
    monitor.setSamplingActive(false)
    print("Screen Sharing sampler: local focus suspends the timer and obsolete reads; return starts a fresh baseline")
}

private final class WatchdogFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var jobs: [MainQueueWatchdog.Ping] = []
    private var messages: [String] = []
    func setTime(_ value: TimeInterval) { lock.lock(); time = value; lock.unlock() }
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func enqueue(_ job: @escaping MainQueueWatchdog.Ping) { lock.lock(); jobs.append(job); lock.unlock() }
    func log(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
    var reports: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    func run() {
        lock.lock(); let job = jobs.removeFirst(); lock.unlock()
        job()
    }
}

func testMainQueueWatchdog() {
    let fixture = WatchdogFixture()
    let watchdog = MainQueueWatchdog(enqueue: { fixture.enqueue($0) }, now: { fixture.now() }, log: { fixture.log($0) })
    watchdog.tick()
    expectTrue(fixture.reports.isEmpty, "A queued ping does not prove main-queue responsiveness")
    fixture.setTime(3)
    for _ in 0..<20_000 { watchdog.tick() }
    expectEqual(fixture.count, 1, "The diagnostic itself cannot accumulate work on a hung main queue")
    expectEqual(fixture.reports.count, 1)
    expectTrue(fixture.reports[0].contains("main_queue_delayed elapsedMs=3000"))
    fixture.run()
    expectTrue(fixture.reports.last?.contains("main_queue_recovered elapsedMs=3000") == true)
    fixture.setTime(35)
    watchdog.tick(); fixture.run()
    expectEqual(fixture.count, 0)
    expectTrue(fixture.reports.last?.contains("heartbeat elapsedMs=0") == true)
    print("Main-queue watchdog: stalled queue is reported independently; one pending ping; recovery and healthy heartbeat")
}

@MainActor func testNativeWatchdogTimer() async throws {
    let fixture = WatchdogFixture()
    let watchdog = MainQueueWatchdog(log: { fixture.log($0) })
    watchdog.start()
    defer { watchdog.stop() }
    // Run the actual dispatch-source handler and main queue. A callback that
    // accidentally inherits MainActor isolation traps on the worker queue.
    for _ in 0..<100 {
        if fixture.reports.contains(where: { $0.contains("liveness.heartbeat") }) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    fail("The native watchdog timer did not complete a main-queue ping")
}
