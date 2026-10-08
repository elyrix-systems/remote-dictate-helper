import AppKit

/// Metadata by default; transcript capture requires a separate explicit opt-in.
/// Disk I/O never runs on an input callback or main queue.
/// Queue admission and file retention are bounded so prolonged diagnostics cannot
/// grow indefinitely or hold up paste interception when storage is slow.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog(
        enabled: Bundle.main.object(forInfoDictionaryKey: "RDDiagnosticLogging") as? Bool == true,
        textEnabled: Bundle.main.object(forInfoDictionaryKey: "RDDiagnosticTextLogging") as? Bool == true,
        destination: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RemoteDictateHelper/debug.log"))
    let enabled: Bool
    let textEnabled: Bool
    let destination: URL
    private let queue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.diagnostics", qos: .utility)
    private let slots = DispatchSemaphore(value: 512)
    private let textSlots = DispatchSemaphore(value: 8)
    private let droppedLock = NSLock()
    private var dropped = 0
    private let maximumBytes: Int
    private let archives: Int
    private let session = UUID().uuidString
    private var sequence: UInt64 = 0 // writer queue only

    init(enabled: Bool, textEnabled: Bool = false, destination: URL, maximumBytes: Int = 2 * 1024 * 1024, archives: Int = 3) {
        self.enabled = enabled; self.destination = destination
        self.textEnabled = enabled && textEnabled
        self.maximumBytes = max(1024, maximumBytes); self.archives = max(1, archives)
    }

    func record(_ message: String) {
        guard enabled else { return }
        let metadata = Self.token(message, limit: 4096)
        enqueue { metadata }
    }

    /// Contents belong to the captured local source revision, not to the remote
    /// field. Subsequent stages/cancellations share the operation identifier.
    func recordText(operation: UUID, client: String, revision: Int, type: String, value: DiagnosticText) {
        guard textEnabled else { return }
        guard textSlots.wait(timeout: .now()) == .success else {
            droppedLock.lock(); dropped += 1; droppedLock.unlock(); return
        }
        struct Payload: Encodable {
            let text: String?
            let truncated: Bool
            let unavailableReason: String?
        }
        let context = "op=\(operation) client=\(Self.token(client)) stage=local-text-captured revision=\(revision) type=\(Self.token(type)) remoteReceipt=unverified"
        let accepted = enqueue { [self] in
            defer { textSlots.signal() }
            let payload = Payload(text: value.text, truncated: value.truncated, unavailableReason: value.unavailableReason)
            let data = try JSONEncoder().encode(payload)
            return "\(context) payload=\(String(decoding: data, as: UTF8.self))"
        }
        if !accepted { textSlots.signal() }
    }

    @discardableResult
    private func enqueue(_ message: @escaping @Sendable () throws -> String) -> Bool {
        guard enabled else { return false }
        guard slots.wait(timeout: .now()) == .success else {
            droppedLock.lock(); dropped += 1; droppedLock.unlock(); return false
        }
        droppedLock.lock(); let skipped = dropped; dropped = 0; droppedLock.unlock()
        let date = Date.now, uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            defer { slots.signal() }
            sequence &+= 1
            do {
                let metadata = "droppedSinceLast=\(skipped) " + (try message())
                try rotateIfNeeded()
                try OperationalLog(destination: destination).append(
                    "session=\(session) seq=\(sequence) uptime=\(String(format: "%.6f", uptime)) \(metadata)", at: date,
                    enforcePrivatePermissions: textEnabled)
            } catch {
                // Diagnostic failure must not alter the paste protocol.
                // No retries or synchronous fallback on the caller's thread.
            }
        }
        return true
    }

    func flush() { queue.sync {} } // shutdown/tests only, never during paste

    private func rotateIfNeeded() throws {
        let manager = FileManager.default
        // lstat-style attributes do not follow a symlink. Refuse rotation too.
        guard let attributes = try? manager.attributesOfItem(atPath: destination.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw POSIXError(.EINVAL) }
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 >= maximumBytes else { return }
        for index in stride(from: archives, through: 1, by: -1) {
            let to = destination.appendingPathExtension(String(index))
            if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
            let from = index == 1 ? destination : destination.appendingPathExtension(String(index - 1))
            if manager.fileExists(atPath: from.path) { try manager.moveItem(at: from, to: to) }
        }
    }

    static func token(_ value: String, limit: Int = 200) -> String {
        String(value.prefix(limit).map { $0.isNewline || $0.asciiValue == 0 ? " " : $0 })
    }

    static func app(_ pid: pid_t?) -> String {
        guard let pid else { return "none" }
        let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
        return "\(pid):\(token(identifier))"
    }

    static var front: String {
        shared.enabled ? app(NSWorkspace.shared.frontmostApplication?.processIdentifier) : "diagnostics-disabled"
    }
}

extension PasteInputEvent {
    /// Only the first cancelling event is recorded, never the typed character,
    /// scan code of ordinary keys, cursor coordinates or text from an AX element.
    var diagnosticMetadata: String {
        "kind=\(kind) keyClass=\(kind == .mouse ? "mouse" : key == 9 ? "v" : "other") sourcePID=\(pid) sourceBundle=\(DiagnosticLog.token(sourceBundle ?? "unknown")) selected=\(fromDictation) command=\(command) flags=0x\(String(flags, radix: 16)) repeat=\(autorepeat) sequence=\(sequence.map(String.init) ?? "none") eventUptime=\(String(format: "%.6f", eventUptime))"
    }
}
