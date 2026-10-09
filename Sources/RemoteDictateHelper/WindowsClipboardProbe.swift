import AppKit

/// Explicit diagnostic experiment, never part of automatic dictation. Keeps
/// payload lifetime independent of the dictation app while using the production
/// native sender. Posted keys are not a remote clipboard acknowledgement.
@MainActor
final class WindowsClipboardProbe {
    struct Step {
        let label: String
        let lifetime: TimeInterval
        let delay: TimeInterval
        var refreshFocus = false
    }
    enum Mode: String {
        case sustained, transient, comparison, focusComparison
        var lifetime: TimeInterval { self == .sustained ? 5 : 0.65 }
        var steps: [Step] {
            if self == .focusComparison {
                let pair = [Step(label: "DIRECT", lifetime: 5, delay: 0.025),
                            Step(label: "REFRESH", lifetime: 5, delay: 0.025, refreshFocus: true)]
                return pair + pair + pair
            }
            guard self == .comparison else {
                return [Step(label: rawValue, lifetime: lifetime, delay: 0.025)]
            }
            // Compare lifetime and pre-paste delay independently. Every trial
            // keeps the same remote window and input stamp; no refocus/retry.
            let trio = [Step(label: "SHORT", lifetime: 0.65, delay: 0.025),
                        Step(label: "HOLD", lifetime: 5, delay: 0.025),
                        Step(label: "WAIT", lifetime: 5, delay: 1)]
            return trio + trio
        }
    }
    enum Failure: Error { case busy, inputUnavailable, targetTimeout, changed }
    private let board: NSPasteboard
    private let access: ClipboardAccess
    private let target: () -> pid_t?
    private let input: () -> WindowsAppPasteMonitor.InputStamp?
    private let captureWindow: @MainActor (pid_t) throws -> (() throws -> Void)
    private let ready: (pid_t) throws -> Void
    typealias RefreshFocus = WindowsFocusRefreshProbe.Action
    private let refreshFocus: RefreshFocus
    private let post: (CGEvent) -> Void
    private let now: () -> TimeInterval
    private let pause: (TimeInterval) async throws -> Void
    private let protectedPause: (TimeInterval) async -> Void
    private let log: (String) -> Void
    private let status: (String) -> Void
    private let finished: (Bool) -> Void
    private var task: Task<Void, Never>?
    private(set) var isBusy = false

    init(board: NSPasteboard = .general, access: ClipboardAccess = .shared,
         target: @escaping () -> pid_t? = {
             let app = NSWorkspace.shared.frontmostApplication
             return app?.bundleIdentifier == WindowsAppPasteMonitor.bundleIdentifier ? app?.processIdentifier : nil
         }, input: @escaping () -> WindowsAppPasteMonitor.InputStamp?,
         captureWindow: @escaping @MainActor (pid_t) throws -> (() throws -> Void) = WindowsAppPasteMonitor.windowValidation,
         ready: ((pid_t) throws -> Void)? = nil,
         refreshFocus: @escaping RefreshFocus = { pid, stable, target, log in
             try await WindowsFocusRefreshProbe.run(targetPID: pid, validateStable: stable,
                                                   validateTarget: target, log: log)
         },
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         protectedPause: @escaping (TimeInterval) async -> Void = { seconds in
             // Cancellation must not truncate protection after a partial paste.
             await Task.detached { try? await Task.sleep(for: .seconds(seconds)) }.value
         }, log: @escaping (String) -> Void = { DiagnosticLog.shared.record($0) },
         status: @escaping (String) -> Void = { _ in }, finished: @escaping (Bool) -> Void = { _ in }) {
        self.board = board; self.access = access; self.target = target; self.input = input
        self.captureWindow = captureWindow; self.post = post; self.now = now
        self.refreshFocus = refreshFocus
        self.pause = pause; self.protectedPause = protectedPause
        self.log = log; self.status = status; self.finished = finished
        self.ready = ready ?? { pid in
            try ExplicitPasteShortcut(targetIsFrontmost: { target() == $0 }).checkReadiness(targetPID: pid)
        }
    }

    func start(_ mode: Mode) throws {
        guard !isBusy else { throw Failure.busy }
        guard input() != nil else { throw Failure.inputUnavailable }
        isBusy = true
        task = Task { await run(mode) }
    }

    func cancel() { task?.cancel() }

    private func run(_ mode: Mode) async {
        let id = UUID(), started = now()
        let old = "RDH-OLD-\(id.uuidString.prefix(8))"
        let new = "RDH-NEW-\(id.uuidString.prefix(8))"
        var original: LocalClipboardSnapshot?
        var ownedRevision: Int?
        var pasteStarted: TimeInterval?
        var success = false
        var cleanupSucceeded = true
        func trace(_ message: String) {
            log("op=\(id) client=windows-probe mode=\(mode.rawValue) elapsedMs=\(Int((now() - started) * 1000)) \(message)")
        }
        func validateOwnership() throws {
            guard let ownedRevision, board.changeCount == ownedRevision else {
                trace("cancel reason=clipboard_changed expected=\(ownedRevision.map(String.init) ?? "none") actual=\(board.changeCount)")
                throw Failure.changed
            }
        }
        func publish(_ snapshot: LocalClipboardSnapshot, text: String?) throws {
            let items = try snapshot.materialize()
            try validateOwnership()
            ownedRevision = board.clearContents()
            if !items.isEmpty, !board.writeObjects(items) { throw LocalClipboardError.writeFailed }
            access.remember(board, revision: ownedRevision!, snapshot: snapshot, text: text)
        }
        func marker(_ value: String) -> LocalClipboardSnapshot {
            .init(items: [[.init(type: .string, data: Data(value.utf8))]])
        }
        do {
            trace("stage=started oldMarker=\(old) newMarker=\(new) trials=\(mode.steps.count)")
            status("Test: preserving clipboard")
            try await access.prepare(board)
            try Task.checkCancellation()
            let saved = try access.read(board)
            original = saved.snapshot; ownedRevision = saved.revision
            try publish(marker(old), text: old)
            trace("stage=old-published revision=\(ownedRevision!)")
            status("Test: click an empty field in Windows App")
            let deadline = now() + 20
            var pid: pid_t?
            while pid == nil {
                try Task.checkCancellation(); try validateOwnership()
                guard now() < deadline else { throw Failure.targetTimeout }
                pid = target()
                if pid == nil { try await pause(0.05) }
            }
            let targetPID = pid!
            // OLD is published before entering the remote window. NEW is
            // published after focus settles, with no subsequent focus switch.
            try await pause(1)
            guard target() == targetPID, let stamp = input() else { throw Failure.changed }
            let validateWindow = try captureWindow(targetPID)
            func validateStable() throws {
                try Task.checkCancellation(); try validateOwnership()
                guard input() == stamp else {
                    trace("cancel reason=input_changed")
                    throw Failure.changed
                }
            }
            func validate() throws {
                try validateStable()
                guard target() == targetPID else {
                    trace("cancel reason=context_or_input_changed expectedPID=\(targetPID) actualPID=\(target().map(String.init) ?? "none") expectedKeys=\(stamp.keys) actualKeys=\(input().map { String($0.keys) } ?? "none")")
                    throw Failure.changed
                }
                try validateWindow()
            }
            for (index, step) in mode.steps.enumerated() {
                let trial = index + 1
                let trialText = mode.steps.count > 1 ? "\(new)-\(trial)-\(step.label)\n" : new
                try validate(); try ready(targetPID)
                try publish(marker(trialText), text: trialText)
                let published = now()
                trace("stage=new-published trial=\(trial) profile=\(step.label) revision=\(ownedRevision!) targetPID=\(targetPID) lifetimeMs=\(Int(step.lifetime * 1000)) delayMs=\(Int(step.delay * 1000))")
                status("Test: inserting marker \(trial)/\(mode.steps.count) (\(step.label))")
                try await pause(step.delay)
                try validate(); try ready(targetPID)
                if step.refreshFocus {
                    try await refreshFocus(targetPID, validateStable, validate, trace)
                    try validate(); try ready(targetPID)
                }
                try await WindowsAppPasteShortcut.send(validate: validate, post: { event in
                    if event.type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 9 {
                        pasteStarted = self.now()
                    }
                    self.post(event)
                    trace("stage=native-paste trial=\(trial) type=\(event.type.rawValue) key=\(event.getIntegerValueField(.keyboardEventKeycode))")
                }, pause: { try await self.pause(0.025) })
                trace("stage=paste-posted trial=\(trial) remoteReceipt=unverified")
                try await pause(max(0, step.lifetime - (now() - published)))
                try Task.checkCancellation()
                // Deliberately emulate source restoration in this controlled test.
                // New user copies always win; focus changes never cause another paste.
                try publish(marker(old), text: old)
                trace("stage=old-restored trial=\(trial) revision=\(ownedRevision!) remoteReceipt=unverified")
                if trial < mode.steps.count { try await pause(1) }
            }
            success = true
        } catch {
            trace("stage=stopped reason=\(error)")
            status("Test stopped; finishing clipboard cleanup")
        }
        if let pasteStarted {
            let remaining = pasteStarted + 5 - now()
            if remaining > 0 { await protectedPause(remaining) }
        }
        if let original, let ownedRevision, board.changeCount == ownedRevision {
            do {
                try publish(original, text: nil)
                trace("stage=original-restored")
            } catch {
                success = false; cleanupSucceeded = false
                trace("stage=original-restore-failed reason=\(error)")
            }
        } else if original != nil {
            trace("stage=original-restore-skipped reason=newer-copy")
        }
        status(!cleanupSucceeded ? "Test: original clipboard restoration failed"
            : success ? "Test posted \(mode.steps.count) marker(s): check remote results" : "Test stopped: see diagnostic log")
        trace("stage=finished posted=\(pasteStarted != nil) remoteReceipt=unverified")
        task = nil; isBusy = false; finished(cleanupSucceeded)
    }
}
