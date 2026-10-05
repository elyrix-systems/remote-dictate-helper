import AppKit

/// Post one paste for an intercepted transaction. The former Backspace cleanup
/// was removed; it is available only in historical versions, never as a fallback.
final class GuardedPaste {
    func run(targetPID: pid_t, shortcut: ExplicitPasteShortcut,
             validateBeforeInput: () throws -> Void) -> PasteResult {
        do {
            try validateBeforeInput()
            try shortcut.checkReadiness(targetPID: targetPID)
            try validateBeforeInput()
            try shortcut.send(targetPID: targetPID)
            return PasteResult(didRun: true, detail: "Command+V posted; remote result unverified")
        } catch {
            return PasteResult(didRun: false, detail: "Paste stopped: \(error); no retry")
        }
    }
}

struct PasteResult {
    let didRun: Bool
    let detail: String
}
