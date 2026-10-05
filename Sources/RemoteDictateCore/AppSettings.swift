import Foundation

public enum ClipboardReturnPolicy: String, Codable, CaseIterable, Sendable {
    case restoresPrevious, keepsTranscript
}

public struct DictationSource: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var name: String
    public var enabled: Bool
    public var clipboardReturn: ClipboardReturnPolicy
    public init(bundleIdentifier: String, name: String, enabled: Bool = true,
                clipboardReturn: ClipboardReturnPolicy = .restoresPrevious) {
        self.bundleIdentifier = bundleIdentifier; self.name = name
        self.enabled = enabled; self.clipboardReturn = clipboardReturn
    }
    public func matches(_ identifier: String?) -> Bool {
        guard enabled, !bundleIdentifier.isEmpty, let identifier else { return false }
        return identifier == bundleIdentifier || identifier.hasPrefix(bundleIdentifier + ".")
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4
    /// Retained for source compatibility with 1.0.0 clients. Encoding always
    /// writes currentSchemaVersion, as it did before this property was retired.
    @available(*, deprecated, message: "Use AppSettings.currentSchemaVersion; this value does not control encoding.")
    public var settingsSchemaVersion = currentSchemaVersion
    public var sources: [DictationSource] = [
        DictationSource(bundleIdentifier: "com.electron.wispr-flow", name: "Wispr Flow"),
        DictationSource(bundleIdentifier: "com.superduper.superwhisper", name: "superwhisper"),
        DictationSource(bundleIdentifier: "so.valis.desktop", name: "Valis")
    ]
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case settingsSchemaVersion, sources, automaticFlowPasteEnabled
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let saved = try c.decodeIfPresent([DictationSource].self, forKey: .sources) {
            // Disabled sources from older settings remain excluded.
            sources = saved.filter(\.enabled)
        } else if c.contains(.automaticFlowPasteEnabled) {
            sources = sources.filter { $0.bundleIdentifier == "com.electron.wispr-flow" }
        }
        // Earlier versions offered a passive Backspace mode and a global pause.
        // Both were retired: this app always uses interception while running.
        // Old keys are ignored and omitted when the file is saved.
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .settingsSchemaVersion)
        try c.encode(sources, forKey: .sources)
    }
}

public final class SettingsStore {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func loadOrCreate() throws -> AppSettings {
        let result: AppSettings
        do {
            result = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            result = .init()
        }
        try save(result)
        return result
    }
    public func save(_ settings: AppSettings) throws {
        let serializer = JSONEncoder()
        serializer.outputFormatting = [.sortedKeys, .prettyPrinted]
        let contents = try serializer.encode(settings)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try contents.write(to: fileURL, options: [.atomic])
    }
}
