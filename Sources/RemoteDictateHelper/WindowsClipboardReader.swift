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
/// Only one blocking AppKit read can be outstanding, including after timeout.
final class WindowsClipboardReader: Sendable {
    static let shared = WindowsClipboardReader()
    private let worker = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.clipboard-read", qos: .userInitiated)
    private let slot = DispatchSemaphore(value: 1)
    private let read: @Sendable (Int) throws -> WindowsClipboardRead
    private let timeout: TimeInterval

    init(name: NSPasteboard.Name = .general, timeout: TimeInterval = 0.25,
         read: (@Sendable (Int) throws -> WindowsClipboardRead)? = nil) {
        self.timeout = timeout
        self.read = read ?? { revision in try Self.readOnce(name: name, revision: revision) }
    }

    func prepare(revision: Int) async throws -> WindowsClipboardRead {
        try Task.checkCancellation()
        guard reserveWorker() else { throw WindowsClipboardReadError.busy }
        let request = ClipboardReadRequest(timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                let timer = Task.detached { [timeout] in
                    do { try await Task.sleep(for: .seconds(timeout)) }
                    catch { return }
                    request.finish(.failure(WindowsClipboardReadError.timedOut))
                }
                worker.async { [slot, read] in
                    guard request.isPending else {
                        slot.signal(); timer.cancel()
                        request.finish(.failure(WindowsClipboardReadError.timedOut)); return
                    }
                    let result = Result { try autoreleasepool { try read(revision) } }
                    slot.signal(); timer.cancel()
                    request.finish(result)
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
    }

    // Zero-timeout admission only; never waits on the async caller's thread.
    private func reserveWorker() -> Bool { slot.wait(timeout: .now()) == .success }

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

/// Cancellation/timeout release the caller even if an external pasteboard owner
/// is blocked. Late worker results can neither resume twice nor trigger input.
private final class ClipboardReadRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let deadline: TimeInterval
    private var result: Result<WindowsClipboardRead, Error>?
    private var continuation: CheckedContinuation<WindowsClipboardRead, Error>?

    init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }

    var isPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return result == nil && ProcessInfo.processInfo.systemUptime < deadline
    }

    func install(_ continuation: CheckedContinuation<WindowsClipboardRead, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func finish(_ proposed: Result<WindowsClipboardRead, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        let resolved: Result<WindowsClipboardRead, Error>
        if case .success = proposed, ProcessInfo.processInfo.systemUptime >= deadline {
            resolved = .failure(WindowsClipboardReadError.timedOut)
        } else { resolved = proposed }
        result = resolved
        let waiting = continuation; continuation = nil
        lock.unlock()
        waiting?.resume(with: resolved)
    }
}
