import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let url: URL
    private let webView = MarkdownWebView()
    private var watcher: FileWatcher?
    private var onClose: ((DocumentWindowController) -> Void)?
    private var didEnsureTabBar = false
    /// Scrolled to once, after the first render (a link to `other.md#section`).
    private var pendingFragment: String?
    /// The document's current text, for searching across tabs.
    private(set) var sourceText = ""
    private lazy var findBar: FindBarViewController = {
        let bar = FindBarViewController()
        bar.layoutAttribute = .bottom
        bar.isHidden = true
        bar.onFind = { [weak self] query, backwards, incremental in
            self?.find(query, backwards: backwards, incremental: incremental)
        }
        bar.onClose = { [weak self] in self?.hideFindBar() }
        bar.onClear = { [weak self] in self?.webView.clearFind() }
        return bar
    }()

    /// `open` is how this window asks the app to open another document: from a
    /// clicked link (with an optional #fragment) or from files dropped on it.
    init(
        url: URL,
        fragment: String? = nil,
        open: @escaping (URL, String?) -> Void,
        onClose: @escaping (DocumentWindowController) -> Void
    ) {
        self.url = url
        self.pendingFragment = fragment
        self.onClose = onClose

        let window = NSWindow(
            contentRect: Self.initialContentRect(),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 420, height: 300)
        // A standard opaque titlebar, deliberately: with .fullSizeContentView the
        // WKWebView covers the titlebar strip and swallows the mouse events that
        // drag the window, leaving nothing to grab.
        window.title = url.lastPathComponent
        window.representedURL = url
        window.tabbingMode = .preferred
        super.init(window: window)

        window.delegate = self
        window.contentView = webView
        webView.onOpenLink = { url, fragment in open(url, fragment) }
        webView.onDropFiles = { urls in urls.forEach { open($0, nil) } }
        webView.loadRenderer()

        reload()
        watcher = FileWatcher(url: url) { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// A frame that always sits inside the active screen's visible area.
    /// `NSWindow.center()` is not safe here: on a tall default size, or on a
    /// multi-display layout with screens at negative origins, it can put the
    /// titlebar above the top of the screen where it cannot be grabbed.
    private static func initialContentRect() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 900, height: 800)
        }
        let visible = screen.visibleFrame
        let width = min(900, visible.width - 80)
        let height = min(1000, visible.height - 80)
        return NSRect(
            x: visible.minX + (visible.width - width) / 2,
            y: visible.minY + (visible.height - height) / 2,
            width: max(width, 420),
            height: max(height, 300)
        )
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show the tab bar even for a lone window: AppKit hides it by default,
        // and a hidden bar is not a drop target, so a dragged-out tab could
        // never be dropped back. Only on first show, so View > Hide Tab Bar
        // sticks for the window afterwards.
        if !didEnsureTabBar {
            didEnsureTabBar = true
            if let window, window.tabGroup?.isTabBarVisible == false {
                window.toggleTabBar(nil)
            }
        }
    }

    /// Scroll an already-open document to a heading (link to `file.md#id`).
    func scroll(toFragment id: String) {
        webView.scroll(toFragment: id)
    }

    // MARK: Outline

    /// Per window: only this document's sidebar opens or closes.
    @objc func toggleOutline(_ sender: Any?) {
        webView.toggleOutline()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleOutline(_:)) {
            item.title = webView.isOutlineVisible ? "Hide Outline" : "Show Outline"
        }
        return true
    }

    // MARK: File actions

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func copyPath(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: Print and PDF

    @objc func printDocument(_ sender: Any?) {
        runPrint(with: NSPrintInfo.shared, showsPanels: true)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            // A copy: jobDisposition/jobSavingURL must not leak into later prints.
            guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
            self.runPrint(with: info, showsPanels: false)
        }
    }

    private func runPrint(with info: NSPrintInfo, showsPanels: Bool) {
        guard let window else { return }
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = showsPanels
        operation.showsProgressPanel = showsPanels
        // WKWebView's print view has no frame of its own; without one the
        // output is blank.
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Search results

    /// Bring this tab forward and land on the rendered match for a hit from the
    /// all-tabs search (`line` is 0-based).
    func showSearchResult(query: String, line: Int) {
        showAndFocus()
        guard let window else { return }
        if findBar.parent == nil { window.addTitlebarAccessoryViewController(findBar) }
        findBar.isHidden = false
        findBar.query = query
        webView.findAtSourceLine(query, line: line) { [weak self] count, index in
            self?.findBar.showResult(count: count, index: index)
        }
    }

    // MARK: Find

    @objc func showFindBar(_ sender: Any?) {
        guard let window else { return }
        if findBar.parent == nil { window.addTitlebarAccessoryViewController(findBar) }
        findBar.isHidden = false
        // Seed with the page selection, like every other macOS find.
        webView.selectedText { [weak self] text in
            guard let self else { return }
            if let text, !text.isEmpty, !text.contains("\n") { self.findBar.query = text }
            self.findBar.focus()
        }
    }

    private func hideFindBar() {
        findBar.isHidden = true
        webView.clearFind()
        findBar.showResult(count: 0, index: -1)
        window?.makeFirstResponder(webView)
    }

    @objc func findNext(_ sender: Any?) { runFind(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { runFind(backwards: true) }

    @objc func useSelectionForFind(_ sender: Any?) {
        webView.selectedText { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.findBar.query = text
        }
    }

    private func runFind(backwards: Bool) {
        // Cmd-G with the bar closed opens it rather than doing nothing.
        guard !findBar.isHidden, findBar.parent != nil else {
            showFindBar(nil)
            return
        }
        findBar.search(backwards: backwards)
    }

    private func find(_ query: String, backwards: Bool, incremental: Bool) {
        webView.find(query, backwards: backwards, restart: incremental) { [weak self] count, index in
            self?.findBar.showResult(count: count, index: index)
        }
    }

    private func reload() {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Fall back to a lenient decode -- better a mojibake render than a
            // blank window when a file is not valid UTF-8.
            guard let data = try? Data(contentsOf: url) else {
                NSLog("xem: cannot read \(url.path): \(error)")
                return
            }
            text = String(decoding: data, as: UTF8.self)
        }
        sourceText = text
        let fragment = pendingFragment
        pendingFragment = nil
        webView.render(markdown: text, baseDir: url.deletingLastPathComponent().path, fragment: fragment)
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        onClose?(self)
        onClose = nil
    }
}
