import RemoteDictateCore

/// The displayed selection advances only after persistence/application succeeds.
/// Failed or busy edits leave the last committed selection available to the UI.
@MainActor
final class DictationSourceSettings {
    var value: AppSettings
    private let persist: (AppSettings) throws -> Void

    init(value: AppSettings, persist: @escaping (AppSettings) throws -> Void) {
        self.value = value; self.persist = persist
    }

    func updateSources(_ sources: [DictationSource]) throws {
        guard sources != value.sources else { return }
        var updated = value
        updated.sources = sources
        try persist(updated)
        value = updated
    }
}
