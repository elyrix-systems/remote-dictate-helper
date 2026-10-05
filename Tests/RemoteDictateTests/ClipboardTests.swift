import AppKit
import RemoteDictateCore

final class ClipboardTests {
    @MainActor func testRestorationOwnershipFormatsAndDeadlines() throws {
        let board = NSPasteboard(name: .init("rdh-clipboard-\(UUID())")); defer { board.releaseGlobally() }
        var clock: TimeInterval = 0
        var outcomes: [LocalClipboardRestoration.Outcome] = []
        var receipt: LocalClipboardRestoration.Receipt?
        let restore = LocalClipboardRestoration(board: board, now: { clock },
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
                let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: originalRevision))
                expectTrue(payload.encodingMarkerAdded)
                copy("ORIGINAL-PRIVATE") // Provider/bridge returns different formats.
                let baseline = try restore.captureReplayBaseline(releasedRevision: board.changeCount, session: session)
                try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: session, replacing: baseline)
                if success { restore.recordPastePosted(session) }
                let allowance: TimeInterval = success ? 0.2 : 5
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
        let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: baseline))
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
        let restore = LocalClipboardRestoration(board: board, now: { clock })
        board.clearContents()
        let empty = try LocalClipboardSnapshot.capture(board)
        let originalRevision = board.changeCount
        let first = try restore.begin(observedOriginal: empty)
        board.clearContents(); board.setString("text", forType: .string)
        let payload = try expectUnwrap(CapturedClipboard.read(from: board, after: originalRevision))
        let baseline = try restore.captureReplayBaseline(releasedRevision: board.changeCount, session: first)
        let second = try restore.begin(observedOriginal: empty)
        expectThrows(try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: second, replacing: baseline))
        try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: first, replacing: baseline)
        restore.recordPastePosted(first); restore.finish(first); clock = 0.2; restore.restoreIfDue()
        expectEqual(try LocalClipboardSnapshot.capture(board), empty)
        expectThrows(try restore.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: first, replacing: baseline))
        board.clearContents(); board.setString("oversized", forType: .string)
        expectThrows(try LocalClipboardSnapshot.capture(board, maximumBytes: 2))
    }
}
