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
                }, ready: { _ in }, post: { [unowned self] event in
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

    for mode in WindowsClipboardProbe.Mode.allCases {
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
