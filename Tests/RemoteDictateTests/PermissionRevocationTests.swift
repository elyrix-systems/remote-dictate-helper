import AppKit
import RemoteDictateCore

private final class RevocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = true
    private var values: [String] = []
    private weak var filter: PasteEventFilter?
    private var decision: PasteCaptureDecision?
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var isTrusted: Bool { lock.lock(); defer { lock.unlock() }; return trusted }
    func revoke() { lock.lock(); trusted = false; lock.unlock() }
    func setFilter(_ value: PasteEventFilter) { lock.lock(); filter = value; lock.unlock() }
    func revokeDuringAdmission(_ value: PasteCaptureDecision) {
        lock.lock(); decision = value; trusted = false; let current = filter; lock.unlock()
        // Resolve first to exercise withdrawal of a result not yet returned to
        // the tap. Retirement must also refuse every later attempt to resolve.
        value.resolve(true)
        current?.checkPermission()
    }
    var lateAcceptance: Bool {
        lock.lock(); let current = decision; lock.unlock()
        return current?.resolve(true) ?? true
    }
}

/// A real owned Mach port/source, not a session event tap. This exercises the
/// Core Foundation invalidation contract without TCC changes or real input.
private final class DisposablePort: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    init() throws {
        var context = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        port = try expectUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil))
        source = try expectUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
    }
    func disconnect() { CFMachPortInvalidate(port) }
    deinit { CFMachPortInvalidate(port) }
}

private func revocationEvent(_ type: CGEventType = .keyDown, pid: pid_t = 202) throws -> CGEvent {
    let event = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: type == .keyDown))
    event.flags = .maskCommand
    event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
    return event
}

@MainActor func testPermissionRevocationSafety() throws {
    let source = AppSettings().sources[0]
    for reason in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
        let probe = RevocationProbe(), owned = try DisposablePort()
        let filter = PasteEventFilter(sources: [source], onEvent: { _, decision in decision?.resolve(true) },
            onDisabled: {
                expectFalse(CFMachPortIsValid(owned.port), "Native disconnection must precede UI notification")
                expectFalse(CFRunLoopSourceIsValid(owned.source))
                probe.record("disabled")
            }, sourceIdentifier: { _ in source.bundleIdentifier })
        expectTrue(filter.installTap { owned.disconnect(); probe.record("disconnect") })
        // Accepted down would normally suppress its matching up even after a
        // focus change. Revocation must discard this pairing too.
        expectTrue(filter.handle(type: .keyDown, event: try revocationEvent()))
        let retired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let event = try revocationEvent()
                expectFalse(filter.handle(type: reason, event: event))
            } catch { fail("Could not construct synthetic event: \(error)") }
            retired.signal()
        }
        // Deliberately prevent main-actor progress: teardown runs on the input
        // worker before any queued UI cleanup can execute.
        expectEqual(retired.wait(timeout: .now() + 1), .success)
        expectTrue(filter.isStopped)
        for _ in 0..<1_000 {
            expectFalse(filter.handle(type: reason, event: try revocationEvent()))
            expectFalse(filter.handle(type: .keyUp, event: try revocationEvent(.keyUp)))
            expectFalse(filter.handle(type: .keyDown, event: try revocationEvent()))
            expectFalse(filter.handle(type: .leftMouseDown, event: try revocationEvent(.leftMouseDown, pid: 0)))
        }
        filter.stop()
        expectEqual(probe.events, ["disconnect", "disabled"], "Disconnect and UI notification happen once")
    }

    let probe = RevocationProbe()
    let filter = PasteEventFilter(sources: [source], onEvent: { _, decision in
        if let decision { probe.revokeDuringAdmission(decision) }
    }, onDisabled: { probe.record("disabled") }, permissionCheck: { probe.isTrusted },
        sourceIdentifier: { _ in source.bundleIdentifier })
    probe.setFilter(filter)
    expectTrue(filter.installTap { probe.record("disconnect") })
    filter.checkPermission()
    expectTrue(probe.events.isEmpty)
    expectFalse(filter.handle(type: .keyDown, event: try revocationEvent()), "Revocation withdraws even an accepted pending decision")
    expectFalse(probe.lateAcceptance)
    expectEqual(probe.events, ["disconnect", "disabled"])
    for _ in 0..<1_000 { filter.checkPermission() }
    expectEqual(probe.events, ["disconnect", "disabled"])

    let late = RevocationProbe()
    let stopped = PasteEventFilter(sources: [], onEvent: { _, _ in fail("Stopped filter delivered input") },
        onDisabled: { late.record("disabled") }, permissionCheck: { late.isTrusted })
    stopped.stop()
    expectFalse(stopped.installTap { late.record("disconnect") }, "Stop-before-creation must retire late native resources")
    late.revoke(); stopped.checkPermission(); stopped.stop()
    expectEqual(late.events, ["disconnect"], "Normal stop must not notify a stale UI callback")
    print("Permission revocation: immediate native port/source invalidation, paired-key pass-through, bounded notifications, cancelled admission and late setup cleanup; no TCC changes or real input")
}

@MainActor func testDisabledScreenSamplerStops() async throws {
    let board = NSPasteboard(name: .init("rdh-revoked-\(UUID())"))
    defer { board.releaseGlobally() }
    var reads = 0, errors = 0
    let access = ClipboardAccess(immediateRead: { _ in reads += 1; throw IsolatedClipboardError.unavailable })
    let monitor = DictationPasteMonitor(board: board, access: access, targetPID: { 100 }, isAvailable: { true },
        onCaptured: { _ in fail("Disabled sampler cannot capture") }, onError: { _ in errors += 1 })
    monitor.setSamplingActive(true)
    monitor.filterDisabled()
    let before = reads
    for _ in 0..<1_000 { monitor.filterDisabled(); monitor.scheduleSample() }
    try await Task.sleep(for: .milliseconds(60))
    expectEqual(reads, before, "No polling or provider reads after a disabled filter")
    expectEqual(errors, 1)
    expectThrows(try monitor.validate(UUID()))
    monitor.stop()
    print("Disabled Screen Sharing monitor stops sampling and reports once; named board only")
}
