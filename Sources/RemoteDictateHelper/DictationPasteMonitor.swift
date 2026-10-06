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
    }
    private let board: NSPasteboard
    private let targetPID: () -> pid_t?
    private let isAvailable: () -> Bool
    private let now: () -> TimeInterval
    private let onCaptured: (UUID) -> Void
    private let onError: (Error) -> Void
    private let report: (String) -> Void
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

    init(board: NSPasteboard = .general, targetPID: @escaping () -> pid_t?,
         isAvailable: @escaping () -> Bool, sources: [DictationSource] = AppSettings().sources,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onCaptured: @escaping (UUID) -> Void, onError: @escaping (Error) -> Void,
         report: @escaping (String) -> Void = { _ in }) {
        self.board = board; self.targetPID = targetPID; self.isAvailable = isAvailable
        self.sources = sources; self.now = now
        self.onCaptured = onCaptured; self.onError = onError; self.report = report
    }

    func start() throws {
        guard AccessibilityPermission.isTrusted() else { throw DictationCaptureError.unavailable }
        filterHealthy = true
        let next = PasteEventFilter(sources: sources, onEvent: { [weak self] input, decision in
            Task { @MainActor in
                guard let self, self.filter != nil else { return }
                if let decision { decision.evaluate { self.observe(input) } }
                else { _ = self.observe(input) }
            }
        }, onDisabled: { [weak self] in
            Task { @MainActor in self?.filterDisabled() }
        })
        guard next.start() else { throw DictationCaptureError.unavailable }
        filter = next
        report("active paste filter installed; no Backspace")
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        sample()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        filter?.stop(); filter = nil
        pending = nil; suppressedPID = nil; history.clear(); sampledTargetPID = nil
    }

    func filterDisabled() {
        filterHealthy = false; suppressedPID = nil
        if pending != nil { pending?.failure = DictationCaptureError.filterDisabled }
        // Never silently enable deletion or re-enable an unhealthy filter.
        Task { @MainActor [weak self] in
            self?.report("active paste filter disabled by macOS; input passes through")
            self?.onError(DictationCaptureError.filterDisabled)
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
        do { try history.sample(board) }
        catch {
            history.clear(); failedSampleRevision = board.changeCount
            report("baseline unavailable revision=\(board.changeCount)")
        }
    }

    /// Return true only when the caller must remove this event from the stream.
    /// Native tests use event metadata and a named board, never real input.
    @discardableResult
    func observe(_ event: Event) -> Bool {
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
                current.failure = DictationCaptureError.inputChanged
            }
            pending = current
            return remove
        }
        guard event.fromDictation, event.kind == .down, event.key == 9, event.command,
              !event.autorepeat, filterHealthy, let target = targetPID() else { return remove }
        let revision = board.changeCount
        guard revision != lastHandledRevision else { return remove }
        lastHandledRevision = revision
        guard isAvailable() else { report("paste skipped: another operation is finishing"); return remove }
        let started = now()
        do {
            let candidates = history.preceding(revision)
            guard let baseline = candidates.last, sampledTargetPID == target else { throw DictationCaptureError.originalUnknown }
            guard let payload = try CapturedClipboard.read(from: board, after: baseline.revision) else {
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
            report("captured revision=\(payload.revision) characters=\(payload.text.count) intercepted=true encodingMarkerAdded=\(payload.encodingMarkerAdded) returnPolicy=\(event.clipboardReturn.rawValue)")
            onCaptured(id)
            return true
        } catch { history.clear(); onError(error) }
        return remove
    }

    func completeIfReleased(_ id: UUID) throws -> Result? {
        try validate(id)
        guard let current = pending, current.id == id else { throw CancellationError() }
        let revision = board.changeCount
        if revision != current.lastReportedRevision {
            pending?.lastReportedRevision = revision
            report("release clipboard changed afterMs=\(Int((now() - current.started) * 1000)) keyUp=\(current.keyUp) payloadRevision=\(current.payload.revision) currentRevision=\(revision)")
        }
        if current.keyUp {
            let original: ClipboardBaselineHistory.Entry?
            if revision != current.payload.revision {
                let returned = try LocalClipboardSnapshot.capture(board)
                let text = board.string(forType: .string)
                guard board.changeCount == revision else { throw LocalClipboardError.changed }
                original = try ClipboardBaselineHistory.resolve(current.candidates, returned: returned, text: text)
            } else if current.clipboardReturn == .keepsTranscript {
                // Explicit source contract, never a timeout-based guess that an
                // app has finished restoring. The later replay checks revision.
                original = current.candidates.last
            } else { original = nil }
            if let original {
                report("released afterMs=\(Int((now() - current.started) * 1000)) revision=\(revision) originalRevision=\(original.revision)")
                return Result(payload: current.payload, original: original, releasedRevision: revision,
                    targetPID: current.targetPID)
            }
        }
        guard now() - current.started < 5 else {
            report("release timeout keyUp=\(current.keyUp) clipboardChanged=\(revision != current.payload.revision) payloadRevision=\(current.payload.revision) currentRevision=\(revision) returnPolicy=\(current.clipboardReturn.rawValue)")
            throw current.keyUp ? DictationCaptureError.releaseTimeout : DictationCaptureError.pasteKeyUpTimeout
        }
        return nil
    }
    func waitForRelease(_ id: UUID) async throws -> Result {
        while true {
            try Task.checkCancellation()
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
            throw DictationCaptureError.inputChanged
        }
        guard targetPID() == current.targetPID else { throw DictationCaptureError.targetChanged }
    }
    func discard(_ id: UUID) {
        if pending?.id == id { pending = nil; history.clear() }
    }
}
