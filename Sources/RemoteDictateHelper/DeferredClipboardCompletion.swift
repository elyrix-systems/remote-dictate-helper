import Foundation
import RemoteDictateCore

enum ClipboardSharingObservation {
    case waitingForTarget, waitingForMenu, enabled, disabled
}

/// Read-only confirmation after an enable request lost its observable menu.
/// Time spent outside the original target never proves that sharing is off.
@MainActor
final class ClipboardSharingConfirmation {
    private let now: () -> TimeInterval
    private var availableSince: TimeInterval?
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }

    func readiness(_ observation: ClipboardSharingObservation) throws -> ClipboardCompletionReadiness {
        switch observation {
        case .waitingForTarget: availableSince = nil; return .waitingForTarget
        case .waitingForMenu: availableSince = nil; return .waitingForMenu
        case .enabled: return .ready
        case .disabled:
            let time = now()
            if availableSince == nil { availableSince = time }
            guard time - availableSince! < 1 else { throw ClipboardCompletionError.sharingUnconfirmed }
            return .waitingForMenu
        }
    }
}

enum ClipboardCompletionReadiness: Equatable {
    case ready, waitingForTarget, waitingForMenu
}

enum ClipboardCompletionError: Error, CustomStringConvertible {
    case alreadyPending, sharingUnconfirmed
    var description: String {
        switch self {
        case .alreadyPending: "Clipboard completion is already pending."
        case .sharingUnconfirmed: "Clipboard sync could not be confirmed for the original connection."
        }
    }
}

/// Wait on observed readiness before ONE completion attempt. Never activates
/// another app, repeats a failed action, posts keys or changes a clipboard.
@MainActor
final class DeferredClipboardCompletion {
    private struct Pending {
        let probe: () throws -> ClipboardCompletionReadiness
        let complete: () throws -> Void
        let onWaiting: (ClipboardCompletionReadiness) -> Void
        let onFinished: (Result<Void, Error>) -> Void
    }
    private var pending: Pending?
    private var timer: Timer?
    private var lastReadiness: ClipboardCompletionReadiness?
    private let automaticallyPoll: Bool
    var hasPendingCompletion: Bool { pending != nil }

    init(automaticallyPoll: Bool = true) {
        self.automaticallyPoll = automaticallyPoll
    }

    func start(
        probe: @escaping () throws -> ClipboardCompletionReadiness,
        complete: @escaping () throws -> Void,
        onWaiting: @escaping (ClipboardCompletionReadiness) -> Void,
        onFinished: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard pending == nil else { throw ClipboardCompletionError.alreadyPending }
        pending = Pending(probe: probe, complete: complete, onWaiting: onWaiting, onFinished: onFinished)
        lastReadiness = nil
        if automaticallyPoll {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        poll()
    }

    /// Verification only: never calls the original action again. Preserve a
    /// preceding restored-clipboard Send failure even when sharing is enabled.
    func startConfirmation(after error: Error,
                           observe: @escaping () throws -> ClipboardSharingObservation,
                           now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           onWaiting: @escaping (ClipboardCompletionReadiness) -> Void,
                           onFinished: @escaping (Result<Void, Error>) -> Void) throws {
        guard case let ExplicitClipboardTransferError.restorationFailed(operation, _) = error else { throw error }
        let confirmation = ClipboardSharingConfirmation(now: now)
        try start(probe: { try confirmation.readiness(observe()) }, complete: {
            if let operation { throw ExplicitClipboardTransferError.restoredClipboardSendFailed(operation) }
        }, onWaiting: onWaiting, onFinished: onFinished)
    }

    /// Separate from scheduling for deterministic, no-UI tests.
    func poll() {
        guard let pending else { return }
        do {
            let readiness = try pending.probe()
            guard readiness == .ready else {
                if readiness != lastReadiness {
                    lastReadiness = readiness
                    pending.onWaiting(readiness)
                }
                return
            }
            // Clear the poll obligation before invoking external code. The app
            // still holds its transfer lease, preventing a second operation.
            clear()
            pending.onFinished(Result { try pending.complete() })
        } catch {
            clear()
            pending.onFinished(.failure(error))
        }
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        pending = nil
        lastReadiness = nil
    }
}
