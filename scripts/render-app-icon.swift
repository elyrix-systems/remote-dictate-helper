import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct RenderIcons {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { fatalError("usage: render-app-icon ICONSET_DIR [preview]") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@2x"
                let name = "icon_\(points)x\(points)\(suffix).png"
                try writePNG(render(size: points * scale), to: output.appendingPathComponent(name))
            }
        }
        if CommandLine.arguments.count > 2 {
            let sheet = NSImage(size: NSSize(width: 640, height: 560))
            sheet.lockFocus()
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 640, height: 560).fill()
            render(size: 400).draw(in: NSRect(x: 120, y: 125, width: 400, height: 400))
            ("Microphone → text in a remote window" as NSString).draw(in: NSRect(x: 80, y: 85, width: 520, height: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)])
            BrandIcon.mark(in: NSRect(x: 268, y: 30, width: 24, height: 24), color: .black)
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 330, y: 24, width: 40, height: 36), xRadius: 8, yRadius: 8).fill()
            BrandIcon.mark(in: NSRect(x: 338, y: 30, width: 24, height: 24), color: .white)
            sheet.unlockFocus()
            try writePNG(sheet, to: output.appendingPathComponent("icon-preview.png"))
        }
    }

    static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, pixels, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
    static func render(size: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus(); defer { image.unlockFocus() }
        let s = CGFloat(size) / 1024
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { .init(x: x*s, y: y*s, width: w*s, height: h*s) }
        let bg = NSBezierPath(roundedRect: rect(64, 64, 896, 896), xRadius: 200*s, yRadius: 200*s)
        let palette: [NSColor] = [
            .init(srgbRed: 0.20, green: 0.43, blue: 0.83, alpha: 1),
            .init(srgbRed: 0.075, green: 0.16, blue: 0.39, alpha: 1)
        ]
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowOffset = NSSize(width: 0, height: -10*s); shadow.shadowBlurRadius = 24*s
        NSGraphicsContext.saveGraphicsState(); shadow.set(); palette[1].setFill(); bg.fill(); NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: palette)?.draw(in: bg, angle: -65)
        NSGraphicsContext.saveGraphicsState(); bg.addClip()
        NSColor.white.withAlphaComponent(0.08).setFill(); NSBezierPath(ovalIn: rect(200, 480, 940, 720)).fill()
        NSGraphicsContext.restoreGraphicsState()
        BrandIcon.mark(in: rect(174, 174, 676, 676), color: .white)
        return image
    }
}
