import AppKit

func testDiagnosticLogStorage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("debug.log")
    let disabled = DiagnosticLog(enabled: false, destination: destination)
    disabled.record("must not create a file"); disabled.flush()
    expectFalse(FileManager.default.fileExists(atPath: destination.path))
    let log = DiagnosticLog(enabled: true, destination: destination, maximumBytes: 1024, archives: 2)
    for index in 0..<24 { log.record("event=\(index) " + String(repeating: "metadata ", count: 30)) }
    log.record("last\nforged-line\0end"); log.flush()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    expectEqual(files.count, 3, "Retention is bounded to current plus two archives")
    var all = ""
    for file in files {
        let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
        expectEqual(metadata[.posixPermissions] as? Int, 0o600)
        let data = try String(contentsOf: file, encoding: .utf8)
        for line in data.split(separator: "\n") { expectTrue(line.contains("session=") && line.contains("uptime=")) }
        all += data
    }
    expectTrue(all.contains("last forged-line end"))
    let protected = directory.appendingPathComponent("protected")
    try "keep".write(to: protected, atomically: true, encoding: .utf8)
    let link = directory.appendingPathComponent("link.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)
    let redirected = DiagnosticLog(enabled: true, destination: link, maximumBytes: 1024)
    redirected.record("must not follow symlink"); redirected.flush()
    expectEqual(try String(contentsOf: protected, encoding: .utf8), "keep")
}

@MainActor
func testCaptureCancellationDiagnostics() throws {
    for reason in ["click", "key", "target", "clipboard-timeout", "unknown-return"] {
        let board = NSPasteboard(name: .init("rdh-diagnostic-\(UUID())"))
        defer { board.releaseGlobally() }
        var target: pid_t? = 100
        var time: TimeInterval = 0
        var id: UUID?
        var lines: [String] = []
        let monitor = DictationPasteMonitor(board: board, access: eagerTestClipboardAccess(), targetPID: { target }, isAvailable: { true },
            now: { time }, onCaptured: { id = $0 }, onError: { fail("\($0)") }, diagnostic: { lines.append($0) })
        func copy(_ value: String) { board.clearContents(); expectTrue(board.setString(value, forType: .string)) }
        copy("SECRET-ORIGINAL"); monitor.sample(); copy("SECRET-TRANSCRIPT")
        expectTrue(monitor.observe(.init(kind: .down, key: 9, command: true, pid: 42, fromDictation: true)))
        let operation = try expectUnwrap(id)
        expectTrue(monitor.observe(.init(kind: .up, key: 9, command: false, pid: 42, fromDictation: true)))
        switch reason {
        case "click": monitor.observe(.init(kind: .mouse, key: 0, command: false, pid: 0, fromDictation: false))
        case "key": monitor.observe(.init(kind: .down, key: 33, command: false, pid: 0, fromDictation: false))
        case "target": target = 200
        case "unknown-return": copy("SECRET-UNKNOWN")
        default: time = 1; expectNil(try monitor.completeIfReleased(operation)); time = 5
        }
        let revision = board.changeCount
        expectThrows(try monitor.completeIfReleased(operation))
        expectEqual(board.changeCount, revision, "Debugging must never rewrite clipboard")
        let combined = lines.joined(separator: "\n")
        expectTrue(combined.contains("op=\(operation)")); expectFalse(combined.contains("SECRET-"))
        switch reason {
        case "click": expectTrue(combined.contains("reason=input_event") && combined.contains("kind=mouse"))
        case "key": expectTrue(combined.contains("keyClass=other")); expectFalse(combined.contains("key=33"))
        case "target": expectTrue(combined.contains("expectedPID=100 observedTargetPID=200"))
        case "unknown-return": expectTrue(combined.contains("reason=returned_clipboard_unmatched"))
        default: expectTrue(combined.contains("reason=clipboard_return_timeout") && combined.contains("keyUp=true"))
        }
        monitor.discard(operation)
    }
}
