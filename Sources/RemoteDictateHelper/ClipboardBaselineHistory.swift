import AppKit

/// A transient provider failure must not poison an unchanged clipboard forever.
/// The idle sampler gets three spaced retries, never an unbounded polling loop.
struct ClipboardBaselineRetry {
    private(set) var revision: Int?
    private(set) var failures = 0
    private var nextAttempt: TimeInterval = 0
    private static let delays: [TimeInterval] = [0.5, 2, 5]

    func permits(_ revision: Int, at time: TimeInterval) -> Bool {
        self.revision != revision || time >= nextAttempt
    }

    mutating func failed(_ revision: Int, at time: TimeInterval, error: Error) -> TimeInterval? {
        if self.revision != revision { reset(); self.revision = revision }
        failures += 1
        let transient: Bool
        switch error {
        case is IsolatedClipboardError, LocalClipboardError.unavailable, LocalClipboardError.changed:
            transient = true
        default: transient = false
        }
        guard transient, failures <= Self.delays.count else {
            nextAttempt = .infinity; return nil
        }
        let delay = Self.delays[failures - 1]
        nextAttempt = time + delay
        return delay
    }

    mutating func reset() { revision = nil; failures = 0; nextAttempt = 0 }
}

/// Short, RAM-only history while Screen Sharing is active. The returned source
/// clipboard must match a snapshot observed BEFORE the paste attempt. Never
/// invent an original from the dictation payload or an unknown remote echo.
struct ClipboardBaselineHistory {
    struct Entry {
        let revision: Int
        let snapshot: LocalClipboardSnapshot
        let text: String?
        var byteCount: Int { snapshot.items.flatMap { $0 }.reduce(0) { $0 + $1.data.count } }
    }

    private(set) var entries: [Entry] = []
    private let maximumBytes: Int
    private let maximumEntries: Int

    init(maximumBytes: Int = 64 * 1024 * 1024, maximumEntries: Int = 8) {
        self.maximumBytes = maximumBytes
        self.maximumEntries = maximumEntries
    }

    @MainActor mutating func sample(_ board: NSPasteboard, access: ClipboardAccess = .shared) throws {
        let revision = board.changeCount
        guard entries.last?.revision != revision else { return }
        let value = try access.read(board)
        let snapshot = value.snapshot
        let text = value.text
        guard snapshot.items.flatMap({ $0 }).reduce(0, { $0 + $1.data.count }) <= maximumBytes else { throw LocalClipboardError.tooLarge }
        guard board.changeCount == revision else { throw LocalClipboardError.changed }
        entries.append(Entry(revision: revision, snapshot: snapshot, text: text))
        while entries.count > maximumEntries || entries.reduce(0, { $0 + $1.byteCount }) > maximumBytes {
            entries.removeFirst()
        }
    }

    func preceding(_ revision: Int) -> [Entry] { entries.filter { $0.revision < revision } }
    mutating func clear() { entries.removeAll() }

    static func resolve(_ candidates: [Entry], returned: LocalClipboardSnapshot, text: String?) throws -> Entry {
        // A source can restore a zero-item clipboard as one empty UTF-8 text
        // item (observed with Flow after wake). Accept only that representation
        // of the latest empty original, retaining its exact zero-item snapshot.
        // Nil text alone is not proof of emptiness: images/files have it too.
        if let latest = candidates.last, latest.snapshot.items.isEmpty,
           text == "", returned.items == [[.init(type: .string, data: Data())]] {
            return latest
        }
        // Prefer the most recent matching value, not an older rich version of
        // the same text. Text equality tolerates Screen Sharing changing the
        // representations of the returned original; it is not writer identity.
        guard let original = candidates.last(where: {
            $0.snapshot == returned || (text != nil && $0.text == text)
        }) else { throw DictationCaptureError.originalUnknown }
        return original
    }
}
