import AppKit

final class ReleaseTests {
    @MainActor func testReturnBeforePasteStartsFreshTransaction() throws {
        let board = NSPasteboard(name: .init("rdh-focus-return-\(UUID())")); defer { board.releaseGlobally() }
        var target: pid_t? = 100
        var clock: TimeInterval = 0
        var captured: UUID?
        let monitor = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(), targetPID: { target }, isAvailable: { true },
            now: { clock }, onCaptured: { captured = $0 }, onError: { fail("\($0)") })
        func copy(_ value: String) { board.clearContents(); expectTrue(board.setString(value, forType: .string)) }
        copy("before recording"); monitor.sample()
        target = nil; monitor.sample()
        copy("copied while outside")
        monitor.observe(.init(kind: .mouse, key: 0, command: false, pid: 7, fromDictation: false))
        clock = 90 // Recording duration does not start a paste deadline.
        target = 100; monitor.sample()
        copy("dictation after returning")
        expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
        let id = try expectUnwrap(captured)
        expectNil(try monitor.completeIfReleased(id))
        expectTrue(monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)))
        copy("copied while outside")
        let result = try expectUnwrap(monitor.completeIfReleased(id))
        expectEqual(result.original.text, "copied while outside")
        expectEqual(result.payload.text, "dictation after returning")
        monitor.discard(id)
    }

    @MainActor func testTimeoutDistinguishesKeyReleaseFromClipboard() throws {
        for keyUp in [false, true] {
            for clipboardReturned in [false, true] {
                let board = NSPasteboard(name: .init("rdh-release-\(UUID())")); defer { board.releaseGlobally() }
                var clock: TimeInterval = 0
                var captured: UUID?
                var messages: [String] = []
                let monitor = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(), targetPID: { 100 }, isAvailable: { true },
                    now: { clock }, onCaptured: { captured = $0 }, onError: { fail("\($0)") },
                    report: { messages.append($0) })
                func copy(_ value: String) { board.clearContents(); expectTrue(board.setString(value, forType: .string)) }
                copy("PRIVATE-ORIGINAL"); monitor.sample(); copy("PRIVATE-DICTATION")
                expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
                let id = try expectUnwrap(captured)
                if keyUp { monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)) }
                if clipboardReturned { copy("PRIVATE-ORIGINAL") }
                let revision = board.changeCount
                clock = 0.5
                let first = try monitor.completeIfReleased(id)
                if keyUp && clipboardReturned { expectNotNil(first) }
                else {
                    expectNil(first)
                    clock = 5
                    do { _ = try monitor.completeIfReleased(id); fail("Incomplete source paste must not replay") }
                    catch let error as DictationCaptureError {
                        switch error {
                        case .releaseTimeout: expectTrue(keyUp)
                        case .pasteKeyUpTimeout: expectFalse(keyUp)
                        default: fail("Unexpected failure: \(error)")
                        }
                    }
                    expectTrue(messages.contains { $0.contains("release timeout keyUp=\(keyUp) clipboardChanged=\(clipboardReturned)") })
                }
                expectEqual(board.changeCount, revision, "Diagnostics must never modify clipboard")
                expectFalse(messages.joined().contains("PRIVATE-"), "Only metadata belongs in diagnostics")
                monitor.discard(id)
            }
        }
    }
}
