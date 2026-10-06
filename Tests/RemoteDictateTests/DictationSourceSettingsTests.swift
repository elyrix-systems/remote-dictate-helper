import Foundation
import RemoteDictateCore

@MainActor
func testImmediateSourceSettings() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SettingsStore(fileURL: directory.appendingPathComponent("config.json"))
    let original = try store.loadOrCreate()
    var applied = original
    var failure: Error?
    var writes = 0
    let selection = DictationSourceSettings(value: original, persist: { updated in
        if let failure { throw failure }
        try store.save(updated)
        applied = updated
        writes += 1
    })
    let custom = DictationSource(bundleIdentifier: "example.custom", name: "Custom", clipboardReturn: .keepsTranscript)
    let added = original.sources + [custom]
    try selection.updateSources(added)
    expectEqual(try store.loadOrCreate().sources, added, "Add must persist before returning")
    expectEqual(selection.value, applied)
    try selection.updateSources(added)
    expectEqual(writes, 1, "Selecting the same app must not rewrite settings")

    let removed = [custom]
    try selection.updateSources(removed)
    expectEqual(try store.loadOrCreate().sources, removed, "Removal must persist without closing the window")
    expectEqual(selection.value, applied)
    expectEqual(applied.sources.first?.clipboardReturn, .keepsTranscript)
    let committed = selection.value
    for error in [CocoaError(.fileWriteNoPermission) as Error,
                  NSError(domain: "SourceSettingsTests.Busy", code: 1)] {
        failure = error
        expectThrows(try selection.updateSources([]))
        expectEqual(selection.value, committed, "A rejected edit must leave the displayed selection intact")
        expectEqual(applied, committed, "A rejected edit must not change active sources")
        expectEqual(try store.loadOrCreate(), committed)
        expectEqual(writes, 2)
    }
    failure = nil
    try selection.updateSources([])
    expectTrue(try store.loadOrCreate().sources.isEmpty, "Removing the final source is also saved")
    expectEqual(selection.value, applied)
    try selection.updateSources(added)
    expectEqual(try store.loadOrCreate().sources, added, "A failed edit must not prevent later saves")
    print("immediate source settings passed: add/remove persistence, no-op, exact policy retention and failed/busy rollback")
}
