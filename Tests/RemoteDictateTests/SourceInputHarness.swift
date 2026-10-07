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
         observe: @escaping @MainActor (PasteInputEvent) -> Bool) {
        filter = PasteEventFilter(sources: sources, onEvent: { input, decision in
            // handle() is called synchronously on the main actor in this harness.
            MainActor.assumeIsolated {
                if let decision { decision.evaluate { observe(input) } }
                else { _ = observe(input) }
            }
        }, onDisabled: { fail("No native tap is installed in source contract tests") },
        sourceIdentifier: { _ in identifier })
    }

    func paste(down: Bool) throws -> Bool {
        let event = try expectUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down))
        event.flags = .maskCommand
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 202)
        return filter.handle(type: down ? .keyDown : .keyUp, event: event)
    }
}
