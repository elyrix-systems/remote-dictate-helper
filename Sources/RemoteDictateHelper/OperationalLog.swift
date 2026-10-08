import Darwin
import Foundation

/// Append-only metadata log. O_APPEND prevents competing writes from overwriting
/// one another; O_NOFOLLOW refuses a log path that points at another file.
struct OperationalLog {
    let destination: URL

    func append(_ metadata: String, at date: Date = .now, enforcePrivatePermissions: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        if enforcePrivatePermissions, fchmod(descriptor, 0o600) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let record = Data("\(stamp) \(metadata)\n".utf8)
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: record)
    }
}
