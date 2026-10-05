import AppKit

/// Original vector artwork: a microphone sends text into another window.
/// Template rendering lets macOS control menu contrast in both appearances.
enum BrandIcon {
    static func mark(in bounds: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.minX, yBy: bounds.minY)
        transform.scaleX(by: bounds.width / 24, yBy: bounds.height / 24)
        transform.concat()
        color.setStroke(); color.setFill()
        func stroke(_ points: [NSPoint], width: CGFloat = 1.6) {
            let p = NSBezierPath(); p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
            for (i, point) in points.enumerated() { if i == 0 { p.move(to: point) } else { p.line(to: point) } }
            p.stroke()
        }
        // Leave a deliberate opening where the transfer enters the window.
        let window = NSBezierPath()
        window.move(to: .init(x: 10, y: 15))
        window.line(to: .init(x: 10, y: 19.5))
        window.curve(to: .init(x: 12, y: 21.5), controlPoint1: .init(x: 10, y: 21), controlPoint2: .init(x: 10.5, y: 21.5))
        window.line(to: .init(x: 20.5, y: 21.5))
        window.curve(to: .init(x: 22.5, y: 19.5), controlPoint1: .init(x: 22, y: 21.5), controlPoint2: .init(x: 22.5, y: 21))
        window.line(to: .init(x: 22.5, y: 5))
        window.curve(to: .init(x: 20.5, y: 3), controlPoint1: .init(x: 22.5, y: 3.5), controlPoint2: .init(x: 22, y: 3))
        window.line(to: .init(x: 12, y: 3))
        window.curve(to: .init(x: 10, y: 5), controlPoint1: .init(x: 10.5, y: 3), controlPoint2: .init(x: 10, y: 3.5))
        window.line(to: .init(x: 10, y: 8))
        window.lineWidth = 1.6; window.lineCapStyle = .round; window.stroke()
        stroke([.init(x: 10.5, y: 17.5), .init(x: 22, y: 17.5)], width: 1.2)
        stroke([.init(x: 15.8, y: 13.7), .init(x: 19.3, y: 13.7)], width: 1.4)
        stroke([.init(x: 15.8, y: 9.8), .init(x: 19.3, y: 9.8)], width: 1.4)
        // Microphone capsule, cradle and stem stay legible at menu-bar size.
        NSBezierPath(roundedRect: NSRect(x: 2, y: 13, width: 4, height: 8), xRadius: 2, yRadius: 2).fill()
        let cradle = NSBezierPath(); cradle.move(to: .init(x: 0.6, y: 14.5)); cradle.line(to: .init(x: 0.6, y: 12.5))
        cradle.curve(to: .init(x: 7.4, y: 12.5), controlPoint1: .init(x: 0.6, y: 8), controlPoint2: .init(x: 7.4, y: 8))
        cradle.line(to: .init(x: 7.4, y: 14.5)); cradle.lineWidth = 1.5; cradle.lineCapStyle = .round; cradle.stroke()
        stroke([.init(x: 4, y: 9.1), .init(x: 4, y: 5.5)], width: 1.5)
        stroke([.init(x: 2, y: 5.5), .init(x: 6, y: 5.5)], width: 1.5)
        stroke([.init(x: 8, y: 11.5), .init(x: 13.3, y: 11.5)], width: 1.5)
        stroke([.init(x: 11.4, y: 13.4), .init(x: 13.3, y: 11.5), .init(x: 11.4, y: 9.6)], width: 1.5)
    }

    static func menuImage(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
            mark(in: NSRect(x: 1, y: 0, width: 22, height: 22), color: .black)
            if attention { NSBezierPath(ovalIn: NSRect(x: 19, y: 0, width: 4, height: 4)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }
}
