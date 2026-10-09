import AppKit

/// Diagnostic only. A real activation round trip with a transparent owned window,
/// not a private
/// Windows App notification or an acknowledgement of remote clipboard delivery.
@MainActor
enum WindowsFocusRefreshProbe {
    typealias Action = @MainActor (pid_t, @MainActor () throws -> Void,
        @MainActor () throws -> Void, @MainActor (String) -> Void) async throws -> Void

    static func dictationExperimentEnabled(info: [String: Any]) -> Bool {
        info["RDDiagnosticLogging"] as? Bool == true && info["RDWindowsFocusRefreshExperiment"] as? Bool == true
    }

    enum Phase: String { case acquiringHelper, returningToTarget }
    enum Failure: Error { case timeout(Phase), unexpectedFocus, activationRefused }

    struct Environment {
        let helperPID: pid_t
        let front: () -> pid_t?
        let ownsKeyWindow: () -> Bool
        let show: () -> Void
        let returnToTarget: () -> Bool
        let close: () -> Void
        let now: () -> TimeInterval
        let pause: () async throws -> Void
        var nativeState: () -> String = { "unavailable" }
    }

    static func perform(targetPID: pid_t, environment e: Environment,
                        validateStable: @MainActor () throws -> Void,
                        validateTarget: @MainActor () throws -> Void,
                        log: @MainActor (String) -> Void) async throws {
        // A failure deadline, not a fixed wait. Ordinary builds never call this
        // from dictation. No retries, input or clipboard access occur here.
        let started = e.now(), deadline = started + 1
        var phase = Phase.acquiringHelper
        defer { e.close() }
        var lastState: String?
        func traceState(_ stage: String, force: Bool = false) {
            let state = "frontPID=\(e.front().map(String.init) ?? "none") ownsKeyWindow=\(e.ownsKeyWindow()) \(e.nativeState())"
            guard force || state != lastState else { return }
            lastState = state
            log("stage=focus-probe-\(stage) phase=\(phase.rawValue) elapsedMs=\(Int((e.now() - started) * 1000)) \(state)")
        }
        func check() throws {
            try Task.checkCancellation(); try validateStable()
            guard e.now() < deadline else { throw Failure.timeout(phase) }
        }
        do {
            try check(); try validateTarget()
            traceState("before-show", force: true)
            e.show()
            traceState("show-requested", force: true)
            while e.front() != e.helperPID || !e.ownsKeyWindow() {
                try check()
                traceState("waiting")
                guard e.front() == targetPID || e.front() == e.helperPID else {
                    throw Failure.unexpectedFocus
                }
                try await e.pause()
            }
            try check()
            log("stage=focus-probe-owned elapsedMs=\(Int((e.now() - started) * 1000))")
            phase = .returningToTarget
            guard e.returnToTarget() else { throw Failure.activationRefused }
            traceState("return-requested", force: true)
            while e.front() != targetPID {
                try check()
                traceState("waiting")
                // Do not reactivate Windows App after a user chooses another app
                // or another helper window. There is exactly one return request.
                guard e.front() == e.helperPID, e.ownsKeyWindow() else {
                    throw Failure.unexpectedFocus
                }
                try await e.pause()
            }
            try check(); try validateTarget()
            log("stage=focus-probe-returned elapsedMs=\(Int((e.now() - started) * 1000)) remoteReceipt=unverified")
        } catch {
            traceState("failed", force: true)
            throw error
        }
    }

    static func makeWindow() -> NSWindow {
        // Use the ordinary key/main window path already used by Settings.
        // A transient NSPanel plus activate() did not acquire focus in 111.1.4.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Windows clipboard test"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Keep the proven normal-window activation path, but do not render a
        // popup or intercept a mouse click while focus is borrowed. This is
        // applied before ordering the window; no fade/animation or extra wait.
        window.alphaValue = 0
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "Checking focus refresh…")
        label.frame = NSRect(x: 20, y: 22, width: 260, height: 20)
        window.contentView?.addSubview(label)
        window.center()
        return window
    }

    static func run(targetPID: pid_t, validateStable: @MainActor () throws -> Void,
                    validateTarget: @MainActor () throws -> Void, log: @MainActor (String) -> Void) async throws {
        guard let target = NSRunningApplication(processIdentifier: targetPID),
              target.bundleIdentifier == WindowsAppPasteMonitor.bundleIdentifier,
              !target.isTerminated else { throw Failure.unexpectedFocus }
        let window = makeWindow()
        let environment = Environment(helperPID: ProcessInfo.processInfo.processIdentifier,
            front: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            ownsKeyWindow: { NSApp.keyWindow === window },
            show: { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) },
            returnToTarget: {
                NSApp.yieldActivation(to: target)
                return target.activate(from: .current, options: [])
            },
            close: { window.close() },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { try await Task.sleep(for: .milliseconds(10)) },
            nativeState: {
                "appActive=\(NSApp.isActive) appHidden=\(NSApp.isHidden) policy=\(NSApp.activationPolicy().rawValue) windowVisible=\(window.isVisible) windowAlpha=\(window.alphaValue) windowKey=\(window.isKeyWindow) windowMain=\(window.isMainWindow) canBecomeKey=\(window.canBecomeKey) onActiveSpace=\(window.isOnActiveSpace)"
            })
        try await perform(targetPID: targetPID, environment: environment,
                          validateStable: validateStable, validateTarget: validateTarget, log: log)
    }
}
