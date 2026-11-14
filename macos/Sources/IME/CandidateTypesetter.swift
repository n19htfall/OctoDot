import AppKit

/// What drawing the candidate window takes in one style, made once for that
/// style: its fonts, the highlighted text's color, and every size measured
/// so far. A key lays the page out at least twice (once to see whether a
/// narrower page keeps the first candidate in place, once for real) and
/// draws its text twice (plain, and again where the highlight covers it).
/// Each of those measured every string with Core Text, and asked AppKit for
/// the fonts anew; most of a key's drawing time went there.
///
/// Sizes are kept by text. A string's size depends only on its font, not on
/// its color, so they hold until the style changes, and the bar then makes a
/// new typesetter. The page arrows' images are kept too, and dropped when the
/// appearance changes, since their colors are resolved for it.
@MainActor
final class CandidateTypesetter {
    let style: CandidateStyle
    let textFont: NSFont
    let indexFont: NSFont
    let smallFont: NSFont
    /// The highlighted candidate's text color (CandidateStyle.onAccentColor).
    let onAccentColor: NSColor
    /// The text's line height, for the clip around a fading word.
    let lineHeight: CGFloat

    /// Long text is cut with an ellipsis, on one line.
    static let truncating: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()

    /// Distinct strings kept per font before the cache starts over: a page
    /// has at most a few dozen, a session a few thousand.
    private static let capacity = 2048

    private var textSizes: [String: NSSize] = [:]
    private var smallSizes: [String: NSSize] = [:]
    private var indexSizes: [Int: NSSize] = [:]
    private var arrows: [ArrowKey: NSImage] = [:]

    private struct ArrowKey: Hashable {
        var symbol: String
        var enabled: Bool
    }

    init(style: CandidateStyle) {
        self.style = style
        textFont = style.textFont
        indexFont = style.indexFont
        smallFont = style.smallFont
        onAccentColor = style.onAccentColor
        lineHeight = ceil(textFont.ascender - textFont.descender)
    }

    /// The size of a candidate (or its translation) in the text font.
    func textSize(_ text: String) -> NSSize { size(text, textFont, &textSizes) }

    /// The size of a comment in the small font.
    func smallSize(_ text: String) -> NSSize { size(text, smallFont, &smallSizes) }

    /// The size of the index numeral `number`.
    func indexSize(_ number: Int) -> NSSize {
        if let known = indexSizes[number] { return known }
        let measured = NSAttributedString(string: "\(number)", attributes: [.font: indexFont]).size()
        indexSizes[number] = measured
        return measured
    }

    /// A page arrow, in the small size, colored for whether it can be used.
    func arrow(_ symbol: String, enabled: Bool) -> NSImage? {
        let key = ArrowKey(symbol: symbol, enabled: enabled)
        if let known = arrows[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: style.smallSize, weight: .semibold)
            .applying(.init(paletteColors: [enabled ? .secondaryLabelColor : .quaternaryLabelColor]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        arrows[key] = image
        return image
    }

    /// Light or dark mode changed: what was drawn for the previous one goes.
    func appearanceChanged() {
        arrows.removeAll()
    }

    private func size(_ text: String, _ font: NSFont, _ cache: inout [String: NSSize]) -> NSSize {
        if let known = cache[text] { return known }
        if cache.count >= Self.capacity { cache.removeAll(keepingCapacity: true) }
        let measured = NSAttributedString(string: text, attributes: [.font: font]).size()
        cache[text] = measured
        return measured
    }
}
