import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Keyed by resolved path so reopening a file focuses its window instead of
    /// stacking duplicates.
    private var controllers: [String: DocumentWindowController] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearancePreference.apply()
        buildMenu()
        installTabKeyMonitor()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openDocument(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    func openDocument(_ url: URL, fragment: String? = nil) {
        let key = key(for: url)
        if let existing = controllers[key] {
            NSLog("xem: focus existing window for %@", key)
            existing.showAndFocus()
            if let fragment { existing.scroll(toFragment: fragment) }
            return
        }
        NSLog("xem: open new window for %@ (%d already open)", key, controllers.count)
        let controller = DocumentWindowController(
            url: url,
            fragment: fragment,
            open: { [weak self] url, fragment in self?.openLink(url, fragment: fragment) },
            onClose: { [weak self] closed in
                guard let self else { return }
                self.controllers.removeValue(forKey: self.key(for: closed.url))
            }
        )
        controllers[key] = controller
        controller.showAndFocus()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// A link clicked in a document, or a file dropped on one. Markdown opens
    /// as another tab; viewable files open in their app; anything else is only
    /// revealed in Finder, so a link can never launch an executable.
    private func openLink(_ url: URL, fragment: String?) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSLog("xem: link target missing: %@", url.path)
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if url.isDocumentLike {
            openDocument(url, fragment: fragment)
        } else if let type = UTType(filenameExtension: url.pathExtension),
                  [UTType.image, .pdf, .audiovisualContent].contains(where: { type.conforms(to: $0) }) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Open Recent

    private let recentMenu = NSMenu(title: "Open Recent")

    /// Rebuilt on demand rather than via AppKit's automatic recent-documents
    /// menu, which routes through NSDocumentController and would try to
    /// instantiate an NSDocument.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openDocument(url) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: Search all tabs

    private lazy var searchController: GlobalSearchWindowController = {
        let controller = GlobalSearchWindowController()
        controller.documents = { [weak self] in
            guard let self else { return [] }
            return self.controllers.values
                .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                .map { ($0.url, $0.sourceText) }
        }
        controller.onSelect = { [weak self] url, query, line in
            guard let self, let target = self.controllers[self.key(for: url)] else { return }
            target.showSearchResult(query: query, line: line)
        }
        return controller
    }()

    @objc private func showGlobalSearch(_ sender: Any?) {
        searchController.showAndFocus()
    }

    // MARK: Help

    private lazy var shortcutsController = ShortcutsWindowController()

    @objc private func showShortcuts(_ sender: Any?) {
        shortcutsController.showAndFocus()
    }

    @objc private func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: "A small markdown viewer that live-reloads on save.\n\n"
                + "Keyboard shortcuts: Help \u{2192} Keyboard Shortcuts (\u{2318}/).",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private var settingsController: SettingsWindowController?

    @objc private func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.showAndFocus()
    }

    @objc private func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { openDocument(url) }
    }

    /// Tab keys. A local monitor runs before the web view sees the event, so
    /// WebKit cannot claim Cmd-Shift-Arrow for text selection, and Ctrl-Tab
    /// works regardless of which view has focus. It also owns Cmd-Shift-\
    /// (AppKit's own tab overview is replaced by the filterable switcher).
    private func installTabKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let window = NSApp.keyWindow
            let switcherIsKey = window != nil && window === self.tabSwitcher.window
            switch (event.keyCode, mods) {
            case (42, [.command, .shift]):   // backslash
                self.showTabSwitcher(nil)
            case (124, [.command, .shift]),  // right arrow
                 (48, [.control]):           // tab
                if switcherIsKey { self.tabSwitcher.moveSelection(by: 1) } else { window?.selectNextTab(nil) }
            case (123, [.command, .shift]),  // left arrow
                 (48, [.control, .shift]):
                if switcherIsKey { self.tabSwitcher.moveSelection(by: -1) } else { window?.selectPreviousTab(nil) }
            default:
                return event
            }
            return nil
        }
    }

    // MARK: Tab switcher

    private lazy var tabSwitcher: TabSwitcherWindowController = {
        let controller = TabSwitcherWindowController()
        controller.entries = { [weak self] in self?.tabSwitcherEntries() ?? [] }
        controller.onSelect = { [weak self] url in
            self?.controllers[self?.key(for: url) ?? ""]?.showAndFocus()
        }
        return controller
    }()

    /// Documents in tab order, grouped by window.
    private func tabSwitcherEntries() -> [TabSwitcherWindowController.Entry] {
        let current = (NSApp.keyWindow?.windowController as? DocumentWindowController)?.url
        var seen = Set<ObjectIdentifier>()
        var entries: [TabSwitcherWindowController.Entry] = []
        for window in NSApp.windows {
            for tab in window.tabGroup?.windows ?? [window] where seen.insert(ObjectIdentifier(tab)).inserted {
                guard let document = tab.windowController as? DocumentWindowController else { continue }
                entries.append(.init(url: document.url, isCurrent: document.url == current))
            }
        }
        return entries
    }

    @objc private func showTabSwitcher(_ sender: Any?) {
        tabSwitcher.showAndFocus()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Xem", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Xem", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Xem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        let reveal = fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        let copyPath = fileMenu.addItem(withTitle: "Copy Path", action: #selector(DocumentWindowController.copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export as PDF…", action: #selector(DocumentWindowController.exportPDF(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Print…", action: #selector(DocumentWindowController.printDocument(_:)), keyEquivalent: "p")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Handled by DocumentWindowController (WKWebView has no built-in find UI).
        let find = editMenu.addItem(withTitle: "Find…", action: #selector(DocumentWindowController.showFindBar(_:)), keyEquivalent: "f")
        find.keyEquivalentModifierMask = .command
        editMenu.addItem(withTitle: "Find Next", action: #selector(DocumentWindowController.findNext(_:)), keyEquivalent: "g")
        let prevFind = editMenu.addItem(withTitle: "Find Previous", action: #selector(DocumentWindowController.findPrevious(_:)), keyEquivalent: "G")
        prevFind.keyEquivalentModifierMask = [.command, .shift]
        let findAll = editMenu.addItem(withTitle: "Find in All Tabs…", action: #selector(showGlobalSearch(_:)), keyEquivalent: "F")
        findAll.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(withTitle: "Use Selection for Find", action: #selector(DocumentWindowController.useSelectionForFind(_:)), keyEquivalent: "e")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(MarkdownWebView.textZoomReset(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(MarkdownWebView.textZoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(MarkdownWebView.textZoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        // Text column width. Option-Cmd brackets, to stay clear of Cmd +/-
        // (text zoom) and the system's Option-Cmd +/- screen zoom.
        let wider = viewMenu.addItem(withTitle: "Wider Column", action: #selector(MarkdownWebView.widerColumn(_:)), keyEquivalent: "]")
        wider.keyEquivalentModifierMask = [.command, .option]
        let narrower = viewMenu.addItem(withTitle: "Narrower Column", action: #selector(MarkdownWebView.narrowerColumn(_:)), keyEquivalent: "[")
        narrower.keyEquivalentModifierMask = [.command, .option]
        let defaultWidth = viewMenu.addItem(withTitle: "Default Column Width", action: #selector(MarkdownWebView.resetColumnWidth(_:)), keyEquivalent: "0")
        defaultWidth.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        let outline = viewMenu.addItem(withTitle: "Show Outline", action: #selector(DocumentWindowController.toggleOutline(_:)), keyEquivalent: "o")
        outline.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        // Ctrl-Cmd-F, the macOS standard; plain Cmd-F belongs to Find.
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
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
        let allTabs = windowMenu.addItem(withTitle: "Show All Tabs…", action: #selector(showTabSwitcher(_:)), keyEquivalent: "\\")
        allTabs.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(withTitle: "Show/Hide Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "/")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}
