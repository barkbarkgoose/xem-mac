import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let url: URL
    private let webView = MarkdownWebView()
    private var watcher: FileWatcher?
    private var onClose: ((DocumentWindowController) -> Void)?

    init(url: URL, onClose: @escaping (DocumentWindowController) -> Void) {
        self.url = url
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
    }

    private func reload() {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Fall back to a lenient decode -- better a mojibake render than a
            // blank window when a file is not valid UTF-8.
            guard let data = try? Data(contentsOf: url) else {
                NSLog("geenyan: cannot read \(url.path): \(error)")
                return
            }
            text = String(decoding: data, as: UTF8.self)
        }
        webView.render(markdown: text, baseDir: url.deletingLastPathComponent().path)
    }

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        onClose?(self)
        onClose = nil
    }
}
