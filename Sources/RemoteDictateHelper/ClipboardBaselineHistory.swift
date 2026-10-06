import AppKit

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

    mutating func sample(_ board: NSPasteboard) throws {
        let revision = board.changeCount
        guard entries.last?.revision != revision else { return }
        let snapshot = try LocalClipboardSnapshot.capture(board, maximumBytes: maximumBytes)
        let text = board.string(forType: .string)
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
