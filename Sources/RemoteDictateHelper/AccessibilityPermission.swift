import AppKit
import ApplicationServices

enum AccessibilityPermission {
    /// Background checks must never request access or open a window.
    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// The native access alert owns its Open System Settings action. Opening the
    /// pane ourselves as well races that alert and can leave it over Settings.
    @MainActor
    static func openSettings(
        check: () -> Bool = { isTrusted() },
        request: () -> Void = { requestAccess() },
        openPane: () -> Void = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    ) {
        if check() { openPane() } else { request() }
    }

    private static func requestAccess() {
        // Use the documented option value because the SDK imports its CFString
        // symbol as mutable global state under Swift 6 strict concurrency.
        let request = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(request)
    }
}
