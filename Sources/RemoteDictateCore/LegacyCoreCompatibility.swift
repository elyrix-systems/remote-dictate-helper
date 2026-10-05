// Source compatibility for clients of the 1.0 SwiftPM library product.
// The helper does not call these APIs. Remove only in a major release.

public extension ClipboardReturnPolicy {
    /// Former UI label, retained for existing library clients.
    @available(*, deprecated, message: "Choose presentation text in the client UI.")
    var title: String {
        self == .restoresPrevious ? "App restores the previous clipboard" : "App leaves the dictated text in the clipboard"
    }
}

public extension AppSettings {
    /// Compatibility lookup using the same source matching rules as capture.
    @available(*, deprecated, message: "Use sources.first(where:) with DictationSource.matches(_:).")
    func source(for identifier: String?) -> DictationSource? {
        sources.first { $0.matches(identifier) }
    }
}

public extension ExplicitClipboardTransferDriver {
    /// Legacy drivers transfer an already prepared clipboard. The helper's
    /// driver overrides this requirement to write only while sharing is off.
    func prepareClipboard() throws {}
}

public extension ExplicitClipboardTransfer {
    /// Legacy fixed-clipboard transfer with immediate sharing restoration.
    /// Retains its final validation; automatic dictation uses a deferred lease.
    @available(*, deprecated, message: "Use begin(using:) and restore its lease after paste and local clipboard restoration.")
    func run(using driver: any ExplicitClipboardTransferDriver) throws {
        let lease = try begin(using: driver)
        try lease.restoreSharing()
        try driver.validateTargetAndClipboard()
    }
}
