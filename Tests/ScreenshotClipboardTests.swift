import AppKit
import XCTest
@testable import ReadingGlass

@MainActor
final class ScreenshotClipboardTests: XCTestCase {
    func testCopiesPNGAtFullResolutionWithoutUsingGeneralClipboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let surface = RasterSurface(size: PixelSize(width: 2, height: 1), bytesPerRow: 8,
                                    pixels: Data([0, 0, 255, 255, 255, 0, 0, 255]))
        try ScreenshotClipboard.copy(surface, to: pasteboard)
        let data = try XCTUnwrap(pasteboard.data(forType: .png))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 2)
        XCTAssertEqual(bitmap.pixelsHigh, 1)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }
}
