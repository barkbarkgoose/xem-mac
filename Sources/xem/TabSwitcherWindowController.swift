import AppKit

/// Cmd-Shift-\: every open document (across all windows' tabs) in one list,
/// filtered as you type. Replaces AppKit's tab overview, which has no filter
/// and no arrow-key navigation.
final class TabSwitcherWindowController: NSWindowController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate
{
    struct Entry {
        let url: URL
        let isCurrent: Bool
    }

    /// Supplied by the app, in tab order.
    var entries: () -> [Entry] = { [] }
    var onSelect: ((URL) -> Void)?

    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Entry] = []
    private var shown: [Entry] = []

    init() {
        let window = PopupPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "All Tabs"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 200)
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        applyFonts()
        NotificationCenter.default.addObserver(
            forName: UIFontSize.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFonts() }
    }

    /// Follow the interface text size.
    private func applyFonts() {
        field.font = UIFontSize.font()
        for column in table.tableColumns { column.headerCell.font = UIFontSize.font() }
        table.rowHeight = ceil(UIFontSize.regular * 1.6)
        table.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func showAndFocus() {
        all = entries()
        field.stringValue = ""
        applyFilter()
        window?.center(over: NSApp.keyWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(field)
    }

    /// Ctrl-Tab / Ctrl-Shift-Tab while the switcher is open.
    func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let current = table.selectedRow >= 0 ? table.selectedRow : 0
        select(row: (current + delta + shown.count) % shown.count)
    }

    // MARK: UI

    private func buildContent() -> NSView {
        field.placeholderString = "Filter tabs by name"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterChanged(_:))

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = "Document"
        name.width = 200
        let folder = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folder.title = "Folder"
        folder.width = 300
        folder.resizingMask = .autoresizingMask
        table.addTableColumn(name)
        table.addTableColumn(folder)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let container = NSView()
        for view in [field, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: Filtering

    @objc private func filterChanged(_ sender: Any?) { applyFilter() }

    private func applyFilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            shown = all
        } else {
            // Every word must appear in the name or the path.
            let words = query.split(separator: " ").map(String.init)
            shown = all.filter { entry in
                let haystack = entry.url.lastPathComponent + " " + entry.url.deletingLastPathComponent().path
                return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        table.reloadData()
        // Empty filter: land on the current tab. Typing: land on the best match.
        let preferred = query.isEmpty ? shown.firstIndex { $0.isCurrent } : nil
        if let row = preferred ?? (shown.isEmpty ? nil : 0) { select(row: row) }
    }

    // MARK: Choosing

    @objc private func rowClicked(_ sender: Any?) { choose(row: table.clickedRow) }

    private func choose(row: Int) {
        guard shown.indices.contains(row) else { return }
        let url = shown[row].url
        window?.close()
        onSelect?(url)
    }

    private func select(row: Int) {
        guard shown.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            choose(row: table.selectedRow >= 0 ? table.selectedRow : 0)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveLeft(_:)):
            // Left/Right edit the filter text; with nothing typed they step too.
            guard field.stringValue.isEmpty else { return false }
            moveSelection(by: selector == #selector(NSResponder.moveRight(_:)) ? 1 : -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.close()
            return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        window?.close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingMiddle
            return field
        }()
        if id.rawValue == "name" {
            cell.stringValue = entry.url.lastPathComponent
            cell.font = UIFontSize.font(weight: entry.isCurrent ? .bold : .regular)
            cell.textColor = .labelColor
        } else {
            cell.stringValue = (entry.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            cell.font = UIFontSize.font(NSFont.smallSystemFontSize)
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }
}
