import AppKit
import SwiftUI

@MainActor
final class GlassWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let glass: NSPanel
    private let toolbar: NSPanel
    private let diagnostics: NSWindow
    private let glassContent = GlassContentView()
    private let fullTranslation = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 520),
                                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private var previousGlassFrame: CGRect?
    private var dragStart: (glass: CGRect, toolbar: CGRect)?

    init(model: AppModel) {
        self.model = model
        glass = NSPanel(contentRect: model.glassFrame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        toolbar = ToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        diagnostics = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 570),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        super.init()
        glass.title = "ReadingGlass Capture Area"
        glass.isOpaque = false
        glass.backgroundColor = .clear
        glass.hasShadow = false
        glass.hidesOnDeactivate = false
        glass.ignoresMouseEvents = true
        glass.contentView = glassContent
        glass.level = .floating
        glass.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        glass.isReleasedWhenClosed = false

        toolbar.title = "ReadingGlass Toolbar"
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = true
        toolbar.hidesOnDeactivate = false
        toolbar.level = .floating
        toolbar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbar.isReleasedWhenClosed = false
        toolbar.contentView = NSHostingView(rootView: GlassToolbarView(
            model: model,
            onDragBegan: { [weak self] in self?.beginDrag() },
            onDragChanged: { [weak self] offset in self?.drag(by: offset) },
            onDragEnded: { [weak self] in self?.dragStart = nil }
        ))
        toolbar.delegate = self

        diagnostics.title = "ReadingGlass — OCR Diagnostics"
        diagnostics.contentMinSize = NSSize(width: 450, height: 400)
        diagnostics.isReleasedWhenClosed = false
        diagnostics.level = .floating
        diagnostics.delegate = self
        diagnostics.contentView = NSHostingView(rootView: OCRDiagnosticsView(model: model))
        diagnostics.center()
        fullTranslation.title = "ReadingGlass — Full Translation"
        fullTranslation.isReleasedWhenClosed = false
        fullTranslation.level = .floating
        fullTranslation.contentView = NSHostingView(rootView: FullTranslationView(model: model))
        fullTranslation.center()

        model.onGeometryChanged = { [weak self] frame in self?.positionWindows(frame) }
        model.onToolbarLayoutChanged = { [weak self] in
            guard let self else { return }
            self.positionWindows(self.model.glassFrame)
        }
        model.onVisibilityChanged = { [weak self] visible in
            if visible { self?.showGlass() }
            else { self?.glass.orderOut(nil); self?.toolbar.orderOut(nil) }
        }
        model.onShowDiagnostics = { [weak self] in self?.showDiagnostics() }
        model.onPresentation = { [weak self] presentation in
            if let presentation { self?.glassContent.present(presentation) }
            else { self?.glassContent.clear() }
        }
        model.onOriginal = { [weak self] value in self?.glassContent.showOriginal(value) }
        model.onRefinedBackground = { [weak self] surface in self?.glassContent.refine(surface) }
        model.onShowFullTranslation = { [weak self] in
            self?.fullTranslation.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        positionWindows(model.glassFrame)
    }

    func show() { showGlass(); showDiagnostics() }

    private func showGlass() {
        glass.orderFrontRegardless()
        toolbar.orderFrontRegardless()
    }

    func showDiagnostics() {
        diagnostics.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionWindows(_ frame: CGRect) {
        glass.setFrame(frame, display: true)
        let screen = model.currentDisplay?.visibleFrame ?? frame
        let desiredWidth: CGFloat = (model.showsSizeControls ? 1050 : 830) + (model.displays.count > 1 ? 130 : 0)
        let width = min(desiredWidth, max(1, screen.width - 32))
        let proposedX: CGFloat
        if let dragStart {
            proposedX = dragStart.toolbar.minX + frame.minX - dragStart.glass.minX
        } else if let previous = previousGlassFrame {
            proposedX = previous.size != frame.size ? toolbar.frame.minX :
                toolbar.frame.minX + frame.minX - previous.minX
        } else { proposedX = frame.minX }
        let x = min(max(proposedX, screen.minX + 16), screen.maxX - width - 16)
        toolbar.setFrame(CGRect(x: x, y: frame.maxY + 8, width: width, height: 56), display: true)
        previousGlassFrame = frame
    }

    func beginDrag() {
        dragStart = (model.glassFrame, toolbar.frame)
    }

    func drag(by proposedOffset: CGSize) {
        guard let dragStart, let display = model.currentDisplay else { return }
        let offset = CaptureGeometry.clampedDragOffset(proposedOffset, glass: dragStart.glass,
                                                      toolbar: dragStart.toolbar, on: display)
        let frame = CaptureGeometry.clampedGlassFrame(
            dragStart.glass.offsetBy(dx: offset.width, dy: offset.height), on: display)
        guard frame != model.glassFrame else { return }
        model.setGlassFrame(frame)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === diagnostics,
              !model.isHidden else { return }
        toolbar.makeKeyAndOrderFront(nil)
    }
}

private final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
