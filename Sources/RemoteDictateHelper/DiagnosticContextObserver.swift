import AppKit

/// Read-only observation, separate from admission, validation and replay. AX is
/// sampled on a worker, with short timeouts and at most one outstanding probe.
/// No titles, URLs, host names, document names, clipboard data or AX values.
@MainActor
final class DiagnosticContextObserver {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var lastFront: String?
    private var lastClipboard: Int?
    private var lastModifiers: String?
    private var observeUntil: TimeInterval = 0
    private var nextAX: TimeInterval = 0
    private let worker = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.context", qos: .utility)
    private let probeSlot = DispatchSemaphore(value: 1)
    private let windows = DiagnosticWindowProbe()
    private let log = DiagnosticLog.shared

    func start() {
        guard log.enabled, timer == nil else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown"
        log.record("diagnostics.start version=\(version) build=\(build) os=\(ProcessInfo.processInfo.operatingSystemVersionString) timezone=\(TimeZone.current.identifier) utcOffset=\(TimeZone.current.secondsFromGMT()) pid=\(ProcessInfo.processInfo.processIdentifier) contents=excluded")
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, name)
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observe(DistributedNotificationCenter.default(), Notification.Name(name))
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        sample()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let name = note.name.rawValue
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observeUntil = ProcessInfo.processInfo.systemUptime + 10
                self.log.record("context.notification name=\(name) front=\(DiagnosticLog.front)")
                self.sample()
            }
        }
        observers.append((center, token))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        log.record("diagnostics.stop")
    }

    private func sample() {
        let app = NSWorkspace.shared.frontmostApplication
        let front = DiagnosticLog.app(app?.processIdentifier)
        if front != lastFront {
            log.record("context.foreground from=\(lastFront ?? "unknown") to=\(front)")
            lastFront = front
        }
        let now = ProcessInfo.processInfo.systemUptime
        let remote = ["com.apple.ScreenSharing", "com.microsoft.rdc.macos"].contains(app?.bundleIdentifier ?? "")
        if remote { observeUntil = now + 10 }
        guard now < observeUntil else { return }
        let revision = NSPasteboard.general.changeCount
        if revision != lastClipboard {
            let types = (NSPasteboard.general.types ?? []).prefix(20).map { DiagnosticLog.token($0.rawValue) }
            log.record("context.clipboard fromRevision=\(lastClipboard.map(String.init) ?? "unknown") toRevision=\(revision) afterMetadataRevision=\(NSPasteboard.general.changeCount) types=\(types.joined(separator: ",")) front=\(front) writer=unknown")
            lastClipboard = revision
        }
        let modifiers = "session=0x\(String(CGEventSource.flagsState(.combinedSessionState).rawValue, radix: 16)) hid=0x\(String(CGEventSource.flagsState(.hidSystemState).rawValue, radix: 16))"
        if modifiers != lastModifiers {
            log.record("context.modifiers \(modifiers) front=\(front)"); lastModifiers = modifiers
        }
        guard remote, now >= nextAX, AccessibilityPermission.isTrusted(), let pid = app?.processIdentifier,
              probeSlot.wait(timeout: .now()) == .success else { return }
        nextAX = now + 1
        let windows = windows, slot = probeSlot, log = log
        worker.async {
            defer { slot.signal() }
            if let change = windows.sample(pid: pid) { log.record("context.ax \(change)") }
        }
    }
}

/// Serial-worker confined. An AX reference is an opaque session-local identity,
/// not a window title or evidence of a remote text caret.
private final class DiagnosticWindowProbe: @unchecked Sendable {
    private var last: String?
    func sample(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        func element(_ attribute: String) -> (AXUIElement?, Int32) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error.rawValue) }
            return (unsafeDowncast(value, to: AXUIElement.self), error.rawValue)
        }
        let (window, windowError) = element(kAXFocusedWindowAttribute)
        let (focused, focusedError) = element(kAXFocusedUIElementAttribute)
        var role = "unknown"
        if let focused {
            AXUIElementSetMessagingTimeout(focused, 0.05)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &value) == .success, let text = value as? String {
                role = DiagnosticLog.token(text)
            }
        }
        let state = "pid=\(pid) windowRef=\(window.map { String(CFHash($0)) } ?? "none") windowAX=\(windowError) focusRef=\(focused.map { String(CFHash($0)) } ?? "none") focusAX=\(focusedError) focusRole=\(role)"
        guard state != last else { return nil }
        let previous = last ?? "unknown"; last = state
        return "from={\(previous)} to={\(state)} remoteCaret=unobservable"
    }
}
