import AppKit

/// Cmd-, window. For now: the find highlight colors, per appearance.
final class SettingsWindowController: NSWindowController {
    /// One entry per color well; the well's `tag` indexes into this.
    private let slots: [(FindColors.Role, FindColors.Appearance)] = [
        (.match, .light), (.active, .light), (.match, .dark), (.active, .dark),
    ]
    private var wells: [NSColorWell] = []

    init() {
        let window = PopupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        // Otherwise document windows (tabbingMode .preferred) would try to
        // open as tabs of this one.
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.contentView = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func showAndFocus() {
        window?.center(over: NSApp.keyWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() -> NSView {
        func label(_ text: String, bold: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            if bold { field.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            return field
        }
        wells = slots.enumerated().map { index, slot in
            let well = NSColorWell(style: .default)
            well.color = FindColors.color(slot.0, slot.1)
            well.tag = index
            well.target = self
            well.action = #selector(wellChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return well
        }

        let grid = NSGridView(views: [
            [label("Find highlights", bold: true), label("All matches"), label("Current match")],
            [label("Light appearance"), wells[0], wells[1]],
            [label("Dark appearance"), wells[2], wells[3]],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 24
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .center

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        let note = NSTextField(wrappingLabelWithString:
            "Colors for the other appearance apply when macOS switches between light and dark.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [grid, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return stack
    }

    @objc private func wellChanged(_ sender: NSColorWell) {
        let (role, appearance) = slots[sender.tag]
        FindColors.set(sender.color, role, appearance)
    }

    @objc private func resetTapped() {
        FindColors.resetAll()
        for (well, slot) in zip(wells, slots) {
            well.color = FindColors.themeDefault(slot.0, slot.1)
        }
    }
}
