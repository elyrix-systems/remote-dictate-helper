import AppKit

private func receivedSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
}

@MainActor
func testWindowsClipboardReader() async throws {
    let board = NSPasteboard(name: .init("RD-Windows-Read-\(UUID())"))
    defer { board.releaseGlobally() }
    // Read an in-process owned board on its owner thread. AppKit refuses some
    // same-process provider calls from a worker. The separate-process local
    // spike exercises the real async reader with a deferred external provider.
    func read(_ revision: Int) throws -> WindowsClipboardRead {
        try WindowsClipboardReader.readOnce(name: board.name, revision: revision)
    }
    let plain = Data("RD-synthetic-Привет".utf8)
    let rich = Data("<b>RD-synthetic</b>".utf8)
    board.declareTypes([.string, .html], owner: nil)
    expectTrue(board.setData(plain, forType: .string)); expectTrue(board.setData(rich, forType: .html))
    let revision = board.changeCount
    let ready = try read(revision)
    expectEqual(ready.type, NSPasteboard.PasteboardType.string.rawValue)
    expectEqual(ready.bytes, plain.count)
    expectEqual(board.changeCount, revision, "Read cannot republish the clipboard")
    expectEqual(board.data(forType: .string), plain); expectEqual(board.data(forType: .html), rich)
    do { _ = try read(revision - 1); fail("Stale revision must fail") }
    catch WindowsClipboardReadError.changed {}

    for type in [NSPasteboard.PasteboardType.rtf, .html] {
        let bytes = type == .rtf ? Data("{\\rtf1\\ansi RD-synthetic}".utf8) : rich
        board.clearContents(); board.setData(bytes, forType: type)
        let before = board.changeCount
        let ready = try read(board.changeCount)
        // AppKit can also advertise a generated plain-text representation of RTF.
        expectTrue([type.rawValue, NSPasteboard.PasteboardType.string.rawValue].contains(ready.type))
        expectTrue(ready.bytes > 0)
        expectEqual(board.data(forType: type), bytes); expectEqual(board.changeCount, before)
    }
    board.clearContents(); board.setData(Data(), forType: .string)
    do { _ = try read(board.changeCount); fail("Empty text must not paste") }
    catch WindowsClipboardReadError.empty {}
    board.clearContents(); board.setData(Data([1]), forType: .init("test.non-text"))
    do { _ = try read(board.changeCount); fail("Missing text must fail") }
    catch WindowsClipboardReadError.unavailable {}

    // The blocking closure models an external provider. The general clipboard
    // and other applications are never read; timeout must release the caller.
    for cancel in [false, true] {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blocked = WindowsClipboardReader(timeout: cancel ? 5 : 0.04, read: { _ in
            started.signal(); release.wait()
            return WindowsClipboardRead(type: "test.synthetic", bytes: 1)
        })
        let pending = Task { try await blocked.prepare(revision: 1) }
        var didStart = false
        for _ in 0..<1000 {
            if receivedSignal(started) { didStart = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        expectTrue(didStart, "Worker should start without blocking the main actor")
        if cancel { pending.cancel() }
        do { _ = try await pending.value; fail("Blocked read must not succeed") }
        catch is CancellationError { expectTrue(cancel) }
        catch WindowsClipboardReadError.timedOut { expectFalse(cancel) }
        do { _ = try await blocked.prepare(revision: 2); fail("Do not queue behind a blocked provider") }
        catch WindowsClipboardReadError.busy {}
        release.signal()
        // The old provider may finish later, but its result is already terminal.
        // Admission opens only after that worker exits. Then a fresh operation
        // can proceed without creating a second concurrent AppKit read.
        release.signal()
        var recovered = false
        for _ in 0..<1000 {
            do { _ = try await blocked.prepare(revision: 3); recovered = true; break }
            catch WindowsClipboardReadError.busy { try await Task.sleep(for: .milliseconds(1)) }
        }
        expectTrue(recovered, "Reader recovers once the external provider finishes")
    }
    let expired = WindowsClipboardReader(timeout: 0, read: { _ in fail("Expired read must not start") })
    do { _ = try await expired.prepare(revision: 1); fail("Zero deadline must finish") }
    catch WindowsClipboardReadError.timedOut {}
    print("Windows clipboard reader passed: named-board formats preserved, missing/empty/stale data refused, bounded timeout/cancellation and single outstanding read")
}
