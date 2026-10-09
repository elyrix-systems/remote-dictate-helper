import AppKit
import RemoteDictateCore

@MainActor
final class RemoteDictateApp: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let settingsStore = SettingsStore(fileURL: defaultSettingsURL())
    private let log = OperationalLog(destination: defaultLogURL())
    private var settings = AppSettings()
    private var monitor: DictationPasteMonitor?
    private var windowsMonitor: WindowsAppPasteMonitor?
    private var runningTask: Task<Void, Never>?
    private var operationGeneration = 0
    private var settingsWindowController: SettingsWindowController?
    private var lastError: String?
    private var clipboardSession: LocalClipboardRestoration.Session?
    private var sharedClipboardLease: SharedClipboardTransferLease?
    private var sharedClipboardDriver: ScreenSharingClipboardMenu?
    private let sharingCompletion = DeferredClipboardCompletion()
    private var completionPastePosted = false
    private var contextCancelled = false
    private var quitAfterClipboardRestore = false
    private let diagnosticContext = DiagnosticContextObserver()
    private var windowsProbe: WindowsClipboardProbe?
    private let windowsFocusExperiment = WindowsFocusRefreshProbe.dictationExperimentEnabled(info: Bundle.main.infoDictionary ?? [:])
    private lazy var launchAtLogin = LaunchAtLogin(report: { [weak self] in self?.appendLog("login item \($0)") })
    private var busy: Bool {
        runningTask != nil || sharedClipboardLease != nil || clipboardRestoration.hasPendingRestore || clipboardSession != nil
            || windowsMonitor?.isBusy == true
            || windowsProbe?.isBusy == true
    }
    private var canAcceptPaste: Bool { !quitAfterClipboardRestore && !busy }
    private lazy var clipboardRestoration = LocalClipboardRestoration(onOutcome: { [weak self] outcome, receipt in
        guard let self else { return }
        self.appendLog("local clipboard restore outcome=\(outcome.rawValue)")
        if outcome == .failed { self.lastError = "Local clipboard restoration failed"; self.setStatus("Error: clipboard restore failed") }
        self.restoreSharedClipboardAfterLocalCompletion(receipt: receipt)
        if self.sharedClipboardLease == nil { self.completePendingQuit(success: outcome != .failed) }
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also recognize an earlier installation of this product whose bundle
        // identifier differs. Never stop another process as part of startup.
        let ownBundle = Bundle.main.bundleURL.lastPathComponent
        let others = NSWorkspace.shared.runningApplications.filter { candidate in
            guard candidate.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            if let identifier = Bundle.main.bundleIdentifier, candidate.bundleIdentifier == identifier { return true }
            return ownBundle.hasSuffix(".app") && candidate.bundleURL?.lastPathComponent == ownBundle
        }
        guard others.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Another helper is running"
            alert.informativeText = "Quit the other copy of Remote Dictate Helper before opening this one."
            alert.runModal(); NSApp.terminate(nil); return
        }
        do {
            settings = try settingsStore.loadOrCreate()
        } catch { lastError = "Settings could not be loaded"; appendLog("settings load failed") }
        if let iconURL = Bundle.main.url(forResource: "RemoteDictateHelper", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        configureMenu()
        diagnosticContext.start()
        setStatus(lastError == nil ? "Idle" : "Error: settings unavailable")
        configureMonitor()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        appendLog("app launched version=\(version)")
        if windowsFocusExperiment { appendLog("experimental Windows focus refresh enabled for dictation") }
        let loginNeedsAttention = launchAtLogin.registerOnFirstLaunch()
        if loginNeedsAttention || SettingsReadiness.shouldOpenOnLaunch(completed: UserDefaults.standard.bool(forKey: SettingsWindowController.completionKey),
                                               accessibility: AccessibilityPermission.isTrusted()) {
            openSettings()
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        runningTask?.cancel(); monitor?.stop(); windowsMonitor?.stop()
        diagnosticContext.stop(); DiagnosticLog.shared.flush()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowsProbe?.cancel()
        cancelCurrentOperation()
        monitor?.stop(); monitor = nil
        guard clipboardRestoration.hasPendingRestore || sharedClipboardLease != nil || windowsProbe?.isBusy == true else { return .terminateNow }
        quitAfterClipboardRestore = true
        setStatus(windowsProbe?.isBusy == true ? "Finishing clipboard test before quit" : "Finishing before quit; return to Screen Sharing")
        return .terminateLater
    }
    private func configureMenu() {
        statusItem.button?.title = ""
        statusItem.button?.image = BrandIcon.menuImage()
        statusItem.button?.setAccessibilityLabel("Remote Dictate Helper")
        statusItem.button?.toolTip = "Remote Dictate Helper"
        statusItem.menu = menu
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem); menu.addItem(.separator())
        let scope = NSMenuItem(title: "Apple Screen Sharing & Windows App", action: nil, keyEquivalent: "")
        scope.isEnabled = false; menu.addItem(scope)
        if DiagnosticLog.shared.enabled {
            let diagnostics = NSMenuItem(title: DiagnosticLog.shared.textEnabled
                ? "Diagnostic text logging enabled" : "Diagnostic logging enabled", action: nil, keyEquivalent: "")
            diagnostics.isEnabled = false; menu.addItem(diagnostics)
            if windowsFocusExperiment {
                let experiment = NSMenuItem(title: "Windows focus refresh experiment enabled", action: nil, keyEquivalent: "")
                experiment.isEnabled = false; menu.addItem(experiment)
            }
            let probe = NSMenuItem(title: "Windows Clipboard Test…", action: #selector(openWindowsClipboardTest), keyEquivalent: "")
            probe.target = self; menu.addItem(probe)
            let focusProbe = NSMenuItem(title: "Windows Focus Test…", action: #selector(openWindowsFocusTest), keyEquivalent: "")
            focusProbe.target = self; menu.addItem(focusProbe)
        }
        for (title, action, key) in [
            ("Settings…", #selector(openSettings), ","),
            ("Product Website", #selector(openProductWebsite), "")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openWindowsClipboardTest() {
        guard DiagnosticLog.shared.enabled, canAcceptPaste else { return }
        let alert = NSAlert()
        alert.messageText = "Test Windows clipboard timing"
        alert.informativeText = "Use an empty Notepad document on the remote Windows computer. Choose a test, then click that document within 20 seconds. Do not dictate, type or switch windows until the test finishes.\n\nCompare 6 pastes runs SHORT (650 ms), HOLD (5 seconds) and WAIT (5 seconds, paste delayed 1 second), twice without changing focus. Allow 35 seconds. Each trial inserts one numbered marker.\n\nYour original local clipboard is restored afterward unless you copy something new. This is a diagnostic test, not a fix."
        alert.addButton(withTitle: "Compare 6 pastes")
        alert.addButton(withTitle: "Hold NEW for 5 seconds")
        alert.addButton(withTitle: "Restore OLD after 650 ms")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let mode: WindowsClipboardProbe.Mode
        switch response {
        case .alertFirstButtonReturn: mode = .comparison
        case .alertSecondButtonReturn: mode = .sustained
        case .alertThirdButtonReturn: mode = .transient
        default: return
        }
        startWindowsProbe(mode)
    }
    @objc private func openWindowsFocusTest() {
        guard DiagnosticLog.shared.enabled, canAcceptPaste else { return }
        let alert = NSAlert()
        alert.messageText = "Compare clipboard focus refresh"
        alert.informativeText = "Click an empty remote text field after starting. Do not type, dictate or switch windows for 45 seconds.\n\nSix test pastes alternate DIRECT and REFRESH. Before each REFRESH, a small helper window briefly takes focus and returns to the same Windows App window. Any other input or clipboard change stops the test.\n\nThis experiment tests a possible workaround; automatic dictation is unchanged. Your original local clipboard is restored unless another app or you replace it."
        alert.addButton(withTitle: "Start focus test")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        startWindowsProbe(.focusComparison)
    }
    private func startWindowsProbe(_ mode: WindowsClipboardProbe.Mode) {
        guard DiagnosticLog.shared.enabled, canAcceptPaste else { return }
        let probe = WindowsClipboardProbe(input: { [weak self] in self?.windowsMonitor?.diagnosticInputStamp },
            status: { [weak self] in self?.setStatus($0) }, finished: { [weak self] cleanupSucceeded in
                guard let self, self.quitAfterClipboardRestore,
                      !self.clipboardRestoration.hasPendingRestore, self.sharedClipboardLease == nil else { return }
                self.completePendingQuit(success: cleanupSucceeded)
            })
        windowsProbe = probe
        do { try probe.start(mode) }
        catch { setStatus("Test unavailable: \(error)") }
    }
    @objc private func openProductWebsite() {
        guard let url = URL(string: "https://elyrix-systems.com/remote-dictate-helper/") else { return }
        NSWorkspace.shared.open(url)
    }
    private func cancelCurrentOperation() {
        operationGeneration += 1
        runningTask?.cancel(); runningTask = nil
        monitor?.stop(); monitor = nil
        windowsMonitor?.stop(); windowsMonitor = nil
        contextCancelled = true
        finishClipboardSession()
    }
    private func configureMonitor() {
        monitor?.stop(); monitor = nil
        windowsMonitor?.stop(); windowsMonitor = nil
        guard !quitAfterClipboardRestore else { return }
        let next = DictationPasteMonitor(targetPID: {
            let app = NSWorkspace.shared.frontmostApplication
            return app?.bundleIdentifier == "com.apple.ScreenSharing" ? app?.processIdentifier : nil
        }, isAvailable: { [weak self] in self?.canAcceptPaste ?? false },
        sources: settings.sources,
        onCaptured: { [weak self] id in
            guard let self, let monitor = self.monitor else { return }
            self.startPaste(id, monitor: monitor)
        }, onError: { [weak self] error in
            self?.lastError = String(describing: error)
            self?.setStatus("Error: \(error)")
            self?.appendLog("capture error=\(error)")
        }, report: { [weak self] in self?.appendLog("capture \($0)") })
        do { try next.start(); monitor = next }
        catch { lastError = String(describing: error); setStatus("Error: \(error)"); appendLog("monitor start error=\(error)") }
        let focusRefresh: WindowsFocusRefreshProbe.Action?
        if windowsFocusExperiment {
            focusRefresh = { pid, stable, target, log in
                try await WindowsFocusRefreshProbe.run(targetPID: pid, validateStable: stable, validateTarget: target, log: log)
            }
        } else { focusRefresh = nil }
        let windows = WindowsAppPasteMonitor(sources: settings.sources,
            isAvailable: { [weak self] in self?.canAcceptPaste ?? false },
            focusRefresh: focusRefresh,
            onCaptured: { [weak self] in
                self?.lastError = nil; self?.setStatus("Captured: preparing Windows App paste")
            }, onCompleted: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.setStatus("Done: paste sent to Windows App")
                case .failure(is CancellationError): self.setStatus("Idle")
                case .failure(WindowsAppPasteError.targetChanged), .failure(WindowsAppPasteError.inputChanged):
                    self.setStatus("Idle")
                case let .failure(error):
                    self.lastError = String(describing: error); self.setStatus("Error: \(error)")
                }
            }, report: { [weak self] in self?.appendLog($0) })
        do { try windows.start(); windowsMonitor = windows }
        catch { lastError = String(describing: error); setStatus("Error: \(error)"); appendLog("Windows App monitor start error=\(error)") }
    }
    private func startPaste(_ id: UUID, monitor: DictationPasteMonitor) {
        guard canAcceptPaste else { monitor.discard(id); return }
        let generation = operationGeneration
        lastError = nil; contextCancelled = false
        setStatus("Captured: waiting for clipboard release")
        runningTask = Task { [weak self] in
            guard let self else { return }
            var stage = "capture-window"
            func trace(_ detail: String) {
                DiagnosticLog.shared.record("op=\(id) client=screen-sharing stage=\(stage) front=\(DiagnosticLog.front) \(detail)")
            }
            defer {
                monitor.discard(id)
                if generation == self.operationGeneration { self.finishClipboardSession(); self.runningTask = nil }
            }
            do {
                guard let target = NSWorkspace.shared.frontmostApplication,
                      target.bundleIdentifier == "com.apple.ScreenSharing" else { throw DictationCaptureError.targetChanged }
                let window = try ScreenSharingClipboardMenu.captureWindow(target: target)
                trace("targetPID=\(target.processIdentifier) windowRef=\(CFHash(window))")
                stage = "wait-source-release"
                trace("begin")
                let captured = try await monitor.waitForRelease(id)
                try Task.checkCancellation()
                guard generation == self.operationGeneration,
                      captured.targetPID == target.processIdentifier else { throw CancellationError() }
                stage = "begin-clipboard-restoration"
                let session = try self.clipboardRestoration.begin(observedOriginal: captured.original.snapshot)
                trace("restorationSession=\(session.id) releasedRevision=\(captured.releasedRevision)")
                self.clipboardSession = session
                stage = "replay-and-restore"
                trace("begin")
                try await self.replay(captured, session: session, target: target, window: window,
                    validateInput: { try monitor.validate(id) })
                trace("replay-finished; clipboard completion may still be pending")
            } catch is CancellationError { trace("cancel reason=task_cancelled"); self.appendLog("operation cancelled") }
            catch DictationCaptureError.targetChanged { trace("cancel reason=foreground_target_changed"); self.cancelForContextChange("foreground target changed", id: id, stage: stage) }
            catch DictationCaptureError.inputChanged { trace("cancel reason=new_input"); self.cancelForContextChange("new input (key or click)", id: id, stage: stage) }
            catch ScreenSharingClipboardMenuError.targetChanged { trace("cancel reason=connection_window_changed"); self.cancelForContextChange("connection window changed", id: id, stage: stage) }
            catch ExplicitPasteShortcutError.targetChanged { trace("cancel reason=paste_target_changed"); self.cancelForContextChange("paste target changed", id: id, stage: stage) }
            catch {
                trace("error=\(error)")
                self.lastError = String(describing: error)
                self.setStatus("Error: \(error)"); self.appendLog("operation error=\(error)")
            }
        }
    }
    private func cancelForContextChange(_ reason: String, id: UUID, stage: String) {
        contextCancelled = true; lastError = nil
        setStatus("Idle"); appendLog("operation \(id) cancelled: \(reason); stage=\(stage); no retry or deferred paste")
    }
    private func replay(_ captured: DictationPasteMonitor.Result, session: LocalClipboardRestoration.Session,
                        target: NSRunningApplication, window: AXUIElement, validateInput: () throws -> Void) async throws {
        let payload = captured.payload
        try validateInput()
        let baseline = try clipboardRestoration.captureReplayBaseline(releasedRevision: captured.releasedRevision, session: session)
        let input = ExplicitPasteShortcut(isolatedSoftwareCommand: true,
            interceptedPaste: true,
            report: { [weak self] in self?.appendLog("input \($0)") })
        _ = try await input.waitUntilReady(targetPID: target.processIdentifier, validateTarget: {
            try validateInput(); try ScreenSharingClipboardMenu.validateWindow(target: target, expected: window)
        }, onWaiting: { [weak self] in self?.appendLog("input waiting: \($0)") })
        try Task.checkCancellation(); try validateInput()
        let driver = try ScreenSharingClipboardMenu(target: target, transcript: payload.text,
            expectedWindow: window, input: input, writeTranscript: { [clipboardRestoration] _ in
                try clipboardRestoration.writeCapturedSnapshot(payload.snapshot, text: payload.text, session: session, replacing: baseline)
            }, validateTranscript: { [clipboardRestoration] in
                try clipboardRestoration.validateOwned(session)
            }, trace: { [weak self] in self?.appendLog("clipboard menu \($0)") })
        sharedClipboardLease = try ExplicitClipboardTransfer().begin(using: driver)
        sharedClipboardDriver = driver; completionPastePosted = false; contextCancelled = false
        let paste = GuardedPaste().run(targetPID: target.processIdentifier, shortcut: input,
            validateBeforeInput: { try validateInput(); try driver.validateTargetAndClipboard() })
        completionPastePosted = paste.didRun
        appendLog("input posted=\(paste.didRun) backspace=false intercepted=true")
        if paste.didRun { clipboardRestoration.recordPastePosted(session) }
        else { lastError = paste.detail }
        setStatus(paste.didRun ? "Finishing: restoring clipboard" : "Error: input failed; restoring clipboard")
    }
    @objc private func openSettings() {
        guard !busy else { setStatus("Wait for the current transfer before changing settings"); return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, launchAtLogin: launchAtLogin,
                onSave: { [weak self] in try self?.saveSettings($0) },
                onPermissionGranted: { [weak self] in
                    guard let self, !self.busy else { return false }
                    // A revoked grant can leave an existing event tap unusable.
                    // Recreate it when Settings observes a grant, as first use did.
                    self.lastError = nil; self.configureMonitor()
                    let ready = self.monitor != nil && self.windowsMonitor != nil
                    if ready { self.setStatus("Ready") }
                    return ready
                })
        }
        if settingsWindowController?.window?.isVisible != true {
            settingsWindowController?.settings = settings
        }
        settingsWindowController?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func saveSettings(_ updated: AppSettings) throws {
        guard !busy else {
            throw NSError(domain: "RemoteDictateHelper.Settings", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Wait for the current clipboard transfer to finish, then add or remove the app again."])
        }
        do {
            try settingsStore.save(updated); settings = updated; lastError = nil
            configureMonitor(); if lastError == nil { setStatus("Idle") }
        } catch { lastError = "Settings save failed"; setStatus("Error: settings save failed"); throw error }
    }
    private func setStatus(_ message: String) {
        statusMenuItem.title = message.count > 80 ? String(message.prefix(77)) + "…" : message
        let attention: Bool
        if sharingCompletion.hasPendingCompletion { attention = true }
        else if clipboardRestoration.hasPendingRestore || sharedClipboardLease != nil { attention = false }
        else { attention = message.hasPrefix("Error") }
        statusItem.button?.title = ""
        statusItem.button?.image = BrandIcon.menuImage(attention: attention)
        statusItem.button?.toolTip = "Remote Dictate Helper — \(message)"
        statusItem.button?.setAccessibilityLabel("Remote Dictate Helper — \(message)")
    }
    private static func defaultSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RemoteDictateHelper/settings.json")
    }
    private static func defaultLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RemoteDictateHelper/menu-bar.log")
    }

    private func finishClipboardSession() {
        guard let session = clipboardSession else { return }
        clipboardSession = nil
        clipboardRestoration.finish(session)
    }

    private func restoreSharedClipboardAfterLocalCompletion(receipt: LocalClipboardRestoration.Receipt? = nil) {
        guard let lease = sharedClipboardLease, let driver = sharedClipboardDriver,
              !sharingCompletion.hasPendingCompletion else { return }
        do {
            try sharingCompletion.start(
                probe: { try driver.restorationReadiness() },
                complete: {
                    let validate = receipt.map { receipt in { try receipt.validate() } }
                    try lease.restoreSharing(sendingRestoredClipboard: validate)
                },
                onWaiting: { [weak self] readiness in
                    self?.setStatus(readiness == .waitingForTarget
                        ? "Return to Screen Sharing to finish clipboard restore"
                        : "Waiting for Screen Sharing clipboard menu")
                    self?.appendLog("shared clipboard completion waiting readiness=\(readiness)")
                },
                onFinished: { [weak self] result in
                    self?.finishSharedClipboardCompletion(result, receipt: receipt)
                }
            )
        } catch {
            finishSharedClipboardCompletion(.failure(error), receipt: receipt)
        }
    }

    private func finishSharedClipboardCompletion(_ result: Result<Void, Error>, receipt: LocalClipboardRestoration.Receipt?) {
        // The poller has stopped and the single completion attempt has ended.
        // Release busy only now; a new operation must not replace the receipt.
        sharedClipboardLease = nil
        sharedClipboardDriver = nil
        switch result {
        case .success:
            appendLog("shared clipboard restored after local clipboard completion; restoredSnapshotSent=\(receipt != nil); remote completion unverified")
            if contextCancelled, lastError == nil {
                setStatus("Idle")
            } else if completionPastePosted, receipt != nil, lastError == nil {
                setStatus("Done: original clipboard restored; sharing enabled")
            } else if receipt == nil, lastError == nil {
                setStatus("Clipboard changed; sharing enabled")
            } else {
                setStatus("Error: operation incomplete; sharing enabled")
            }
        case let .failure(error):
            let sharingRestored: Bool
            if case ExplicitClipboardTransferError.restoredClipboardSendFailed = error {
                sharingRestored = true
            } else {
                sharingRestored = false
            }
            lastError = String(describing: error)
            setStatus(sharingRestored ? "Error: sharing restored; original clipboard sync failed" : "Error: enable Use Shared Clipboard for the original connection")
            appendLog("shared clipboard restore error=\(error)")
        }
        if case .success = result {
            completePendingQuit(success: true)
        } else {
            completePendingQuit(success: false)
        }
    }

    private func completePendingQuit(success: Bool) {
        guard quitAfterClipboardRestore else { return }
        quitAfterClipboardRestore = false
        // Keep the app/error visible if preference recovery could not finish.
        NSApplication.shared.reply(toApplicationShouldTerminate: success)

    }

    private func appendLog(_ message: String) {
        try? log.append(message)
        DiagnosticLog.shared.record("operational \(message)")
    }
}

@main
enum RemoteDictateEntry {
    @MainActor static func main() {
        if ClipboardReaderProcess.runIfRequested() { return }
        let application = NSApplication.shared
        let controller = RemoteDictateApp()
        application.setActivationPolicy(.accessory)
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    }
}
