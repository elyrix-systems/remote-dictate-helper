import Foundation

enum ClipboardCompletionReadiness: Equatable {
    case ready, waitingForTarget, waitingForMenu
}

enum ClipboardCompletionError: Error, CustomStringConvertible {
    case alreadyPending
    var description: String {
        switch self {
        case .alreadyPending: "Clipboard completion is already pending."
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
