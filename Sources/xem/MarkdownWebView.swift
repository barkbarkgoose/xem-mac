import AppKit
import WebKit

/// A WKWebView preloaded with the bundled renderer. Markdown is pushed in as a
/// JSON-encoded argument -- never interpolated into JS source, where a stray
/// backtick or quote in the document would break the call.
final class MarkdownWebView: WKWebView {
    private var isReady = false
    private var pending: (text: String, baseDir: String)?

    init() {
        let config = WKWebViewConfiguration()
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        super.init(frame: .zero, configuration: config)
        setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { isInspectable = true }
        navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

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
    func render(markdown text: String, baseDir: String) {
        guard isReady else {
            pending = (text, baseDir)
            return
        }
        let payload = ["markdown": text, "baseDir": baseDir]
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
        if let pending {
            self.pending = nil
            render(markdown: pending.text, baseDir: pending.baseDir)
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
        if action.navigationType == .linkActivated, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
