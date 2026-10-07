import AppKit

private final class DelayedClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: delay)
        item.setData(Data("SYNTHETIC-DEFERRED-文字".utf8), forType: type)
    }
}

/// Runs only in an owned test child, on a disposable named board.
func runClipboardProviderFixture() -> Bool {
    let args = CommandLine.arguments
    guard args.count == 4, args[1] == "--test-clipboard-provider", let delay = Double(args[3]) else { return false }
    let board = NSPasteboard(name: .init(args[2]))
    let provider = DelayedClipboardProvider(delay: delay), item = NSPasteboardItem()
    item.setDataProvider(provider, forTypes: [.string])
    board.clearContents(); precondition(board.writeObjects([item]))
    FileHandle.standardOutput.write(Data([1]))
    withExtendedLifetime(provider) { RunLoop.main.run(until: Date().addingTimeInterval(10)) }
    return true
}

private func provider(for board: NSPasteboard, delay: TimeInterval) throws -> Process {
    let process = Process(), ready = Pipe()
    process.executableURL = Bundle.main.executableURL
    process.arguments = ["--test-clipboard-provider", board.name.rawValue, String(delay)]
    process.standardOutput = ready; process.standardError = FileHandle.nullDevice
    try process.run()
    expectEqual(ready.fileHandleForReading.readData(ofLength: 1), Data([1]))
    return process
}

private func stopFixture(_ process: Process) {
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

@MainActor
func testIsolatedClipboardReading() async throws {
    let board = NSPasteboard(name: .init("rdh-isolated-\(UUID())"))
    defer { board.releaseGlobally() }
    let access = ClipboardAccess(reader: isolationTestReader())
    let text = "Synthetic • Русский • 日本語\n1. One\n2. Two"
    let item = NSPasteboardItem(), second = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data("<p>日本語</p>".utf8), forType: .html)
    second.setData(Data([0, 255, 1]), forType: .init("example.binary"))
    board.clearContents(); expectTrue(board.writeObjects([item, second]))
    let expected = try LocalClipboardSnapshot.capture(board), revision = board.changeCount
    // Warm code loading separately from the deliberately short provider deadline.
    try await access.prepare(board, timeout: 2)
    expectEqual(try access.read(board).snapshot, expected)
    expectEqual(try access.read(board).text, text)
    expectEqual(board.changeCount, revision, "Reads never republish data")

    let delayed = try provider(for: board, delay: 0.025)
    try await access.prepare(board)
    expectEqual(try access.read(board).text, "SYNTHETIC-DEFERRED-文字")
    stopFixture(delayed)

    let hung = try provider(for: board, delay: 60)
    var ticks = 0
    let heartbeat = Task { @MainActor in
        while !Task.isCancelled {
            ticks += 1
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
        }
    }
    let started = ProcessInfo.processInfo.systemUptime
    do { try await access.prepare(board, timeout: 0.08); fail("Hung provider must time out") }
    catch IsolatedClipboardError.timedOut { }
    expectTrue(ProcessInfo.processInfo.systemUptime - started < 0.5, "A provider must not hold the caller for its 60-second timeout")
    expectTrue(ticks >= 3, "Main actor continues running during clipboard I/O")
    expectThrows(try access.read(board), "Timed-out result cannot become a cached snapshot")
    heartbeat.cancel(); stopFixture(hung)

    // Timeout reaps the reader and releases admission, rather than leaving an
    // uninterruptible AppKit worker occupying it for the next minute.
    board.clearContents(); board.setString("after timeout", forType: .string)
    try await access.prepare(board)
    expectEqual(try access.read(board).text, "after timeout")

    let cancelledOwner = try provider(for: board, delay: 60)
    let reader = isolationTestReader()
    let revisionToCancel = board.changeCount
    let nameToCancel = board.name
    let read = Task { try await reader.read(name: nameToCancel, revision: revisionToCancel) }
    try await Task.sleep(for: .milliseconds(25))
    do { _ = try await reader.read(name: board.name, revision: revisionToCancel); fail("Only one reader may be admitted") }
    catch IsolatedClipboardError.busy { }
    read.cancel()
    do { _ = try await read.value; fail("Cancelled read must not succeed") } catch is CancellationError { }
    stopFixture(cancelledOwner)
    board.clearContents(); board.setString("after cancellation", forType: .string)
    try await access.prepare(board)
    let sameTextRevision = board.changeCount
    board.clearContents(); board.setString("after cancellation", forType: .string)
    expectTrue(board.changeCount != sameTextRevision)
    expectThrows(try access.read(board), "Even a same-text copy invalidates prepared ownership")
    print("Isolated reader: exact rich/multiple formats, delayed provider, 60-second hung provider, responsive main actor, timeout/cancel cleanup and fresh revision recovery passed; named boards only")
}

@MainActor
func testAsyncCaptureAndExpiredDecision() async throws {
    let board = NSPasteboard(name: .init("rdh-async-capture-\(UUID())"))
    defer { board.releaseGlobally() }
    let access = ClipboardAccess(reader: isolationTestReader())
    var id: UUID?, errors: [String] = [], reports: [String] = [], clock: TimeInterval = 0
    let monitor = DictationPasteMonitor(board: board, access: access, targetPID: { 100 }, isAvailable: { true },
        onCaptured: { id = $0 }, onError: { errors.append(String(describing: $0)) }, diagnostic: { reports.append($0) })
    defer { monitor.stop() }
    let down = PasteInputEvent(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)
    let up = PasteInputEvent(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)
    func copy(_ value: String) { board.clearContents(); board.setString(value, forType: .string) }
    func sampled() async throws {
        reports.removeAll(); monitor.scheduleSample()
        for _ in 0..<100 {
            if reports.contains(where: { $0.contains("read_ready stage=baseline") }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fail("Baseline should complete asynchronously")
    }
    copy("ORIGINAL"); try await sampled()
    copy("Synthetic dictation"); let decision = PasteCaptureDecision()
    monitor.handle(down, decision: decision)
    let accepted = await Task.detached { decision.wait() }.value
    expectTrue(accepted, "Capture refused: \(errors); stages: \(reports)"); let captured = try expectUnwrap(id)
    monitor.handle(up, decision: nil)
    copy("ORIGINAL")
    let result = try await monitor.waitForRelease(captured)
    expectEqual(result.payload.text, "Synthetic dictation")
    let restore = LocalClipboardRestoration(board: board, access: access, now: { clock })
    let session = try restore.begin(observedOriginal: result.original.snapshot)
    let baseline = try restore.captureReplayBaseline(releasedRevision: result.releasedRevision, session: session)
    try restore.writeCapturedSnapshot(result.payload.snapshot, text: result.payload.text, session: session, replacing: baseline)
    restore.recordPastePosted(session); restore.finish(session)
    clock = 0.2; restore.restoreIfDue()
    expectEqual(board.string(forType: .string), "ORIGINAL")
    expectTrue(errors.isEmpty)
    monitor.discard(captured); id = nil

    copy("NEW ORIGINAL"); try await sampled()
    let delayed = try provider(for: board, delay: 0.15)
    let late = PasteCaptureDecision(wait: 0.015)
    monitor.handle(down, decision: late)
    let suppressed = await Task.detached { late.wait() }.value
    expectFalse(suppressed, "A provider read cannot hold the event tap beyond its deadline")
    try await Task.sleep(for: .milliseconds(200))
    expectNil(id, "No late capture or deferred replay after original input passed through")
    stopFixture(delayed)
    print("Asynchronous capture/release/restoration and expired event-tap decision passed")
}

private func isolationTestReader() -> IsolatedClipboardReader {
    if let executable = ProcessInfo.processInfo.environment["RD_TEST_READER_EXECUTABLE"] {
        return IsolatedClipboardReader(executable: URL(fileURLWithPath: executable))
    }
    return .shared
}
