import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage

enum TranslationRenderError: LocalizedError, Sendable {
    case invalidGeometry
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidGeometry: "The translation does not match a valid captured region."
        case .allocationFailed: "The translation image could not be allocated."
        }
    }
}

/// Core Text and mutable drawing buffers stay on this actor. The app receives
/// separate immutable background/foreground rasters, so refinement can never
/// move, fade, or replace a published word.
actor TranslationRenderer {
    func render(frame: CapturedFrame, translations: [RegionTranslation],
                occupiedRegions: [TextRegion] = []) async throws -> TranslationPresentation {
        try Task.checkCancellation()
        return try autoreleasepool {
            _ = try frame.surface.makeCGImage()
            guard frame.scaleX.isFinite, frame.scaleY.isFinite,
                  frame.scaleX > 0, frame.scaleY > 0 else { throw TranslationRenderError.invalidGeometry }
            let size = frame.surface.size
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: size.width, height: size.height,
                                          bitsPerComponent: 8, bytesPerRow: frame.surface.bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                            .union(.byteOrder32Little).rawValue) else {
                throw TranslationRenderError.allocationFailed
            }
            context.clear(CGRect(x: 0, y: 0, width: size.width, height: size.height))
            context.textMatrix = .identity
            var background = frame.surface.pixels
            var overflow: [RegionTranslation] = []
            var backingRegions: [TranslationBacking] = []
            var suggestedWidth: Double?
            let scale = max(frame.scaleX, frame.scaleY)

            // Resolve large prose first so a stray nested observation cannot
            // reserve space over the main paragraph.
            let ordered = translations.sorted {
                let left = $0.region.bounds, right = $1.region.bounds
                let leftArea = Double(left.width) * Double(left.height)
                let rightArea = Double(right.width) * Double(right.height)
                return leftArea == rightArea ? left.y < right.y : leftArea > rightArea
            }
            for translation in ordered {
                try Task.checkCancellation()
                guard Self.isValid(translation.region.bounds, in: size) else {
                    throw TranslationRenderError.invalidGeometry
                }
                let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let source = translation.region.bounds
                guard !backingRegions.contains(where: { Self.intersects($0.bounds, source) }) else {
                    overflow.append(translation)
                    continue
                }
                let palette = Self.palette(around: source, in: frame.surface)
                let available = Self.availableArea(for: translation,
                    among: occupiedRegions + translations.map(\.region), surface: frame.surface,
                    background: palette.background, reserved: backingRegions.map(\.bounds), scale: scale)
                let minimum = CGFloat(16 * scale)
                let sourceGlyphHeight = translation.region.spans.map { $0.bounds.height }.sorted()
                let medianHeight = sourceGlyphHeight.isEmpty ? source.height : sourceGlyphHeight[sourceGlyphHeight.count / 2]
                var fontSize = max(minimum, min(CGFloat(28 * scale), CGFloat(medianHeight) * 1.05))
                var fit = Self.layout(text: text, size: fontSize, color: palette.foreground,
                    available: available, source: source, imageHeight: size.height, kind: translation.region.kind)
                while !fit.complete && fontSize > minimum {
                    fontSize = max(minimum, fontSize - CGFloat(scale))
                    fit = Self.layout(text: text, size: fontSize, color: palette.foreground,
                        available: available, source: source, imageHeight: size.height, kind: translation.region.kind)
                }
                if !fit.complete {
                    overflow.append(translation)
                    if available.x + available.width >= size.width - 2 {
                        suggestedWidth = max(frame.captureRectGlobalPoints.width * 1.2,
                                             frame.captureRectGlobalPoints.width + 160)
                    }
                }
                // If not even one complete word fits at the readable floor,
                // keep the original pixels and offer the full-text view.
                guard let textFrame = fit.frame else { continue }
                guard !backingRegions.contains(where: { Self.intersects($0.bounds, fit.backgroundBounds) }) else {
                    if !overflow.contains(translation) { overflow.append(translation) }
                    continue
                }
                Self.fill(fit.backgroundBounds, color: palette.background, in: &background,
                          bytesPerRow: frame.surface.bytesPerRow)
                backingRegions.append(TranslationBacking(regionID: translation.region.id,
                                                         bounds: fit.backgroundBounds,
                                                         blackText: (palette.foreground.components?.first ?? 0) < 0.5))
                context.saveGState()
                context.clip(to: Self.quartzRect(fit.backgroundBounds, imageHeight: size.height))
                CTFrameDraw(textFrame, context)
                context.restoreGState()
            }
            guard let bytes = context.data else { throw TranslationRenderError.allocationFailed }
            let foreground = RasterSurface(size: size, bytesPerRow: frame.surface.bytesPerRow,
                                           pixels: Data(bytes: bytes, count: frame.surface.pixels.count))
            return TranslationPresentation(frame: frame, regions: translations, foreground: foreground,
                                           initialBackground: RasterSurface(size: size,
                                                                            bytesPerRow: frame.surface.bytesPerRow,
                                                                            pixels: background),
                                           overflow: overflow, backingRegions: backingRegions,
                                           suggestedWidth: suggestedWidth)
        }
    }

    private struct Layout {
        let frame: CTFrame?
        let backgroundBounds: PixelRect
        let complete: Bool
    }

    private struct Palette {
        let background: (UInt8, UInt8, UInt8)
        let foreground: CGColor
    }

    private static func layout(text: String, size: CGFloat, color: CGColor,
                               available: PixelRect, source: PixelRect, imageHeight: Int,
                               kind: TextRegionKind) -> Layout {
        let padding = 2
        let width = max(0, available.width - 2 * padding)
        let maximumHeight = max(0, available.height - 2 * padding)
        guard width > 0, maximumHeight > 0 else {
            return Layout(frame: nil, backgroundBounds: available, complete: false)
        }
        let attributed = attributedText(text, size: size, color: color, bold: kind == .heading)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let required = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: 1_000_000), nil
        )
        let height = min(available.height, max(source.height + 2 * padding, Int(ceil(required.height)) + 2 * padding))
        let background = PixelRect(x: available.x, y: available.y, width: available.width, height: height)
        let inner = PixelRect(x: background.x + padding, y: background.y + padding,
                              width: width, height: max(0, background.height - 2 * padding))
        let path = CGPath(rect: quartzRect(inner, imageHeight: imageHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let brokenWord = firstBrokenWord(in: text, lines: lines)
        if visible.length >= text.utf16.count, brokenWord == nil,
           kind == .paragraph || lines.count <= 1 {
            return Layout(frame: frame, backgroundBounds: background, complete: true)
        }
        // Compact UI labels and headings must never become vertical fragments.
        guard kind == .paragraph else {
            return Layout(frame: nil, backgroundBounds: background, complete: false)
        }
        let prefix = completePrefix(of: text, fittingUTF16: min(visible.length, brokenWord ?? visible.length))
        guard !prefix.isEmpty else {
            return Layout(frame: nil, backgroundBounds: background, complete: false)
        }
        let prefixSetter = CTFramesetterCreateWithAttributedString(attributedText(prefix, size: size, color: color))
        let prefixFrame = CTFramesetterCreateFrame(prefixSetter, CFRange(location: 0, length: 0), path, nil)
        guard CTFrameGetVisibleStringRange(prefixFrame).length >= prefix.utf16.count,
              firstBrokenWord(in: prefix, lines: CTFrameGetLines(prefixFrame) as! [CTLine]) == nil else {
            return Layout(frame: nil, backgroundBounds: background, complete: false)
        }
        return Layout(frame: prefixFrame, backgroundBounds: background, complete: false)
    }

    private static func attributedText(_ text: String, size: CGFloat, color: CGColor,
                                       bold: Bool = false) -> CFAttributedString {
        let regular = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = bold ? CTFontCreateCopyWithSymbolicTraits(regular, size, nil, .traitBold, .traitBold) ?? regular : regular
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]) as CFAttributedString
    }

    private static func firstBrokenWord(in text: String, lines: [CTLine]) -> Int? {
        let boundaries = lines.map { CTLineGetStringRange($0) }.map { $0.location + $0.length }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var broken: Int?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = NSRange(range, in: text)
            if boundaries.contains(where: { $0 > word.location && $0 < word.location + word.length }) {
                broken = word.location
                return false
            }
            return true
        }
        return broken
    }

    private static func completePrefix(of text: String, fittingUTF16 limit: Int) -> String {
        guard limit > 0 else { return "" }
        for unit: NLTokenUnit in [.sentence, .word] {
            let tokenizer = NLTokenizer(unit: unit)
            tokenizer.string = text
            var end: String.Index?
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let length = text[..<range.upperBound].utf16.count
                guard length <= limit else { return false }
                end = range.upperBound
                return true
            }
            if let end { return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return ""
    }

    private static func availableArea(for translation: RegionTranslation, among regions: [TextRegion],
                                      surface: RasterSurface, background: (UInt8, UInt8, UInt8),
                                      reserved: [PixelRect], scale: Double) -> PixelRect {
        let source = translation.region.bounds
        let size = surface.size
        let x = max(0, source.x - 2), y = max(0, source.y - 2)
        let heights = translation.region.spans.map { $0.bounds.height }.sorted()
        let lineHeight = heights.isEmpty ? source.height : heights[heights.count / 2]
        let compact = translation.region.kind != .paragraph
        var right = compact ? min(size.width, source.x + source.width + 2 + min(source.width, Int(160 * scale))) : size.width
        var bottom = min(size.height, source.y + source.height + 2 +
                         (compact ? max(0, Int(24 * scale) - source.height) : max(1, lineHeight) * 2))
        let obstacles = regions.filter { $0.id != translation.region.id }.map(\.bounds) + reserved
        for bounds in obstacles {
            let verticalOverlap = min(bottom, bounds.y + bounds.height) - max(y, bounds.y)
            if verticalOverlap > 0, bounds.x >= source.x + source.width {
                right = min(right, max(x, bounds.x - 2))
            }
            let horizontalOverlap = min(right, bounds.x + bounds.width) - max(x, bounds.x)
            if horizontalOverlap > 0, bounds.y >= source.y + source.height {
                bottom = min(bottom, max(y, bounds.y - 2))
            }
        }
        // Stop expansion at visible card edges or separators as well as text boxes.
        surface.pixels.withUnsafeBytes { data in
            let bytes = data.bindMemory(to: UInt8.self)
            func differs(_ px: Int, _ py: Int) -> Bool {
                let offset = py * surface.bytesPerRow + px * 4
                return max(abs(Int(bytes[offset + 2]) - Int(background.0)),
                           abs(Int(bytes[offset + 1]) - Int(background.1)),
                           abs(Int(bytes[offset]) - Int(background.2))) > 18
            }
            if right > source.x + source.width + 2 {
                for px in (source.x + source.width + 2)..<right {
                    let changed = (1...5).filter { differs(px, source.y + (source.height - 1) * $0 / 6) }.count
                    if changed >= 4 { right = px; break }
                }
            }
            if bottom > source.y + source.height + 2 {
                for py in (source.y + source.height + 2)..<bottom {
                    let changed = (1...7).filter { differs(source.x + (source.width - 1) * $0 / 8, py) }.count
                    if changed >= 6 { bottom = py; break }
                }
            }
        }
        return PixelRect(x: x, y: y, width: right - x, height: max(0, bottom - y))
    }

    private static func intersects(_ a: PixelRect, _ b: PixelRect) -> Bool {
        min(a.x + a.width, b.x + b.width) > max(a.x, b.x) &&
            min(a.y + a.height, b.y + b.height) > max(a.y, b.y)
    }

    private static func palette(around bounds: PixelRect, in surface: RasterSurface) -> Palette {
        let xs = [bounds.x - 3, bounds.x + bounds.width / 2, bounds.x + bounds.width + 2]
        let ys = [bounds.y - 3, bounds.y + bounds.height + 2]
        var samples: [(Double, Double, Double)] = []
        surface.pixels.withUnsafeBytes { data in
            let bytes = data.bindMemory(to: UInt8.self)
            for y in ys where y >= 0 && y < surface.size.height {
                for x in xs where x >= 0 && x < surface.size.width {
                    let offset = y * surface.bytesPerRow + x * 4
                    samples.append((Double(bytes[offset + 2]), Double(bytes[offset + 1]), Double(bytes[offset])))
                }
            }
        }
        let warmWhite: (UInt8, UInt8, UInt8) = (250, 249, 246)
        guard !samples.isEmpty else {
            return Palette(background: warmWhite, foreground: CGColor(gray: 0, alpha: 1))
        }
        let red = samples.map(\.0), green = samples.map(\.1), blue = samples.map(\.2)
        let uniform = [red, green, blue].allSatisfy { ($0.max() ?? 255) - ($0.min() ?? 0) <= 24 }
        let average: (UInt8, UInt8, UInt8) = (
            UInt8((red.reduce(0, +) / Double(samples.count)).rounded()),
            UInt8((green.reduce(0, +) / Double(samples.count)).rounded()),
            UInt8((blue.reduce(0, +) / Double(samples.count)).rounded())
        )
        let luminance = 0.2126 * linear(average.0) + 0.7152 * linear(average.1) + 0.0722 * linear(average.2)
        if uniform, luminance <= 0.10 {
            return Palette(background: average, foreground: CGColor(gray: 1, alpha: 1))
        }
        if uniform, luminance >= 0.30 {
            return Palette(background: average, foreground: CGColor(gray: 0, alpha: 1))
        }
        return Palette(background: warmWhite, foreground: CGColor(gray: 0, alpha: 1))
    }

    private static func linear(_ byte: UInt8) -> Double {
        let value = Double(byte) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func fill(_ bounds: PixelRect, color: (UInt8, UInt8, UInt8),
                             in pixels: inout Data, bytesPerRow: Int) {
        pixels.withUnsafeMutableBytes { data in
            let bytes = data.bindMemory(to: UInt8.self)
            for y in bounds.y..<(bounds.y + bounds.height) {
                for x in bounds.x..<(bounds.x + bounds.width) {
                    let offset = y * bytesPerRow + x * 4
                    bytes[offset] = color.2
                    bytes[offset + 1] = color.1
                    bytes[offset + 2] = color.0
                    bytes[offset + 3] = 255
                }
            }
        }
    }

    private static func quartzRect(_ bounds: PixelRect, imageHeight: Int) -> CGRect {
        CGRect(x: bounds.x, y: imageHeight - bounds.y - bounds.height,
               width: bounds.width, height: bounds.height)
    }

    private static func isValid(_ bounds: PixelRect, in size: PixelSize) -> Bool {
        bounds.x >= 0 && bounds.y >= 0 && bounds.width > 0 && bounds.height > 0 &&
        bounds.x <= size.width && bounds.y <= size.height &&
        bounds.width <= size.width - bounds.x && bounds.height <= size.height - bounds.y
    }
}
