import AppKit

enum WindowsClipboardReadError: Error, CustomStringConvertible {
    case busy, timedOut, changed, unavailable, empty
    var description: String {
        switch self {
        case .busy: "The previous Windows App clipboard read is still finishing; no paste."
        case .timedOut: "Windows App clipboard data was not readable within 250 ms; no paste."
        case .changed: "The clipboard changed while preparing Windows App paste; no paste."
        case .unavailable: "No readable text representation for Windows App paste."
        case .empty: "The Windows App clipboard text representation is empty; no paste."
        }
    }
}

struct WindowsClipboardRead: Sendable {
    let type: String
    let bytes: Int
}

/// Materializes one advertised text representation without copying it back.
/// This is local availability, not acknowledgement from the remote clipboard.
/// All external data access is confined to the shared read-only child process.
final class WindowsClipboardReader: Sendable {
    static let shared = WindowsClipboardReader()
    private let name: NSPasteboard.Name
    private let timeout: TimeInterval

    init(name: NSPasteboard.Name = .general, timeout: TimeInterval = 0.25) {
        self.name = name; self.timeout = timeout
    }

    func prepare(revision: Int) async throws -> WindowsClipboardRead {
        do {
            let response = try await IsolatedClipboardReader.shared.read(name: name, revision: revision, textOnly: true, timeout: timeout)
            guard let type = response.type, let bytes = response.bytes else { throw WindowsClipboardReadError.unavailable }
            return WindowsClipboardRead(type: type, bytes: bytes)
        } catch LocalClipboardError.changed { throw WindowsClipboardReadError.changed }
        catch IsolatedClipboardError.busy { throw WindowsClipboardReadError.busy }
        catch IsolatedClipboardError.timedOut { throw WindowsClipboardReadError.timedOut }
        catch IsolatedClipboardError.unavailable { throw WindowsClipboardReadError.unavailable }
    }

    /// Called only by ClipboardReaderProcess (or eager component fixtures).
    static func readOnce(name: NSPasteboard.Name, revision: Int) throws -> WindowsClipboardRead {
        let board = NSPasteboard(name: name)
        guard board.changeCount == revision else { throw WindowsClipboardReadError.changed }
        let types = board.types ?? []
        // Prefer the plain text requested by Windows App in the observed RDP
        // failures; support rich-only sources without decoding or normalizing.
        guard let type = [NSPasteboard.PasteboardType.string, .rtf, .html].first(where: types.contains) else {
            throw WindowsClipboardReadError.unavailable
        }
        guard board.changeCount == revision else { throw WindowsClipboardReadError.changed }
        let data = board.data(forType: type)
        guard board.changeCount == revision else { throw WindowsClipboardReadError.changed }
        guard let data else { throw WindowsClipboardReadError.unavailable }
        guard !data.isEmpty else { throw WindowsClipboardReadError.empty }
        return WindowsClipboardRead(type: type.rawValue, bytes: data.count)
    }
}
