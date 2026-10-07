import AppKit
import RemoteDictateCore

final class InterceptionTests {
    @MainActor func testAllConfiguredSources() throws {
        let board = NSPasteboard(name: .init("rdh-source-contract-\(UUID())"))
        defer { board.releaseGlobally() }
        for source in SourceInputHarness.sources {
            for suffix in ["", ".helper"] {
                for policy in ClipboardReturnPolicy.allCases {
                    var selected = source; selected.clipboardReturn = policy
                    var id: UUID?
                    let monitor = DictationPasteMonitor(board: board, targetPID: { 100 }, isAvailable: { true },
                        sources: [selected], onCaptured: { id = $0 }, onError: { fail("\($0)") })
                    let input = SourceInputHarness(sources: [selected], identifier: source.bundleIdentifier + suffix) {
                        monitor.observe($0)
                    }
                    for _ in 0..<2 {
                        board.clearContents(); expectTrue(board.setString("original", forType: .string))
                        monitor.sample()
                        board.clearContents(); expectTrue(board.setString("dictation", forType: .string))
                        expectTrue(try input.paste(down: true)); expectTrue(try input.paste(down: false))
                        let captured = try expectUnwrap(id)
                        if policy == .restoresPrevious {
                            expectNil(try monitor.completeIfReleased(captured))
                            board.clearContents(); expectTrue(board.setString("original", forType: .string))
                        }
                        let result = try expectUnwrap(monitor.completeIfReleased(captured))
                        expectEqual(result.payload.text, "dictation")
                        expectEqual(result.original.text, "original")
                        monitor.discard(captured); id = nil
                    }
                    monitor.stop()
                }
            }
        }
        print("Screen Sharing source contract passed: all default/custom sources and helper IDs share capture and clipboard-return policies; named clipboard only")
    }

    @MainActor func testSuppressionScopeAndRelease() throws {
        let board = NSPasteboard(name: .init("rdh-intercept-\(UUID())")); defer { board.releaseGlobally() }
        var target: pid_t? = 100
        var available = true
        var ids: [UUID] = []; var errors: [Error] = []
        let monitor = DictationPasteMonitor(board: board, targetPID: { target }, isAvailable: { available },
            onCaptured: { ids.append($0) }, onError: { errors.append($0) })
        let down = DictationPasteMonitor.Event(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)
        let up = DictationPasteMonitor.Event(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)
        func copy(_ text: String) { board.clearContents(); expectTrue(board.setString(text, forType: .string)) }
        func arm(_ text: String = "dictation") { copy("original"); monitor.sample(); copy(text) }
        // Physical/manual paste, unknown app, our own replay, local target,
        // unavailable work and whitespace remain unmodified.
        arm()
        expectFalse(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 7, fromDictation: false)))
        expectFalse(monitor.observe(.init(kind: .down, key: 9, command: true, pid: ProcessInfo.processInfo.processIdentifier, fromDictation: true)))
        target = nil; expectFalse(monitor.observe(down)); target = 100
        available = false; expectFalse(monitor.observe(down)); available = true
        arm("  \n"); expectFalse(monitor.observe(down)); expectFalse(monitor.observe(up))
        expectTrue(ids.isEmpty)
        arm()
        expectTrue(monitor.observe(down))
        let id = try expectUnwrap(ids.last)
        expectNil(try monitor.completeIfReleased(id))
        expectFalse(monitor.observe(.init(kind: .up, key: 9, command: true, pid: 7, fromDictation: false)))
        expectTrue(monitor.observe(up))
        expectFalse(monitor.observe(up), "Do not remove unrelated later key-ups")
        expectNil(try monitor.completeIfReleased(id), "Restoring apps must release the actual revision")
        copy("original")
        let result = try expectUnwrap(monitor.completeIfReleased(id))
        expectEqual(result.payload.text, "dictation")
        monitor.discard(id)
        // The same text in a fresh revision is another transaction.
        arm(); expectTrue(monitor.observe(down)); expectEqual(ids.count, 2)
        target = nil
        expectTrue(monitor.observe(up), "Balance the removed down even after focus leaves")
        expectThrows(try monitor.completeIfReleased(ids.last!))
        monitor.discard(ids.last!); target = 100
        arm(); expectTrue(monitor.observe(down))
        monitor.filterDisabled()
        expectFalse(monitor.observe(up))
        expectThrows(try monitor.completeIfReleased(ids.last!))
        monitor.discard(ids.last!)
        arm(); expectFalse(monitor.observe(down), "Do not silently resume or switch to deletion")
        monitor.stop()
    }

    @MainActor func testAppThatLeavesItsTranscript() throws {
        let board = NSPasteboard(name: .init("rdh-keeps-\(UUID())")); defer { board.releaseGlobally() }
        var id: UUID?
        let monitor = DictationPasteMonitor(board: board, targetPID: { 100 }, isAvailable: { true },
            onCaptured: { id = $0 }, onError: { fail("\($0)") })
        board.clearContents(); board.setString("old", forType: .string); monitor.sample()
        board.clearContents(); board.setString("new", forType: .string)
        let revision = board.changeCount
        expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true, clipboardReturn: .keepsTranscript)))
        expectTrue(monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)))
        let result = try expectUnwrap(monitor.completeIfReleased(try expectUnwrap(id)))
        expectEqual(result.original.text, "old")
        expectEqual(result.releasedRevision, revision)
        expectEqual(result.payload.text, "new")
        monitor.stop()
    }

    @MainActor func testSlowCapturePassesOriginalThrough() {
        let board = NSPasteboard(name: .init("rdh-slow-\(UUID())")); defer { board.releaseGlobally() }
        var clock: TimeInterval = 0; var errors = 0
        let monitor = DictationPasteMonitor(board: board, targetPID: { 100 }, isAvailable: { true },
            now: { clock += 0.2; return clock }, onCaptured: { _ in fail("Slow capture must not suppress") }, onError: { _ in errors += 1 })
        board.clearContents(); board.setString("old", forType: .string); monitor.sample()
        board.clearContents(); board.setString("new", forType: .string)
        expectFalse(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
        expectEqual(errors, 1)
    }

    @MainActor func testInterceptedReplayNeverDeletes() {
        var keys: [Int64] = []
        let paste = ExplicitPasteShortcut(isolatedSoftwareCommand: true, isTrusted: { true },
            targetIsFrontmost: { _ in true }, flags: { [] }, hardwareFlags: { [] },
            post: { keys.append($0.getIntegerValueField(.keyboardEventKeycode)) })
        let result = GuardedPaste().run(targetPID: 100, shortcut: paste, validateBeforeInput: {})
        expectTrue(result.didRun)
        expectEqual(keys, [55, 9, 9, 55])
    }
}
