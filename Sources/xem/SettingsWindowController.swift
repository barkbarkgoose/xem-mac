import AppKit

/// Cmd-, window: interface text size, and the find highlight colors per
/// appearance.
final class SettingsWindowController: NSWindowController {
    /// One entry per color well; the well's `tag` indexes into this.
    private let slots: [(FindColors.Role, FindColors.Appearance)] = [
        (.match, .light), (.active, .light), (.match, .dark), (.active, .dark),
    ]
    private var wells: [NSColorWell] = []

    /// Every text control, with the base size and weight to scale from.
    private var scaled: [(control: NSControl, base: CGFloat, bold: Bool)] = []
    private let sizeValue = NSTextField(labelWithString: "")
    private let sizeStepper = NSStepper()
    private let appearanceControl = NSSegmentedControl()
    private let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        let window = PopupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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
        applyFonts()
        NotificationCenter.default.addObserver(
            forName: UIFontSize.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFonts() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func showAndFocus() {
        window?.center(over: NSApp.keyWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: UI

    private func label(_ text: String, base: CGFloat = NSFont.systemFontSize, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        scaled.append((field, base, bold))
        return field
    }

    private func buildContent() -> NSView {
        // Interface text size: [ 110% ] [-/+]
        sizeStepper.minValue = UIFontSize.range.lowerBound * 100
        sizeStepper.maxValue = UIFontSize.range.upperBound * 100
        sizeStepper.increment = UIFontSize.step * 100
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged(_:))
        scaled.append((sizeValue, NSFont.systemFontSize, false))
        let sizeControls = NSStackView(views: [sizeValue, sizeStepper])
        sizeControls.spacing = 8

        // Appearance: [ System | Light | Dark ]
        appearanceControl.segmentCount = AppearancePreference.allCases.count
        for (index, option) in AppearancePreference.allCases.enumerated() {
            appearanceControl.setLabel(option.title, forSegment: index)
        }
        appearanceControl.trackingMode = .selectOne
        appearanceControl.selectedSegment = AppearancePreference.allCases.firstIndex(of: .current) ?? 0
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged(_:))
        scaled.append((appearanceControl, NSFont.systemFontSize, false))

        // Column width: Narrow ... Full Width
        widthPopup.addItems(withTitles: ContentWidth.allCases.map(\.title))
        widthPopup.selectItem(at: ContentWidth.current.rawValue)
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        scaled.append((widthPopup, NSFont.systemFontSize, false))
        NotificationCenter.default.addObserver(
            forName: ContentWidth.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.widthPopup.selectItem(at: ContentWidth.current.rawValue) }

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
            [label("Interface", bold: true), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Text size"), sizeControls, NSGridCell.emptyContentView],
            [label("Appearance"), appearanceControl, NSGridCell.emptyContentView],
            [label("Document", bold: true), NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [label("Column width"), widthPopup, NSGridCell.emptyContentView],
            [label("Find highlights", bold: true), label("All matches"), label("Current match")],
            [label("Light appearance"), wells[0], wells[1]],
            [label("Dark appearance"), wells[2], wells[3]],
        ])
        // Rows 1, 2 and 4 (text size, appearance, column width) span the two
        // value columns.
        for row in [1, 2, 4] {
            grid.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2), verticalRange: NSRange(location: row, length: 1))
        }
        grid.rowSpacing = 12
        grid.columnSpacing = 24
        grid.row(at: 3).topPadding = 10
        grid.row(at: 5).topPadding = 10
        grid.column(at: 1).xPlacement = .center
        grid.column(at: 2).xPlacement = .center
        grid.cell(atColumnIndex: 1, rowIndex: 1).xPlacement = .leading
        grid.cell(atColumnIndex: 1, rowIndex: 2).xPlacement = .leading
        grid.cell(atColumnIndex: 1, rowIndex: 4).xPlacement = .leading

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetTapped))
        scaled.append((reset, NSFont.systemFontSize, false))
        let note = NSTextField(wrappingLabelWithString:
            "Text size applies to Xem's own panels and the outline sidebar, not the menu bar. "
            + "Document text is zoomed separately with \u{2318}+ / \u{2318}-.")
        scaled.append((note, NSFont.smallSystemFontSize, false))
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 340

        let stack = NSStackView(views: [grid, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return stack
    }

    /// Re-font every control and resize the window to fit, keeping its top edge.
    private func applyFonts() {
        for item in scaled {
            let size = UIFontSize.size(item.base)
            item.control.font = item.bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        }
        sizeValue.stringValue = "\(Int((UIFontSize.scale * 100).rounded()))%"
        sizeStepper.doubleValue = UIFontSize.scale * 100
        (scaled.last { $0.base == NSFont.smallSystemFontSize }?.control as? NSTextField)?
            .preferredMaxLayoutWidth = 340 * CGFloat(UIFontSize.scale)

        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = window.frame.origin
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    // MARK: Actions

    @objc private func sizeChanged(_ sender: NSStepper) {
        UIFontSize.scale = sender.doubleValue / 100
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        ContentWidth.current = ContentWidth(rawValue: sender.indexOfSelectedItem) ?? .standard
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        AppearancePreference.current = AppearancePreference.allCases[sender.selectedSegment]
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
        UIFontSize.scale = 1.0
        AppearancePreference.current = .system
        appearanceControl.selectedSegment = 0
        ContentWidth.current = .standard
    }
}
