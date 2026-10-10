import AppKit
import Darwin

enum IsolatedClipboardError: Error, CustomStringConvertible {
    case timedOut, busy, unavailable
    var description: String {
        switch self {
        case .timedOut: "Clipboard provider did not respond in time; no deferred paste."
        case .busy: "A clipboard read is still finishing; no deferred paste."
        case .unavailable: "Clipboard reader could not return a complete snapshot."
        }
    }
}

/// Only this read-only subprocess may ask external pasteboard providers for data.
/// Its output is a bounded binary plist in an anonymous pipe, never a disk file.
/// The same signed executable takes this branch before creating NSApplication,
/// login items, event taps or diagnostic logs.
enum ClipboardReaderProcess {
    static let argument = "--clipboard-reader"
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumWireBytes = 3 * maximumBytes + 1024 * 1024

    struct Response: Codable, Sendable {
        struct Item: Codable, Sendable {
            let type: String
            let data: Data
        }
        var items: [[Item]] = []
        var text: String?
        var type: String?
        var bytes: Int?
        var diagnosticText: DiagnosticText?
        var error: String?
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.dropFirst().first == argument else { return false }
        guard args.count == 5, let revision = Int(args[3]),
              ["snapshot", "text", "text-diagnostic"].contains(args[4]) else { return true }
        let response: Response
        do {
            let board = NSPasteboard(name: .init(args[2]))
            guard board.changeCount == revision else { throw LocalClipboardError.changed }
            if args[4] != "snapshot" {
                let result = try WindowsClipboardReader.readOnce(name: board.name, revision: revision,
                    includeDiagnosticText: args[4] == "text-diagnostic")
                response = Response(type: result.type, bytes: result.bytes, diagnosticText: result.diagnosticText)
            } else {
                let snapshot = try LocalClipboardSnapshot.capture(board)
                let text = board.string(forType: .string)
                guard (text?.utf8.count ?? 0) <= maximumBytes else { throw LocalClipboardError.tooLarge }
                guard board.changeCount == revision else { throw LocalClipboardError.changed }
                response = Response(items: snapshot.items.map { $0.map { .init(type: $0.type.rawValue, data: $0.data) } }, text: text)
            }
        } catch LocalClipboardError.changed { response = Response(error: "changed") }
        catch LocalClipboardError.tooLarge { response = Response(error: "tooLarge") }
        catch WindowsClipboardReadError.changed { response = Response(error: "changed") }
        catch WindowsClipboardReadError.empty { response = Response(error: "empty") }
        catch { response = Response(error: "unavailable") }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        if let data = try? encoder.encode(response), data.count <= maximumWireBytes {
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        return true
    }
}

/// There is at most one owned reader process. A hung provider is confined to it;
/// timeout/cancellation stop that child only. AppKit payload reads never run on
/// the menu thread, event-tap thread, or a worker sharing the parent's AppKit locks.
final class IsolatedClipboardReader: Sendable {
    static let shared = IsolatedClipboardReader()
    private let queue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.isolated-clipboard", qos: .userInitiated)
    private let slot = DispatchSemaphore(value: 1)
    private let executable: URL
    private let onAdmitted: (@Sendable () -> Void)?

    /// Optional instrumentation lets component tests await actual reader
    /// admission. Production leaves it nil; no callback runs under a lock.
    init(executable: URL = Bundle.main.executableURL!, onAdmitted: (@Sendable () -> Void)? = nil) {
        self.executable = executable; self.onAdmitted = onAdmitted
    }

    func read(name: NSPasteboard.Name, revision: Int, textOnly: Bool = false,
              includeDiagnosticText: Bool = false,
              timeout: TimeInterval = 0.25) async throws -> ClipboardReaderProcess.Response {
        try Task.checkCancellation()
        guard reserve() else { throw IsolatedClipboardError.busy }
        let request = Request(timeout: timeout)
        onAdmitted?()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [executable, slot] in
                    let result = Result { try Self.readProcess(executable: executable, name: name,
                        revision: revision, textOnly: textOnly, includeDiagnosticText: includeDiagnosticText, request: request) }
                    slot.signal()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { request.cancel() }
    }

    private func reserve() -> Bool { slot.wait(timeout: .now()) == .success }

    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        let deadline: TimeInterval
        init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw IsolatedClipboardError.timedOut }
        }
    }

    private static func spawn(executable: URL, name: NSPasteboard.Name, revision: Int,
                              textOnly: Bool, includeDiagnosticText: Bool, output: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw IsolatedClipboardError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let readFD = output.fileHandleForReading.fileDescriptor
        let writeFD = output.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addclose(&actions, readFD) == 0,
              posix_spawn_file_actions_addclose(&actions, writeFD) == 0 else { throw IsolatedClipboardError.unavailable }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw IsolatedClipboardError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        // Inherit only descriptors explicitly selected above, never unrelated
        // app sockets/files. The child gets no ability to post input from us.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw IsolatedClipboardError.unavailable
        }
        let arguments = [executable.path, ClipboardReaderProcess.argument, name.rawValue,
                         String(revision), textOnly ? (includeDiagnosticText ? "text-diagnostic" : "text") : "snapshot"]
        let argv = arguments.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw IsolatedClipboardError.unavailable }
        return pid
    }

    private static func readProcess(executable: URL, name: NSPasteboard.Name, revision: Int,
                                    textOnly: Bool, includeDiagnosticText: Bool, request: Request) throws -> ClipboardReaderProcess.Response {
        try request.check()
        let output = Pipe()
        let pid = try spawn(executable: executable, name: name, revision: revision,
                            textOnly: textOnly, includeDiagnosticText: includeDiagnosticText, output: output)
        try? output.fileHandleForWriting.close()
        defer {
            // Reap our exact child directly. Foundation's waitUntilExit run-loop
            // polling can add ~100 ms after EOF, exceeding the tap's 80 ms budget.
            var status: Int32 = 0
            var observed = waitpid(pid, &status, WNOHANG)
            while observed == -1 && errno == EINTR { observed = waitpid(pid, &status, WNOHANG) }
            if observed == 0 {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR { }
            }
            try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw IsolatedClipboardError.unavailable }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try request.check()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard count <= ClipboardReaderProcess.maximumWireBytes - data.count else { throw LocalClipboardError.tooLarge }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { break }
            else if errno == EAGAIN || errno == EINTR {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&descriptor, 1, 5)
            } else { throw IsolatedClipboardError.unavailable }
        }
        try request.check()
        guard let response = try? PropertyListDecoder().decode(ClipboardReaderProcess.Response.self, from: data) else {
            throw IsolatedClipboardError.unavailable
        }
        switch response.error {
        case nil: return response
        case "changed": throw LocalClipboardError.changed
        case "tooLarge": throw LocalClipboardError.tooLarge
        case "empty": throw WindowsClipboardReadError.empty
        default: throw IsolatedClipboardError.unavailable
        }
    }
}

/// Synchronous protocol guards use only an already prepared immutable value.
/// A newer revision invalidates it, including an equal-text copy. Production
/// never falls back to a synchronous provider read on a cache miss.
@MainActor
final class ClipboardAccess {
    struct Value {
        let revision: Int
        let snapshot: LocalClipboardSnapshot
        let text: String?
    }
    static let shared = ClipboardAccess()
    private var cached: (name: NSPasteboard.Name, value: Value)?
    private let immediateRead: ((NSPasteboard) throws -> Value)?
    private let reader: IsolatedClipboardReader

    init(reader: IsolatedClipboardReader = .shared, immediateRead: ((NSPasteboard) throws -> Value)? = nil) {
        self.reader = reader; self.immediateRead = immediateRead
    }

    func read(_ board: NSPasteboard) throws -> Value {
        if let immediateRead { return try immediateRead(board) }
        guard let cached, cached.name == board.name, cached.value.revision == board.changeCount else {
            throw LocalClipboardError.changed
        }
        return cached.value
    }

    func prepare(_ board: NSPasteboard, timeout: TimeInterval = 0.25) async throws {
        if immediateRead != nil { return }
        let revision = board.changeCount
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let result: ClipboardReaderProcess.Response
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw IsolatedClipboardError.timedOut }
            do {
                result = try await reader.read(name: board.name, revision: revision, timeout: remaining)
                break
            } catch IsolatedClipboardError.busy {
                // A cancelled baseline reader needs a few milliseconds to be
                // reaped before the candidate may use the one process slot.
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        try Task.checkCancellation()
        guard board.changeCount == revision else { throw LocalClipboardError.changed }
        let snapshot = LocalClipboardSnapshot(items: result.items.map { $0.map { .init(type: .init($0.type), data: $0.data) } })
        remember(board, revision: revision, snapshot: snapshot, text: result.text)
    }

    /// Only after an acknowledged write of these eagerly materialized bytes.
    /// Reading our own publication back via a second process could deadlock on
    /// AppKit's lazy writeObjects provider, which is serviced by this run loop.
    func remember(_ board: NSPasteboard, revision: Int, snapshot: LocalClipboardSnapshot, text: String?) {
        cached = (board.name, Value(revision: revision, snapshot: snapshot, text: text))
    }
}
