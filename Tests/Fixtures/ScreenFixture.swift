#if SCREEN_FIXTURE
import AppKit
import SwiftUI

/// Standalone synthetic desktop target. Not compiled into ReadingGlass or the
/// test bundle unless explicitly built with -D SCREEN_FIXTURE.
@main
enum ScreenFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        let window = NSWindow(contentRect: screen.visibleFrame.insetBy(dx: 40, dy: 40),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ReadingGlass Synthetic Fixture"
        // Keep synthetic content above ordinary apps but below the glass.
        // This prevents live acceptance from reading unrelated desktop content.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces]
        window.contentView = NSHostingView(rootView: FixtureContent())
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        menu.addItem(item)
        appMenu(menu)
    }
    private func appMenu(_ menu: NSMenu) { NSApp.mainMenu = menu; NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct FixtureContent: View {
    @State private var count = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("ReadingGlass synthetic screen fixture").font(.system(size: 32, weight: .bold))
                Button("Click-through counter: \(count)") { count += 1 }
                    .font(.system(size: 28)).buttonStyle(.bordered)
                ForEach(0..<12) { index in
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Fixture row \(index + 1) — value \(count)").bold()
                        Text("The train leaves tomorrow at nine.")
                        Text("Le train part demain à neuf heures.")
                        Text("El tren sale mañana a las nueve.")
                        Text("Tradução em português: o próximo trem sai amanhã às nove.")
                    }
                    .font(.system(size: 28))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(40)
        }.background(.white).foregroundStyle(.black)
    }
}
#endif
