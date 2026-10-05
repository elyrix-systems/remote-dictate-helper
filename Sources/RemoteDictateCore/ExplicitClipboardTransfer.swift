import Foundation

public struct SharedClipboardMenuState: Equatable, Sendable {
    public let sharedClipboardEnabled: Bool
    public let sendClipboardEnabled: Bool

    public init(sharedClipboardEnabled: Bool, sendClipboardEnabled: Bool) {
        self.sharedClipboardEnabled = sharedClipboardEnabled
        self.sendClipboardEnabled = sendClipboardEnabled
    }
}

public protocol ExplicitClipboardTransferDriver {
    func readState() throws -> SharedClipboardMenuState
    func validateTargetAndClipboard() throws
    /// Optionally prepare a new transcript, only while automatic sharing is off.
    func prepareClipboard() throws
    /// Return only after observing the requested state; never retry a toggle blindly.
    func setSharedClipboardEnabled(_ enabled: Bool) throws
    func sendClipboard() throws
    /// Send only the restored snapshot authorized by this validation closure.
    /// Revalidate immediately before the external action. No paste/input action.
    func sendRestoredClipboard(validating validateClipboard: () throws -> Void) throws
}

public enum ExplicitClipboardTransferError: Error, CustomStringConvertible {
    case sharedClipboardInitiallyOff
    case sendUnavailable
    case restorationFailed(operation: String?, restoration: String)
    case restoredClipboardSendFailed(String)

    public var description: String {
        switch self {
        case .sharedClipboardInitiallyOff:
            "Enable Use Shared Clipboard before transferring text."
        case .sendUnavailable:
            "Send Clipboard is unavailable; no paste shortcut sent."
        case let .restorationFailed(operation, restoration):
            "Use Shared Clipboard could not be restored. Re-enable it for the original connection. Restore: \(restoration). Operation: \(operation ?? "completed")."
        case let .restoredClipboardSendFailed(reason):
            "Sharing was re-enabled, but sending the restored clipboard failed: \(reason). Local clipboard retention is unverified."
        }
    }
}

/// An explicit restoration obligation for the captured connection. Keep alive
/// until local clipboard restoration finishes, including skipped/failed outcomes.
/// No implicit deinit action and no retry of an ambiguous restoration attempt.
public final class SharedClipboardTransferLease {
    private let driver: any ExplicitClipboardTransferDriver
    private var restoration: Result<Void, Error>?

    fileprivate init(driver: any ExplicitClipboardTransferDriver) { self.driver = driver }

    public func restoreSharing(
        after operationError: Error? = nil,
        sendingRestoredClipboard validateClipboard: (() throws -> Void)? = nil
    ) throws {
        if let restoration { return try restoration.get() }
        let result = Result<Void, Error> {
            var sendError: Error?
            if let validateClipboard {
                do {
                    try validateClipboard()
                    try driver.sendRestoredClipboard(validating: validateClipboard)
                } catch { sendError = error }
            }
            // Always attempt preference recovery, including when the snapshot
            // changed or Send failed. Never repeat either Send or a toggle.
            do {
                try driver.setSharedClipboardEnabled(true)
                let state = try driver.readState()
                guard state.sharedClipboardEnabled else {
                    throw SharedClipboardSettingError.unconfirmed(expected: true, observed: state)
                }
            } catch {
                throw ExplicitClipboardTransferError.restorationFailed(
                    operation: (sendError ?? operationError).map { String(describing: $0) },
                    restoration: String(describing: error)
                )
            }
            if let sendError {
                throw ExplicitClipboardTransferError.restoredClipboardSendFailed(String(describing: sendError))
            }
        }
        restoration = result
        try result.get()
    }
}

/// One-shot transfer. The caller holds sharing off through paste and local
/// restoration, then releases the returned lease.
public struct ExplicitClipboardTransfer {
    public init() {}

    public func begin(using driver: any ExplicitClipboardTransferDriver) throws -> SharedClipboardTransferLease {
        try driver.validateTargetAndClipboard()
        guard try driver.readState().sharedClipboardEnabled else {
            throw ExplicitClipboardTransferError.sharedClipboardInitiallyOff
        }

        let lease = SharedClipboardTransferLease(driver: driver)
        do {
            try driver.setSharedClipboardEnabled(false)
            let state = try driver.readState()
            guard !state.sharedClipboardEnabled else {
                throw SharedClipboardSettingError.unconfirmed(expected: false, observed: state)
            }
            try driver.validateTargetAndClipboard()
            try driver.prepareClipboard()
            try driver.validateTargetAndClipboard()
            let preparedState = try driver.readState()
            guard !preparedState.sharedClipboardEnabled else {
                throw SharedClipboardSettingError.unconfirmed(expected: false, observed: preparedState)
            }
            guard preparedState.sendClipboardEnabled else {
                throw ExplicitClipboardTransferError.sendUnavailable
            }
            try driver.sendClipboard()
            try driver.validateTargetAndClipboard()
        } catch {
            // A failed toggle or Send can already have affected the other app.
            try lease.restoreSharing(after: error)
            throw error
        }
        return lease
    }
}
