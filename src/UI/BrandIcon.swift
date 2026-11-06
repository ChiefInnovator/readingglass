import AppKit

/// The same simple reading-pane mark used by the public site and app icon.
@MainActor
enum BrandIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 16, height: 12),
                                     xRadius: 2, yRadius: 2)
            frame.lineWidth = 1.6
            frame.stroke()
            let text = NSBezierPath()
            text.lineWidth = 1.6
            text.lineCapStyle = .round
            text.move(to: NSPoint(x: 6, y: 11))
            text.line(to: NSPoint(x: 14, y: 11))
            text.move(to: NSPoint(x: 6, y: 7))
            text.line(to: NSPoint(x: 11, y: 7))
            text.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ReadingGlass"
        return image
    }
}
