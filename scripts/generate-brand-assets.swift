import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent(".build/brand", isDirectory: true)
let assets = root.appendingPathComponent("site/assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func raster(width: Int, height: Int, draw: () -> Void) throws -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let navy = NSColor(srgbRed: 0.06, green: 0.16, blue: 0.23, alpha: 1)
let mint = NSColor(srgbRed: 0.64, green: 0.90, blue: 0.91, alpha: 1)
func icon(in rect: NSRect) {
    let transform = AffineTransform(scale: rect.width / 1024)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: transform.m11, y: transform.m22)
    navy.setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190).fill()
    NSColor.white.setStroke()
    let pane = NSBezierPath(roundedRect: NSRect(x: 236, y: 310, width: 552, height: 404), xRadius: 58, yRadius: 58)
    pane.lineWidth = 30
    pane.stroke()
    mint.setStroke()
    let lines = NSBezierPath()
    lines.lineCapStyle = .round
    lines.lineWidth = 32
    lines.move(to: NSPoint(x: 350, y: 555)); lines.line(to: NSPoint(x: 674, y: 555))
    lines.move(to: NSPoint(x: 350, y: 451)); lines.line(to: NSPoint(x: 572, y: 451))
    lines.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

let app = try raster(width: 1024, height: 1024) { icon(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)) }
try app.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("app-icon.png"))

let social = try raster(width: 1200, height: 630) {
    NSColor(srgbRed: 0.95, green: 0.98, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
    icon(in: NSRect(x: 800, y: 145, width: 330, height: 330))
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: navy]
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .regular), .foregroundColor: navy]
    ("ReadingGlass" as NSString).draw(at: NSPoint(x: 80, y: 355), withAttributes: title)
    ("Translate your screen.\nKeep your text on your Mac." as NSString)
        .draw(in: NSRect(x: 84, y: 200, width: 690, height: 116), withAttributes: body)
    ("Native macOS • Local translation" as NSString)
        .draw(at: NSPoint(x: 84, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: navy])
}
try social.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("social-card.png"))
print("Generated app-icon.png and social-card.png")
