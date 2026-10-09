import AppKit

@MainActor
func testWindowsClipboardProbe() async throws {
    @MainActor final class Fixture {
        let board = NSPasteboard(name: .init("RDH-probe-test-" + UUID().uuidString))
        var time: TimeInterval = 0
        var target: pid_t? = 42
        var stamp: WindowsAppPasteMonitor.InputStamp? = .init(keys: 1, modifiers: 0)
        var windowValid = true
        var events: [CGEvent] = []
        var logs: [String] = []
        var pauses = 0
        var onPause: ((Int) -> Void)?
        var onPost: ((CGEvent) -> Void)?
        var onProtectedPause: (() -> Void)?
        var finished = false
        var refreshCalls = 0
        var onRefresh: (() -> Void)?
        var probe: WindowsClipboardProbe!
        init() throws {
            board.clearContents()
            let original = NSPasteboardItem()
            original.setString("private-original-test-value", forType: .string)
            original.setData(Data([0,1,2,255]), forType: .init("rdh.original-bytes"))
            expectTrue(board.writeObjects([original]))
            probe = WindowsClipboardProbe(board: board, access: eagerTestClipboardAccess(),
                target: { [unowned self] in target }, input: { [unowned self] in stamp },
                captureWindow: { [unowned self] _ in
                    return { [unowned self] in if !windowValid { throw WindowsClipboardProbe.Failure.changed } }
                }, ready: { _ in }, refreshFocus: { [unowned self] _, stable, target, _ in
                    try target(); refreshCalls += 1; onRefresh?()
                    try stable(); time += 0.08; try target()
                }, post: { [unowned self] event in
                    events.append(event); onPost?(event)
                }, now: { [unowned self] in time }, pause: { [unowned self] delay in
                    pauses += 1; time += delay; onPause?(pauses)
                    try Task.checkCancellation(); await Task.yield()
                }, protectedPause: { [unowned self] delay in time += delay; onProtectedPause?() },
                log: { [unowned self] in logs.append($0) }, finished: { [unowned self] restored in
                    expectTrue(restored); finished = true
                })
        }
        func wait() async {
            for _ in 0..<3000 {
                if !probe.isBusy { return }
                await Task.yield()
            }
            fail("Probe did not finish")
        }
        func dispose() { board.releaseGlobally() }
        var keys: [Int64] { events.map { $0.getIntegerValueField(.keyboardEventKeycode) } }
        func userCopy() {
            board.clearContents(); board.setString("user-copied-later", forType: .string)
        }
    }

    for mode: WindowsClipboardProbe.Mode in [.sustained, .transient] {
        let f = try Fixture(); defer { f.dispose() }
        let original = try LocalClipboardSnapshot.capture(f.board)
        var atPaste: String?
        f.onPost = { event in
            if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9 {
                atPaste = f.board.string(forType: .string)
            }
        }
        try f.probe.start(mode)
        expectThrows(try f.probe.start(mode), "Never overlap experiments")
        await f.wait()
        expectTrue(atPaste?.hasPrefix("RDH-NEW-") == true)
        expectEqual(f.keys, [55,9,9,55], "Exactly one production paste sequence")
        expectFalse(f.events.last!.flags.contains(.maskCommand))
        expectEqual(try LocalClipboardSnapshot.capture(f.board), original, "Restore every original format")
        let published = f.logs.first { $0.contains("stage=new-published") }!
        let restored = f.logs.first { $0.contains("stage=old-restored") }!
        func elapsed(_ line: String) -> Int {
            Int(line.components(separatedBy: "elapsedMs=")[1].split(separator: " ")[0])!
        }
        expectTrue(abs(elapsed(restored) - elapsed(published) - Int(mode.lifetime * 1000)) <= 1)
        expectTrue(f.finished)
        expectFalse(f.logs.joined().contains("private-original-test-value"), "Original contents never logged")
        expectTrue(f.logs.contains { $0.contains("remoteReceipt=unverified") })
    }

    let batch = try Fixture(); defer { batch.dispose() }
    let batchOriginal = try LocalClipboardSnapshot.capture(batch.board)
    var markers: [String] = []
    var pasteTimes: [TimeInterval] = []
    batch.onPost = { event in
        if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9 {
            markers.append(batch.board.string(forType: .string) ?? "")
            pasteTimes.append(batch.time)
        }
    }
    try batch.probe.start(.comparison); await batch.wait()
    expectEqual(batch.keys, Array(repeating: [Int64(55),9,9,55], count: 6).flatMap { $0 })
    expectEqual(Set(markers).count, 6, "Each scheduled trial has a fresh marker; never replay")
    expectEqual(try LocalClipboardSnapshot.capture(batch.board), batchOriginal)
    let published = batch.logs.filter { $0.contains("stage=new-published") }
    let restored = batch.logs.filter { $0.contains("stage=old-restored") }
    expectEqual(published.count, 6); expectEqual(restored.count, 6)
    func elapsedSeconds(_ line: String) -> TimeInterval {
        Double(line.components(separatedBy: "elapsedMs=")[1].split(separator: " ")[0])! / 1000
    }
    for (index, step) in WindowsClipboardProbe.Mode.comparison.steps.enumerated() {
        expectTrue(markers[index].hasSuffix("-\(index + 1)-\(step.label)\n"))
        expectTrue(abs(elapsedSeconds(restored[index]) - elapsedSeconds(published[index]) - step.lifetime) < 0.002)
        expectTrue(abs(pasteTimes[index] - elapsedSeconds(published[index]) - step.delay - 0.025) < 0.002)
    }
    expectTrue(batch.time < 35, "Bound the complete comparison after target acquisition")
    expectEqual(batch.refreshCalls, 0, "The timing experiment never changes focus")

    let focus = try Fixture(); defer { focus.dispose() }
    let focusOriginal = try LocalClipboardSnapshot.capture(focus.board)
    var focusMarkers: [String] = []
    focus.onPost = { event in
        if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9 {
            focusMarkers.append(focus.board.string(forType: .string) ?? "")
        }
    }
    try focus.probe.start(.focusComparison); await focus.wait()
    expectEqual(focus.refreshCalls, 3)
    expectEqual(focus.keys.count, 24)
    expectEqual(Set(focusMarkers).count, 6)
    for (index, marker) in focusMarkers.enumerated() {
        expectTrue(marker.hasSuffix(index.isMultiple(of: 2) ? "-DIRECT\n" : "-REFRESH\n"))
    }
    expectEqual(try LocalClipboardSnapshot.capture(focus.board), focusOriginal)
    expectTrue(focus.time < 45)

    for change in ["clipboard", "input", "modifiers", "window", "focus", "cancel"] {
        let f = try Fixture(); defer { f.dispose() }
        let original = try LocalClipboardSnapshot.capture(f.board)
        f.onRefresh = {
            switch change {
            case "clipboard": f.userCopy()
            case "input": f.stamp = .init(keys: 2, modifiers: 0)
            case "modifiers": f.stamp = .init(keys: 1, modifiers: 1)
            case "window": f.windowValid = false
            case "focus": f.target = 77
            default: f.probe.cancel()
            }
        }
        try f.probe.start(.focusComparison); await f.wait()
        expectEqual(f.keys, [55,9,9,55], "Refuse input after a changed focus experiment: \(change)")
        expectEqual(f.refreshCalls, 1)
        if change == "clipboard" { expectEqual(f.board.string(forType: .string), "user-copied-later") }
        else { expectEqual(try LocalClipboardSnapshot.capture(f.board), original) }
    }

    // Changes between trials must stop the whole series, even if a later
    // trial would have the same synthetic payload or the window returns.
    for change in ["clipboard", "focus", "window", "input", "filter", "cancel"] {
        let f = try Fixture(); defer { f.dispose() }
        let original = try LocalClipboardSnapshot.capture(f.board)
        f.onPause = { _ in
            guard f.logs.last?.contains("stage=old-restored trial=1 ") == true else { return }
            switch change {
            case "clipboard": f.userCopy()
            case "focus": f.target = nil
            case "window": f.windowValid = false
            case "input": f.stamp = .init(keys: 2, modifiers: 0)
            case "filter": f.stamp = nil
            default: f.probe.cancel()
            }
        }
        try f.probe.start(.comparison); await f.wait()
        expectEqual(f.keys, [55,9,9,55], "Stop remaining trials after \(change)")
        expectFalse(f.events.last!.flags.contains(.maskCommand))
        if change == "clipboard" { expectEqual(f.board.string(forType: .string), "user-copied-later") }
        else { expectEqual(try LocalClipboardSnapshot.capture(f.board), original) }
    }

    for change in ["clipboard", "focus", "window", "input", "filter"] {
        let f = try Fixture(); defer { f.dispose() }
        let original = try LocalClipboardSnapshot.capture(f.board)
        f.onPause = { n in
            guard n == 2 else { return } // after NEW, before any keys
            switch change {
            case "clipboard": f.userCopy()
            case "focus": f.target = 77
            case "window": f.windowValid = false
            case "input": f.stamp = .init(keys: 2, modifiers: 0)
            default: f.stamp = nil
            }
        }
        try f.probe.start(.sustained); await f.wait()
        expectTrue(f.events.isEmpty, "Changed context must never receive delayed test input")
        if change == "clipboard" { expectEqual(f.board.string(forType: .string), "user-copied-later") }
        else { expectEqual(try LocalClipboardSnapshot.capture(f.board), original) }
    }

    for afterV in [false, true] {
        let f = try Fixture(); defer { f.dispose() }
        let original = try LocalClipboardSnapshot.capture(f.board)
        f.onPost = { event in
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if key == (afterV ? 9 : 55), event.flags.contains(.maskCommand) { f.probe.cancel() }
        }
        try f.probe.start(.transient); await f.wait()
        expectEqual(f.keys, afterV ? [55,9,9,55] : [55,55])
        expectFalse(f.events.last!.flags.contains(.maskCommand), "Quit/cancel balances all pressed keys")
        if afterV { expectTrue(f.time >= 6, "Partial paste retains cleanup protection") }
        expectEqual(try LocalClipboardSnapshot.capture(f.board), original)
    }

    let changedDuringCleanup = try Fixture(); defer { changedDuringCleanup.dispose() }
    changedDuringCleanup.onProtectedPause = { changedDuringCleanup.userCopy() }
    try changedDuringCleanup.probe.start(.transient); await changedDuringCleanup.wait()
    expectEqual(changedDuringCleanup.board.string(forType: .string), "user-copied-later")

    let timeout = try Fixture(); defer { timeout.dispose() }
    let saved = try LocalClipboardSnapshot.capture(timeout.board)
    timeout.target = nil
    try timeout.probe.start(.sustained); await timeout.wait()
    expectTrue(timeout.events.isEmpty)
    expectTrue(timeout.time >= 20 && timeout.time < 21)
    expectEqual(try LocalClipboardSnapshot.capture(timeout.board), saved)

    let empty = try Fixture(); defer { empty.dispose() }
    empty.board.clearContents()
    try empty.probe.start(.sustained); await empty.wait()
    expectTrue((empty.board.pasteboardItems ?? []).isEmpty, "Preserve a truly empty original")
}
