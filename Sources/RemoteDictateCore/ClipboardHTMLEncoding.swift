import Foundation

/// Make an unlabelled UTF-8 HTML byte stream self-describing for rich-text
/// consumers. Do not render HTML, change its body, or guess a legacy encoding.
public enum ClipboardHTMLEncoding {
    public static func markingUnlabelledUTF8(_ data: Data) -> Data {
        let bom = Data([0xef, 0xbb, 0xbf])
        guard !data.starts(with: bom), !data.contains(0),
              data.contains(where: { $0 >= 0x80 }),
              let html = String(data: data, encoding: .utf8) else { return data }
        // Respect an existing declaration, including non-UTF-8 declarations.
        // This conservative check does not parse or reconstruct the document.
        let declaration = "(?is)<meta\\b[^>]*\\bcharset\\s*=|<\\?xml\\b[^>]*\\bencoding\\s*="
        guard html.range(of: declaration, options: .regularExpression) == nil else { return data }
        return bom + data
    }
}
