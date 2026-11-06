import Foundation

/// AppKit screen geometry, in global bottom-left-origin points.
struct DisplayGeometry: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat
}

enum GeometryError: Error, Equatable {
    case invalid
    case outsideDisplay
}

enum CaptureGeometry {
    static let margin: CGFloat = 16
    static let toolbarHeadroom: CGFloat = 68

    /// Logical points keep the reading area consistent on Retina and 1x screens.
    static func initialGlassFrame(on display: DisplayGeometry) -> CGRect {
        clampedGlassFrame(CGRect(x: CGFloat.nan, y: CGFloat.nan,
                                width: CGFloat.nan, height: CGFloat.nan), on: display)
    }

    /// Fits the glass on one display while retaining room for its toolbar.
    static func clampedGlassFrame(_ proposed: CGRect, on display: DisplayGeometry) -> CGRect {
        let visible = display.visibleFrame
        guard isValid(visible) else { return .zero }

        // Normally these are 16/68 points. Very small displays retain a positive
        // capture area instead of producing a negative or off-screen rectangle.
        let horizontalMargin = min(margin, max(0, (visible.width - 1) / 2))
        let verticalMargin = min(margin, max(0, (visible.height - 1) / 2))
        let headroom = min(toolbarHeadroom, max(0, visible.height - 2 * verticalMargin - 1))
        let available = CGRect(
            x: visible.minX + horizontalMargin,
            y: visible.minY + verticalMargin,
            width: visible.width - 2 * horizontalMargin,
            height: visible.height - 2 * verticalMargin - headroom
        )
        let defaultWidth = min(1400, max(320, (available.width * 0.70).rounded()))
        let defaultHeight = min(420, max(160, (available.height * 0.28).rounded()))
        let requestedWidth = proposed.size.width.isFinite && proposed.size.width > 0 ? proposed.size.width : defaultWidth
        let requestedHeight = proposed.size.height.isFinite && proposed.size.height > 0 ? proposed.size.height : defaultHeight
        let width = min(available.width, max(320, requestedWidth.rounded()))
        let height = min(available.height, max(160, requestedHeight.rounded()))
        let requestedX = proposed.origin.x.isFinite ? proposed.origin.x : available.midX - width / 2
        let requestedY = proposed.origin.y.isFinite ? proposed.origin.y : available.midY - height / 2
        return CGRect(
            x: min(max(requestedX.rounded(), available.minX), available.maxX - width),
            y: min(max(requestedY.rounded(), available.minY), available.maxY - height),
            width: width,
            height: height
        )
    }

    /// Move both windows by the same amount, retaining their relative positions
    /// when either one reaches the selected display's edge.
    static func clampedDragOffset(_ proposed: CGSize, glass: CGRect, toolbar: CGRect,
                                  on display: DisplayGeometry) -> CGSize {
        let visible = display.visibleFrame
        guard isValid(visible), isValid(glass), isValid(toolbar),
              proposed.width.isFinite, proposed.height.isFinite else { return .zero }
        let horizontalMargin = min(margin, max(0, (visible.width - 1) / 2))
        let verticalMargin = min(margin, max(0, (visible.height - 1) / 2))
        let available = visible.insetBy(dx: horizontalMargin, dy: verticalMargin)
        let windows = glass.union(toolbar)
        return CGSize(
            width: min(max(proposed.width, available.minX - windows.minX), available.maxX - windows.maxX),
            height: min(max(proposed.height, available.minY - windows.minY), available.maxY - windows.maxY)
        )
    }

    /// Grow to the right without moving the chosen reading position or toolbar.
    /// Repeated requests become no-ops at the selected display's usable edge.
    static func automaticallyWidenedFrame(_ frame: CGRect, requestedWidth: CGFloat,
                                          on display: DisplayGeometry) -> CGRect? {
        guard isValid(frame), isValid(display.visibleFrame), requestedWidth.isFinite else { return nil }
        let limit = display.visibleFrame.maxX - margin - frame.minX
        let width = min(requestedWidth, limit)
        guard width > frame.width + 1 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
    }

    /// ScreenCaptureKit's display-local source rectangle uses top-left-origin
    /// points. Backing scale belongs only in the output pixel dimensions.
    static func sourceRect(glassFrame: CGRect, display: DisplayGeometry) throws -> CGRect {
        guard isValid(glassFrame), isValid(display.frame) else {
            throw GeometryError.invalid
        }
        guard glassFrame.minX >= display.frame.minX,
              glassFrame.minY >= display.frame.minY,
              glassFrame.maxX <= display.frame.maxX,
              glassFrame.maxY <= display.frame.maxY else {
            throw GeometryError.outsideDisplay
        }
        return CGRect(
            x: glassFrame.minX - display.frame.minX,
            y: display.frame.maxY - glassFrame.maxY,
            width: glassFrame.width,
            height: glassFrame.height
        )
    }

    static func pixelSize(for rect: CGRect, scale: CGFloat) -> CGSize {
        guard isValid(rect), scale.isFinite, scale > 0 else { return .zero }
        let width = rect.width * scale
        let height = rect.height * scale
        guard width.isFinite, height.isFinite else { return .zero }
        return CGSize(width: ceil(width), height: ceil(height))
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite &&
        rect.size.width > 0 && rect.size.height > 0 &&
        rect.maxX.isFinite && rect.maxY.isFinite
    }
}
