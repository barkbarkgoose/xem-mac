import AppKit
import WebKit

/// `xem --term <file.md>`: render through the real WebKit pipeline offscreen and
/// page through it inside the terminal using iTerm2's inline image protocol.
///
/// The offscreen web view is sized to the terminal's text area (in points), so
/// a frame is a viewport snapshot at the terminal's backing scale. Scrolling
/// scrolls the page itself, which keeps app.js's anchor-based scroll restore
/// working across live reloads; see "Drawing" for how scrolls are sent cheaply.
final class TerminalViewer: NSObject {
    private let file: URL
    private var window: NSWindow!
    private var webView: MarkdownWebView!
    private var watcher: FileWatcher?

    private var input = [UInt8]()
    private var sources: [DispatchSourceProtocol] = []
    private var started = false

    // Terminal geometry. Cell size is in points; `scale` is pixels per point.
    private var cols = 80
    private var rows = 24
    private var cellW: CGFloat = 0
    private var cellH: CGFloat = 0
    private var scale: CGFloat = 2

    // Page state, refreshed on every frame.
    private var scrollY: CGFloat = 0
    private var scrollMax: CGFloat = 0
    private var hasRendered = false

    // Frame coalescing: key repeat must not queue a backlog of snapshots.
    private var drawing = false
    private var drawAgain = false
    private var pendingLines = 0
    private var pendingJump: CGFloat?
    private var needsFull = true
    /// Temporary status-line text; the key hints come back when it expires.
    private var message: String?
    private var messageToken = 0

    init(file: URL) {
        self.file = file
    }

    func run() {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            fail("--term needs an interactive terminal")
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else {
            fail("cannot read \(file.path)")
        }
        Terminal.enter(title: "xem: \(file.lastPathComponent)")
        watchSignals()
        watchInput()

        // Ask iTerm2 for the exact cell size and scale. The reply arrives on
        // stdin; terminals that don't understand the query stay silent.
        Terminal.write("\u{1b}]1337;ReportCellSize\u{07}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in start() }
    }

    // MARK: Setup

    private func start() {
        guard !started else { return }
        started = true
        if ProcessInfo.processInfo.environment["TERM_PROGRAM"] != "iTerm.app" {
            flash("inline images need iTerm2 (press o to open in Xem)", seconds: 6)
        }
        updateGeometry()

        webView = MarkdownWebView()
        // App chrome (outline, its toggle, scrollbars) means nothing here.
        let css = """
            #outline, #outline-toggle { display: none !important; }
            html { scrollbar-width: none; }
            ::-webkit-scrollbar { display: none; }
            """
        let js = "var s=document.createElement('style');s.textContent=\(Self.jsString(css));document.documentElement.appendChild(s);"
        webView.configuration.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.onRendered = { [weak self] in
            guard let self else { return }
            self.hasRendered = true
            self.requestDraw(full: true)
            // Images load after the render settles; catch them on a second pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.requestDraw(full: true) }
        }

        // Offscreen but real: WebKit does not lay out a view that was never hosted.
        window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: viewSize.width, height: viewSize.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView
        window.orderBack(nil)

        webView.loadRenderer()
        reload()
        watcher = FileWatcher(url: file) { [weak self] in self?.reload() }

        Terminal.write("\u{1b}[2J")
        drawStatus()
    }

    private var viewSize: NSSize {
        NSSize(width: CGFloat(cols) * cellW, height: CGFloat(max(rows - 1, 1)) * cellH)
    }

    private func updateGeometry() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            cols = Int(ws.ws_col)
            rows = Int(ws.ws_row)
        }
        if cellW == 0 || cellH == 0 {
            // No ReportCellSize reply: a typical 13pt monospace cell.
            cellW = 8
            cellH = 17
            scale = NSScreen.main?.backingScaleFactor ?? 2
        }
    }

    private func reload() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            flash("cannot read \(file.lastPathComponent)")
            return
        }
        webView.render(markdown: text, baseDir: file.deletingLastPathComponent().path)
    }

    private func watchSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Terminal.restoreAndExit(0) }
            src.resume()
            sources.append(src)
        }
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        winch.setEventHandler { [weak self] in self?.resized() }
        winch.resume()
        sources.append(winch)
    }

    private func resized() {
        guard started else { return }
        updateGeometry()
        window.setContentSize(viewSize)
        Terminal.write("\u{1b}[2J")
        // Give the page a moment to reflow at the new width.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in requestDraw(full: true) }
    }

    // MARK: Input

    private func watchInput() {
        let src = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { Terminal.restoreAndExit(0) }  // tty went away
            self?.input.append(contentsOf: buf[0..<n])
            self?.parseInput()
        }
        src.resume()
        sources.append(src)
    }

    private func parseInput() {
        while !input.isEmpty {
            guard input[0] == 0x1b else {
                key(input.removeFirst())
                continue
            }
            guard input.count >= 2 else { return }  // wait for the rest
            switch input[1] {
            case UInt8(ascii: "["), UInt8(ascii: "O"):
                // CSI / SS3: parameters, then a final byte in 0x40...0x7E.
                guard let end = input.dropFirst(2).firstIndex(where: { (0x40...0x7e).contains($0) }) else { return }
                let body = String(decoding: input[2...end], as: UTF8.self)
                input.removeFirst(end + 1)
                escape(body)
            case UInt8(ascii: "]"):
                // OSC, terminated by BEL or ESC \.
                var end = 2
                var terminator = 0
                while end < input.count {
                    if input[end] == 0x07 { terminator = 1; break }
                    if input[end] == 0x1b, end + 1 < input.count, input[end + 1] == 0x5c { terminator = 2; break }
                    end += 1
                }
                guard terminator > 0 else { return }
                let body = String(decoding: input[2..<end], as: UTF8.self)
                input.removeFirst(end + terminator)
                osc(body)
            default:
                input.removeFirst(2)  // Alt-key; ignore
            }
        }
    }

    /// `ReportCellSize=<height>;<width>[;<scale>]`, in points.
    private func osc(_ body: String) {
        let prefix = "1337;ReportCellSize="
        guard body.hasPrefix(prefix) else { return }
        let parts = body.dropFirst(prefix.count).split(separator: ";").compactMap { Double($0) }
        guard parts.count >= 2, parts[0] > 0, parts[1] > 0 else { return }
        cellH = CGFloat(parts[0])
        cellW = CGFloat(parts[1])
        scale = parts.count >= 3 && parts[2] > 0 ? CGFloat(parts[2]) : (NSScreen.main?.backingScaleFactor ?? 2)
        start()
    }

    private func escape(_ body: String) {
        if body.hasPrefix("<") {
            // SGR mouse: <button;x;yM. 64/65 are wheel up/down.
            let fields = body.dropFirst().dropLast().split(separator: ";")
            switch fields.first.flatMap({ Int($0) }) {
            case 64: scroll(lines: -Self.wheelLines)
            case 65: scroll(lines: Self.wheelLines)
            default: break
            }
            return
        }
        switch body {
        case "A": scroll(lines: -Self.keyLines)
        case "B": scroll(lines: Self.keyLines)
        case "5~": scroll(lines: -pageLines)
        case "6~": scroll(lines: pageLines)
        case "H", "1~", "7~": jump(to: 0)
        case "F", "4~", "8~": jump(to: .greatestFiniteMagnitude)
        default: break
        }
    }

    private static let wheelLines = 2
    private static let keyLines = 3
    /// Rows of the terminal the page occupies (all but the status line).
    private var viewRows: Int { max(rows - 1, 1) }
    private var pageLines: Int { max(viewRows - 2, 1) }

    private func key(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03:  // q, ^C
            Terminal.restoreAndExit(0)
        case UInt8(ascii: "j"), 0x05, 0x0e, 0x0d:  // j, ^E, ^N, Enter
            scroll(lines: Self.keyLines)
        case UInt8(ascii: "k"), 0x19, 0x10:  // k, ^Y, ^P
            scroll(lines: -Self.keyLines)
        case UInt8(ascii: "d"), 0x04:  // d, ^D
            scroll(lines: viewRows / 2)
        case 0x15, UInt8(ascii: "u"):  // ^U, u
            scroll(lines: -viewRows / 2)
        case UInt8(ascii: " "), UInt8(ascii: "f"), 0x06:  // space, f, ^F
            scroll(lines: pageLines)
        case UInt8(ascii: "b"), 0x02:  // b, ^B
            scroll(lines: -pageLines)
        case UInt8(ascii: "g"):
            jump(to: 0)
        case UInt8(ascii: "G"):
            jump(to: .greatestFiniteMagnitude)
        case UInt8(ascii: "r"), 0x0c:  // r, ^L: re-read and repaint
            Terminal.write("\u{1b}[2J")
            reload()
            requestDraw(full: true)
        case UInt8(ascii: "o"):
            openInApp()
        default:
            break
        }
    }

    private func scroll(lines: Int) {
        pendingLines += lines
        requestDraw()
    }

    private func jump(to y: CGFloat) {
        pendingJump = y
        pendingLines = 0
        requestDraw(full: true)
    }

    private func openInApp() {
        flash("opening in Xem…")
        ExternalOpen.open([file]) { [weak self] error in
            guard let self else { return }
            if let error {
                self.flash("open failed: \(error.localizedDescription)")
            } else {
                // The window appearing is confirmation enough; restore the key hints.
                self.messageToken += 1
                self.message = nil
                self.drawStatus()
            }
        }
    }

    // MARK: Drawing
    //
    // Small scrolls move in whole terminal rows, like scrolling text: the
    // terminal shifts the picture it already has (a scroll region plus SU/SD,
    // which carries iTerm2's image cells along) and only the newly exposed rows
    // are captured and sent. Re-sending the whole screen per wheel tick was
    // several hundred KB a frame and made iTerm2 stutter. Anything else (jumps,
    // big moves, reloads, resizes, hitting either end) repaints the full view.

    /// Set XEM_TERM_FULL_FRAMES=1 to repaint the whole view on every scroll.
    private static let fullFramesOnly = ProcessInfo.processInfo.environment["XEM_TERM_FULL_FRAMES"] == "1"

    private func requestDraw(full: Bool = false) {
        if full { needsFull = true }
        guard started, hasRendered else { return }
        if drawing {
            drawAgain = true
            return
        }
        drawing = true
        drawFrame()
    }

    private func drawFrame() {
        let jumpTo = pendingJump
        let lines = pendingLines
        let full = needsFull || jumpTo != nil || Self.fullFramesOnly || abs(lines) > viewRows / 2
        pendingJump = nil
        pendingLines = 0
        needsFull = false

        let move: String
        if let jumpTo {
            move = "window.scrollTo(0, \(jumpTo.isFinite && jumpTo < 1e9 ? jumpTo : 1e9));"
        } else if lines != 0 {
            move = "window.scrollBy(0, \(CGFloat(lines) * cellH));"
        } else {
            move = ""
        }
        let js = "var y0 = window.scrollY;" + move
            + "[y0, window.scrollY, document.documentElement.scrollHeight - window.innerHeight]"

        let t0 = CFAbsoluteTimeGetCurrent()
        webView.evaluateJavaScript(js) { [self] result, _ in
            var moved: CGFloat = CGFloat(lines) * cellH
            if let values = result as? [NSNumber], values.count == 3 {
                moved = CGFloat(values[1].doubleValue - values[0].doubleValue)
                scrollY = CGFloat(values[1].doubleValue)
                scrollMax = max(CGFloat(values[2].doubleValue), 0)
            }
            if !full && moved == 0 && lines != 0 {
                // Already at the top/bottom: nothing to draw.
                return finishFrame()
            }
            // Clamped at an end, the page moved by less than whole rows; the
            // picture on screen can't be shifted to match, so repaint it.
            let exact = abs(moved - CGFloat(lines) * cellH) < 0.5
            if full || !exact || lines == 0 {
                capture(rowOffset: 0, rowCount: viewRows) { [self] png in
                    if let png { Terminal.write("\u{1b}[H" + inlineImage(png, rows: viewRows)) }
                    trace(since: t0, kind: "full", bytes: png?.count ?? 0)
                    finishFrame()
                }
                return
            }
            let n = min(abs(lines), viewRows)
            let down = lines > 0
            capture(rowOffset: down ? viewRows - n : 0, rowCount: n) { [self] png in
                guard let png else { return finishFrame() }
                // Shift inside rows 1...viewRows only, then drop the region
                // before drawing: an image ending on the region's last row
                // would otherwise scroll it again when the cursor moves past.
                var out = "\u{1b}[1;\(viewRows)r" + (down ? "\u{1b}[\(n)S" : "\u{1b}[\(n)T") + "\u{1b}[r"
                out += "\u{1b}[\(down ? viewRows - n + 1 : 1);1H" + inlineImage(png, rows: n)
                Terminal.write(out)
                trace(since: t0, kind: "strip \(n)", bytes: png.count)
                finishFrame()
            }
        }
    }

    private func finishFrame() {
        drawStatus()
        drawing = false
        if drawAgain || pendingLines != 0 || needsFull {
            drawAgain = false
            requestDraw()
        }
    }

    /// Snapshot terminal rows `rowOffset ..< rowOffset + rowCount` of the view
    /// as a PNG at the terminal's pixel density.
    private func capture(rowOffset: Int, rowCount: Int, completion: @escaping (Data?) -> Void) {
        let width = viewSize.width
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: CGFloat(rowOffset) * cellH, width: width, height: CGFloat(rowCount) * cellH)
        // Ask for the terminal's pixel density, not the offscreen window's.
        config.snapshotWidth = NSNumber(value: Double(width * scale / window.backingScaleFactor))
        webView.takeSnapshot(with: config) { image, _ in
            completion(image.flatMap(Self.png))
        }
    }

    private func inlineImage(_ png: Data, rows height: Int) -> String {
        "\u{1b}]1337;File=inline=1;size=\(png.count);width=\(cols);height=\(height);preserveAspectRatio=0:"
            + png.base64EncodedString() + "\u{07}"
    }

    private func trace(since start: CFAbsoluteTime, kind: String, bytes: Int) {
        guard let handle = Self.traceHandle else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        handle.write(Data(String(format: "%@ %.1f ms %d KB\n", kind, ms, bytes / 1024).utf8))
    }

    /// Show `text` in place of the key hints for a few seconds.
    private func flash(_ text: String, seconds: Double = 3) {
        message = text
        messageToken += 1
        let token = messageToken
        if started { drawStatus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.messageToken == token else { return }
            self.message = nil
            if self.started { self.drawStatus() }
        }
    }

    private func drawStatus() {
        let position: String
        if scrollMax <= 1 {
            position = "All"
        } else if scrollY <= 1 {
            position = "Top"
        } else if scrollY >= scrollMax - 1 {
            position = "Bot"
        } else {
            position = "\(Int((scrollY / scrollMax * 100).rounded()))%"
        }
        let help = "j/k scroll  space/b page  g/G top/end  o open in Xem  q quit"
        let left = " \(file.lastPathComponent)  \(position)"
        let right = (message ?? help) + " "
        var line = left
        let gap = cols - left.count - right.count
        if gap >= 2 {
            line += String(repeating: " ", count: gap) + right
        }
        line = String(line.prefix(cols))
        line += String(repeating: " ", count: max(cols - line.count, 0))
        Terminal.write("\u{1b}[\(rows);1H\u{1b}[7m\(line)\u{1b}[0m")
    }

    // MARK: Helpers

    private static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// XEM_TERM_TRACE=<path> logs per-frame timing and size.
    private static let traceHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["XEM_TERM_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "''"
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("xem --term: \(message)\n".utf8))
        exit(1)
    }
}

/// Raw-mode, alternate-screen terminal state, restored on every exit path.
private enum Terminal {
    nonisolated(unsafe) static var saved = termios()
    nonisolated(unsafe) static var active = false

    static func enter(title: String) {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        active = true
        atexit { Terminal.restore() }
        // NSLog and WebKit chatter go to stderr, which is this tty; it would
        // print over the picture. Errors after this point show in the status line.
        let null = open("/dev/null", O_WRONLY)
        if null >= 0 { dup2(null, STDERR_FILENO); close(null) }
        // Alt screen, hide cursor, SGR mouse (wheel), tab title.
        write("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}]0;\(title)\u{07}")
    }

    static func restore() {
        guard active else { return }
        active = false
        write("\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h\u{1b}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    static func restoreAndExit(_ code: Int32) -> Never {
        restore()
        exit(code)
    }

    static func write(_ s: String) {
        var data = Array(s.utf8)
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            offset += n
        }
    }
}

/// Hands documents to a real Xem instance. The terminal viewer is itself an
/// instance of Xem.app as far as LaunchServices is concerned, so a plain
/// `open -a Xem` (or NSWorkspace) can be routed back into it, and the "window"
/// would live, and die, with the terminal tab.
enum ExternalOpen {
    static func open(_ urls: [URL], completion: @escaping (Error?) -> Void = { _ in }) {
        let me = getpid()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        // Terminal viewers run as .accessory and the GUI app as .regular, but
        // check argv too: an older viewer may still report .regular.
        if let gui = others.first(where: {
            $0.processIdentifier != me && $0.activationPolicy == .regular && !isHeadless($0.processIdentifier)
        }) {
            do {
                try sendOpen(urls, to: gui.processIdentifier)
                gui.activate()
                completion(nil)
            } catch {
                completion(error)
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// Whether `pid` was started with --term or --snapshot (from its argv).
    private static func isHeadless(_ pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return false }
        // Layout: argc, exec path, padding NULs, then argv strings (then env).
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buf[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let argv = strings.dropFirst().prefix(Int(argc))  // drop the exec path
        return argv.contains("--term") || argv.contains("--snapshot")
    }

    /// An 'odoc' Apple Event addressed by PID, so it can't land on the wrong
    /// instance.
    private static func sendOpen(_ urls: [URL], to pid: pid_t) throws {
        let list = NSAppleEventDescriptor.list()
        for (i, url) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: url), at: i + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        try event.sendEvent(options: [.noReply], timeout: 5)
    }
}

/// App delegate for terminal mode: never opens windows in this process.
final class TerminalAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpen.open(urls)
    }
}

