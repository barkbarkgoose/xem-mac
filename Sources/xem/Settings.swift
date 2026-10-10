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
