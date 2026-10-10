import AppKit
import IOKit.hidsystem

enum AccessibilityPermission {
    /// Background checks must never request access or open a window.
    static func isTrusted() -> Bool { state == .granted }
    static var state: AccessibilityAccessState { AccessibilityAccessMonitor.shared.state }
    static func invalidate() { AccessibilityAccessMonitor.shared.invalidate() }

    /// The native access alert owns its Open System Settings action. Opening the
    /// pane ourselves as well races that alert and can leave it over Settings.
    @MainActor
    static func openSettings(
        check: () async -> AccessibilityAccessState = { await AccessibilityAccessMonitor.shared.refreshedState() },
        request: () async -> Void = { await requestAccess() },
        openPane: () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    ) async {
        switch await check() {
        case .granted, .denied:
            // An existing denied entry needs the user's toggle, not another
            // prompt. A granted entry still lets the user manage its permission.
            openPane()
        case .notRequested:
            // A deleted entry must be requested through the live HID API. The
            // native alert alone owns navigation; never open a second pane.
            await request()
        case .checking, .unavailable:
            break // Keep input stopped; never infer a grant from a failed check.
        }
    }

    private static let requestQueue = DispatchQueue(label: "systems.elyrix.RemoteDictateHelper.access-request")
    private static let requestSlot = DispatchSemaphore(value: 1)

    private static func requestAccess() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard requestSlot.wait(timeout: .now()) == .success else { continuation.resume(); return }
            requestQueue.async {
                _ = IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
                invalidate()
                requestSlot.signal()
                continuation.resume()
            }
        }
    }
}
