import Foundation
import RemoteDictateCore

final class SettingsTests {
    func testMigrationRemovesUnusedFields() throws {
        let old = Data(#"{"automaticFlowPasteEnabled":true,"automaticPasteEnabled":true,"wisprDatabasePath":"unused","donorAppPath":"unused","remoteCleanupMode":"backspace"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        expectEqual(settings.sources.map(\.bundleIdentifier), ["com.electron.wispr-flow"])
        let saved = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        for obsolete in ["wisprDatabase", "donor", "automaticFlow", "remoteCleanup", "pasteHandling"] {
            expectFalse(saved.contains(obsolete))
        }
        // A previous global pause/deletion choice cannot survive as a hidden mode.
        let previous = Data(#"{"enabled":false,"pasteHandling":"backspace","sources":[{"bundleIdentifier":"example.selected","name":"Selected","enabled":true,"clipboardReturn":"keepsTranscript"},{"bundleIdentifier":"example.disabled","name":"Disabled","enabled":false,"clipboardReturn":"restoresPrevious"}]}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: previous)
        expectEqual(migrated.sources.count, 1)
        expectEqual(migrated.sources[0].clipboardReturn, .keepsTranscript)
        expectEqual(migrated.sources[0].bundleIdentifier, "example.selected")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
        expectNil(json["enabled"]); expectNil(json["pasteHandling"])
        expectEqual(json["settingsSchemaVersion"] as? Int, 4)
        expectEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(migrated)), migrated)
        expectTrue(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sources":[]}"#.utf8)).sources.isEmpty)
    }
    func testSourceScope() {
        let sources = AppSettings().sources
        expectEqual(sources.map(\.bundleIdentifier), ["com.electron.wispr-flow", "com.superduper.superwhisper", "so.valis.desktop"])
        for source in sources {
            expectTrue(source.matches(source.bundleIdentifier))
            expectTrue(source.matches(source.bundleIdentifier + ".helper"))
            for other in [source.bundleIdentifier + "-other", "com.apple.ScreenSharing", "systems.elyrix.RemoteDictateHelper", ""] {
                expectFalse(source.matches(other))
            }
            expectFalse(source.matches(nil))
            var disabled = source; disabled.enabled = false
            expectFalse(disabled.matches(source.bundleIdentifier))
        }
        expectFalse(DictationSource(bundleIdentifier: "", name: "Empty").matches(""))
    }
}
