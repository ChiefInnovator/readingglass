import AppKit

/// Separate image layers keep the words stationary during background fades.
final class GlassContentView: NSView {
    private let originalLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let refinedLayer = CALayer()
    private let foregroundLayer = CALayer()
    private let rim = CAShapeLayer()
    private let innerRim = CAShapeLayer()
    private var showingOriginal = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for item in [originalLayer, backgroundLayer, refinedLayer, foregroundLayer] {
            item.contentsGravity = .resize
            item.masksToBounds = true
            layer?.addSublayer(item)
        }
        rim.fillColor = nil
        rim.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        rim.lineWidth = 1
        innerRim.fillColor = nil
        innerRim.strokeColor = NSColor.white.withAlphaComponent(0.6).cgColor
        innerRim.lineWidth = 1
        layer?.addSublayer(rim)
        layer?.addSublayer(innerRim)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [originalLayer, backgroundLayer, refinedLayer, foregroundLayer] { item.frame = bounds }
        rim.path = CGPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        innerRim.path = CGPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        CATransaction.commit()
    }

    func present(_ presentation: TranslationPresentation) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        originalLayer.contents = try? presentation.frame.surface.makeCGImage()
        backgroundLayer.contents = try? presentation.initialBackground.makeCGImage()
        foregroundLayer.contents = try? presentation.foreground.makeCGImage()
        refinedLayer.removeAllAnimations()
        refinedLayer.contents = nil
        refinedLayer.opacity = 0
        updateVisibility()
        CATransaction.commit()
    }

    func showOriginal(_ value: Bool) {
        showingOriginal = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateVisibility()
        CATransaction.commit()
    }

    func refine(_ surface: RasterSurface) {
        guard let image = try? surface.makeCGImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refinedLayer.contents = image
        refinedLayer.opacity = 1
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        refinedLayer.add(fade, forKey: "backgroundFade")
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [originalLayer, backgroundLayer, refinedLayer, foregroundLayer] {
            item.removeAllAnimations()
            item.contents = nil
        }
        CATransaction.commit()
    }

    private func updateVisibility() {
        originalLayer.isHidden = !showingOriginal
        backgroundLayer.isHidden = showingOriginal
        refinedLayer.isHidden = showingOriginal
        foregroundLayer.isHidden = showingOriginal
    }
}
