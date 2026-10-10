import AppKit
import UniformTypeIdentifiers
import WebKit

/// A WKWebView preloaded with the bundled renderer. Markdown is pushed in as a
/// JSON-encoded argument -- never interpolated into JS source, where a stray
/// backtick or quote in the document would break the call.
final class MarkdownWebView: WKWebView {
    private var isReady = false
    private var pending: (text: String, baseDir: String, fragment: String?)?
    private let bridge = ScriptBridge()

    /// A relative link in the document was clicked (app.js resolved it).
    var onOpenLink: ((_ url: URL, _ fragment: String?) -> Void)?
    /// Files were dropped on the page.
    var onDropFiles: (([URL]) -> Void)?

    private static let scaleKey = "textScale"
    private static let scaleRange = 0.5...3.0
    private static let scaleStep = 0.1

    /// Text-only zoom, shared by every window and remembered across launches.
    private var textScale: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: Self.scaleKey)
            return saved == 0 ? 1.0 : saved
        }
        set {
            let clamped = min(max(newValue, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
            // Round away float drift from repeated 0.1 steps.
            UserDefaults.standard.set((clamped * 100).rounded() / 100, forKey: Self.scaleKey)
        }
    }

    init() {
        let config = WKWebViewConfiguration()
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        config.userContentController.add(bridge, name: "xem")
        super.init(frame: .zero, configuration: config)
        bridge.owner = self
        setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { isInspectable = true }
        navigationDelegate = self
        NotificationCenter.default.addObserver(
            forName: FindColors.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFindColors() }
        NotificationCenter.default.addObserver(
            forName: UIFontSize.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyUIScale() }
    }

    deinit {
        // The content controller retains its handlers.
        configuration.userContentController.removeScriptMessageHandler(forName: "xem")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc func textZoomIn(_ sender: Any?) { adjustTextScale(by: Self.scaleStep) }
    @objc func textZoomOut(_ sender: Any?) { adjustTextScale(by: -Self.scaleStep) }
    @objc func textZoomReset(_ sender: Any?) {
        textScale = 1.0
        applyTextScale()
    }

    private func adjustTextScale(by delta: Double) {
        textScale += delta
        applyTextScale()
    }

    private func applyTextScale() {
        guard isReady else { return }
        evaluateJavaScript("window.xem.setTextScale(\(textScale));") { _, error in
            if let error { NSLog("xem: setTextScale failed: \(error)") }
        }
    }

    /// The menu claims Cmd-+ (Cmd-Shift-=); most keyboards press plain Cmd-=,
    /// which would otherwise be dropped.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.charactersIgnoringModifiers == "=" {
            textZoomIn(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The page's current selection, if any.
    func selectedText(_ completion: @escaping (String?) -> Void) {
        evaluateJavaScript("window.getSelection().toString()") { result, _ in
            completion(result as? String)
        }
    }

    /// Find-in-page, implemented in app.js so every match can be highlighted
    /// (WKWebView.find only selects one). `restart` re-runs the search from
    /// the reader's position; otherwise this steps to the next/previous match.
    /// Completes with the total match count and the active match's index.
    func find(
        _ query: String, backwards: Bool, restart: Bool,
        completion: @escaping (_ count: Int, _ index: Int) -> Void
    ) {
        guard isReady, let json = Self.jsonString(query) else { return completion(0, -1) }
        evaluateJavaScript("window.xem.find(\(json), \(backwards), \(restart));") { result, _ in
            let status = result as? [String: Any]
            completion(status?["count"] as? Int ?? 0, status?["index"] as? Int ?? -1)
        }
    }

    func clearFind() {
        guard isReady else { return }
        evaluateJavaScript("window.xem.clearFind();", completionHandler: nil)
    }

    /// Push the user's stored find colors (Settings window) into the page.
    private func applyFindColors() {
        guard isReady, let json = Self.jsonString(FindColors.pagePayload()) else { return }
        evaluateJavaScript("window.xem.setFindColors(\(json));", completionHandler: nil)
    }

    private static func jsonString(_ value: Any) -> String? {
        // fragmentsAllowed so a bare String encodes too.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Select the rendered match for a hit at `line` (0-based) in the source.
    func findAtSourceLine(
        _ query: String, line: Int,
        completion: @escaping (_ count: Int, _ index: Int) -> Void
    ) {
        guard isReady, let json = Self.jsonString(query) else { return completion(0, -1) }
        evaluateJavaScript("window.xem.findAtSourceLine(\(json), \(line));") { result, _ in
            let status = result as? [String: Any]
            completion(status?["count"] as? Int ?? 0, status?["index"] as? Int ?? -1)
        }
    }

    func scroll(toFragment id: String) {
        guard isReady, let json = Self.jsonString(id) else { return }
        evaluateJavaScript("window.xem.scrollToId(\(json));", completionHandler: nil)
    }

    /// This window's own outline state; it starts from the remembered default.
    private(set) var isOutlineVisible = OutlinePreference.isVisible

    func toggleOutline() {
        isOutlineVisible.toggle()
        // The default for windows opened later follows the latest choice.
        OutlinePreference.isVisible = isOutlineVisible
        applyOutline()
    }

    private func applyUIScale() {
        guard isReady else { return }
        evaluateJavaScript("window.xem.setUIScale(\(UIFontSize.scale));", completionHandler: nil)
    }

    private func applyOutline() {
        guard isReady else { return }
        evaluateJavaScript(
            "window.xem.setOutlineVisible(\(isOutlineVisible));", completionHandler: nil)
    }

    fileprivate func handleScriptMessage(_ body: Any) {
        guard let message = body as? [String: Any] else { return }
        if message["type"] as? String == "toggleOutline" {
            toggleOutline()
            return
        }
        guard message["type"] as? String == "openLink",
              let path = message["path"] as? String
        else { return }
        let fragment = (message["fragment"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        onOpenLink?(URL(fileURLWithPath: path), fragment)
    }

    // MARK: Context menu

    /// WebKit's default menu offers Reload / Back / Forward, which would blank
    /// the renderer (the page is the app's own index.html). Replace with
    /// document-level actions.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let unwanted: Set<String> = [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
        ]
        for item in menu.items where unwanted.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        if let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        // Target nil: resolved through the responder chain to the window's controller.
        menu.addItem(withTitle: "Reveal in Finder",
                     action: #selector(DocumentWindowController.revealInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy Path",
                     action: #selector(DocumentWindowController.copyPath(_:)), keyEquivalent: "")
    }

    // MARK: Drag and drop

    /// Dropped markdown/text files open as documents. Anything else falls
    /// through to WebKit, which would otherwise navigate the page away.
    private func droppedDocuments(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return (urls ?? []).filter(\.isDocumentLike)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedDocuments(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedDocuments(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedDocuments(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedDocuments(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }

    func loadRenderer() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("web") else {
            NSLog("xem: web resources missing from bundle")
            return
        }
        // Read access is granted at "/" rather than the web root: documents
        // reference images anywhere on disk, and a narrower scope makes every
        // relative <img> in every document fail silently.
        loadFileURL(
            root.appendingPathComponent("index.html"),
            allowingReadAccessTo: URL(fileURLWithPath: "/", isDirectory: true)
        )
    }

    /// `baseDir` lets the page resolve relative image paths against the document,
    /// not against the bundle's web root.
    func render(markdown text: String, baseDir: String, fragment: String? = nil) {
        guard isReady else {
            pending = (text, baseDir, fragment)
            return
        }
        let payload = ["markdown": text, "baseDir": baseDir, "fragment": fragment ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        evaluateJavaScript("window.xem.render(\(json));") { _, error in
            if let error { NSLog("xem: render failed: \(error)") }
        }
    }
}

extension MarkdownWebView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        applyTextScale()
        applyFindColors()
        applyUIScale()
        applyOutline()
        if let pending {
            self.pending = nil
            render(markdown: pending.text, baseDir: pending.baseDir, fragment: pending.fragment)
        }
    }

    /// Keep the web view on the local renderer; send real links to the browser.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        // Anything with a real scheme (http, mailto, ...) belongs to the system.
        // Relative and file links never get here: app.js intercepts them.
        if action.navigationType == .linkActivated, let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Keeps the web view from being retained by its own content controller.
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    weak var owner: MarkdownWebView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleScriptMessage(message.body)
    }
}

extension URL {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    var isMarkdown: Bool { Self.markdownExtensions.contains(pathExtension.lowercased()) }

    /// Something Xem can display: markdown, or any plain-text file.
    var isDocumentLike: Bool {
        if isMarkdown { return true }
        guard let type = UTType(filenameExtension: pathExtension) else { return false }
        return type.conforms(to: .plainText)
    }
}
