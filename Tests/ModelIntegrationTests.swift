import AppKit
import XCTest
@testable import ReadingGlass

/// Opt-in, image-only acceptance of the model pipeline inside the real app host.
/// Unlike package tests, this requires LaMa512 in Bundle.main. No desktop pixels
/// are captured, and any exported images contain this test's synthetic sentence.
final class ModelIntegrationTests: XCTestCase, @unchecked Sendable {
    func testPackagedModelsRecognizeTranslateRenderAndRestore() async throws {
        guard ProcessInfo.processInfo.environment["READINGGLASS_TEST_REAL_MODEL"] == "1" else {
            throw XCTSkip("Set READINGGLASS_TEST_REAL_MODEL=1 for packaged model integration")
        }
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "LaMa512", withExtension: "mlmodelc"),
                                    "The application host must contain the compiled LaMa512 model")
        let expected = "Le train part demain à neuf heures."
        let surface = try await Self.makeFixture(expected)
        let frame = CapturedFrame(
            id: FrameID(sequence: 1, capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds),
            stamp: RevisionStamp(geometry: 1, language: 1, model: "5788ec08c047f3f2e17808101b8d9566ac930d58"),
            displayID: 0,
            captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: 1000, height: 180)),
            surface: surface, scaleX: 1, scaleY: 1
        )
        let ocr = try await TextRecognizer().recognize(frame)
        XCTAssertEqual(Self.normalized(ocr.lines.map(\.text).joined(separator: " ")), Self.normalized(expected))
        let regions = TextSegmenter().segment(lines: ocr.lines, previous: [])
        XCTAssertFalse(regions.isEmpty)

        let scheduler = InferenceScheduler()
        let translator = RuntimeTranslationBackend(scheduler: scheduler)
        let installation = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadingGlass/Models/TranslateGemma/5788ec08c047f3f2e17808101b8d9566ac930d58", isDirectory: true)
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await translator.load(directory: installation)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        do {
            let translateStart = ProcessInfo.processInfo.systemUptime
            var translated: [RegionTranslation] = []
            for region in regions {
                let result = try await translator.translate(
                    text: region.text, source: "fr", target: "en",
                    maximumOutputTokens: 96, deadline: .seconds(3)
                )
                XCTAssertEqual(result.finish, .complete)
                XCTAssertFalse(result.text.isEmpty)
                guard result.finish == .complete, !result.text.isEmpty else {
                    throw ModelIntegrationFailure.incompleteTranslation
                }
                translated.append(RegionTranslation(region: region, text: result.text))
            }
            let translationSeconds = ProcessInfo.processInfo.systemUptime - translateStart
            let english = translated.map(\.text).joined(separator: " ").lowercased()
            XCTAssertTrue(english.contains("train"), english)
            XCTAssertTrue(english.contains("tomorrow"), english)
            XCTAssertTrue(english.contains("nine") || english.contains("9"), english)

            let presentation = try await TranslationRenderer().render(
                frame: frame, translations: translated, occupiedRegions: regions
            )
            XCTAssertTrue(presentation.overflow.isEmpty, "The complete synthetic sentence should fit")
            XCTAssertEqual(presentation.backingRegions.count, translated.count)
            XCTAssertNotEqual(presentation.initialBackground.pixels, surface.pixels)
            let foregroundBefore = presentation.foreground.pixels

            let restorer = BackgroundInpainter(scheduler: scheduler)
            let restoreStart = ProcessInfo.processInfo.systemUptime
            try await restorer.prepare(modelURL: modelURL)
            let refined = try await restorer.restore(presentation: presentation)
            let restorationSeconds = ProcessInfo.processInfo.systemUptime - restoreStart
            XCTAssertEqual(refined.size, surface.size)
            XCTAssertEqual(refined.bytesPerRow, surface.bytesPerRow)
            XCTAssertEqual(refined.pixels.count, surface.pixels.count)
            XCTAssertNotEqual(refined.pixels, presentation.initialBackground.pixels,
                              "The real restoration path must produce a refined background")
            XCTAssertEqual(presentation.foreground.pixels, foregroundBefore,
                           "Refinement must not mutate the published translated foreground")

            let initialComposite = try Self.composite(background: presentation.initialBackground,
                                                      foreground: presentation.foreground)
            let refinedComposite = try Self.composite(background: refined, foreground: presentation.foreground)
            let foreground = [UInt8](foregroundBefore)
            let initialPixels = [UInt8](initialComposite.pixels)
            let refinedPixels = [UInt8](refinedComposite.pixels)
            var opaqueGlyphPixels = 0
            for offset in stride(from: 0, to: foreground.count, by: 4) where foreground[offset + 3] == 255 {
                opaqueGlyphPixels += 1
                XCTAssertEqual(Array(initialPixels[offset..<(offset + 4)]),
                               Array(refinedPixels[offset..<(offset + 4)]),
                               "Opaque translated glyphs must remain unchanged after refinement")
            }
            XCTAssertGreaterThan(opaqueGlyphPixels, 0)

            if let outputPath = ProcessInfo.processInfo.environment["READINGGLASS_VALIDATION_DIR"], !outputPath.isEmpty {
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try await Self.writePNG(surface, to: output.appendingPathComponent("synthetic-original.png"))
                try await Self.writePNG(initialComposite, to: output.appendingPathComponent("synthetic-initial-translation.png"))
                try await Self.writePNG(refinedComposite, to: output.appendingPathComponent("synthetic-refined-translation.png"))
            }
            print(String(format: "Packaged model integration: OCR=%.3fs modelLoad=%.3fs translation=%.3fs restorationWithLoad=%.3fs regions=%d",
                         ocr.elapsedSeconds, loadSeconds, translationSeconds, restorationSeconds, regions.count))
            print("Packaged synthetic translation: \(translated.map(\.text).joined(separator: " "))")
            await translator.unload()
        } catch {
            await translator.unload()
            throw error
        }
    }

    private static func normalized(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    @MainActor
    private static func makeFixture(_ text: String) throws -> RasterSurface {
        let width = 1000, height = 180
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let gradient = try XCTUnwrap(NSGradient(starting: NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.91, alpha: 1),
                                                ending: NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.98, alpha: 1)))
        gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 0)
        (text as NSString).draw(at: NSPoint(x: 28, y: 68), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.cgImage)
        return try rasterizing(image)
    }

    private static func composite(background: RasterSurface, foreground: RasterSurface) throws -> RasterSurface {
        XCTAssertEqual(background.size, foreground.size)
        let context = try context(for: background.size)
        let bounds = CGRect(x: 0, y: 0, width: background.size.width, height: background.size.height)
        context.draw(try background.makeCGImage(), in: bounds)
        context.draw(try foreground.makeCGImage(), in: bounds)
        return try raster(context, size: background.size)
    }

    private static func rasterizing(_ image: CGImage) throws -> RasterSurface {
        let size = PixelSize(width: image.width, height: image.height)
        let context = try context(for: size)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try raster(context, size: size)
    }

    private static func context(for size: PixelSize) throws -> CGContext {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: size.width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little).rawValue
        ))
    }

    private static func raster(_ context: CGContext, size: PixelSize) throws -> RasterSurface {
        let bytes = try XCTUnwrap(context.data)
        return RasterSurface(size: size, bytesPerRow: size.width * 4,
                             pixels: Data(bytes: bytes, count: size.width * size.height * 4))
    }

    @MainActor
    private static func writePNG(_ surface: RasterSurface, to destination: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: try surface.makeCGImage())
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: destination, options: .atomic)
    }
}

private enum ModelIntegrationFailure: Error { case incompleteTranslation }
