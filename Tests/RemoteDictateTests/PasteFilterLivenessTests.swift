import AppKit
import RemoteDictateCore

private final class FilterCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var lookups = 0
    private var admissions = 0
    private var resolved = false
    func lookup() { lock.lock(); lookups += 1; lock.unlock() }
    func admission() { lock.lock(); admissions += 1; lock.unlock() }
    func resolution(_ value: Bool) { lock.lock(); resolved = value; lock.unlock() }
    var resolution: Bool { lock.lock(); defer { lock.unlock() }; return resolved }
    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (lookups, admissions)
    }
}

/// No real tap, applications, clipboard access or posted input. The resolver is
/// deliberately held after the deadline to reproduce an unresponsive OS lookup.
func testPasteFilterLiveness() async throws {
    let counters = FilterCounters()
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let source = AppSettings().sources[0]
    let filter = PasteEventFilter(sources: [source], onEvent: { _, decision in
        if let decision { counters.admission(); decision.resolve(true) }
    }, onDisabled: {}, sourceIdentifier: { _ in
        counters.lookup()
        _ = release.wait(timeout: .now() + 2)
        finished.signal()
        return source.bundleIdentifier
    })
    defer { release.signal(); filter.stop() }
    func event(_ key: UInt16, pid: pid_t = 202) throws -> CGEvent {
        let value = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
        value.flags = .maskCommand
        value.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
        return value
    }
    // Ordinary keys, physical paste and our own replay never resolve a bundle.
    expectFalse(filter.handle(type: .keyDown, event: try event(0)))
    expectFalse(filter.handle(type: .keyDown, event: try event(9, pid: 0)))
    expectFalse(filter.handle(type: .keyDown, event: try event(9, pid: ProcessInfo.processInfo.processIdentifier)))
    expectEqual(counters.counts.0, 0)
    let started = ProcessInfo.processInfo.systemUptime
    expectFalse(filter.handle(type: .keyDown, event: try event(9)))
    expectTrue(ProcessInfo.processInfo.systemUptime - started < 0.35,
               "A two-second source lookup must not hold the event stream")
    // The stuck lookup occupies one slot; more input must not queue more work.
    for _ in 0..<20 {
        expectFalse(filter.handle(type: .keyDown, event: try event(9)))
        expectFalse(filter.handle(type: .keyDown, event: try event(0)))
    }
    expectEqual(counters.counts.0, 1)
    filter.stop()
    // Restarting a client cannot queue another OS lookup behind the stuck one.
    let replacement = PasteEventFilter(sources: [source], onEvent: { _, _ in },
        onDisabled: {}, sourceIdentifier: { _ in counters.lookup(); return source.bundleIdentifier })
    defer { replacement.stop() }
    expectFalse(replacement.handle(type: .keyDown, event: try event(9)))
    expectEqual(counters.counts.0, 1)
    release.signal()
    expectEqual(finished.wait(timeout: .now() + 1), .success)
    try await Task.sleep(for: .milliseconds(100))
    expectEqual(counters.counts.1, 0, "A late identity result cannot request a deferred capture")
    print("Paste filter liveness: blocked source lookup is bounded; ordinary input bypasses lookup; no queued or late capture")
}

func testBlockedAdmissionLiveness() async throws {
    let counters = FilterCounters()
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let source = AppSettings().sources[0]
    let filter = PasteEventFilter(sources: [source], onEvent: { _, decision in
        guard let decision else { return }
        counters.admission()
        _ = release.wait(timeout: .now() + 2)
        counters.resolution(decision.resolve(true))
        finished.signal()
    }, onDisabled: {}, sourceIdentifier: { _ in source.bundleIdentifier })
    defer { release.signal(); filter.stop() }
    let event = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
    event.flags = .maskCommand
    event.setIntegerValueField(.eventSourceUnixProcessID, value: 202)
    let started = ProcessInfo.processInfo.systemUptime
    expectFalse(filter.handle(type: .keyDown, event: event))
    expectTrue(ProcessInfo.processInfo.systemUptime - started < 0.35,
               "A stalled admission callback must not hold the event stream")
    expectEqual(counters.counts.1, 1)
    filter.stop()
    release.signal()
    expectEqual(finished.wait(timeout: .now() + 1), .success)
    expectFalse(counters.resolution, "A stopped/expired capture cannot commit late")
    print("Paste filter liveness: blocked admission releases input; stopped/expired work cannot accept late")
}

@MainActor func testLateAdmissionCannotReplay() async throws {
    // An OS call made by admission itself stalls the main actor, while the tap
    // is free to expire independently. Neither adapter may then commit/replay.
    let sourceEvent = PasteInputEvent(kind: .down, key: 9, command: true, pid: 202, fromDictation: true)
    var captured = 0
    let windows = WindowsAppPasteMonitor(sources: AppSettings().sources, isAvailable: { true },
        targetPID: { usleep(120_000); return 101 }, revision: { 1 },
        prepareClipboard: { _ in fail("Late admission must not even start a reader") },
        isTrusted: { true }, captureWindow: { _ in { } },
        post: { _ in fail("Expired Windows capture cannot post any input") }, onCaptured: { captured += 1 })
    let decision = PasteCaptureDecision(wait: 0.02)
    expectFalse(windows.observe(sourceEvent, decision: decision))
    expectFalse(decision.wait()); expectFalse(windows.isBusy); expectEqual(captured, 0)

    let board = NSPasteboard(name: .init("rdh-late-admission-\(UUID())"))
    defer { board.releaseGlobally() }
    var stall = false
    let screen = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(),
        targetPID: { if stall { usleep(120_000) }; return 101 }, isAvailable: { true },
        onCaptured: { _ in captured += 1 }, onError: { fail("Unexpected error: \($0)") })
    board.clearContents(); board.setString("original", forType: .string); screen.sample()
    board.clearContents(); board.setString("dictation", forType: .string)
    stall = true
    let screenDecision = PasteCaptureDecision(wait: 0.02)
    expectFalse(screen.observe(sourceEvent, decision: screenDecision))
    expectFalse(screenDecision.wait()); expectEqual(captured, 0)
    await Task.yield()
    expectEqual(captured, 0, "Neither adapter schedules a late transaction")
    print("Both adapters refuse late admission after a stalled OS check; no reader, keys or capture callback")
}
