import AppKit

final class EmptyClipboardReturnTests {
    @MainActor func testEmptyTextReturnAndExactRestoration() throws {
        let board = NSPasteboard(name: .init("rdh-empty-return-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var time: TimeInterval = 0
        var captures: [UUID] = []
        var errors: [Error] = []
        let monitor = DictationPasteMonitor(board: board, targetPID: { 100 }, isAvailable: { true },
            now: { time }, onCaptured: { captures.append($0) }, onError: { errors.append($0) })
        let down = DictationPasteMonitor.Event(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)
        let up = DictationPasteMonitor.Event(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)
        var outcomes: [LocalClipboardRestoration.Outcome] = []
        let restore = LocalClipboardRestoration(board: board, now: { time }, onOutcome: { outcome, receipt in
            outcomes.append(outcome)
            expectNotNil(receipt)
            do { try receipt?.validate() } catch { fail("Empty original receipt must validate") }
        })
        func copy(_ text: String) {
            let item = NSPasteboardItem()
            expectTrue(item.setString(text, forType: .string))
            board.clearContents()
            expectTrue(board.writeObjects([item]))
        }

        board.clearContents()
        // Reproduce the observed sequence using a disposable board: zero items
        // before dictation, then a single zero-byte UTF-8 item on source return.
        // Repeat after restoration to protect the next dictation as well.
        for attempt in 1...2 {
            let original = try LocalClipboardSnapshot.capture(board)
            expectTrue(original.items.isEmpty)
            expectNil(board.string(forType: .string))
            monitor.sample()
            copy("Synthetic dictation \(attempt)")
            expectTrue(monitor.observe(down))
            expectTrue(errors.isEmpty)
            expectEqual(captures.count, attempt)
            let id = try expectUnwrap(captures.last)
            expectNil(try monitor.completeIfReleased(id))
            expectTrue(monitor.observe(up))
            expectNil(try monitor.completeIfReleased(id), "Key-up alone must not authorize replay")
            time += 0.5
            copy("")
            let returned = try LocalClipboardSnapshot.capture(board)
            expectEqual(returned.items, [[.init(type: .string, data: Data())]])
            let result = try expectUnwrap(monitor.completeIfReleased(id))
            expectEqual(result.payload.text, "Synthetic dictation \(attempt)")
            expectEqual(result.original.snapshot, original)
            expectEqual(result.releasedRevision, board.changeCount)

            let session = try restore.begin(observedOriginal: result.original.snapshot)
            let baseline = try restore.captureReplayBaseline(releasedRevision: result.releasedRevision, session: session)
            try restore.writeCapturedSnapshot(result.payload.snapshot, text: result.payload.text, session: session, replacing: baseline)
            expectEqual(board.string(forType: .string), result.payload.text)
            // Model successful posting; no real input is sent by this test.
            restore.recordPastePosted(session)
            restore.finish(session)
            time += 0.2
            restore.restoreIfDue()
            expectEqual(outcomes.count, attempt)
            expectEqual(outcomes.last, .restored)
            expectEqual(try LocalClipboardSnapshot.capture(board), original)
            expectNil(board.string(forType: .string), "Restore zero items, not the source's empty text item")
            monitor.discard(id)
        }
        print("empty clipboard return passed: capture, source release, replay ownership and exact empty restoration, twice; no actual input")
    }

    func testEmptyReturnDoesNotAcceptUnknownContent() throws {
        typealias Snapshot = LocalClipboardSnapshot
        typealias Entry = ClipboardBaselineHistory.Entry
        let empty = Entry(revision: 1, snapshot: Snapshot(items: []), text: nil)
        let emptyText = Snapshot(items: [[.init(type: .string, data: Data())]])
        let copiedText = Entry(revision: 2,
            snapshot: Snapshot(items: [[.init(type: .string, data: Data("original".utf8))]]), text: "original")
        let nonText = Entry(revision: 2,
            snapshot: Snapshot(items: [[.init(type: .png, data: Data([1, 2, 3]))]]), text: nil)

        for candidates in [[], [copiedText], [nonText], [empty, copiedText], [empty, nonText]] {
            expectThrows(try ClipboardBaselineHistory.resolve(candidates, returned: emptyText, text: ""),
                "An empty return needs a latest original with zero items")
        }
        for (returned, text): (Snapshot, String?) in [
            (emptyText, nil),
            (Snapshot(items: [[.init(type: .string, data: Data(" ".utf8))]]), " "),
            (Snapshot(items: [[.init(type: .string, data: Data("unknown".utf8))]]), "unknown"),
            (Snapshot(items: [[.init(type: .png, data: Data())]]), nil),
            (Snapshot(items: [[.init(type: .string, data: Data()), .init(type: .html, data: Data())]]), ""),
            (Snapshot(items: [emptyText.items[0], emptyText.items[0]]), "")
        ] {
            expectThrows(try ClipboardBaselineHistory.resolve([empty], returned: returned, text: text),
                "Do not equate whitespace, unknown formats or multiple items with an empty original")
        }
        let olderEmptyText = Entry(revision: 0, snapshot: emptyText, text: "")
        let resolved = try ClipboardBaselineHistory.resolve([olderEmptyText, empty], returned: emptyText, text: "")
        expectEqual(resolved.revision, empty.revision, "Prefer the latest empty original to an older text representation")
        expectEqual(resolved.snapshot, empty.snapshot)
        print("empty clipboard matching guards passed: latest empty original only, no unknown content or format loss")
    }
}
