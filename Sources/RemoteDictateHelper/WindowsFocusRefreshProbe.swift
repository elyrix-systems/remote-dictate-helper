import AppKit

/// Diagnostic only. A real, visible activation round trip, not a private
/// Windows App notification or an acknowledgement of remote clipboard delivery.
@MainActor
enum WindowsFocusRefreshProbe {
    enum Failure: Error { case timeout, unexpectedFocus, activationRefused }

    struct Environment {
        let helperPID: pid_t
        let front: () -> pid_t?
        let ownsKeyWindow: () -> Bool
        let show: () -> Void
        let returnToTarget: () -> Bool
        let close: () -> Void
        let now: () -> TimeInterval
        let pause: () async throws -> Void
    }

    static func perform(targetPID: pid_t, environment e: Environment,
                        validateStable: @MainActor () throws -> Void,
                        validateTarget: @MainActor () throws -> Void,
                        log: @MainActor (String) -> Void) async throws {
        // A failure deadline, not a fixed wait. The ordinary dictation adapter
        // never calls this experiment. No retries or input occur here.
        let started = e.now(), deadline = started + 1
        defer { e.close() }
        func check() throws {
            try Task.checkCancellation(); try validateStable()
            guard e.now() < deadline else { throw Failure.timeout }
        }
        try check(); try validateTarget()
        e.show()
        while e.front() != e.helperPID || !e.ownsKeyWindow() {
            try check()
            guard e.front() == targetPID || e.front() == e.helperPID else {
                throw Failure.unexpectedFocus
            }
            try await e.pause()
        }
        try check()
        log("stage=focus-probe-owned elapsedMs=\(Int((e.now() - started) * 1000))")
        guard e.returnToTarget() else { throw Failure.activationRefused }
        while e.front() != targetPID {
            try check()
            // Do not reactivate Windows App after a user chooses another app
            // or another helper window. There is exactly one return request.
            guard e.front() == e.helperPID, e.ownsKeyWindow() else {
                throw Failure.unexpectedFocus
            }
            try await e.pause()
        }
        try check(); try validateTarget()
        log("stage=focus-probe-returned elapsedMs=\(Int((e.now() - started) * 1000)) remoteReceipt=unverified")
    }

    static func run(targetPID: pid_t, validateStable: @MainActor () throws -> Void,
                    validateTarget: @MainActor () throws -> Void, log: @MainActor (String) -> Void) async throws {
        guard let target = NSRunningApplication(processIdentifier: targetPID),
              target.bundleIdentifier == WindowsAppPasteMonitor.bundleIdentifier,
              !target.isTerminated else { throw Failure.unexpectedFocus }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Windows clipboard test"
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "Checking focus refresh…")
        label.frame = NSRect(x: 20, y: 22, width: 260, height: 20)
        panel.contentView?.addSubview(label)
        panel.center()
        let environment = Environment(helperPID: ProcessInfo.processInfo.processIdentifier,
            front: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            ownsKeyWindow: { NSApp.keyWindow === panel },
            show: { panel.makeKeyAndOrderFront(nil); NSApp.activate() },
            returnToTarget: { target.activate(options: []) },
            close: { panel.close() },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { try await Task.sleep(for: .milliseconds(10)) })
        try await perform(targetPID: targetPID, environment: environment,
                          validateStable: validateStable, validateTarget: validateTarget, log: log)
    }
}
