import XCTest
@testable import ReadingGlass

final class CaptureGeometryTests: XCTestCase {
    func testInitialSizeUsesUsablePointsAndNotRetinaPixelCount() {
        let retina = display(width: 1728, height: 1117, scale: 2)
        let standard = display(width: 1728, height: 1117, scale: 1)
        let frame = CaptureGeometry.initialGlassFrame(on: retina)
        XCTAssertEqual(frame.size, CGSize(width: 1187, height: 285))
        XCTAssertEqual(frame, CaptureGeometry.initialGlassFrame(on: standard))
        XCTAssertEqual(CaptureGeometry.initialGlassFrame(on: display(width: 5120, height: 2160)).size,
                       CGSize(width: 1400, height: 420))
        XCTAssertTrue(display(width: 800, height: 600).frame.contains(
            CaptureGeometry.initialGlassFrame(on: display(width: 800, height: 600))))
    }
    func testAutomaticWidthPreservesOriginAndStopsAtDisplayEdge() throws {
        let screen = display(x: -1920, y: -100, width: 1920, height: 1080)
        let start = CGRect(x: -1500, y: 200, width: 820, height: 300)
        let grown = try XCTUnwrap(CaptureGeometry.automaticallyWidenedFrame(start, requestedWidth: 10_000, on: screen))
        XCTAssertEqual(grown.origin, start.origin)
        XCTAssertEqual(grown.height, start.height)
        XCTAssertEqual(grown.maxX, screen.visibleFrame.maxX - CaptureGeometry.margin)
        XCTAssertNil(CaptureGeometry.automaticallyWidenedFrame(grown, requestedWidth: 10_000, on: screen))
        XCTAssertNil(CaptureGeometry.automaticallyWidenedFrame(start, requestedWidth: 500, on: screen))
    }

    private func display(
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 1728,
        height: CGFloat = 1117,
        scale: CGFloat = 2
    ) -> DisplayGeometry {
        let frame = CGRect(x: x, y: y, width: width, height: height)
        return DisplayGeometry(id: 1, name: "Test", frame: frame, visibleFrame: frame, scale: scale)
    }

    func testRetinaSourceRectStaysInPointsAndOutputUsesPixels() throws {
        let screen = display()
        let glass = CGRect(x: 100, y: 500, width: 820, height: 300)
        XCTAssertEqual(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen),
                       CGRect(x: 100, y: 317, width: 820, height: 300))
        XCTAssertEqual(CaptureGeometry.pixelSize(for: glass, scale: screen.scale),
                       CGSize(width: 1640, height: 600))
    }

    func testDisplaysLeftAboveAndBelowPrimaryUseTheirOwnOrigin() throws {
        for origin in [CGPoint(x: -1920, y: 200), CGPoint(x: 300, y: 1117), CGPoint(x: -200, y: -1080)] {
            let screen = display(x: origin.x, y: origin.y, width: 1920, height: 1080, scale: 1)
            let glass = CGRect(x: origin.x + 70, y: origin.y + 400, width: 820, height: 300)
            XCTAssertEqual(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen),
                           CGRect(x: 70, y: 380, width: 820, height: 300))
        }
    }

    func testOutputDimensionsRoundOutwardAtFractionalScale() {
        XCTAssertEqual(CaptureGeometry.pixelSize(for: CGRect(x: 0, y: 0, width: 320.25, height: 160.5), scale: 1.5),
                       CGSize(width: 481, height: 241))
    }

    func testClampReservesMarginsAndToolbarHeadroom() throws {
        let screen = display(x: -1920, y: -100, width: 1920, height: 1080)
        let proposed = CGRect(x: -3000, y: 2000, width: 820, height: 300)
        let glass = CaptureGeometry.clampedGlassFrame(proposed, on: screen)
        XCTAssertEqual(glass.minX, screen.visibleFrame.minX + 16)
        XCTAssertEqual(glass.maxY, screen.visibleFrame.maxY - 16 - 68)
        XCTAssertEqual(glass.size, proposed.size)
        XCTAssertNoThrow(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen))
    }

    func testClampUsesVisibleFrameAndFitsOversizedGlass() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let visible = CGRect(x: 0, y: 70, width: 1280, height: 706)
        let screen = DisplayGeometry(id: 1, name: "Test", frame: frame, visibleFrame: visible, scale: 2)
        let glass = CaptureGeometry.clampedGlassFrame(CGRect(x: -20, y: -20, width: 2000, height: 2000), on: screen)
        XCTAssertEqual(glass, CGRect(x: 16, y: 86, width: 1248, height: 606))
    }

    func testDragKeepsWiderToolbarAndGlassOnTheSameDisplay() {
        let screen = display(x: -1920, y: -100, width: 1920, height: 1080)
        let glass = CGRect(x: -1500, y: 200, width: 820, height: 300)
        let toolbar = CGRect(x: -1500, y: 508, width: 1000, height: 56)
        let rightTop = CaptureGeometry.clampedDragOffset(CGSize(width: 10_000, height: 10_000),
                                                         glass: glass, toolbar: toolbar, on: screen)
        XCTAssertEqual(rightTop, CGSize(width: 484, height: 400))
        let leftBottom = CaptureGeometry.clampedDragOffset(CGSize(width: -10_000, height: -10_000),
                                                           glass: glass, toolbar: toolbar, on: screen)
        XCTAssertEqual(leftBottom, CGSize(width: -404, height: -284))
        for offset in [rightTop, leftBottom, .zero] {
            XCTAssertTrue(screen.visibleFrame.contains(glass.offsetBy(dx: offset.width, dy: offset.height)))
            XCTAssertTrue(screen.visibleFrame.contains(toolbar.offsetBy(dx: offset.width, dy: offset.height)))
        }
    }

    func testDragKeepsWiderGlassWithinDisplayAndPreservesUnclampedOffset() {
        let screen = display(width: 1728, height: 1117)
        let glass = CGRect(x: 100, y: 300, width: 1200, height: 300)
        let toolbar = CGRect(x: 100, y: 608, width: 1000, height: 56)
        XCTAssertEqual(CaptureGeometry.clampedDragOffset(CGSize(width: 10_000, height: 0),
                                                        glass: glass, toolbar: toolbar, on: screen),
                       CGSize(width: 412, height: 0))
        XCTAssertEqual(CaptureGeometry.clampedDragOffset(CGSize(width: 40, height: -25),
                                                        glass: glass, toolbar: toolbar, on: screen),
                       CGSize(width: 40, height: -25))
    }

    func testMinimumSizeIsLimitedToAvailableScreenSpace() {
        let screen = display(width: 300, height: 200)
        let glass = CaptureGeometry.clampedGlassFrame(CGRect(x: 0, y: 0, width: 10, height: 10), on: screen)
        XCTAssertEqual(glass, CGRect(x: 16, y: 16, width: 268, height: 100))
    }

    func testNonFiniteProposedFrameFallsBackToUsableGeometry() throws {
        let screen = display()
        let glass = CaptureGeometry.clampedGlassFrame(
            CGRect(x: CGFloat.nan, y: CGFloat.infinity, width: CGFloat.nan, height: -1), on: screen)
        XCTAssertEqual(glass.size, CGSize(width: 1187, height: 285))
        XCTAssertNoThrow(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen))
    }

    func testPartialCrossDisplayCaptureIsRejectedOnEveryEdge() {
        let screen = display(width: 1000, height: 800)
        let invalid = [
            CGRect(x: -1, y: 100, width: 300, height: 200),
            CGRect(x: 701, y: 100, width: 300, height: 200),
            CGRect(x: 100, y: -1, width: 300, height: 200),
            CGRect(x: 100, y: 601, width: 300, height: 200)
        ]
        for glass in invalid {
            XCTAssertThrowsError(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen)) {
                XCTAssertEqual($0 as? GeometryError, .outsideDisplay)
            }
        }
    }

    func testInvalidAndEmptyCaptureRectanglesAreRejected() {
        let screen = display()
        for glass in [CGRect.zero, CGRect(x: 10, y: 10, width: -20, height: 30),
                      CGRect(x: CGFloat.infinity, y: 10, width: 30, height: 30)] {
            XCTAssertThrowsError(try CaptureGeometry.sourceRect(glassFrame: glass, display: screen)) {
                XCTAssertEqual($0 as? GeometryError, .invalid)
            }
        }
        XCTAssertEqual(CaptureGeometry.pixelSize(for: .zero, scale: 2), .zero)
        XCTAssertEqual(CaptureGeometry.pixelSize(for: screen.frame, scale: 0), .zero)
        XCTAssertEqual(CaptureGeometry.pixelSize(for: screen.frame, scale: .infinity), .zero)
    }
}
