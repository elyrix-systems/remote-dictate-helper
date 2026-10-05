import ApplicationServices

enum AccessibilityPermission {
    /// Polling never opens System Settings. Only an explicit user action requests
    /// the system prompt, and an existing grant needs no additional request.
    static func isTrusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if !prompt { return false }
        // Use the documented option value because the SDK imports its CFString
        // symbol as mutable global state under Swift 6 strict concurrency.
        let request = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue] as CFDictionary
        return AXIsProcessTrustedWithOptions(request)
    }
}
