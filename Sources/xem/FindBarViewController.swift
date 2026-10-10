import AppKit

/// A find strip docked under the titlebar. WKWebView on macOS has no built-in
/// find UI (it does not implement `performTextFinderAction:`), so this drives
/// `WKWebView.find` through callbacks.
final class FindBarViewController: NSTitlebarAccessoryViewController, NSSearchFieldDelegate {
    /// `(query, backwards, incremental)`. `incremental` is true while typing,
    /// when the search should restart from the current match, not skip past it.
    var onFind: ((String, Bool, Bool) -> Void)?
    var onClose: (() -> Void)?
    /// The query was emptied; drop the highlights.
    var onClear: (() -> Void)?

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private var chevrons: [NSButton] = []
    private var heightConstraint: NSLayoutConstraint?

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override func loadView() {
        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(queryChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.textColor = .secondaryLabelColor

        let previous = Self.button(symbol: "chevron.up", tip: "Previous Match", action: #selector(previousTapped))
        let next = Self.button(symbol: "chevron.down", tip: "Next Match", action: #selector(nextTapped))
        done.target = self
        done.action = #selector(doneTapped)
        done.bezelStyle = .rounded
        done.controlSize = .small

        for item in [previous, next] { item.target = self }
        chevrons = [previous, next]

        let stack = NSStackView(views: [field, status, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 36))
        container.addSubview(stack)
        let height = container.heightAnchor.constraint(equalToConstant: 36)
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        view = container
        applyFonts()
        NotificationCenter.default.addObserver(
            forName: UIFontSize.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFonts() }
    }

    /// Follow the interface text size; the strip grows with its text.
    private func applyFonts() {
        field.font = UIFontSize.font()
        status.font = UIFontSize.font(NSFont.smallSystemFontSize)
        done.font = UIFontSize.font(NSFont.smallSystemFontSize)
        let config = NSImage.SymbolConfiguration(pointSize: UIFontSize.small, weight: .semibold)
        for button in chevrons { button.symbolConfiguration = config }
        let height = max(36, ceil(UIFontSize.regular * 1.7 + 12))
        heightConstraint?.constant = height
        view.setFrameSize(NSSize(width: view.frame.width, height: height))
    }

    private static func button(symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.toolTip = tip
        return button
    }

    /// Focus the field with its text selected, ready to be overwritten.
    func focus() {
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// `index` is zero-based; -1 means no active match.
    func showResult(count: Int, index: Int) {
        if query.isEmpty {
            status.stringValue = ""
        } else if count == 0 {
            status.stringValue = "Not found"
        } else {
            status.stringValue = "\(index + 1) of \(count)"
        }
    }

    func search(backwards: Bool, incremental: Bool = false) {
        guard !query.isEmpty else {
            onClear?()
            status.stringValue = ""
            return
        }
        onFind?(query, backwards, incremental)
    }

    @objc private func queryChanged(_ sender: Any?) { search(backwards: false, incremental: true) }
    @objc private func nextTapped() { search(backwards: false) }
    @objc private func previousTapped() { search(backwards: true) }
    @objc private func doneTapped() { onClose?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return = next, Shift-Return = previous.
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            search(backwards: shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
