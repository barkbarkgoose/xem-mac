import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keyed by resolved path so reopening a file focuses its window instead of
    /// stacking duplicates.
    private var controllers: [String: DocumentWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        installTabKeyMonitor()
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

    private func findItem(
        _ title: String, _ action: NSTextFinder.Action, key: String, mods: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = action.rawValue
        return item
    }

    /// Tab switching keys. A local monitor runs before the web view sees the
    /// event, so WebKit cannot claim Cmd-Shift-Arrow for text selection, and
    /// Ctrl-Tab works regardless of which view has focus.
    private func installTabKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let window = NSApp.keyWindow
            switch (event.keyCode, mods) {
            case (124, [.command, .shift]),  // right arrow
                 (48, [.control]):           // tab
                window?.selectNextTab(nil)
            case (123, [.command, .shift]),  // left arrow
                 (48, [.control, .shift]):
                window?.selectPreviousTab(nil)
            default:
                return event
            }
            return nil
        }
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
        editMenu.addItem(.separator())
        // WKWebView implements the system find bar; the item's tag picks the action.
        editMenu.addItem(findItem("Find…", .showFindInterface, key: "f", mods: .command))
        editMenu.addItem(findItem("Find Next", .nextMatch, key: "g", mods: .command))
        editMenu.addItem(findItem("Find Previous", .previousMatch, key: "g", mods: [.command, .shift]))
        editMenu.addItem(findItem("Use Selection for Find", .setSearchString, key: "e", mods: .command))
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

        // Without a Window menu there is no way to re-merge windows into tabs
        // (Merge All Windows) once a tab has been dragged out.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        // Shown with Cmd-Shift-Arrow; Ctrl-Tab / Ctrl-Shift-Tab are handled by
        // `installTabKeyMonitor`, which also pre-empts WebKit's own use of Cmd-Shift-Arrow.
        let arrow = { (key: Int) in String(UnicodeScalar(UInt32(key))!) }
        let next = windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: arrow(NSRightArrowFunctionKey))
        next.keyEquivalentModifierMask = [.command, .shift]
        let prev = windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: arrow(NSLeftArrowFunctionKey))
        prev.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Show/Hide Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
