import AppKit

@MainActor
func testWindowsClipboardReader() async throws {
    let board = NSPasteboard(name: .init("RD-Windows-Read-\(UUID())"))
    defer { board.releaseGlobally() }
    let reader = WindowsClipboardReader(name: board.name)
    func read(_ revision: Int) async throws -> WindowsClipboardRead {
        try await reader.prepare(revision: revision)
    }
    let plain = Data("RD-synthetic-Привет".utf8)
    let rich = Data("<b>RD-synthetic</b>".utf8)
    board.declareTypes([.string, .html], owner: nil)
    expectTrue(board.setData(plain, forType: .string)); expectTrue(board.setData(rich, forType: .html))
    let revision = board.changeCount
    let ready = try await read(revision)
    expectEqual(ready.type, NSPasteboard.PasteboardType.string.rawValue)
    expectEqual(ready.bytes, plain.count)
    expectEqual(board.changeCount, revision, "Read cannot republish the clipboard")
    expectEqual(board.data(forType: .string), plain); expectEqual(board.data(forType: .html), rich)
    do { _ = try await read(revision - 1); fail("Stale revision must fail") }
    catch WindowsClipboardReadError.changed {}

    for type in [NSPasteboard.PasteboardType.rtf, .html] {
        let bytes = type == .rtf ? Data("{\\rtf1\\ansi RD-synthetic}".utf8) : rich
        board.clearContents(); board.setData(bytes, forType: type)
        let before = board.changeCount
        let ready = try await read(board.changeCount)
        // AppKit can also advertise a generated plain-text representation of RTF.
        expectTrue([type.rawValue, NSPasteboard.PasteboardType.string.rawValue].contains(ready.type))
        expectTrue(ready.bytes > 0)
        expectEqual(board.data(forType: type), bytes); expectEqual(board.changeCount, before)
    }
    board.clearContents(); board.setData(Data(), forType: .string)
    do { _ = try await read(board.changeCount); fail("Empty text must not paste") }
    catch WindowsClipboardReadError.empty {}
    board.clearContents(); board.setData(Data([1]), forType: .init("test.non-text"))
    do { _ = try await read(board.changeCount); fail("Missing text must fail") }
    catch WindowsClipboardReadError.unavailable {}

    let expired = WindowsClipboardReader(name: board.name, timeout: 0)
    do { _ = try await expired.prepare(revision: board.changeCount); fail("Zero deadline must finish") }
    catch WindowsClipboardReadError.timedOut {}
    print("Windows clipboard reader passed through isolated process: formats unchanged, missing/empty/stale data refused, deadline checked before reading")
}
