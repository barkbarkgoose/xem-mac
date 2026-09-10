import AppKit
import WebKit

/// Headless render-to-PNG, used to verify the real WebKit pipeline (Mermaid and
/// KaTeX in particular) without a visible window:
///     geenyan --snapshot <in.md> <out.png>
final class Snapshotter: NSObject {
    private let input: URL
    private let output: URL
    private var window: NSWindow!
    private var webView: MarkdownWebView!

    init(input: URL, output: URL) {
        self.input = input
        self.output = output
    }

    func run() {
        webView = MarkdownWebView()
        // Offscreen, but a real window: WebKit does not lay out a view that was
        // never hosted, and the snapshot would come back blank.
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 1400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // GEENYAN_SNAPSHOT_LIGHT=1 forces the light palette for verification,
        // regardless of the system appearance.
        if ProcessInfo.processInfo.environment["GEENYAN_SNAPSHOT_LIGHT"] == "1" {
            window.appearance = NSAppearance(named: .aqua)
        }
        window.contentView = webView
        window.orderBack(nil)

        webView.loadRenderer()

        guard let text = try? String(contentsOf: input, encoding: .utf8) else {
            fail("cannot read \(input.path)")
            return
        }
        webView.render(markdown: text, baseDir: input.deletingLastPathComponent().path)

        // Give the page time to run mermaid/katex, then capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [self] in capture() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [self] in fail("timed out") }
    }

    private func capture() {
        // Grow the view to the full document height so nothing is cropped.
        webView.evaluateJavaScript("document.body.scrollHeight") { [self] value, _ in
            let height = (value as? CGFloat) ?? 1400
            window.setContentSize(NSSize(width: 1000, height: max(height, 200)))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: 1000, height: max(height, 200))
                webView.takeSnapshot(with: config) { [self] image, error in
                    guard let image,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:])
                    else {
                        fail("snapshot failed: \(error?.localizedDescription ?? "no image")")
                        return
                    }
                    do {
                        try png.write(to: output)
                        FileHandle.standardError.write(
                            Data("snapshot: \(output.path) (\(Int(image.size.width))x\(Int(image.size.height)))\n".utf8))
                        exit(0)
                    } catch {
                        fail("write failed: \(error)")
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("geenyan --snapshot: \(message)\n".utf8))
        exit(1)
    }
}
