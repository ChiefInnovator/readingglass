import AppKit

enum ScreenshotClipboardError: LocalizedError {
    case encodingFailed, clipboardUnavailable
    var errorDescription: String? {
        switch self {
        case .encodingFailed: "The screenshot could not be encoded."
        case .clipboardUnavailable: "The clipboard could not accept the screenshot. Try again."
        }
    }
}

@MainActor
enum ScreenshotClipboard {
    static func copy(_ surface: RasterSurface, to pasteboard: NSPasteboard = .general) throws {
        let bitmap = NSBitmapImageRep(cgImage: try surface.makeCGImage())
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenshotClipboardError.encodingFailed
        }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { throw ScreenshotClipboardError.clipboardUnavailable }
    }
}
