import Foundation

public enum SharedClipboardSettingError: Error, CustomStringConvertible {
    case unconfirmed(expected: Bool, observed: SharedClipboardMenuState)

    public var description: String {
        switch self {
        case let .unconfirmed(expected, observed):
            "Use Shared Clipboard was not confirmed: requested=\(expected), observed=\(observed.sharedClipboardEnabled), Send Clipboard enabled=\(observed.sendClipboardEnabled)."
        }
    }
}

/// Confirm only the requested setting. Send availability is a separate gate
/// after clipboard preparation; it is not evidence that a toggle succeeded.
public struct SharedClipboardSettingTransition {
    public init() {}

    public func run(
        enabled: Bool,
        readState: () throws -> SharedClipboardMenuState,
        toggleOnce: () throws -> Void,
        onState: (SharedClipboardMenuState) -> Void = { _ in },
        timeout: TimeInterval = 1,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws {
        var state = try readState()
        onState(state)
        guard state.sharedClipboardEnabled != enabled else { return }
        try toggleOnce()
        let deadline = now() + timeout
        while true {
            let observed = try readState()
            if observed != state { onState(observed) }
            state = observed
            if state.sharedClipboardEnabled == enabled { return }
            let remaining = deadline - now()
            guard remaining > 0 else {
                throw SharedClipboardSettingError.unconfirmed(expected: enabled, observed: state)
            }
            pause(min(0.02, remaining))
        }
    }
}
