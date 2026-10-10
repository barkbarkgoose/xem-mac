import AppKit

/// Base for Xem's auxiliary windows (Settings, shortcuts, search, tab
/// switcher). Esc closes them wherever focus is: a text field handles it
/// itself, but a table or color well only passes it up the responder chain,
/// and `NSWindow` does nothing with `cancelOperation:` by default.
class PopupWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

final class PopupPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

extension NSWindow {
    /// Center over `reference` (normally the window the user was just in),
    /// kept inside its screen. Falls back to centering on screen. Call this
    /// before showing, while `reference` is still the key window.
    func center(over reference: NSWindow?) {
        guard let reference, reference !== self, reference.isVisible else {
            if reference !== self { center() }
            return
        }
        var frame = self.frame
        frame.origin.x = reference.frame.midX - frame.width / 2
        frame.origin.y = reference.frame.midY - frame.height / 2
        if let visible = (reference.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        setFrame(frame, display: false)
    }
}
