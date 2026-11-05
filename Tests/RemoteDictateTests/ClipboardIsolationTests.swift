import AppKit

private final class DelayedClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        FileHandle.standardOutput.write(Data([2]))
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

private func provider(for board: NSPasteboard, delay: TimeInterval,
                      onRead: (@Sendable () -> Void)? = nil) throws -> Process {
    let process = Process(), ready = Pipe()
    process.executableURL = Bundle.main.executableURL
    process.arguments = ["--test-clipboard-provider", board.name.rawValue, String(delay)]
    process.standardOutput = ready; process.standardError = FileHandle.nullDevice
    try process.run()
    expectEqual(ready.fileHandleForReading.readData(ofLength: 1), Data([1]))
    if let onRead {
        ready.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.contains(2) { onRead() }
            if data.isEmpty { handle.readabilityHandler = nil }
        }
    }
    return process
}

private func stopFixture(_ process: Process) {
    (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
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
    let started = ProcessInfo.processInfo.systemUptime
    do { try await access.prepare(board, timeout: 0.08); fail("Hung provider must time out") }
    catch IsolatedClipboardError.timedOut { }
    expectTrue(ProcessInfo.processInfo.systemUptime - started < 0.5, "A provider must not hold the caller for its 60-second timeout")
    expectThrows(try access.read(board), "Timed-out result cannot become a cached snapshot")
    stopFixture(hung)

    // Check progress by ordering, not by requiring three timer ticks inside an
    // 80 ms wall-clock window on a shared CI runner. A fresh provider signals
    // entry into its blocking callback, so the assertion cannot run before I/O.
    // If prepare blocks the main actor, this test resumes only after it finishes.
    let (reads, readSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let progressProvider = try provider(for: board, delay: 60, onRead: { _ = readSignal.yield(()) })
    defer { stopFixture(progressProvider) }
    var readFinished = false
    let pendingRead = Task { @MainActor in
        defer { readFinished = true; readSignal.finish() }
        try await access.prepare(board, timeout: 2)
    }
    var readEvents = reads.makeAsyncIterator()
    let readEvent = await readEvents.next()
    expectNotNil(readEvent, "The provider must enter its blocking read before the progress assertion")
    expectFalse(readFinished, "Main actor must resume while clipboard I/O is still pending")
    pendingRead.cancel()
    do { try await pendingRead.value; fail("Cancelled pending read must not succeed") }
    catch is CancellationError { }
    stopFixture(progressProvider)

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
    clock = 2; restore.restoreIfDue()
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

/// The provider outlives the first reader's deadline and materializes data without
/// a new ownership revision, as a remote clipboard promise can do.
@MainActor func testDeferredBaselineRecovery() async throws {
    let board = NSPasteboard(name: .init("rdh-deferred-baseline-\(UUID())"))
    defer { board.releaseGlobally() }
    let owner = try provider(for: board, delay: 0.6)
    defer { stopFixture(owner) }
    let revision = board.changeCount
    var clock: TimeInterval = 0, reports: [String] = []
    let monitor = DictationPasteMonitor(board: board, access: ClipboardAccess(reader: isolationTestReader()),
        targetPID: { 100 }, isAvailable: { true }, now: { clock },
        onCaptured: { _ in fail("Baseline recovery cannot capture or post input") }, onError: { fail("\($0)") },
        report: { reports.append($0) })
    defer { monitor.stop() }
    monitor.scheduleSample()
    for _ in 0..<200 {
        if reports.contains(where: { $0.contains("baseline unavailable") }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    expectTrue(reports.contains(where: { $0.contains("baseline unavailable") }))
    // Owner is still finishing the original promised-data request. Its later
    // completion must not publish a new clipboard generation to enable recovery.
    try await Task.sleep(for: .milliseconds(600))
    expectEqual(board.changeCount, revision)
    clock = 0.5; monitor.scheduleSample()
    for _ in 0..<200 {
        if reports.contains(where: { $0.contains("baseline recovered") }) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    expectTrue(reports.contains(where: { $0.contains("baseline recovered") }), "Delayed provider should recover: \(reports)")
    expectEqual(board.changeCount, revision)
    print("Actual deferred provider: first isolated reader times out; same-revision baseline recovers without input or clipboard writes")
}

/// Accepted input may see a slow remote echo before the source restores its
/// clipboard. All providers here run on disposable named boards in owned children.
@MainActor func testSourceReturnReadRecovery() async throws {
    enum Scenario: CaseIterable { case sameRevision, replacement, readRace, input, focus, deadline, permanent, unmatched }
    for scenario in Scenario.allCases {
        let board = NSPasteboard(name: .init("rdh-return-recovery-\(UUID())"))
        defer { board.releaseGlobally() }
        let access = ClipboardAccess(reader: isolationTestReader())
        let original = "SYNTHETIC-DEFERRED-文字"
        var clock: TimeInterval = 0, target: pid_t? = 100
        var captured: UUID?, captures = 0, failures = 0
        var raced = false
        weak var observedMonitor: DictationPasteMonitor?
        func copy(_ text: String) { board.clearContents(); expectTrue(board.setString(text, forType: .string)) }
        let monitor = DictationPasteMonitor(board: board, access: access, targetPID: { target },
            isAvailable: { true }, now: { clock }, onCaptured: { captured = $0; captures += 1 },
            onError: { fail("Unexpected capture error: \($0)") }, report: { message in
                guard message.hasPrefix("source return read failed") else { return }
                failures += 1
                guard failures == 1 else { return }
                switch scenario {
                case .replacement: copy(original)
                case .input: observedMonitor?.observe(.init(kind: .mouse, key: 0, command: false, pid: 7, fromDictation: false))
                case .focus: target = nil
                case .deadline: copy(original); clock = 5
                case .unmatched: copy("UNRELATED NEW COPY")
                default: break
                }
            }, diagnostic: { message in
                if scenario == .readRace, !raced, message.contains("clipboard.read_ready stage=source-return") {
                    raced = true; copy(original)
                }
            })
        observedMonitor = monitor
        defer { monitor.stop() }
        copy(original); try await access.prepare(board); monitor.sample()
        let originalSnapshot = try access.read(board).snapshot
        copy("CURRENT TRANSCRIPT"); try await access.prepare(board)
        expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
        let id = try expectUnwrap(captured)
        expectTrue(monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)))
        let delay: TimeInterval = scenario == .sameRevision ? 0.6 : scenario == .readRace ? 0.025 : 60
        let owner = try provider(for: board, delay: delay)
        defer { stopFixture(owner) }
        let slowRevision = board.changeCount
        do {
            let result = try await monitor.waitForRelease(id)
            expectTrue(scenario == .sameRevision || scenario == .replacement || scenario == .readRace)
            expectEqual(result.payload.text, "CURRENT TRANSCRIPT")
            expectEqual(result.original.snapshot, originalSnapshot)
            expectEqual(result.releasedRevision, board.changeCount)
            if scenario == .sameRevision { expectEqual(board.changeCount, slowRevision) }
            else { expectTrue(board.changeCount != slowRevision) }
        } catch let error as DictationCaptureError {
            switch (scenario, error) {
            case (.input, .inputChanged), (.focus, .targetChanged), (.deadline, .releaseTimeout), (.unmatched, .originalUnknown): break
            default: fail("Unexpected source-return failure for \(scenario): \(error)")
            }
        } catch IsolatedClipboardError.timedOut {
            expectEqual(scenario, .permanent)
        }
        expectTrue(failures > 0 && failures <= 4)
        if scenario == .permanent { expectEqual(failures, 4) }
        if scenario == .unmatched {
            expectEqual(board.string(forType: .string), "UNRELATED NEW COPY", "Do not overwrite an unmatched return")
        }
        expectEqual(captures, 1, "Recovery cannot synthesize a second capture")
        monitor.discard(id)
    }
    print("Source return: real delayed/changed providers recover; read budget, input/focus, deadline and unknown-copy guards remain")
}
