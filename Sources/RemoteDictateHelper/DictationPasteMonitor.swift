import AppKit
import RemoteDictateCore

enum DictationCaptureError: Error, CustomStringConvertible {
    case unavailable, originalUnknown, targetChanged, inputChanged, releaseTimeout, pasteKeyUpTimeout, filterDisabled, captureTooSlow
    var description: String {
        switch self {
        case .unavailable: "Input monitoring is unavailable. Check Accessibility permission."
        case .originalUnknown: "Original clipboard was not observed. Copy locally, return to Screen Sharing and dictate again."
        case .targetChanged: "Screen Sharing context changed; no deferred paste."
        case .inputChanged: "Input changed during capture; no deferred paste."
        case .releaseTimeout: "The dictation app did not release its clipboard before the deadline. No replay was sent."
        case .pasteKeyUpTimeout: "The dictation app's paste key release was not observed. No replay was sent."
        case .filterDisabled: "macOS disabled paste interception. Quit and reopen Remote Dictate Helper."
        case .captureTooSlow: "Clipboard capture was too slow for interception; original input was allowed through."
        }
    }
}

/// Each selected source's paste is a transaction, independent of dictation keys.
/// The active tap removes only an accepted V down/up pair. Command
/// modifiers, hardware input, other apps and our own replay are never removed.
@MainActor
final class DictationPasteMonitor {
    typealias Event = PasteInputEvent
    struct Result {
        let payload: CapturedClipboard
        let original: ClipboardBaselineHistory.Entry
        let releasedRevision: Int
        let targetPID: pid_t
    }
    private struct Pending {
        let id: UUID
        let payload: CapturedClipboard
        let candidates: [ClipboardBaselineHistory.Entry]
        let sourcePID: pid_t
        let targetPID: pid_t
        let started: TimeInterval
        let clipboardReturn: ClipboardReturnPolicy
        let inputSequence: UInt64?
        var lastReportedRevision: Int
        var keyUp = false
        var failure: Error?
        var reportedWaitSecond = -1
    }
    private let board: NSPasteboard
    private let access: ClipboardAccess
    private var sampleTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    private let targetPID: () -> pid_t?
    private let isAvailable: () -> Bool
    private let now: () -> TimeInterval
    private let onCaptured: (UUID) -> Void
    private let onError: (Error) -> Void
    private let report: (String) -> Void
    private let diagnostic: (String) -> Void
    private let textLog: DiagnosticLog
    private let sources: [DictationSource]
    private var history = ClipboardBaselineHistory()
    private var pending: Pending?
    private var lastHandledRevision: Int?
    private var failedSampleRevision: Int?
    private var sampledTargetPID: pid_t?
    private var timer: Timer?
    private var filter: PasteEventFilter?
    private var filterHealthy = true
    // Remains through cancellation so the up belonging to a removed down is
    // removed as well, even if focus moved. No synthetic replacement is posted.
    private var suppressedPID: pid_t?
    private var suppressedAt: TimeInterval = 0

    init(board: NSPasteboard = .general, access: ClipboardAccess = .shared, targetPID: @escaping () -> pid_t?,
         isAvailable: @escaping () -> Bool, sources: [DictationSource] = AppSettings().sources,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onCaptured: @escaping (UUID) -> Void, onError: @escaping (Error) -> Void,
         report: @escaping (String) -> Void = { _ in },
         diagnostic: @escaping (String) -> Void = { DiagnosticLog.shared.record($0) },
         textLog: DiagnosticLog = .shared) {
        self.access = access
        self.board = board; self.targetPID = targetPID; self.isAvailable = isAvailable
        self.sources = sources; self.now = now
        self.onCaptured = onCaptured; self.onError = onError; self.report = report
        self.diagnostic = diagnostic
        self.textLog = textLog
    }

    func start() throws {
        guard AccessibilityPermission.isTrusted() else { throw DictationCaptureError.unavailable }
        filterHealthy = true
        let next = PasteEventFilter(sources: sources, onEvent: { [weak self] input, decision in
            Task { @MainActor in
                guard let self, self.filter != nil else { return }
                self.handle(input, decision: decision)
            }
        }, onDisabled: { [weak self] in
            Task { @MainActor in self?.filterDisabled() }
        })
        guard next.start() else { throw DictationCaptureError.unavailable }
        filter = next
        report("active paste filter installed; no Backspace")
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        scheduleSample()
    }

    func stop() {
        if let pending { trace(pending, "stop; no replay") }
        generation += 1
        sampleTask?.cancel(); sampleTask = nil
        captureTask?.cancel(); captureTask = nil
        timer?.invalidate(); timer = nil
        filter?.stop(); filter = nil
        pending = nil; suppressedPID = nil; history.clear(); sampledTargetPID = nil
    }

    func filterDisabled() {
        captureTask?.cancel(); captureTask = nil
        filterHealthy = false; suppressedPID = nil
        if pending != nil { pending?.failure = DictationCaptureError.filterDisabled }
        // Never silently enable deletion or re-enable an unhealthy filter.
        Task { @MainActor [weak self] in
            self?.report("active paste filter disabled by macOS; input passes through")
            self?.onError(DictationCaptureError.filterDisabled)
        }
    }

    /// The timer never calls an external data provider. One asynchronous sample
    /// at a time; failed revisions are not retried every 20 ms.
    func scheduleSample() {
        if suppressedPID != nil, now() - suppressedAt > 5 { suppressedPID = nil }
        guard pending == nil, captureTask == nil else { return }
        guard isAvailable(), let target = targetPID() else {
            sampleTask?.cancel(); sampleTask = nil
            generation += 1
            history.clear(); sampledTargetPID = nil; return
        }
        if sampledTargetPID != target {
            sampleTask?.cancel(); sampleTask = nil; generation += 1
            history.clear(); sampledTargetPID = target
        }
        let revision = board.changeCount
        guard sampleTask == nil, failedSampleRevision != revision,
              history.entries.last?.revision != revision else { return }
        let token = generation
        diagnostic("clipboard.read_begin stage=baseline revision=\(revision) targetPID=\(target)")
        sampleTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { sampleTask = nil } }
            do {
                try await access.prepare(board)
                try Task.checkCancellation()
                guard generation == token, pending == nil, targetPID() == target, isAvailable(),
                      board.changeCount == revision else { return }
                sample()
                diagnostic("clipboard.read_ready stage=baseline revision=\(revision)")
            } catch is CancellationError { }
            catch {
                guard generation == token, board.changeCount == revision else { return }
                history.clear(); failedSampleRevision = revision
                report("baseline unavailable revision=\(revision): \(error)")
                diagnostic("clipboard.read_failed stage=baseline revision=\(revision) targetPID=\(target) error=\(error)")
            }
        }
    }

    /// Prepare outside the decision lock. Only the short, in-memory transaction
    /// commit runs inside it. An expired decision must never suppress or replay.
    func handle(_ input: Event, decision: PasteCaptureDecision?) {
        guard let decision else { _ = observe(input); return }
        guard captureTask == nil else { decision.evaluate { false }; return }
        guard pending == nil, filterHealthy, isAvailable(),
              let target = targetPID(), sampledTargetPID == target,
              history.preceding(board.changeCount).last != nil else {
            decision.evaluate { self.observe(input) }; return
        }
        let revision = board.changeCount, token = generation
        sampleTask?.cancel(); sampleTask = nil
        diagnostic("clipboard.read_begin stage=candidate revision=\(revision) targetPID=\(target)")
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == token { captureTask = nil } }
            do {
                try await access.prepare(board, timeout: min(0.06, decision.remaining))
                try Task.checkCancellation()
                guard generation == token, targetPID() == target, board.changeCount == revision,
                      input.sequence == nil || filter == nil || filter?.inputSequence == input.sequence else { return }
                let baseline = history.preceding(revision).last
                guard let baseline else { throw DictationCaptureError.originalUnknown }
                // Copy/HTML transport preparation also stays outside the lock.
                let payload = try CapturedClipboard.read(from: board, after: baseline.revision, access: access)
                if !decision.evaluate({ self.observe(input, preparedRead: { payload }) }) {
                    lastHandledRevision = revision
                }
                diagnostic("clipboard.read_ready stage=candidate revision=\(revision) decisionExpired=\(decision.remaining == 0)")
            } catch is CancellationError { }
            catch {
                guard generation == token else { return }
                // No fallback, retry or late publication when the source's
                // original key has already been allowed through.
                diagnostic("clipboard.read_failed stage=candidate revision=\(revision) error=\(error) originalInput=allowed")
                lastHandledRevision = revision; history.clear()
                decision.evaluate { false }
                onError(error)
            }
        }
    }

    func sample() {
        if suppressedPID != nil, now() - suppressedAt > 5 { suppressedPID = nil }
        guard pending == nil else { return }
        guard isAvailable(), let target = targetPID() else {
            history.clear(); sampledTargetPID = nil; return
        }
        if sampledTargetPID != target { history.clear(); sampledTargetPID = target }
        guard failedSampleRevision != board.changeCount else { return }
        do { try history.sample(board, access: access) }
        catch {
            history.clear(); failedSampleRevision = board.changeCount
            report("baseline unavailable revision=\(board.changeCount)")
            diagnostic("capture.baseline_unavailable revision=\(board.changeCount) targetPID=\(target) error=\(error)")
        }
    }

    /// Return true only when the caller must remove this event from the stream.
    /// Native tests use event metadata and a named board, never real input.
    @discardableResult
    func observe(_ event: Event, preparedRead: (() throws -> CapturedClipboard?)? = nil) -> Bool {
        if event.pid == ProcessInfo.processInfo.processIdentifier { return false }
        var remove = false
        if event.fromDictation, event.pid == suppressedPID, event.key == 9 {
            if event.kind == .up { remove = true; suppressedPID = nil }
            else if event.kind == .down, event.autorepeat { return true }
        }
        if var current = pending {
            if event.kind == .up, event.key == 9 {
                report("paste key-up afterMs=\(Int((now() - current.started) * 1000)) sourceMatches=\(event.pid == current.sourcePID) recognized=\(event.fromDictation) revision=\(board.changeCount)")
            }
            if event.fromDictation, event.pid == current.sourcePID, event.kind == .up, event.key == 9 {
                current.keyUp = true
            } else if event.kind == .down || event.kind == .mouse {
                if current.failure == nil { trace(current, "cancel reason=input_event \(event.diagnosticMetadata)") }
                current.failure = DictationCaptureError.inputChanged
            }
            pending = current
            return remove
        }
        guard event.fromDictation, event.kind == .down, event.key == 9, event.command,
              !event.autorepeat, filterHealthy, let target = targetPID() else { return remove }
        let revision = board.changeCount
        diagnostic("capture.candidate targetPID=\(target) revision=\(revision) sampledTarget=\(sampledTargetPID.map(String.init) ?? "none") lastHandled=\(lastHandledRevision.map(String.init) ?? "none") \(event.diagnosticMetadata)")
        guard revision != lastHandledRevision else { return remove }
        lastHandledRevision = revision
        guard isAvailable() else { report("paste skipped: another operation is finishing"); diagnostic("capture.rejected reason=busy revision=\(revision)"); return remove }
        let started = now()
        do {
            let candidates = history.preceding(revision)
            guard let baseline = candidates.last, sampledTargetPID == target else { throw DictationCaptureError.originalUnknown }
            let read = preparedRead ?? { try CapturedClipboard.read(from: self.board, after: baseline.revision, access: self.access) }
            guard let payload = try read() else {
                report("empty result skipped"); history.clear(); return remove
            }
            // Keep the active callback short. There is no menu/AX work or input
            // posting here. Failure leaves the original paste unmodified.
            if now() - started > 0.1 { throw DictationCaptureError.captureTooSlow }
            let id = UUID()
            pending = Pending(id: id, payload: payload, candidates: candidates, sourcePID: event.pid,
                targetPID: target, started: started, clipboardReturn: event.clipboardReturn,
                inputSequence: event.sequence, lastReportedRevision: payload.revision)
            suppressedPID = event.pid; suppressedAt = now()
            history.clear()
            diagnostic("op=\(id) client=screen-sharing stage=captured source=\(event.pid):\(DiagnosticLog.token(event.sourceBundle ?? "unknown")) targetPID=\(target) revision=\(revision) originalCandidates=\(candidates.map { String($0.revision) }.joined(separator: ",")) inputSequence=\(event.sequence.map(String.init) ?? "none") policy=\(event.clipboardReturn.rawValue)")
            report("captured revision=\(payload.revision) characters=\(payload.text.count) intercepted=true encodingMarkerAdded=\(payload.encodingMarkerAdded) returnPolicy=\(event.clipboardReturn.rawValue)")
            diagnostic("op=\(id) payloadMetadata items=\(payload.snapshot.items.count) bytes=\(payload.snapshot.items.flatMap { $0 }.reduce(0) { $0 + $1.data.count }) formats=\(payload.snapshot.items.flatMap { $0 }.map { DiagnosticLog.token($0.type.rawValue) }.joined(separator: ",")) contents=excluded")
            onCaptured(id)
            if textLog.textEnabled {
                textLog.recordText(operation: id, client: "screen-sharing", revision: payload.revision,
                    type: NSPasteboard.PasteboardType.string.rawValue, value: .capture(payload.text))
            }
            return true
        } catch { diagnostic("capture.rejected revision=\(revision) reason=\(error)"); history.clear(); onError(error) }
        return remove
    }

    func completeIfReleased(_ id: UUID) throws -> Result? {
        try validate(id)
        guard let current = pending, current.id == id else { throw CancellationError() }
        let revision = board.changeCount
        let second = Int(now() - current.started)
        if second != current.reportedWaitSecond {
            pending?.reportedWaitSecond = second
            trace(current, "wait keyUp=\(current.keyUp) clipboardChanged=\(revision != current.payload.revision) policy=\(current.clipboardReturn.rawValue)")
        }
        if revision != current.lastReportedRevision {
            pending?.lastReportedRevision = revision
            report("release clipboard changed afterMs=\(Int((now() - current.started) * 1000)) keyUp=\(current.keyUp) payloadRevision=\(current.payload.revision) currentRevision=\(revision)")
        }
        if current.keyUp {
            let original: ClipboardBaselineHistory.Entry?
            if revision != current.payload.revision {
                let value = try access.read(board)
                let returned = value.snapshot
                let text = value.text
                guard board.changeCount == revision else { throw LocalClipboardError.changed }
                do {
                    original = try ClipboardBaselineHistory.resolve(current.candidates, returned: returned, text: text)
                } catch {
                    trace(current, "cancel reason=returned_clipboard_unmatched candidates=\(current.candidates.map { String($0.revision) }.joined(separator: ",")) returnedItems=\(returned.items.count) returnedFormats=\(returned.items.flatMap { $0 }.map { DiagnosticLog.token($0.type.rawValue) }.joined(separator: ","))")
                    throw error
                }
            } else if current.clipboardReturn == .keepsTranscript {
                // Explicit source contract, never a timeout-based guess that an
                // app has finished restoring. The later replay checks revision.
                original = current.candidates.last
            } else { original = nil }
            if let original {
                trace(current, "released originalRevision=\(original.revision)")
                report("released afterMs=\(Int((now() - current.started) * 1000)) revision=\(revision) originalRevision=\(original.revision)")
                return Result(payload: current.payload, original: original, releasedRevision: revision,
                    targetPID: current.targetPID)
            }
        }
        guard now() - current.started < 5 else {
            trace(current, "cancel reason=\(current.keyUp ? "clipboard_return_timeout" : "source_v_up_timeout") keyUp=\(current.keyUp)")
            report("release timeout keyUp=\(current.keyUp) clipboardChanged=\(revision != current.payload.revision) payloadRevision=\(current.payload.revision) currentRevision=\(revision) returnPolicy=\(current.clipboardReturn.rawValue)")
            throw current.keyUp ? DictationCaptureError.releaseTimeout : DictationCaptureError.pasteKeyUpTimeout
        }
        return nil
    }
    func waitForRelease(_ id: UUID) async throws -> Result {
        while true {
            try Task.checkCancellation()
            try validate(id)
            if let current = pending, current.keyUp, board.changeCount != current.payload.revision {
                let revision = board.changeCount
                diagnostic("op=\(id) clipboard.read_begin stage=source-return revision=\(revision)")
                try await access.prepare(board)
                try validate(id)
                diagnostic("op=\(id) clipboard.read_ready stage=source-return revision=\(revision)")
            }
            if let result = try completeIfReleased(id) { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func validate(_ id: UUID) throws {
        guard let current = pending, current.id == id else { throw CancellationError() }
        if let failure = current.failure { throw failure }
        // The filter updates this on its own thread, even while AX menu polling
        // occupies the main thread. Queued observer callbacks cannot hide input.
        if let sequence = current.inputSequence, let filter, filter.inputSequence != sequence {
            trace(current, "cancel reason=input_sequence_changed expected=\(sequence) observed=\(filter.inputSequence) lastInput={\(filter.lastInputMetadata)}")
            throw DictationCaptureError.inputChanged
        }
        let actual = targetPID()
        guard actual == current.targetPID else {
            trace(current, "cancel reason=foreground_target_changed expectedPID=\(current.targetPID) observedTargetPID=\(actual.map(String.init) ?? "none")")
            throw DictationCaptureError.targetChanged
        }
    }
    func discard(_ id: UUID) {
        if let current = pending, current.id == id { trace(current, "discard") }
        if pending?.id == id { pending = nil; history.clear() }
    }
    private func trace(_ current: Pending, _ message: String) {
        diagnostic("op=\(current.id) client=screen-sharing elapsedMs=\(Int((now() - current.started) * 1000)) payloadRevision=\(current.payload.revision) currentRevision=\(board.changeCount) targetPID=\(current.targetPID) front=\(DiagnosticLog.front) \(message)")
    }
}
