import AppKit

/// The native sequence verified in Windows App. Never accesses the clipboard.
/// Spacing is between key events, not a dictation-completion timeout.
@MainActor
enum WindowsAppPasteShortcut {
    enum Failure: Error { case cannotCreateEvents }

    private final class Release {
        let commandUp: CGEvent
        let vUp: CGEvent
        let post: (CGEvent) -> Void
        var commandIsDown = false
        var vIsDown = false
        init(commandUp: CGEvent, vUp: CGEvent, post: @escaping (CGEvent) -> Void) {
            self.commandUp = commandUp; self.vUp = vUp; self.post = post
        }
        func finish() {
            if vIsDown { vIsDown = false; post(vUp) }
            if commandIsDown { commandIsDown = false; post(commandUp) }
        }
    }

    static func send(
        validate: () throws -> Void,
        post: @escaping (CGEvent) -> Void,
        registerCleanup: (@escaping () -> Void) -> Void = { _ in },
        pause: () async throws -> Void = { try await Task.sleep(for: .milliseconds(25)) }
    ) async throws {
        try validate()
        guard let source = CGEventSource(stateID: .privateState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw Failure.cannotCreateEvents
        }
        // Preserve the constructor's device-specific Command bit and event type.
        // Accepted physical input also carries the non-coalesced bit.
        commandDown.flags.insert(.maskNonCoalesced)
        commandUp.flags.insert(.maskNonCoalesced)
        vDown.flags = commandDown.flags; vUp.flags = commandDown.flags
        let release = Release(commandUp: commandUp, vUp: vUp, post: post)
        registerCleanup { release.finish() }
        release.commandIsDown = true
        post(commandDown)
        defer { release.finish() }
        try await pause(); try Task.checkCancellation(); try validate()
        post(vDown); release.vIsDown = true
        try await pause(); try Task.checkCancellation(); try validate()
        post(vUp); release.vIsDown = false
        try await pause()
    }
}
