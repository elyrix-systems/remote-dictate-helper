import AppKit

/// Fake provider failures on a named board, with an injected monotonic clock.
/// No timers, real input, foreground changes or general clipboard access.
@MainActor func testBaselineRecoveryBudget() async throws {
    let board = NSPasteboard(name: .init("rdh-baseline-recovery-\(UUID())"))
    defer { board.releaseGlobally() }
    var clock: TimeInterval = 0, reads = 0
    var providerError: Error? = IsolatedClipboardError.timedOut
    var target: pid_t? = 100
    var reports: [String] = [], captured: UUID?
    let access = ClipboardAccess(immediateRead: { board in
        reads += 1
        if let providerError { throw providerError }
        return .init(revision: board.changeCount, snapshot: try LocalClipboardSnapshot.capture(board),
                     text: board.string(forType: .string))
    })
    let monitor = DictationPasteMonitor(board: board, access: access, targetPID: { target },
        isAvailable: { true }, now: { clock }, onCaptured: { captured = $0 },
        onError: { fail("Unexpected capture error: \($0)") }, report: { reports.append($0) })
    defer { monitor.stop() }
    func copy(_ value: String) { board.clearContents(); expectTrue(board.setString(value, forType: .string)) }
    func attempt(expecting expected: Int) async throws {
        monitor.scheduleSample()
        for _ in 0..<100 {
            if reads == expected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        fail("Expected baseline read \(expected), saw \(reads); reports: \(reports)")
    }
    func refuseBurst() async {
        for _ in 0..<1_000 { monitor.scheduleSample() }
        await Task.yield()
    }
    copy("original")
    let originalRevision = board.changeCount
    try await attempt(expecting: 1)
    await refuseBurst(); expectEqual(reads, 1)
    clock = 0.499; await refuseBurst(); expectEqual(reads, 1)
    clock = 0.5; try await attempt(expecting: 2)
    clock = 2.499; await refuseBurst(); expectEqual(reads, 2)
    clock = 2.5; try await attempt(expecting: 3)
    clock = 7.499; await refuseBurst(); expectEqual(reads, 3)
    clock = 7.5; try await attempt(expecting: 4)
    clock = 1_000; await refuseBurst(); expectEqual(reads, 4, "Hung provider has a finite read budget")
    expectEqual(board.changeCount, originalRevision, "Sampling cannot publish or clear the clipboard")
    expectNil(captured)

    // The next clipboard version immediately gets its own budget.
    copy("next original"); try await attempt(expecting: 5)
    providerError = nil
    let recoveredRevision = board.changeCount
    clock += 0.5; try await attempt(expecting: 6)
    expectEqual(board.changeCount, recoveredRevision)
    expectTrue(reports.contains(where: { $0.contains("baseline recovered revision=\(recoveredRevision)") }))
    await refuseBurst(); expectEqual(reads, 6, "A recovered revision is cached, not polled for payloads")

    // Recovery must make the next real transaction usable, preserving the original.
    copy("Тест dictation")
    expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
    let id = try expectUnwrap(captured)
    expectTrue(monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)))
    copy("next original")
    let result = try expectUnwrap(monitor.completeIfReleased(id))
    expectEqual(result.original.text, "next original")
    expectEqual(result.original.revision, recoveredRevision)
    expectEqual(result.payload.text, "Тест dictation")
    monitor.discard(id); captured = nil

    // Deterministic size refusal does not retry, even after a long idle period.
    copy("oversized fixture"); providerError = LocalClipboardError.tooLarge
    let beforeSize = reads
    try await attempt(expecting: beforeSize + 1)
    clock += 100; await refuseBurst(); expectEqual(reads, beforeSize + 1)

    // Leaving the client suspends reads; a fresh visit can recover the same revision.
    target = nil; monitor.setSamplingActive(false)
    clock += 100; await refuseBurst(); expectEqual(reads, beforeSize + 1)
    target = 100; providerError = nil
    try await attempt(expecting: beforeSize + 2)
    expectNil(captured, "Recovery only observes baseline; it never replays a previous failed paste")
    print("Baseline recovery: spaced finite retries, same-revision recovery, exact original, new revision and context guards")
}
