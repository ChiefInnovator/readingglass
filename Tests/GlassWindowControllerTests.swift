import AppKit
import XCTest
@testable import ReadingGlass

@MainActor
final class GlassWindowControllerTests: XCTestCase {
    func testAutomaticWidthKeepsToolbarAttachedAndDoesNotRunWhilePaused() throws {
        let model = AppModel()
        let controller = GlassWindowController(model: model)
        let toolbar = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Toolbar" })
        defer {
            model.shutdown()
            for window in NSApp.windows where window.title.hasPrefix("ReadingGlass") { window.close() }
            withExtendedLifetime(controller) {}
        }
        let origin = model.glassFrame.origin
        let toolbarOrigin = toolbar.frame.origin
        XCTAssertTrue(model.automaticallyWiden(to: model.glassFrame.width + 80))
        XCTAssertEqual(model.glassFrame.origin, origin)
        XCTAssertEqual(toolbar.frame.origin, toolbarOrigin)
        model.togglePause()
        XCTAssertFalse(model.automaticallyWiden(to: model.glassFrame.width + 80))
    }

    func testResizeControlsExpandWithoutMovingTheGlassAndStayAnchoredWhileHeld() throws {
        let model = AppModel()
        let controller = GlassWindowController(model: model)
        let toolbar = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Toolbar" })
        let glassStart = model.glassFrame
        let compactWidth = toolbar.frame.width
        defer {
            model.shutdown()
            for window in NSApp.windows where window.title.hasPrefix("ReadingGlass") { window.close() }
            withExtendedLifetime(controller) {}
        }
        model.showsSizeControls = true
        XCTAssertEqual(model.glassFrame, glassStart)
        XCTAssertGreaterThan(toolbar.frame.width, compactWidth)
        let anchor = toolbar.frame.origin
        model.resize(width: glassStart.width + 40)
        model.resize(width: glassStart.width + 80)
        XCTAssertEqual(toolbar.frame.origin, anchor)
    }

    func testNativeDragHandleUsesScreenCoordinatesAfterWindowMoves() throws {
        let model = AppModel()
        let controller = GlassWindowController(model: model)
        let toolbar = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Toolbar" })
        let glass = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Capture Area" })
        defer {
            model.shutdown()
            for window in NSApp.windows where window.title.hasPrefix("ReadingGlass") { window.close() }
        }
        toolbar.contentView?.layoutSubtreeIfNeeded()
        var views = toolbar.contentView.map { [$0] } ?? []
        var handle: NSView?
        while let view = views.popLast() {
            if view.accessibilityLabel() == "Move glass" { handle = view; break }
            views.append(contentsOf: view.subviews)
        }
        let grip = try XCTUnwrap(handle)
        let start = glass.frame
        let toolbarStart = toolbar.frame
        let mouseStart = toolbar.convertPoint(toScreen: grip.convert(
            CGPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil))
        func send(_ type: NSEvent.EventType, offset: CGSize) throws {
            let screenPoint = CGPoint(x: mouseStart.x + offset.width, y: mouseStart.y + offset.height)
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: toolbar.convertPoint(fromScreen: screenPoint),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: toolbar.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            switch type {
            case .leftMouseDown: grip.mouseDown(with: event)
            case .leftMouseDragged: grip.mouseDragged(with: event)
            case .leftMouseUp: grip.mouseUp(with: event)
            default: XCTFail("Unexpected event type")
            }
        }
        try send(.leftMouseDown, offset: .zero)
        for offset in [CGSize(width: 60, height: 30), CGSize(width: 110, height: 50),
                       CGSize(width: 25, height: 15)] {
            try send(.leftMouseDragged, offset: offset)
            XCTAssertEqual(glass.frame, start.offsetBy(dx: offset.width, dy: offset.height))
            XCTAssertEqual(toolbar.frame, toolbarStart.offsetBy(dx: offset.width, dy: offset.height))
        }
        try send(.leftMouseUp, offset: CGSize(width: 30, height: 20))
        XCTAssertEqual(glass.frame, start.offsetBy(dx: 30, dy: 20))
        // A second gesture takes a new origin rather than retaining the first.
        controller.beginDrag()
        controller.drag(by: CGSize(width: 10, height: 10))
        XCTAssertEqual(glass.frame, start.offsetBy(dx: 40, dy: 30))
    }

    func testRepeatedDragSamplesKeepToolbarAndGlassTogether() throws {
        let model = AppModel()
        let display = try XCTUnwrap(model.currentDisplay)
        let controller = GlassWindowController(model: model)
        let toolbar = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Toolbar" })
        let glass = try XCTUnwrap(NSApp.windows.last { $0.title == "ReadingGlass Capture Area" })
        defer {
            model.shutdown()
            for window in NSApp.windows where window.title.hasPrefix("ReadingGlass") { window.close() }
        }
        let start = model.glassFrame
        let toolbarStart = toolbar.frame
        controller.beginDrag()

        // Samples are absolute offsets from mouse-down, not incremental moves.
        // Large samples hit every edge; reversing must not accumulate drift.
        let offsets = (0..<120).map { step in
            CGSize(width: CGFloat((step % 20) * 6), height: CGFloat((step % 15) * 3))
        } + [CGSize(width: 10_000, height: 10_000), CGSize(width: -10_000, height: -10_000),
             CGSize(width: 20, height: 10), CGSize.zero]
        for offset in offsets {
            controller.drag(by: offset)
            XCTAssertEqual(glass.frame, model.glassFrame)
            XCTAssertEqual(toolbar.frame.minX - toolbarStart.minX,
                           glass.frame.minX - start.minX, accuracy: 0.001)
            XCTAssertEqual(toolbar.frame.minY - toolbarStart.minY,
                           glass.frame.minY - start.minY, accuracy: 0.001)
            XCTAssertTrue(display.visibleFrame.contains(glass.frame))
            XCTAssertTrue(display.visibleFrame.contains(toolbar.frame))
        }
        XCTAssertEqual(glass.frame, start)
        XCTAssertEqual(toolbar.frame, toolbarStart)
    }
}
