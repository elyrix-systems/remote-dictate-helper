import Foundation
import RemoteDictateCore

func testOperationalLog() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("nested/events.log")
    let writer = OperationalLog(destination: file)
    let date = Date(timeIntervalSince1970: 0)
    try writer.append("first", at: date)
    try writer.append("second", at: date)
    let contents = try String(contentsOf: file, encoding: .utf8)
    expectTrue(contents.hasSuffix("second\n"))
    expectEqual(contents.split(separator: "\n").count, 2)
    expectTrue(contents.contains("first\n"))
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    expectEqual(permissions, 0o600)
    let link = directory.appendingPathComponent("redirect.log")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    expectThrows(try OperationalLog(destination: link).append("must not follow"))
    expectEqual(try String(contentsOf: file, encoding: .utf8), contents)
}

func testSettingsPersistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("nested/config.json")
    let store = SettingsStore(fileURL: file)
    expectEqual(try store.loadOrCreate(), AppSettings())
    var custom = AppSettings()
    custom.sources = [DictationSource(bundleIdentifier: "example.custom", name: "Custom", clipboardReturn: .keepsTranscript)]
    try store.save(custom)
    expectEqual(try store.loadOrCreate(), custom)
    let malformed = Data("invalid settings".utf8)
    try malformed.write(to: file)
    expectThrows(try store.loadOrCreate())
    expectEqual(try Data(contentsOf: file), malformed)
}
