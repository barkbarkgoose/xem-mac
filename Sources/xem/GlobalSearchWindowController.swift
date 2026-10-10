import AppKit

/// Cmd-Shift-F: search the source of every open document and jump to a hit.
/// Matching is plain case-insensitive substring over the markdown source; the
/// page then maps the source line to the rendered match (`findAtSourceLine`).
final class GlobalSearchWindowController: NSWindowController,
    NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private struct Hit {
        let url: URL
        let line: Int          // 0-based
        let snippet: String
    }

    private static let maxHitsPerDocument = 100
    private static let maxHits = 1000

    /// Supplied by the app: every open document's URL and current text.
    var documents: () -> [(url: URL, text: String)] = { [] }
    /// A hit was chosen: (document, query, 0-based source line).
    var onSelect: ((URL, String, Int) -> Void)?

    private let field = NSSearchField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "")
    private var hits: [Hit] = []
    private var query = ""

    init() {
        let window = PopupWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Search All Tabs"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 240)
        super.init(window: window)
        window.contentView = buildContent()
        applyFonts()
        NotificationCenter.default.addObserver(
            forName: UIFontSize.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyFonts() }
    }

    /// Follow the interface text size.
    private func applyFonts() {
        field.font = UIFontSize.font()
        summary.font = UIFontSize.font(NSFont.smallSystemFontSize)
        for column in table.tableColumns { column.headerCell.font = UIFontSize.font() }
        table.rowHeight = ceil(UIFontSize.regular * 1.6)
        table.reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func showAndFocus() {
        window?.center(over: NSApp.keyWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(field)
        field.selectText(nil)
        runSearch() // documents may have changed since last time
    }

    // MARK: UI

    private func buildContent() -> NSView {
        field.placeholderString = "Search all open documents"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(queryChanged(_:))

        func column(_ id: String, _ title: String, width: CGFloat, flexible: Bool = false) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 40
            if flexible { column.resizingMask = .autoresizingMask }
            return column
        }
        table.addTableColumn(column("doc", "Document", width: 160))
        table.addTableColumn(column("line", "Line", width: 50))
        table.addTableColumn(column("text", "Match", width: 400, flexible: true))
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

        summary.textColor = .secondaryLabelColor

        let container = NSView()
        for view in [field, scroll, summary] {
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
            summary.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            summary.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            summary.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    // MARK: Searching

    @objc private func queryChanged(_ sender: Any?) { runSearch() }

    private func runSearch() {
        query = field.stringValue.trimmingCharacters(in: .whitespaces)
        hits = []
        var documentCount = 0
        if !query.isEmpty {
            outer: for document in documents() {
                var found = 0
                for (index, line) in document.text.components(separatedBy: "\n").enumerated() {
                    guard let match = line.range(of: query, options: .caseInsensitive) else { continue }
                    if found == 0 { documentCount += 1 }
                    hits.append(Hit(
                        url: document.url, line: index, snippet: Self.snippet(of: line, around: match)))
                    found += 1
                    if hits.count >= Self.maxHits { break outer }
                    if found >= Self.maxHitsPerDocument { break }
                }
            }
        }
        table.reloadData()
        if query.isEmpty {
            summary.stringValue = ""
        } else if hits.isEmpty {
            summary.stringValue = "No results"
        } else {
            let capped = hits.count >= Self.maxHits ? "+" : ""
            summary.stringValue = "\(hits.count)\(capped) lines in \(documentCount) document"
                + (documentCount == 1 ? "" : "s")
        }
    }

    /// The line, trimmed and cut to a window around the match so it stays
    /// readable (and the match visible) for very long lines.
    private static func snippet(of line: String, around match: Range<String.Index>) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let limit = 160
        guard trimmed.count > limit,
              let matchStart = trimmed.range(of: line[match], options: .caseInsensitive)?.lowerBound
        else { return String(trimmed.prefix(limit)) }
        let offset = trimmed.distance(from: trimmed.startIndex, to: matchStart)
        let start = trimmed.index(trimmed.startIndex, offsetBy: max(0, offset - 40))
        let end = trimmed.index(start, offsetBy: min(limit, trimmed.distance(from: start, to: trimmed.endIndex)))
        return (start > trimmed.startIndex ? "…" : "") + trimmed[start..<end]
            + (end < trimmed.endIndex ? "…" : "")
    }

    // MARK: Choosing a hit

    @objc private func rowClicked(_ sender: Any?) {
        open(row: table.clickedRow)
    }

    private func open(row: Int) {
        guard hits.indices.contains(row) else { return }
        let hit = hits[row]
        onSelect?(hit.url, query, hit.line)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            open(row: table.selectedRow >= 0 ? table.selectedRow : 0)
            return true
        case #selector(NSResponder.moveDown(_:)):
            select(row: min(table.selectedRow + 1, hits.count - 1))
            return true
        case #selector(NSResponder.moveUp(_:)):
            select(row: max(table.selectedRow - 1, 0))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.performClose(nil)
            return true
        default:
            return false
        }
    }

    private func select(row: Int) {
        guard hits.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, hits.indices.contains(row) else { return nil }
        let hit = hits[row]
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
            return field
        }()
        cell.font = UIFontSize.font()
        switch id.rawValue {
        case "doc":
            cell.stringValue = hit.url.lastPathComponent
            cell.toolTip = hit.url.path
            cell.textColor = .labelColor
        case "line":
            cell.stringValue = String(hit.line + 1)
            cell.textColor = .secondaryLabelColor
        default:
            cell.stringValue = hit.snippet
            cell.textColor = .labelColor
        }
        return cell
    }
}
