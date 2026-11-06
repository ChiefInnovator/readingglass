import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ReadingGlass

final class OverlayQualityTests: XCTestCase, @unchecked Sendable {
    func testRealVisionDenseCardKeepsParagraphLinesTogetherWithoutNestedRegions() async throws {
        let fixture = try makeFixture(dark: true)
        let recognized = try await TextRecognizer().recognize(fixture.frame)
        let regions = TextSegmenter().segment(lines: recognized.lines, previous: [])
        XCTAssertTrue(regions.contains {
            $0.text.localizedCaseInsensitiveContains("questions") &&
            $0.text.localizedCaseInsensitiveContains("documents")
        }, "Actual Vision lines from a dense card must remain one paragraph.")
        for (index, first) in regions.enumerated() {
            for second in regions.dropFirst(index + 1) {
                let a = first.bounds, b = second.bounds
                let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                XCTAssertFalse(width > 2 && height > 2, "Nested OCR regions must be resolved before layout.")
            }
        }
    }

    func testDenseCardsRetainMetadataAndProduceReadableOverlay() async throws {
        for dark in [false, true] {
            let fixture = try makeFixture(dark: dark)
            let presentation = try await TranslationRenderer().render(
                frame: fixture.frame, translations: fixture.translations, occupiedRegions: fixture.regions)
            XCTAssertTrue(presentation.overflow.isEmpty)
            XCTAssertEqual(presentation.backingRegions.count, fixture.translations.count)
            for y in 200..<230 {
                let row = (y * fixture.frame.surface.bytesPerRow)..<((y + 1) * fixture.frame.surface.bytesPerRow)
                XCTAssertEqual(presentation.initialBackground.pixels[row], fixture.frame.surface.pixels[row],
                               "Already-English metadata must remain untouched")
            }
            if let path = ProcessInfo.processInfo.environment["READINGGLASS_VALIDATION_DIR"], !path.isEmpty {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = dark ? "dark" : "light"
                try writePNG(fixture.frame.surface, to: directory.appendingPathComponent("overlay-\(name)-source.png"))
                try writePNG(composite(presentation), to: directory.appendingPathComponent("overlay-\(name)-translated.png"))
            }
        }
    }

    private func makeFixture(dark: Bool) throws -> (frame: CapturedFrame, regions: [TextRegion], translations: [RegionTranslation]) {
        let width = 960, height = 500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(gray: dark ? 0.12 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: dark ? 0.4 : 0.65, alpha: 1))
        context.stroke(CGRect(x: 20, y: height - 255, width: 920, height: 235))
        context.stroke(CGRect(x: 20, y: 20, width: 920, height: 215))
        let foreground = CGColor(gray: dark ? 1 : 0.05, alpha: 1)
        func draw(_ text: String, x: Int, y: Int, size: CGFloat, bold: Bool = false) {
            let base = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let font = bold ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold)! : base
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground
            ])
            context.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(height - y) - size)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        draw("Notes de réunion", x: 40, y: 40, size: 26, bold: true)
        draw("La prochaine séance aura lieu demain matin. Merci de préparer vos questions", x: 40, y: 95, size: 20)
        draw("et de partager les documents avec les autres membres de l'équipe.", x: 40, y: 123, size: 20)
        draw("18 readers", x: 40, y: 205, size: 17)
        draw("3 tasks", x: 265, y: 205, size: 17)
        draw("1 file", x: 470, y: 205, size: 17)
        draw("Informations pratiques", x: 40, y: 290, size: 25, bold: true)
        draw("Veuillez arriver quelques minutes avant le début de la séance.", x: 40, y: 340, size: 20)
        draw("Le programme complet est disponible dans le document partagé.", x: 40, y: 368, size: 20)
        let bytes = try XCTUnwrap(context.data)
        let surface = RasterSurface(size: PixelSize(width: width, height: height), bytesPerRow: width * 4,
                                    pixels: Data(bytes: bytes, count: width * height * 4))
        let frame = CapturedFrame(id: FrameID(sequence: 1, capturedAtNanoseconds: 1),
            stamp: RevisionStamp(geometry: 1, language: 1, model: "synthetic"), displayID: 1,
            captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: width, height: height)),
            surface: surface, scaleX: 1, scaleY: 1)
        func region(_ text: String, x: Int = 40, y: Int, width: Int = 850, height: Int,
                    kind: TextRegionKind = .paragraph, lineHeight: Int = 20) -> TextRegion {
            let bounds = PixelRect(x: x, y: y, width: width, height: height)
            return TextRegion(id: UUID(), sourceRevision: 1, text: text, bounds: bounds,
                spans: [OCRSpan(textRange: UTF16Range(location: 0, length: text.utf16.count),
                    bounds: PixelRect(x: x, y: y, width: width, height: lineHeight), confidence: 1)], kind: kind)
        }
        let heading = region("Notes de réunion", y: 40, width: 230, height: 32, kind: .heading, lineHeight: 26)
        let paragraph = region("La prochaine séance aura lieu demain matin.", y: 95, height: 55)
        let heading2 = region("Informations pratiques", y: 290, width: 275, height: 32, kind: .heading, lineHeight: 25)
        let paragraph2 = region("Veuillez arriver quelques minutes avant le début de la séance.", y: 340, height: 55)
        let labels = [region("18 readers", y: 205, width: 130, height: 20, kind: .label),
                      region("3 tasks", x: 265, y: 205, width: 100, height: 20, kind: .label),
                      region("1 file", x: 470, y: 205, width: 80, height: 20, kind: .label)]
        let translated = [
            RegionTranslation(region: heading, text: "Meeting notes"),
            RegionTranslation(region: paragraph,
                text: "The next session is tomorrow morning. Please prepare your questions and share the documents with the other team members."),
            RegionTranslation(region: heading2, text: "Practical information"),
            RegionTranslation(region: paragraph2,
                text: "Please arrive a few minutes before the session begins. The full agenda is available in the shared document.")
        ]
        return (frame, [heading, paragraph] + labels + [heading2, paragraph2], translated)
    }

    private func composite(_ presentation: TranslationPresentation) throws -> RasterSurface {
        let size = presentation.frame.surface.size
        let context = try XCTUnwrap(CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.draw(try presentation.initialBackground.makeCGImage(), in: rect)
        context.draw(try presentation.foreground.makeCGImage(), in: rect)
        return RasterSurface(size: size, bytesPerRow: size.width * 4,
            pixels: Data(bytes: try XCTUnwrap(context.data), count: size.width * size.height * 4))
    }

    private func writePNG(_ surface: RasterSurface, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try surface.makeCGImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
