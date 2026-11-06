import AppKit
import XCTest
@testable import ReadingGlass

/// Image-only integration tests: no Screen Recording permission or desktop
/// contents are involved. Sentences match the saved post-restart OCR fixtures.
final class TextRecognizerTests: XCTestCase, @unchecked Sendable {
    func testEnglish() async throws {
        try await assertRecognition("The train leaves tomorrow at nine.")
    }

    func testFrench() async throws {
        try await assertRecognition("Le train part demain à neuf heures.")
    }

    func testGerman() async throws {
        try await assertRecognition("Der Zug fährt morgen um neun Uhr ab.")
    }

    func testJapanese() async throws {
        try await assertRecognition("電車は明日の九時に出発します。")
    }

    func testSimplifiedChinese() async throws {
        try await assertRecognition("火车明天九点出发。")
    }

    func testArabic() async throws {
        try await assertRecognition("يغادر القطار غدًا في الساعة التاسعة.")
    }

    func testSpanish() async throws {
        try await assertRecognition("El tren sale mañana a las nueve.")
    }

    func testPortuguese() async throws {
        try await assertRecognition("Tradução em português: o próximo trem sai amanhã às nove.")
    }

    func testRasterRejectsInvalidDimensionsStrideAndByteCounts() {
        let invalid = [
            RasterSurface(size: PixelSize(width: 0, height: 1), bytesPerRow: 0, pixels: Data()),
            RasterSurface(size: PixelSize(width: 1, height: -1), bytesPerRow: 4, pixels: Data()),
            RasterSurface(size: PixelSize(width: 1, height: 1), bytesPerRow: 8, pixels: Data(count: 8)),
            RasterSurface(size: PixelSize(width: 2, height: 1), bytesPerRow: 8, pixels: Data(count: 7)),
            RasterSurface(size: PixelSize(width: Int.max, height: 1), bytesPerRow: 4, pixels: Data()),
            RasterSurface(size: PixelSize(width: 1, height: Int.max), bytesPerRow: 4, pixels: Data())
        ]
        for surface in invalid {
            XCTAssertThrowsError(try surface.makeCGImage())
        }
    }

    func testBGRAPixelsDecodeAsRedAndBlueWithoutChannelSwapping() throws {
        let surface = RasterSurface(size: PixelSize(width: 2, height: 1), bytesPerRow: 8,
                                    pixels: Data([0, 0, 255, 255, 255, 0, 0, 255]))
        let image = try surface.makeCGImage()
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        let data = try XCTUnwrap(context.data)
        let rgba = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 8))
        XCTAssertEqual(rgba, [255, 0, 0, 255, 0, 0, 255, 255])
    }

    private func assertRecognition(_ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let surface = try await Self.render(expected)
        let frame = CapturedFrame(
            id: FrameID(sequence: 1, capturedAtNanoseconds: 1),
            stamp: RevisionStamp(geometry: 1, language: 0, model: "ocr-test"),
            displayID: 0,
            captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: 2200, height: 180)),
            surface: surface, scaleX: 1, scaleY: 1
        )
        let result = try await TextRecognizer().recognize(frame)
        let actual = result.lines.map(\.text).joined(separator: " ")
        XCTAssertEqual(Self.withoutWhitespace(actual), Self.withoutWhitespace(expected), file: file, line: line)
        XCTAssertFalse(result.supportedLanguages.isEmpty, file: file, line: line)
        XCTAssertFalse(result.lines.isEmpty, file: file, line: line)
        XCTAssertEqual(result.frame.id, frame.id, file: file, line: line)
        XCTAssertEqual(result.frame.stamp, frame.stamp, file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.elapsedSeconds, 0, file: file, line: line)
        for recognized in result.lines {
            assertBounds(recognized.bounds, in: surface.size, file: file, line: line)
            XCTAssertGreaterThan(recognized.confidence, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(recognized.confidence, 1, file: file, line: line)
            for span in recognized.spans {
                assertBounds(span.bounds, in: surface.size, file: file, line: line)
                XCTAssertGreaterThanOrEqual(span.textRange.location, 0, file: file, line: line)
                XCTAssertGreaterThan(span.textRange.length, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(span.textRange.location + span.textRange.length,
                                         recognized.text.utf16.count, file: file, line: line)
            }
        }
    }

    private func assertBounds(_ bounds: PixelRect, in size: PixelSize,
                              file: StaticString, line: UInt) {
        XCTAssertGreaterThanOrEqual(bounds.x, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(bounds.y, 0, file: file, line: line)
        XCTAssertGreaterThan(bounds.width, 0, file: file, line: line)
        XCTAssertGreaterThan(bounds.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.x + bounds.width, size.width, file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.y + bounds.height, size.height, file: file, line: line)
    }

    private static func withoutWhitespace(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }

    @MainActor
    private static func render(_ text: String) throws -> RasterSurface {
        let width = 2200
        let height = 180
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        (text as NSString).draw(at: NSPoint(x: 24, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(bitmap.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little).rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data)
        return RasterSurface(size: PixelSize(width: width, height: height), bytesPerRow: width * 4,
                             pixels: Data(bytes: bytes, count: width * height * 4))
    }
}
