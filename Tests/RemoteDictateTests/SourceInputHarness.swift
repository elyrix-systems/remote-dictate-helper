import AppKit
import RemoteDictateCore

/// Exercise the real event classifier without launching source apps or a tap.
@MainActor
final class SourceInputHarness {
    static var sources: [DictationSource] {
        AppSettings().sources + [DictationSource(bundleIdentifier: "example.custom-dictation", name: "Custom")]
    }
    private let filter: PasteEventFilter

    init(sources: [DictationSource], identifier: String?,
         observe: @escaping @MainActor (PasteInputEvent, PasteCaptureDecision?) -> Bool) {
        filter = PasteEventFilter(sources: sources, onEvent: { input, decision in
            DispatchQueue.main.async {
                _ = observe(input, decision)
                decision?.resolve(false)
            }
        }, onDisabled: { fail("No native tap is installed in source contract tests") },
        sourceIdentifier: { _ in identifier })
    }

    func paste(down: Bool) async throws -> Bool {
        let filter = filter
        let result = try await Task.detached {
            let event = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down))
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 202)
            return filter.handle(type: down ? .keyDown : .keyUp, event: event)
        }.value
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        return result
    }
}
