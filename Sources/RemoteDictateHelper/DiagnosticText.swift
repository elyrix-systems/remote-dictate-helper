import Foundation

/// A bounded copy of already materialized text. Never reads a pasteboard or
/// represents acknowledgement from the remote clipboard/text field.
struct DiagnosticText: Codable, Sendable {
    static let maximumBytes = 64 * 1024
    let text: String?
    let truncated: Bool
    let unavailableReason: String?

    static func capture(_ text: String) -> Self {
        // Copy only a bounded prefix, including one byte to detect truncation.
        capture(Data(text.utf8.prefix(maximumBytes + 1)))
    }

    static func capture(_ data: Data) -> Self {
        let truncated = data.count > maximumBytes
        var end = min(data.count, maximumBytes)
        // A UTF-8 scalar can straddle the byte limit. Do not substitute mojibake
        // or decode rich formats; an invalid prefix is explicitly unavailable.
        if truncated {
            while end > 0, maximumBytes - end < 3,
                  data[data.startIndex + end] & 0xc0 == 0x80 { end -= 1 }
        }
        if let text = String(data: Data(data.prefix(end)), encoding: .utf8) {
            return Self(text: text, truncated: truncated, unavailableReason: nil)
        }
        return Self(text: nil, truncated: truncated, unavailableReason: "invalid-utf8")
    }
}
