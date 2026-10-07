import AppKit
import RemoteDictateCore

// Deterministic input metadata + disposable named pasteboard. No .general,
// global monitor, actual keystrokes, Screen Sharing, Flow or permission prompts.
final class CaptureTests {
    @MainActor func testCaptureLifecycle() throws {
        let board = NSPasteboard(name: .init("rdh-capture-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var target: pid_t? = 100
        var available = true
        var time: TimeInterval = 0
        var captures: [UUID] = []
        var errors: [Error] = []
        let monitor = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(), targetPID: { target }, isAvailable: { available },
            now: { time }, onCaptured: { captures.append($0) }, onError: { errors.append($0) })
        let down = DictationPasteMonitor.Event(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)
        let up = DictationPasteMonitor.Event(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)
        func copy(_ text: String, rich: Bool = false) {
            let item = NSPasteboardItem()
            precondition(item.setString(text, forType: .string))
            if rich { precondition(item.setData(Data("<b>original</b>".utf8), forType: .html)) }
            board.clearContents()
            precondition(board.writeObjects([item]))
        }
        func check(_ value: Bool) { precondition(value) }
        func refuse(_ body: () throws -> Void) {
            do { try body(); fatalError("Expected refusal") } catch {}
        }
        func setup(_ marker: String = "original") {
            monitor.stop()
            target = 100; available = true; time = 0
            captures.removeAll(); errors.removeAll()
            copy(marker, rich: true)
            monitor.sample()
        }
        func capture(_ text: String = "Один и тот же текст\n1. Первый\n2. Второй") -> UUID {
            copy(text)
            monitor.observe(down)
            precondition(errors.isEmpty && captures.count == 1)
            return captures[0]
        }

        // Actual input source + context filter. Equal text is not a trigger.
        setup()
        copy("payload")
        for event in [
            DictationPasteMonitor.Event(kind: .down, key: 9, command: true, pid: 7, fromDictation: false),
            DictationPasteMonitor.Event(kind: .down, key: 8, command: true, pid: 42, fromDictation: true),
            DictationPasteMonitor.Event(kind: .down, key: 9, command: false, pid: 42, fromDictation: true), up
        ] { monitor.observe(event) }
        precondition(captures.isEmpty && errors.isEmpty)
        target = nil; monitor.observe(down)
        precondition(captures.isEmpty && errors.isEmpty)
        target = 100; available = false; monitor.observe(down)
        precondition(captures.isEmpty && errors.isEmpty)
        available = true; monitor.observe(down)
        precondition(captures.isEmpty, "A busy attempt must never be queued for a later caret")

        for blank in ["", " \n\t"] {
            setup(); copy(blank); monitor.observe(down)
            precondition(captures.isEmpty && errors.isEmpty)
        }
        // Two distinct transactions with exactly identical text both work.
        setup()
        for marker in ["old A", "new B"] {
            captures.removeAll()
            copy(marker, rich: true)
            monitor.sample()
            let original = try LocalClipboardSnapshot.capture(board)
            // A poll may already have seen Flow's payload before its V event.
            copy("same payload"); monitor.sample(); monitor.observe(down)
            precondition(captures.count == 1)
            let id = captures[0]
            try check(monitor.completeIfReleased(id) == nil)
            monitor.observe(up)
            try check(monitor.completeIfReleased(id) == nil)
            copy(marker) // Flow/bridge returned text, with different formats.
            let result = try monitor.completeIfReleased(id)!
            precondition(result.payload.text == "same payload" && result.original.snapshot == original)
            let restore = LocalClipboardRestoration(board: board, access: eagerTestClipboardAccess(), now: { time })
            let session = try restore.begin(observedOriginal: result.original.snapshot)
            let baseline = try restore.captureReplayBaseline(releasedRevision: result.releasedRevision, session: session)
            try restore.writeCapturedSnapshot(result.payload.snapshot, text: result.payload.text, session: session, replacing: baseline)
            restore.finish(session)
            time += 5; restore.restoreIfDue()
            try check(LocalClipboardSnapshot.capture(board) == original)
            monitor.discard(id)
        }

        // Newer copy before dictation becomes the original; never keep A from
        // the time the monitor was enabled. Prefer B's most recent formats.
        setup("A"); copy("B"); monitor.sample()
        let b = try LocalClipboardSnapshot.capture(board)
        let idB = capture(); monitor.observe(up); copy("B")
        try check(monitor.completeIfReleased(idB)?.original.snapshot == b)
        monitor.discard(idB)

        setup(); let unknown = capture(); monitor.observe(up); copy("unknown remote return")
        refuse { _ = try monitor.completeIfReleased(unknown) }
        setup(); let changed = capture(); monitor.observe(up); target = nil
        refuse { _ = try monitor.completeIfReleased(changed) }
        monitor.discard(changed) // Same cancellation cleanup as the app task.
        target = 100; copy("original")
        refuse { _ = try monitor.completeIfReleased(changed) }
        precondition(captures.count == 1, "Returning to Screen Sharing must not requeue the abandoned paste")
        setup(); let input = capture()
        monitor.observe(.init(kind: .mouse, key: 0, command: false, pid: 7, fromDictation: false))
        refuse { _ = try monitor.completeIfReleased(input) }
        setup(); let typed = capture()
        monitor.observe(.init(kind: .down, key: 123, command: false, pid: 7, fromDictation: false))
        refuse { try monitor.validate(typed) }
        setup(); let timeout = capture(); time = 5
        refuse { _ = try monitor.completeIfReleased(timeout) }
        setup(); let stopped = capture(); monitor.stop()
        refuse { _ = try monitor.completeIfReleased(stopped) }
        setup(); let secondPaste = capture(); monitor.observe(down)
        refuse { _ = try monitor.completeIfReleased(secondPaste) }

        // A later user copy invalidates replay, including equal text.
        setup(); let late = capture(); monitor.observe(up); copy("original")
        let released = try monitor.completeIfReleased(late)!
        let restore = LocalClipboardRestoration(board: board, access: eagerTestClipboardAccess())
        let session = try restore.begin(observedOriginal: released.original.snapshot)
        let baseline = try restore.captureReplayBaseline(releasedRevision: released.releasedRevision, session: session)
        copy("original")
        refuse { try restore.writeCapturedSnapshot(released.payload.snapshot, text: released.payload.text, session: session, replacing: baseline) }
        monitor.discard(late)

        // Bounded snapshot retention and loss of target clear old candidates.
        var small = ClipboardBaselineHistory(maximumBytes: 1024, maximumEntries: 2)
        for value in ["one", "two", "three"] { copy(value); try small.sample(board, access: eagerTestClipboardAccess()) }
        precondition(small.entries.count == 2 && small.entries.first?.text == "two")
        setup(); target = nil; monitor.sample(); target = 100
        copy("payload"); monitor.observe(down)
        precondition(captures.isEmpty && errors.count == 1)
        print("capture tests passed: source/context, repeated text, empty results, original selection/restore, revisions, input/focus/cancellation, bounded RAM history; no actual input")
    }
}
