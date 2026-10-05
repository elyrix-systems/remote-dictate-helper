import AppKit
import RemoteDictateCore

enum LocalClipboardError: Error, CustomStringConvertible {
    case unavailable, changed, tooLarge, writeFailed

    var description: String {
        switch self {
        case .unavailable: "Cannot preserve every format in the local clipboard; copy stopped."
        case .changed: "Local clipboard changed during dictation; copy stopped."
        case .tooLarge: "Local clipboard exceeds the 64 MiB preservation limit; copy stopped."
        case .writeFailed: "Could not write the local clipboard."
        }
    }
}

/// Eager, complete, in-memory copy. Never retain lazy providers or write contents
/// to a file. Preserve all items and types, including privacy/concealed markers.
struct LocalClipboardSnapshot: Equatable {
    struct Representation: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
    let items: [[Representation]]

    /// Transport preparation only. Never apply this to the user's original
    /// snapshot: restoration must retain its exact original bytes and formats.
    func markingUnlabelledHTMLUTF8() -> Self {
        Self(items: items.map { representations in
            representations.map { representation in
                guard representation.type == .html else { return representation }
                return Representation(type: representation.type,
                    data: ClipboardHTMLEncoding.markingUnlabelledUTF8(representation.data))
            }
        })
    }

    static func capture(_ board: NSPasteboard, maximumBytes: Int = 64 * 1024 * 1024) throws -> Self {
        let revision = board.changeCount
        var bytes = 0
        if board.pasteboardItems == nil, !(board.types?.isEmpty ?? true) {
            throw LocalClipboardError.unavailable
        }
        let items = try (board.pasteboardItems ?? []).map { item in
            try item.types.map { type in
                guard let data = item.data(forType: type) else { throw LocalClipboardError.unavailable }
                guard data.count <= maximumBytes - bytes else { throw LocalClipboardError.tooLarge }
                bytes += data.count
                return Representation(type: type, data: data)
            }
        }
        guard board.changeCount == revision else { throw LocalClipboardError.changed }
        return Self(items: items)
    }

    func materialize() throws -> [NSPasteboardItem] {
        try items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                guard item.setData(representation.data, forType: representation.type) else {
                    throw LocalClipboardError.writeFailed
                }
            }
            return item
        }
    }
}

/// Clipboard ownership is revision-based: even copying the same text again
/// cancels restoration. A deadline is only a remote-paste allowance, NOT an ACK.
@MainActor
final class LocalClipboardRestoration {
    static let remotePasteAllowance: TimeInterval = 5
    // Experimental automatic-capture path only. Posting is not a remote ACK;
    // physical short/long-payload trials must establish this smaller allowance.
    static let pasteAllowance: TimeInterval = 0.2

    /// Proof of this restore's exact revision and all original formats. It is
    /// valid only while the clipboard is unchanged, even for an equal-text copy.
    struct Receipt {
        fileprivate let board: NSPasteboard
        fileprivate let revision: Int
        fileprivate let snapshot: LocalClipboardSnapshot
        fileprivate let session: Session

        func validate() throws {
            guard board.changeCount == revision else { throw LocalClipboardError.changed }
            guard try LocalClipboardSnapshot.capture(board) == snapshot,
                  board.changeCount == revision else { throw LocalClipboardError.changed }
        }
    }

    /// The transient post-dictation clipboard that one replay may replace. This is
    /// separate from the original saved before dictation and never replaces it.
    struct ReplayBaseline {
        fileprivate let sessionID: UUID
        fileprivate let revision: Int
        fileprivate let snapshot: LocalClipboardSnapshot
    }

    final class Session {
        let id = UUID()
        let original: LocalClipboardSnapshot
        let capturedRevision: Int
        var ownedRevision: Int?
        var ownedText: String?
        var lastReportedRevision: Int?
        fileprivate var pastePosted = false

        init(original: LocalClipboardSnapshot, capturedRevision: Int) {
            self.original = original
            self.capturedRevision = capturedRevision
        }
    }

    enum Outcome: String {
        case restored, skippedChanged = "skipped: clipboard changed", failed
    }

    private let board: NSPasteboard
    private let now: () -> TimeInterval
    private let onOutcome: (Outcome, Receipt?) -> Void
    private let onMetadata: ((String) -> Void)?
    private var pending: (session: Session, deadline: TimeInterval)?
    private var timer: Timer?
    private var revisionObserver: Timer?
    private var completionObservation: (session: Session, deadline: TimeInterval, phase: String)?
    private var completionObserver: Timer?
    var hasPendingRestore: Bool { pending != nil }

    init(
        board: NSPasteboard = .general,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onOutcome: @escaping (Outcome, Receipt?) -> Void = { _, _ in },
        onMetadata: ((String) -> Void)? = nil
    ) {
        self.board = board
        self.now = now
        self.onOutcome = onOutcome
        self.onMetadata = onMetadata
    }

    /// Automatic capture already saved this original before the dictation app's paste. The
    /// current (returned) revision is authorized separately by ReplayBaseline.
    func begin(observedOriginal: LocalClipboardSnapshot, capturedRevision: Int) throws -> Session {
        guard pending == nil else { throw LocalClipboardError.changed }
        stopCompletionObservation()
        let session = Session(original: observedOriginal, capturedRevision: capturedRevision)
        recordMetadata(session, phase: "automatic-original-selected")
        return session
    }

    func captureReplayBaseline(releasedRevision: Int, session: Session) throws -> ReplayBaseline {
        guard board.changeCount == releasedRevision else { throw LocalClipboardError.changed }
        let snapshot = try LocalClipboardSnapshot.capture(board)
        guard board.changeCount == releasedRevision else { throw LocalClipboardError.changed }
        recordMetadata(session, phase: "source-return-baseline")
        return ReplayBaseline(sessionID: session.id, revision: releasedRevision, snapshot: snapshot)
    }

    /// Replay authorization is exact revision + snapshot, without comparing
    /// dictated text to history. An explicit post-dictation baseline lets us replace
    /// the dictation app's transient return while preserving the pre-dictation original.
    func writeCapturedSnapshot(_ snapshot: LocalClipboardSnapshot, text: String, session: Session, replacing baseline: ReplayBaseline? = nil) throws {
        let items = try snapshot.materialize()
        guard baseline == nil || baseline?.sessionID == session.id else { throw LocalClipboardError.changed }
        let revision = baseline?.revision ?? session.capturedRevision
        let expected = baseline?.snapshot ?? session.original
        guard board.changeCount == revision,
              try LocalClipboardSnapshot.capture(board) == expected,
              board.changeCount == revision else { throw LocalClipboardError.changed }
        session.ownedRevision = board.clearContents()
        session.ownedText = nil
        guard board.writeObjects(items) else { throw LocalClipboardError.writeFailed }
        session.ownedText = text
        guard ownsClipboard(session), try LocalClipboardSnapshot.capture(board) == snapshot,
              ownsClipboard(session) else { throw LocalClipboardError.changed }
        recordMetadata(session, phase: "captured-payload-written")
    }

    /// Only mark after the complete automatic paste sequence returned.
    /// A partial/failed input keeps the longer fallback allowance.
    func recordPastePosted(_ session: Session) {
        guard ownsClipboard(session) else { return }
        session.pastePosted = true
    }

    func allowance(for session: Session) -> TimeInterval {
        session.pastePosted ? Self.pasteAllowance : Self.remotePasteAllowance
    }

    /// Also used after an error: a partial key post can still reach the remote
    /// host. Reset/disable never choose a shorter allowance or restore at once.
    func finish(_ session: Session) {
        stopCompletionObservation()
        recordMetadata(session, phase: "finished")
        guard session.ownedRevision != nil else { return }
        timer?.invalidate()
        revisionObserver?.invalidate()
        let seconds = allowance(for: session)
        pending = (session, now() + seconds)
        onMetadata?("phase=restore-scheduled allowanceSeconds=\(seconds) pastePosted=\(session.pastePosted)")
        let token = session.id
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreIfDue(token: token) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Scoped read-only diagnostics, ending at the existing restore deadline.
        // This never adopts a revision or moves the deadline to a later time.
        if onMetadata != nil {
            let observer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pending?.session.id == token else { return }
                    self.observePendingRevision()
                }
            }
            revisionObserver = observer
            RunLoop.main.add(observer, forMode: .common)
        }
    }

    /// Exposed internally for a deterministic named-pasteboard diagnostic test.
    func observePendingRevision() {
        guard let session = pending?.session, session.lastReportedRevision != board.changeCount else { return }
        recordMetadata(session, phase: "changed-during-allowance")
    }

    /// Kept separate from scheduling so tests can advance a clock without sleeps.
    func restoreIfDue(token: UUID? = nil) {
        guard let pending, token == nil || pending.session.id == token,
              now() >= pending.deadline else { return }
        timer?.invalidate()
        timer = nil
        revisionObserver?.invalidate()
        revisionObserver = nil
        self.pending = nil
        let session = pending.session
        recordMetadata(session, phase: "restore-check")
        guard ownsClipboard(session) else { onOutcome(.skippedChanged, nil); return }
        do {
            let items = try session.original.materialize()
            guard ownsClipboard(session) else { onOutcome(.skippedChanged, nil); return }
            let revision = board.clearContents()
            if !items.isEmpty {
                guard board.writeObjects(items) else { throw LocalClipboardError.writeFailed }
            }
            guard board.changeCount == revision else { onOutcome(.skippedChanged, nil); return }
            let receipt = Receipt(board: board, revision: revision, snapshot: session.original, session: session)
            try receipt.validate()
            startCompletionObservation(session, phase: "local-restoration")
            onOutcome(.restored, receipt)
        } catch LocalClipboardError.changed {
            onOutcome(.skippedChanged, nil)
        } catch {
            onOutcome(.failed, nil)
        }
    }

    /// Completion may now wait for Screen Sharing to become active. Begin a
    /// fresh read-only window when that stage actually finishes, not earlier.
    func observeSharingCompletion(_ receipt: Receipt) {
        startCompletionObservation(receipt.session, phase: "sharing-completion")
    }

    /// Never restores again, adopts a revision or holds busy/quit state.
    private func startCompletionObservation(_ session: Session, phase: String) {
        guard onMetadata != nil else { return }
        stopCompletionObservation()
        recordMetadata(session, phase: "after-\(phase)")
        completionObservation = (session, now() + 10, phase)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.observeCompletionRevision() }
        }
        completionObserver = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func observeCompletionRevision() {
        guard let observation = completionObservation else { return }
        guard now() < observation.deadline else { stopCompletionObservation(); return }
        if observation.session.lastReportedRevision != board.changeCount {
            recordMetadata(observation.session, phase: "changed-after-\(observation.phase)")
        }
    }

    private func stopCompletionObservation() {
        completionObserver?.invalidate()
        completionObserver = nil
        completionObservation = nil
    }

    private func ownsClipboard(_ session: Session) -> Bool {
        guard let revision = session.ownedRevision, board.changeCount == revision else { return false }
        let matches = session.ownedText.map { board.string(forType: .string) == $0 }
            ?? (board.pasteboardItems?.isEmpty ?? true)
        return matches && board.changeCount == revision
    }

    /// Only numbers/booleans and static phase labels leave this method. No text,
    /// hashes, type names, snapshots or clipboard-writer guesses enter the log.
    private func recordMetadata(_ session: Session, phase: String) {
        guard let onMetadata else { return }
        let revision = board.changeCount
        let text = board.string(forType: .string)
        let sameOwnedText = session.ownedText.map { $0 == text }
        let originalData = session.original.items.first?.first(where: { $0.type == .string })?.data
        let originalText = originalData.flatMap { String(data: $0, encoding: .utf8) }
        let sameOriginalText = originalText.map { $0 == text }
        let sameOriginalSnapshot = (try? LocalClipboardSnapshot.capture(board)).map { $0 == session.original }
        let stable = board.changeCount == revision
        func flag(_ value: Bool?) -> String { value.map { String($0) } ?? "unknown" }
        onMetadata("phase=\(phase) captured=\(session.capturedRevision) owned=\(session.ownedRevision.map(String.init) ?? "none") current=\(revision) sameOwnedText=\(flag(sameOwnedText)) sameOriginalText=\(flag(sameOriginalText)) sameOriginalSnapshot=\(flag(sameOriginalSnapshot)) stable=\(stable)")
        if stable { session.lastReportedRevision = revision }
    }
}
