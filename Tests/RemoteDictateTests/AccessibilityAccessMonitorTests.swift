import Foundation

private final class AccessCheckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var time: TimeInterval = 100
    private var mainThread = false
    private var blocked = false
    private var access: AccessibilityAccessState = .granted
    let release = DispatchSemaphore(value: 0)

    func configure(_ state: AccessibilityAccessState, block: Bool = false) {
        lock.withLock { access = state; blocked = block }
    }
    func advance(_ amount: TimeInterval) { lock.withLock { time += amount } }
    var now: TimeInterval { lock.withLock { time } }
    var count: Int { lock.withLock { calls } }
    var ranOnMain: Bool { lock.withLock { mainThread } }
    func check() -> AccessibilityAccessState {
        let (result, shouldBlock) = lock.withLock {
            calls += 1; mainThread = mainThread || Thread.isMainThread
            return (access, blocked)
        }
        // The result is captured BEFORE the wait to expose stale grant races.
        if shouldBlock { release.wait() }
        return result
    }
}

@MainActor private func awaitAccessCheck(_ condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { fail("Access check did not finish") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor func testLiveAccessibilityAccess() async throws {
    let probe = AccessCheckProbe()
    let monitor = AccessibilityAccessMonitor(poll: false, now: { probe.now }, check: { probe.check() })
    expectEqual(monitor.state, .checking)
    monitor.requestCheck()
    try await awaitAccessCheck { monitor.state == .granted }
    expectFalse(probe.ranOnMain, "The live OS check must never run on the UI thread")
    probe.advance(3)
    expectEqual(monitor.state, .unavailable, "Expired permission cannot authorize native input")
    for state in [AccessibilityAccessState.denied, .granted, .denied, .granted] {
        probe.configure(state)
        let refreshed = await monitor.refreshedState()
        expectEqual(refreshed, state)
    }

    // Native IPC may stall: UI/input reads remain immediate, no extra checks
    // accumulate, and an answer from before invalidation cannot revive a grant.
    let blockedProbe = AccessCheckProbe()
    blockedProbe.configure(.granted, block: true)
    let blockedMonitor = AccessibilityAccessMonitor(poll: false,
        now: { blockedProbe.now }, check: { blockedProbe.check() })
    blockedMonitor.requestCheck()
    try await awaitAccessCheck { blockedProbe.count == 1 }
    for _ in 0..<20_000 { blockedMonitor.requestCheck(); expectEqual(blockedMonitor.state, .checking) }
    expectEqual(blockedProbe.count, 1)
    let began = ProcessInfo.processInfo.systemUptime
    let timeout = await blockedMonitor.refreshedState(timeout: 0.04)
    expectEqual(timeout, .unavailable)
    expectTrue(ProcessInfo.processInfo.systemUptime - began < 1, "A stuck OS call cannot hold the caller")
    expectEqual(blockedProbe.count, 1)
    blockedProbe.configure(.denied)
    blockedProbe.release.signal()
    try await awaitAccessCheck {
        expectFalse(blockedMonitor.state == .granted, "An obsolete native grant must be discarded")
        return blockedMonitor.state == .denied
    }
    expectEqual(blockedProbe.count, 2, "Invalidations coalesce into one fresh check")
    print("Live Accessibility: revoke/regrant, expiry, bounded blocked checks, stale-result refusal and async navigation; injected permissions only")
}
