import AppKit

/// An in-memory payload read at the dictation app's paste attempt. No history, HTML
/// rendering, punctuation changes or appended whitespace. Unlabelled UTF-8
/// HTML gets an encoding marker so rich-text consumers decode it correctly.
struct CapturedClipboard {
    let snapshot: LocalClipboardSnapshot
    let text: String
    let revision: Int
    let encodingMarkerAdded: Bool

    @MainActor static func read(from board: NSPasteboard, after baselineRevision: Int, access: ClipboardAccess = .shared) throws -> Self? {
        let revision = board.changeCount
        guard revision != baselineRevision else { throw LocalClipboardError.changed }
        let value = try access.read(board)
        let snapshot = value.snapshot
        let text = value.text
        guard board.changeCount == revision else { throw LocalClipboardError.changed }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let transport = snapshot.markingUnlabelledHTMLUTF8()
        return Self(snapshot: transport, text: text, revision: revision, encodingMarkerAdded: transport != snapshot)
    }
}

