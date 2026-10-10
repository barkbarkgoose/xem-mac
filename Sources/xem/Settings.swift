import AppKit

/// User-chosen find highlight colors, one pair per appearance. Only colors the
/// user actually changed are stored, so untouched ones keep following theme.css.
enum FindColors {
    enum Role: String, CaseIterable { case match, active }
    enum Appearance: String, CaseIterable { case light, dark }

    static let didChange = Notification.Name("xem.findColorsDidChange")

    /// Mirrors --find-bg / --find-active-bg in theme.css. Used only to show
    /// the current color in the settings window; the page falls back to the
    /// CSS values itself when nothing is stored.
    static func themeDefault(_ role: Role, _ appearance: Appearance) -> NSColor {
        switch (appearance, role) {
        case (.light, .match):  return NSColor(hex: "#FFE08A")!
        case (.light, .active): return NSColor(hex: "#FF9F43")!
        case (.dark, .match):   return NSColor(hex: "#6B5A1F")!
        case (.dark, .active):  return NSColor(hex: "#C77712")!
        }
    }

    private static func key(_ role: Role, _ appearance: Appearance) -> String {
        "find.\(role.rawValue).\(appearance.rawValue)"
    }

    static func color(_ role: Role, _ appearance: Appearance) -> NSColor {
        let stored = UserDefaults.standard.string(forKey: key(role, appearance))
        return stored.flatMap(NSColor.init(hex:)) ?? themeDefault(role, appearance)
    }

    static func set(_ color: NSColor, _ role: Role, _ appearance: Appearance) {
        guard let hex = color.hexString else { return }
        UserDefaults.standard.set(hex, forKey: key(role, appearance))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func resetAll() {
        for role in Role.allCases {
            for appearance in Appearance.allCases {
                UserDefaults.standard.removeObject(forKey: key(role, appearance))
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Payload for `window.xem.setFindColors`: only the stored overrides.
    static func pagePayload() -> [String: [String: String]] {
        var payload: [String: [String: String]] = [:]
        for appearance in Appearance.allCases {
            for role in Role.allCases {
                if let hex = UserDefaults.standard.string(forKey: key(role, appearance)) {
                    payload[appearance.rawValue, default: [:]][role.rawValue] = hex
                }
            }
        }
        return payload
    }
}

/// How wide the document's text column may get. Stepped, shared by every window
/// and remembered, like text zoom. Widths are rem so they scale with that zoom:
/// zooming out and choosing a wider level is how you see more text per line.
enum ContentWidth: Int, CaseIterable {
    case narrow, standard, medium, wide, extraWide, full

    static let didChange = Notification.Name("xem.contentWidthDidChange")
    private static let key = "contentWidth"

    static var current: ContentWidth {
        get {
            let saved = UserDefaults.standard.object(forKey: key) as? Int
            return saved.flatMap(Self.init(rawValue:)) ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .standard: return "Default"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .extraWide: return "Extra Wide"
        case .full: return "Full Width"
        }
    }

    /// CSS value for `--content-width`.
    var css: String {
        switch self {
        case .narrow: return "36rem"
        case .standard: return "46rem"
        case .medium: return "60rem"
        case .wide: return "80rem"
        case .extraWide: return "110rem"
        case .full: return "none"
        }
    }

    static func step(_ delta: Int) {
        let next = min(max(current.rawValue + delta, 0), allCases.count - 1)
        current = ContentWidth(rawValue: next) ?? .standard
    }
}

/// Light, dark, or follow macOS. Applied as `NSApp.appearance`, which drives the
/// native panels and (through the web view's effective appearance) the page's
/// `prefers-color-scheme`, so the CSS, highlight.js, Mermaid and the per-
/// appearance find colors all follow without further wiring.
enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    private static let key = "appearance"

    static var current: AppearancePreference {
        get { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            apply()
        }
    }

    var title: String { rawValue.capitalized }

    /// nil means "follow the system".
    private var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func apply() {
        NSApp.appearance = current.appearance
    }
}

/// Size of Xem's own interface text (find bar, search and switcher panels,
/// shortcuts, settings, the outline sidebar). Separate from the in-document
/// text zoom (Cmd +/-), which only scales the rendered markdown. The menu bar
/// is drawn by macOS and does not follow this.
enum UIFontSize {
    static let didChange = Notification.Name("xem.uiFontSizeDidChange")
    static let range: ClosedRange<Double> = 0.8...1.6
    static let step = 0.1
    private static let key = "uiFontScale"

    static var scale: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: key)
            return saved == 0 ? 1.0 : min(max(saved, range.lowerBound), range.upperBound)
        }
        set {
            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
            // Round away float drift from repeated 0.1 steps.
            UserDefaults.standard.set((clamped * 100).rounded() / 100, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func size(_ base: CGFloat) -> CGFloat { (base * CGFloat(scale)).rounded() }
    static var regular: CGFloat { size(NSFont.systemFontSize) }
    static var small: CGFloat { size(NSFont.smallSystemFontSize) }

    static func font(_ base: CGFloat = NSFont.systemFontSize, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size(base), weight: weight)
    }

    static func monospaced(_ base: CGFloat = NSFont.systemFontSize) -> NSFont {
        .monospacedSystemFont(ofSize: size(base), weight: .regular)
    }
}

/// Whether new windows open with the outline sidebar showing. Each window
/// toggles its own sidebar independently; this just remembers the last choice
/// (across launches) so a new window starts the way you left the last one.
enum OutlinePreference {
    private static let key = "outlineVisible"

    static var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// "#RRGGBB" in sRGB; alpha is not stored.
    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
