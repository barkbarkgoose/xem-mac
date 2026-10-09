import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keyed by resolved path so reopening a file focuses its window instead of
    /// stacking duplicates.
    private var controllers: [String: DocumentWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openDocument(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func openDocument(_ url: URL) {
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let existing = controllers[key] {
            NSLog("xem: focus existing window for %@", key)
            existing.showAndFocus()
            return
        }
        NSLog("xem: open new window for %@ (%d already open)", key, controllers.count)
        let controller = DocumentWindowController(url: url) { [weak self] closed in
            let closedKey = closed.url.resolvingSymlinksInPath().standardizedFileURL.path
            self?.controllers.removeValue(forKey: closedKey)
        }
        controllers[key] = controller
        controller.showAndFocus()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc private func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openDocument(url) }
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Xem", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Xem", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Xem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(MarkdownWebView.textZoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(MarkdownWebView.textZoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MarkdownWebView.textZoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}
