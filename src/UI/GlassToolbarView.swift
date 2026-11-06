import AppKit
import SwiftUI

struct GlassToolbarView: View {
    @ObservedObject var model: AppModel
    let onDragBegan: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            DragHandle(onBegan: onDragBegan, onChanged: onDragChanged, onEnded: onDragEnded)
                .frame(width: 26).help("Drag to move the glass")
            VStack(alignment: .leading, spacing: 3) {
                Text("ReadingGlass").font(.headline)
                Text(model.toolbarStatus).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).help(model.status)
            }.frame(width: 175, alignment: .leading)
            Divider().frame(height: 32)
            Button { model.showsSizeControls.toggle() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help("Show or hide width and height controls").accessibilityLabel("Resize controls")
            if model.showsSizeControls {
                dimension("Width", value: model.glassFrame.width) { model.resize(width: model.glassFrame.width + $0) }
                dimension("Height", value: model.glassFrame.height) { model.resize(height: model.glassFrame.height + $0) }
            }
            LanguageSelector(title: "Translate to", selected: model.targetLanguage,
                             languages: model.languageNames, automatic: false) {
                if let code = $0 { model.setTargetLanguage(code) }
            }.frame(width: 130)
            if model.displays.count > 1 {
                Picker("Display", selection: Binding(get: { model.selectedDisplayID }, set: { model.selectDisplay($0) })) {
                    ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                }.labelsHidden().frame(width: 120).help("Keep the glass on this display")
            }
            Spacer(minLength: 0)
            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }.frame(width: 58)
            OriginalButton { model.holdOriginal($0) }.frame(width: 28, height: 24)
            Button("Read full text") { model.showFullTranslation() }.disabled(model.overflow.isEmpty)
                .help("Read translations that do not fit in the glass").frame(width: 90)
            Button { model.retryTranslation() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(!model.canRetryTranslation).help("Retry failed regions")
                .accessibilityLabel("Retry failed regions").frame(width: 28)
            Button { model.showDiagnostics() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Translation details and model setup")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Rectangle())
        .overlay(Rectangle().stroke(.white.opacity(0.2)))
    }

    private func dimension(_ title: String, value: CGFloat, adjust: @escaping (CGFloat) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(Int(value))").font(.caption.monospacedDigit())
            HStack(spacing: 5) {
                RepeatingSizeButton(symbol: "minus", label: "Decrease \(title.lowercased())") { adjust(-40) }
                RepeatingSizeButton(symbol: "plus", label: "Increase \(title.lowercased())") { adjust(40) }
            }
        }.frame(width: 104, alignment: .leading)
    }
}

private struct OriginalButton: NSViewRepresentable {
    let pressing: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> OriginalControl {
        let button = OriginalControl()
        button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Hold to view original")
        button.bezelStyle = .roundRect
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Hold to view original"
        button.setAccessibilityLabel("Hold to view original")
        button.pressing = pressing
        return button
    }
    func updateNSView(_ button: OriginalControl, context: Context) { button.pressing = pressing }
    final class OriginalControl: NSButton {
        var pressing: ((Bool) -> Void)?
        override func mouseDown(with event: NSEvent) {
            pressing?(true)
            defer { pressing?(false) }
            super.mouseDown(with: event)
        }
    }
}

private struct RepeatingSizeButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
                              target: context.coordinator, action: #selector(Coordinator.performAction))
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .roundRect
        button.controlSize = .small
        button.isContinuous = true
        button.setPeriodicDelay(0.35, interval: 0.075)
        button.setAccessibilityLabel(label)
        button.toolTip = "\(label). Hold to repeat."
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action }

    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func performAction() { action() }
    }
}

private struct DragHandle: NSViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
    }

    final class HandleView: NSView {
        var onBegan: (() -> Void)?
        var onChanged: ((CGSize) -> Void)?
        var onEnded: (() -> Void)?
        private var startPoint: CGPoint?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityLabel("Move glass")
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)?
                .draw(in: NSRect(x: 3, y: bounds.midY - 10, width: 20, height: 20))
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startPoint = window.convertPoint(toScreen: event.locationInWindow)
            NSCursor.closedHand.push()
            onBegan?()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let startPoint else { return }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            onChanged?(CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y))
        }
        override func mouseUp(with event: NSEvent) {
            guard startPoint != nil else { return }
            mouseDragged(with: event)
            startPoint = nil
            NSCursor.pop()
            onEnded?()
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
