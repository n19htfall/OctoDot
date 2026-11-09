import AppKit

/// How the candidate window looks: the user's three choices (Settings →
/// Appearance), and every measurement that follows from them. The defaults
/// are the window as designed: 18 pt, the system's accent color, 5 pt
/// between the highlight and the window's edge.
struct CandidateStyle: Sendable, Equatable {
    var fontSize: CGFloat = 18
    /// "system" (the accent color chosen in System Settings), a preset's
    /// name, or a color of the user's own as "#RRGGBB".
    var accent = "system"
    /// Between the highlight and the window's edge. The window's corners
    /// follow, so the highlight stays concentric with them.
    var inset: CGFloat = 5

    static let fontSizes: ClosedRange<CGFloat> = 12...28
    static let insets: ClosedRange<CGFloat> = 0...12
    static let presets: [(id: String, name: String)] = [
        ("blue", "蓝色"), ("purple", "紫色"), ("pink", "粉色"), ("red", "红色"),
        ("orange", "橙色"), ("yellow", "黄色"), ("green", "绿色"), ("graphite", "石墨色"),
    ]

    /// What the candidate window draws with now. Set when a choice changes.
    @MainActor static var current = load()

    private static let fontSizeKey = "candidateFontSize"
    private static let accentKey = "candidateAccent"
    private static let insetKey = "candidateInset"

    static func load() -> CandidateStyle {
        let defaults = UserDefaults.standard
        var style = CandidateStyle()
        if let size = defaults.object(forKey: fontSizeKey) as? Double {
            style.fontSize = min(max(CGFloat(size), fontSizes.lowerBound), fontSizes.upperBound)
        }
        if let accent = defaults.string(forKey: accentKey), accent == "system" || presets.contains(where: { $0.id == accent })
            || Self.color(hex: accent) != nil {
            style.accent = accent
        }
        if let inset = defaults.object(forKey: insetKey) as? Double {
            style.inset = min(max(CGFloat(inset), insets.lowerBound), insets.upperBound)
        }
        return style
    }

    /// Remembers the choices and puts them in use, from the next update of the window on.
    @MainActor func use() {
        let defaults = UserDefaults.standard
        defaults.set(Double(fontSize), forKey: Self.fontSizeKey)
        defaults.set(accent, forKey: Self.accentKey)
        defaults.set(Double(inset), forKey: Self.insetKey)
        Self.current = self
    }

    // MARK: Measurements, scaled from the design at 18 pt

    /// The highlight's height: the text with room above and below.
    var cellHeight: CGFloat { ceil(fontSize * 5 / 3) }
    var height: CGFloat { cellHeight + 2 * inset }
    /// From the highlight's edge to the text.
    var padding: CGFloat { round(fontSize * 11 / 18) }
    var indexGap: CGFloat { round(fontSize * 5 / 18) }
    var gap: CGFloat { 2 }
    var arrowWidth: CGFloat { round(cellHeight * 26 / 30) }
    /// From the window's left edge to the first candidate's index.
    var textInset: CGFloat { inset + padding }
    /// Index numerals, comments and the page arrows.
    var smallSize: CGFloat { round(fontSize * 2 / 3) }

    var textFont: NSFont { .systemFont(ofSize: fontSize) }
    var indexFont: NSFont { .monospacedDigitSystemFont(ofSize: smallSize, weight: .medium) }
    var smallFont: NSFont { .systemFont(ofSize: smallSize) }

    // MARK: Color

    var accentColor: NSColor {
        switch accent {
        case "system": .controlAccentColor
        case "blue": .systemBlue
        case "purple": .systemPurple
        case "pink": .systemPink
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "graphite": .systemGray
        default: Self.color(hex: accent) ?? .controlAccentColor
        }
    }

    /// The highlighted candidate's text: white, or near black on a light accent
    /// (yellow, or a pale color of the user's own) where white would not read.
    var onAccentColor: NSColor {
        guard let rgb = accentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.68 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    static func color(hex: String) -> NSColor? {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
