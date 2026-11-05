import AppKit
import RemoteDictateCore

final class ClipboardTests {
    /// Model a remote consumer that reads 500 ms after key posting. The actual
    /// clipboard/lifetime code is used on a named board; delivery and consumption
    /// are simulated. This proves a possible ordering race, not the OS incident.
    @MainActor func testDelayedConsumerRetention() throws {
        let board = NSPasteboard(name: .init("rdh-delayed-consumer-\(UUID())"))
        defer { board.releaseGlobally() }
        for hold in [0.2, 2.0] {
            var clock: TimeInterval = 0
            var remoteText = "ORIGINAL", outcomes = 0
            let restore = LocalClipboardRestoration(board: board, access: eagerTestClipboardAccess(),
                now: { clock }, successfulPasteAllowance: hold, onOutcome: { outcome, receipt in
                    expectEqual(outcome, .restored); expectNotNil(receipt)
                    outcomes += 1
                    remoteText = board.string(forType: .string) ?? ""
                })
            func copy(_ value: String) { board.clearContents(); expectTrue(board.setString(value, forType: .string)) }
            copy("ORIGINAL")
            let original = try LocalClipboardSnapshot.capture(board)
            let session = try restore.begin(observedOriginal: original)
            let baseline = try restore.captureReplayBaseline(releasedRevision: board.changeCount, session: session)
            let payload = LocalClipboardSnapshot(items: [[.init(type: .string, data: Data("CURRENT".utf8))]])
            try restore.writeCapturedSnapshot(payload, text: "CURRENT", session: session, replacing: baseline)
            remoteText = "CURRENT" // Simulated delivery before the posted key is consumed.
            restore.recordPastePosted(session); restore.finish(session)
            clock = 0.5; restore.restoreIfDue()
            expectEqual(remoteText, hold < 0.5 ? "ORIGINAL" : "CURRENT")
            expectEqual(outcomes, hold < 0.5 ? 1 : 0)
            clock = 2; restore.restoreIfDue()
            expectEqual(outcomes, 1)
            expectEqual(try LocalClipboardSnapshot.capture(board), original)
            expectEqual(remoteText, "ORIGINAL")
        }
        print("Delayed consumer model: 200ms can expose original; 2s retains current at 500ms; exact single restoration, no real remote input")
    }

    @MainActor func testRestorationOwnershipFormatsAndDeadlines() throws {
        let board = NSPasteboard(name: .init("rdh-clipboard-\(UUID())")); defer { board.releaseGlobally() }
        var clock: TimeInterval = 0
        var outcomes: [LocalClipboardRestoration.Outcome] = []
        var receipt: LocalClipboardRestoration.Receipt?
        let restore = LocalClipboardRestoration(board: board, access: eagerTestClipboardAccess(), now: { clock },
            onOutcome: { outcomes.append($0); receipt = $1 })
        func copy(_ text: String, html: String? = nil) {
            let item = NSPasteboardItem(); expectTrue(item.setString(text, forType: .string))
            if let html { expectTrue(item.setData(Data(html.utf8), forType: .html)) }
            board.clearContents(); expectTrue(board.writeObjects([item]))
        }
        for success in [false, true] {
            for newCopy in [nil, "newer copy", "DICTATION-PRIVATE"] as [String?] {
                copy("ORIGINAL-PRIVATE", html: "<b>ORIGINAL-PRIVATE</b>")
                let original = try LocalClipboardSnapshot.capture(board)
                let originalRevision = board.changeCount
                let session = try restore.begin(observedOriginal: original)
                copy("DICTATION-PRIVATE", html: "<p>Текст</p>")
                let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: originalRevision, access: eagerTestClipboardAccess()))
                expectTrue(payload.encodingMarkerAdded)
                copy("ORIGINAL-PRIVATE") // Provider/bridge returns different formats.
                let baseline = try restore.captureReplayBaseline(releasedRevision: board.changeCount, session: session)
                try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: session, replacing: baseline)
                if success { restore.recordPastePosted(session) }
                let allowance: TimeInterval = success ? 2 : 5
                expectEqual(restore.allowance(for: session), allowance)
                let deadline = clock + allowance
                restore.finish(session)
                let count = outcomes.count
                clock = deadline - 0.01; restore.restoreIfDue()
                expectEqual(outcomes.count, count)
                if let newCopy { copy(newCopy) }
                clock = deadline; restore.restoreIfDue()
                if newCopy == nil {
                    expectEqual(outcomes.last, .restored)
                    expectEqual(try LocalClipboardSnapshot.capture(board), original)
                    try expectUnwrap(receipt).validate()
                    copy("ORIGINAL-PRIVATE")
                    expectThrows(try receipt?.validate(), "Even equal text with a new revision invalidates the receipt")
                } else {
                    expectEqual(outcomes.last, .skippedChanged)
                    expectEqual(board.string(forType: .string), newCopy)
                    expectNil(receipt)
                }
                let after = outcomes.count
                copy("copy after completion")
                clock += 20; restore.restoreIfDue()
                expectEqual(outcomes.count, after)
                expectEqual(board.string(forType: .string), "copy after completion", "Completed restoration never rewrites a later copy")
            }
        }
    }

    @MainActor func testRichMultilingualPayload() throws {
        let board = NSPasteboard(name: .init("rdh-rich-\(UUID())")); defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let baseline = board.changeCount
        let text = String(repeating: "Sample • Текст • 日本語 • 🌍\n1. First\n2. Second\n\n", count: 500)
        let html = Data(("<html><body><p>" + text + "</p></body></html>").utf8)
        let rtf = Data(#"{\rtf1\ansi Sample}"#.utf8)
        let item = NSPasteboardItem()
        expectTrue(item.setString(text, forType: .string))
        expectTrue(item.setData(html, forType: .html)); expectTrue(item.setData(rtf, forType: .rtf))
        board.clearContents(); expectTrue(board.writeObjects([item]))
        let untouched = try LocalClipboardSnapshot.capture(board)
        let revision = board.changeCount
        let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: baseline, access: eagerTestClipboardAccess()))
        expectEqual(payload.text, text, "No punctuation, whitespace or list rendering changes")
        expectTrue(payload.encodingMarkerAdded)
        expectEqual(board.changeCount, revision)
        expectEqual(try LocalClipboardSnapshot.capture(board), untouched, "Capture never rewrites local contents")
        expectEqual(payload.snapshot, untouched.markingUnlabelledHTMLUTF8())
        let bom = Data([0xef, 0xbb, 0xbf])
        expectEqual(ClipboardHTMLEncoding.markingUnlabelledUTF8(html), bom + html)
        for alreadySafe in [bom + html, Data("<p>ASCII</p>".utf8),
                            Data("<meta charset='utf-8'><p>Текст</p>".utf8),
                            Data("<meta charset='windows-1251'><p>Текст</p>".utf8),
                            Data([0xff, 0xfe, 0, 0]), Data([0x80, 0xff])] {
            expectEqual(ClipboardHTMLEncoding.markingUnlabelledUTF8(alreadySafe), alreadySafe)
        }
    }

    @MainActor func testEmptyOriginalAndReplayIsolation() throws {
        let board = NSPasteboard(name: .init("rdh-isolation-\(UUID())")); defer { board.releaseGlobally() }
        var clock: TimeInterval = 0
        let restore = LocalClipboardRestoration(board: board, access: eagerTestClipboardAccess(), now: { clock })
        board.clearContents()
        let empty = try LocalClipboardSnapshot.capture(board)
        let originalRevision = board.changeCount
        let first = try restore.begin(observedOriginal: empty)
        board.clearContents(); board.setString("text", forType: .string)
        let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: originalRevision, access: eagerTestClipboardAccess()))
        let baseline = try restore.captureReplayBaseline(releasedRevision: board.changeCount, session: first)
        let second = try restore.begin(observedOriginal: empty)
        expectThrows(try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: second, replacing: baseline))
        try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: first, replacing: baseline)
        restore.recordPastePosted(first); restore.finish(first); clock = 2; restore.restoreIfDue()
        expectEqual(try LocalClipboardSnapshot.capture(board), empty)
        expectThrows(try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: first, replacing: baseline))
        board.clearContents(); board.setString("oversized", forType: .string)
        expectThrows(try LocalClipboardSnapshot.capture(board, maximumBytes: 2))
    }
}
