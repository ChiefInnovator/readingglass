import AppKit

@main
enum ReadingGlassApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var windows: GlassWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests exercise services without capturing the desktop.
        guard NSClassFromString("XCTestCase") == nil else { return }
        let model = AppModel()
        self.model = model
        windows = GlassWindowController(model: model)
        windows?.show()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BrandIcon.menuBarImage()
        item.button?.toolTip = "ReadingGlass"
        let menu = NSMenu()
        menu.delegate = self
        for (title, action, key) in [
            ("Show / Hide Glass", #selector(toggleGlass), ""),
            ("OCR Diagnostics", #selector(showDiagnostics), ""),
            ("Pause / Resume", #selector(togglePause), ""),
            ("Copy Screenshot", #selector(copyScreenshot), ""),
            ("Reset Glass Size for This Display", #selector(resetGlass), ""),
            ("Quit ReadingGlass", #selector(quit), "q")
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "ReadingGlass")
        let quitItem = NSMenuItem(title: "Quit ReadingGlass", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)
        NSApp.mainMenu = mainMenu
        model.launch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let model else { return }
        menu.items.first { $0.action == #selector(toggleGlass) }?.title = model.isHidden ? "Show Glass" : "Hide Glass"
        menu.items.first { $0.action == #selector(togglePause) }?.title = model.isPaused ? "Resume Translation" : "Pause Translation"
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    @objc private func toggleGlass() { model?.toggleVisibility() }
    @objc private func showDiagnostics() { windows?.showDiagnostics() }
    @objc private func togglePause() { model?.togglePause() }
    @objc private func resetGlass() { model?.resetGlassToDisplay() }
    @objc private func copyScreenshot() { model?.copyScreenshot() }
    @objc private func quit() { NSApp.terminate(nil) }
}
