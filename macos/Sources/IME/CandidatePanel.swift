import AppKit

/// The candidate window: a Liquid Glass capsule (macOS 26 and later; a
/// blurred capsule before), in a borderless, non-activating panel, so the
/// client app never loses focus to it.
///
/// One page at a time, numbered for the digit keys. The highlighted
/// candidate, what Space picks, sits in an accent-colored pill that slides
/// when the highlight moves. Candidates and the page arrows can be clicked.
@MainActor
final class CandidatePanel {
    /// Made on first use, and let go when the core stops (`release`): the
    /// core's library stays loaded after a newer one replaces it, and so
    /// would a window held here, with its views and drawing buffers.
    static var shared: CandidatePanel {
        if let instance { return instance }
        let made = CandidatePanel()
        instance = made
        return made
    }
    private static var instance: CandidatePanel?

    /// The core stops: the window is closed and let go, views and all.
    static func release() {
        guard let instance else { return }
        instance.onAction = nil
        instance.bar.onAction = nil
        instance.panel.orderOut(nil)
        instance.panel.contentView = nil
        instance.panel.close()
        self.instance = nil
    }

    /// The window and its candidate view, to check that `release` frees them.
    static var liveObjects: [AnyObject] {
        guard let instance else { return [] }
        return [instance.panel, instance.bar]
    }

    /// What the panel shows: Sendable, so it can be made outside the main actor.
    struct Page: Sendable, Equatable {
        var candidates: [String]
        var comments: [String]
        var highlighted: Int
        var hasPrevious: Bool
        var hasNext: Bool

        init(_ snapshot: Snapshot) {
            candidates = snapshot.candidates.map(\.text)
            comments = snapshot.candidates.map(\.comment)
            highlighted = snapshot.highlighted
            hasPrevious = snapshot.hasPreviousPage
            hasNext = snapshot.hasNextPage
        }

        init(candidates: [String], highlighted: Int, hasPrevious: Bool, hasNext: Bool) {
            self.candidates = candidates
            self.comments = candidates.map { _ in "" }
            self.highlighted = highlighted
            self.hasPrevious = hasPrevious
            self.hasNext = hasNext
        }
    }

    enum Action: Sendable {
        case pick(Int)          // a position on the page
        case previousPage
        case nextPage
    }

    /// Set by whichever input controller showed the panel last.
    var onAction: (@MainActor (Action) -> Void)?

    private let panel: NSPanel
    private let capsule = CandidateCapsule()
    private var bar: CandidateBar { capsule.bar }

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false          // this owns it: closing must not free it under ARC
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hasShadow = capsule.needsShadow
        panel.contentView = capsule.view
        bar.onAction = { [weak self] action in self?.onAction?(action) }
    }

    /// `caretRect` is the client's line rectangle in screen coordinates.
    func show(_ page: Page, near caretRect: NSRect) {
        guard !page.candidates.isEmpty else { return hide() }
        let size = capsule.update(page)
        panel.setFrame(NSRect(origin: origin(for: size, near: caretRect), size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Moves the panel, as it is, to follow the composition (a client that
    /// reported its place late).
    func move(near caretRect: NSRect) {
        guard panel.isVisible else { return }
        panel.setFrameOrigin(origin(for: panel.frame.size, near: caretRect))
    }

    /// Below the composition's line, with the first candidate's text under
    /// its first letter, as the system's own input methods align it; above
    /// the line when there is no room below, and kept on screen.
    private func origin(for size: NSSize, near caretRect: NSRect) -> NSPoint {
        var origin = NSPoint(x: caretRect.minX - bar.style.textInset, y: caretRect.minY - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.contains(caretRect.origin) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if caretRect == .zero {                  // the client reported no place: near the mouse
                let mouse = NSEvent.mouseLocation
                origin = NSPoint(x: mouse.x, y: mouse.y - size.height - 16)
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y < visible.minY + 4 { origin.y = caretRect.maxY + 6 }   // no room below: above
        }
        return origin
    }

    func hide() {
        panel.orderOut(nil)
        bar.forget()
    }

    /// The panel as it would look for `page`, for the preview command.
    var window: NSWindow { panel }
}

/// The window's body: the glass (macOS 26 and later; a blurred capsule
/// before) with the row of candidates in it.
@MainActor
final class CandidateCapsule {
    let bar = CandidateBar()
    let view: NSView
    /// Liquid Glass draws its own depth; the blur needs the window's shadow.
    let needsShadow: Bool

    init() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // A candidate window floats over anything, often busy text: a
            // tint keeps the glass but quiets what shows through it. Dark mode
            // tints more, since its white text may sit over a light page.
            glass.tintColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark ? NSColor(white: 0.12, alpha: 0.72) : NSColor(white: 1, alpha: 0.5)
            }
            glass.contentView = bar
            view = glass
            needsShadow = false
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            blur.addSubview(bar)
            view = blur
            needsShadow = true
        }
    }

    /// Lays out `page` in the current style; returns the size it needs.
    func update(_ page: CandidatePanel.Page) -> NSSize {
        let size = bar.update(page)
        let radius = size.height / 2
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            view.layer?.cornerRadius = radius
            bar.frame = NSRect(origin: .zero, size: size)
        }
        return size
    }
}

/// The row of candidates: draws the text, holds the highlight pill, and
/// turns clicks into actions.
@MainActor
final class CandidateBar: NSView {
    /// The style of the last layout: the user's, read again at every update.
    private(set) var style = CandidateStyle.current

    var onAction: ((CandidatePanel.Action) -> Void)?

    private var page: CandidatePanel.Page?
    private var cells: [NSRect] = []
    private var previousArrow = NSRect.zero
    private var nextArrow = NSRect.zero
    private var divider = NSRect.zero
    private var hovered: Int?
    private let backdrop = Passive()            // dark mode: under everything, so white text always reads
    private let pill = Passive()
    private let ink = Passive()                 // above the pill: the text
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        pill.wantsLayer = true
        pill.layer?.cornerCurve = .continuous
        backdrop.wantsLayer = true
        backdrop.layer?.cornerCurve = .continuous
        addSubview(backdrop)
        addSubview(pill)
        ink.draws = { [weak self] in self?.drawContent() }
        addSubview(ink)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays out `page`; returns the size the panel needs.
    func update(_ page: CandidatePanel.Page) -> NSSize {
        let sameStyle = style == CandidateStyle.current
        style = CandidateStyle.current
        let sameList = sameStyle && self.page?.candidates == page.candidates
        self.page = page
        hovered = nil
        cells.removeAll()
        let s = style
        var x = s.inset
        let cellHeight = s.cellHeight
        for (i, text) in page.candidates.enumerated() {
            let width = s.padding * 2 + indexSize(i).width + s.indexGap
                + attributed(text, highlighted: false).size().width + commentWidth(page.comments[safe: i])
            cells.append(NSRect(x: x, y: s.inset, width: ceil(width), height: cellHeight))
            x += ceil(width) + s.gap
        }
        if page.hasPrevious || page.hasNext {
            x += 4
            let dividerHeight = round(cellHeight * 0.6)
            divider = NSRect(x: x, y: s.height / 2 - dividerHeight / 2, width: 1, height: dividerHeight)
            x += 5
            previousArrow = NSRect(x: x, y: s.inset, width: s.arrowWidth, height: cellHeight)
            x += s.arrowWidth
            nextArrow = NSRect(x: x, y: s.inset, width: s.arrowWidth, height: cellHeight)
            x += s.arrowWidth + s.inset - s.gap
        } else {
            divider = .zero
            previousArrow = .zero
            nextArrow = .zero
            x += s.inset - s.gap
        }
        let size = NSSize(width: ceil(x), height: s.height)
        frame.size = size
        ink.frame = NSRect(origin: .zero, size: size)
        backdrop.frame = ink.frame
        backdrop.layer?.cornerRadius = size.height / 2
        updateColors()

        if page.highlighted >= 0 && page.highlighted < cells.count {
            let target = cells[page.highlighted]
            pill.layer?.cornerRadius = target.height / 2
            pill.isHidden = false
            if sameList && !pill.frame.isEmpty {        // the highlight moved: slide
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    context.allowsImplicitAnimation = true
                    pill.animator().frame = target
                }
            } else {
                pill.frame = target
            }
        } else {
            pill.isHidden = true
        }
        ink.needsDisplay = true
        return size
    }

    /// Layer colors are fixed CGColors: set again when light or dark mode changes.
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.backgroundColor = style.accentColor.cgColor
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            backdrop.layer?.backgroundColor = dark ? NSColor(white: 0.08, alpha: 0.5).cgColor : NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        ink.needsDisplay = true
    }

    func forget() {
        page = nil
        pill.frame = .zero
    }

    private func commentWidth(_ comment: String?) -> CGFloat {
        guard let comment, !comment.isEmpty else { return 0 }
        return 4 + NSAttributedString(string: comment, attributes: [.font: style.smallFont]).size().width
    }

    private func indexSize(_ i: Int) -> NSSize {
        NSAttributedString(string: "\(i + 1)", attributes: [.font: style.indexFont]).size()
    }

    private func attributed(_ text: String, highlighted: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: style.textFont,
            .foregroundColor: highlighted ? style.onAccentColor : NSColor.labelColor,
        ])
    }

    private func drawContent() {
        guard let page else { return }
        for (i, cell) in cells.enumerated() {
            let highlighted = i == page.highlighted
            if i == hovered && !highlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            }
            let text = attributed(page.candidates[i], highlighted: highlighted)
            let textSize = text.size()
            let onAccent = style.onAccentColor.withAlphaComponent(0.78)
            let index = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: style.indexFont,
                .foregroundColor: highlighted ? onAccent : NSColor.secondaryLabelColor,
            ])
            let indexSize = index.size()
            var x = cell.minX + style.padding
            // The index sits on the text's baseline, not centered: like a footnote numeral.
            let textY = cell.midY - textSize.height / 2
            let baseline = textY + style.textFont.ascender
            index.draw(at: NSPoint(x: x, y: baseline - style.indexFont.ascender))
            x += indexSize.width + style.indexGap
            text.draw(at: NSPoint(x: x, y: textY))
            x += textSize.width
            if let comment = page.comments[safe: i], !comment.isEmpty {
                let small = NSAttributedString(string: comment, attributes: [
                    .font: style.smallFont,
                    .foregroundColor: highlighted ? onAccent : NSColor.tertiaryLabelColor,
                ])
                small.draw(at: NSPoint(x: x + 4, y: baseline - style.smallFont.ascender))
            }
        }
        if !divider.isEmpty {
            NSColor.separatorColor.setFill()
            divider.fill()
            drawArrow("chevron.left", in: previousArrow, enabled: page.hasPrevious, hovered: hovered == -1)
            drawArrow("chevron.right", in: nextArrow, enabled: page.hasNext, hovered: hovered == -2)
        }
    }

    private func drawArrow(_ symbol: String, in rect: NSRect, enabled: Bool, hovered: Bool) {
        if hovered && enabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            let circle = rect.insetBy(dx: 1, dy: (rect.height - rect.width + 2) / 2)
            NSBezierPath(ovalIn: circle).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: style.smallSize, weight: .semibold)
            .applying(.init(paletteColors: [enabled ? .secondaryLabelColor : .quaternaryLabelColor]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    // MARK: The mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// A cell's index, -1 for the previous-page arrow, -2 for the next, or nil.
    private func target(at point: NSPoint) -> Int? {
        if let i = cells.firstIndex(where: { $0.contains(point) }) { return i }
        if previousArrow.contains(point) { return -1 }
        if nextArrow.contains(point) { return -2 }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let now = target(at: convert(event.locationInWindow, from: nil))
        if now != hovered {
            hovered = now
            ink.needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        ink.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let page, let hit = target(at: convert(event.locationInWindow, from: nil)) else { return }
        switch hit {
        case -1: if page.hasPrevious { onAction?(.previousPage) }
        case -2: if page.hasNext { onAction?(.nextPage) }
        default: onAction?(.pick(hit))
        }
    }
}

/// A view that never takes the mouse (the bar beneath handles it), and
/// draws with a closure if given one.
@MainActor
final class Passive: NSView {
    var draws: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { draws?() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
