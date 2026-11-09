import AppKit

/// The candidate window: a Liquid Glass capsule (macOS 26 and later; a
/// blurred capsule before), in a borderless, non-activating panel, so the
/// client app never loses focus to it.
///
/// One page at a time, numbered for the digit keys. The highlighted
/// candidate, what Space picks, sits in an accent-colored pill that slides
/// when the highlight moves. Candidates and the page arrows can be clicked.
/// A page turn or the grid changes the window's size and place: that eases
/// from wherever the window is, including mid-transition. Reduce Motion
/// moves it at once.
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
        instance.halt()
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
        var expanded: Bool
        var columns: Int
        /// Index of `candidates[0]` in the whole menu.
        var origin: Int
        /// Candidates in the whole menu.
        var menuCount: Int

        init(_ snapshot: Snapshot) {
            candidates = snapshot.candidates.map(\.text)
            comments = snapshot.candidates.map(\.comment)
            highlighted = snapshot.highlighted
            hasPrevious = snapshot.hasPreviousPage
            hasNext = snapshot.hasNextPage
            expanded = snapshot.isExpanded
            columns = Snapshot.columns
            origin = snapshot.page * Snapshot.columns
            menuCount = snapshot.menuCount > 0 ? snapshot.menuCount : snapshot.candidates.count
        }

        init(candidates: [String], highlighted: Int, hasPrevious: Bool, hasNext: Bool) {
            self.candidates = candidates
            self.comments = candidates.map { _ in "" }
            self.highlighted = highlighted
            self.hasPrevious = hasPrevious
            self.hasNext = hasNext
            expanded = false
            columns = Snapshot.columns
            origin = 0
            menuCount = candidates.count
        }
    }

    enum Action: Sendable {
        case pick(Int)          // a position on the shown list
        case previousPage
        case nextPage
        case row(Int)           // one row of the grid, from the scroll wheel or the scrollbar
    }

    /// Set by whichever input controller showed the panel last.
    var onAction: (@MainActor (Action) -> Void)?

    private let panel: NSPanel
    private let capsule = CandidateCapsule()
    private var bar: CandidateBar { capsule.bar }
    /// Where the window is going, and the critically damped motion toward it.
    /// Velocity carries over when a new page arrives mid-way, so the frame
    /// retargets instead of jumping to the previous destination.
    private var targetFrame = NSRect.zero
    private var motion = PanelMotion()
    private var link: CADisplayLink?
    private var linkTime: CFTimeInterval = 0
    private var onScreen = false
    private var expanded = false
    private var originIndex = 0

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
        let switching = onScreen && panel.isVisible
            && (expanded != page.expanded || originIndex != page.origin)
        expanded = page.expanded
        originIndex = page.origin
        let size = capsule.update(page)
        // A page or the grid settles more slowly than a key that only
        // changes how wide the same row is.
        place(NSRect(origin: origin(for: size, near: caretRect), size: size),
              response: switching ? 0.38 : 0.2)
    }

    /// Moves the panel, as it is, to follow the composition (a client that
    /// reported its place late). The size stays the one the layout asked for,
    /// not whatever size the ease happens to be at.
    func move(near caretRect: NSRect) {
        guard panel.isVisible else { return }
        let size = targetFrame.size == .zero ? panel.frame.size : targetFrame.size
        place(NSRect(origin: origin(for: size, near: caretRect), size: size), response: nil)
    }

    /// Shows `frame` at once, or eases toward it from the frame on screen.
    private func place(_ frame: NSRect, response: Double?) {
        if let response { motion.response = response }
        targetFrame = frame
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let snap = !onScreen || !panel.isVisible || reduce
        if snap || motion.settled && !displaced(panel.frame, frame) {
            motion.snap(frame)
            panel.setFrame(frame, display: true)
            capsule.applyCornerRadius(cornerRadius(for: frame.height))
            pauseLink()
        } else {
            if motion.settled { motion.snap(panel.frame) }
            capsule.applyCornerRadius(cornerRadius(for: panel.frame.height))
            startLink()
        }
        panel.orderFrontRegardless()
        onScreen = true
    }

    /// A tall grid keeps a small corner; a single row is a pill. In between,
    /// the corner follows the height, so a resize does not pop from one to
    /// the other.
    fileprivate static func radius(for height: CGFloat, row: CGFloat) -> CGFloat {
        if height <= row + 1 { return height / 2 }
        let t = min(1, (height - row) / max(row, 1))
        return min(18, height / 2) * t + height / 2 * (1 - t)
    }

    private func cornerRadius(for height: CGFloat) -> CGFloat {
        Self.radius(for: height, row: bar.style.height)
    }

    private func displaced(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    private func startLink() {
        if link == nil {
            let link = panel.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            self.link = link
        }
        if link?.isPaused != false { linkTime = 0 }
        link?.isPaused = false
    }

    private func pauseLink() {
        link?.isPaused = true
        linkTime = 0
    }

    /// Drops the display link. `release` needs this: the link retains its
    /// target, and the core's window must be free to deallocate.
    private func halt() {
        link?.invalidate()
        link = nil
        onScreen = false
        motion.snap(.zero)
        targetFrame = .zero
    }

    @objc nonisolated private func step(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let duration = link.duration
        MainActor.assumeIsolated { self.tick(timestamp: timestamp, duration: duration) }
    }

    private func tick(timestamp: CFTimeInterval, duration: CFTimeInterval) {
        let now = timestamp
        var dt = linkTime == 0 ? duration : now - linkTime
        linkTime = now
        if dt <= 0 || dt > 0.05 { dt = 1.0 / 60 }
        let moving = motion.step(to: targetFrame, dt: dt)
        var frame = motion.frame
        if frame.width < 1 { frame.size.width = 1 }
        if frame.height < 1 { frame.size.height = 1 }
        panel.setFrame(frame, display: true)
        capsule.applyCornerRadius(cornerRadius(for: frame.height))
        if !moving { pauseLink() }
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
        onScreen = false
        pauseLink()
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
        applyCornerRadius(CandidatePanel.radius(for: size.height, row: bar.style.height))
        if #available(macOS 26.0, *), view is NSGlassEffectView {
            // The glass sizes its content view to itself.
        } else {
            bar.frame = NSRect(origin: .zero, size: size)
        }
        return size
    }

    func applyCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            view.layer?.cornerRadius = radius
        }
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
    private var track = NSRect.zero
    private var thumb = NSRect.zero
    private var separators: [CGFloat] = []
    private var gridWidth: CGFloat = 0
    private var hovered: Int?
    private var wheel: CGFloat = 0
    private var thumbDrag: (startY: CGFloat, origin: Int)?
    private var dragged = false
    private let backdrop = Passive()            // dark mode: under everything, so white text always reads
    private let pill = Passive()
    private let ink = Passive()                 // above the pill: the text
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
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
            && self.page?.origin == page.origin && self.page?.expanded == page.expanded
        self.page = page
        hovered = nil
        cells.removeAll()
        separators.removeAll()
        let size = page.expanded ? layoutGrid(page) : layoutRow(page)
        frame.size = size
        ink.frame = NSRect(origin: .zero, size: size)
        backdrop.frame = ink.frame
        backdrop.layer?.cornerRadius = page.expanded ? min(18, size.height / 2) : size.height / 2
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

    /// One row, with page arrows when the menu has another page.
    private func layoutRow(_ page: CandidatePanel.Page) -> NSSize {
        let s = style
        var x = s.inset
        let cellHeight = s.cellHeight
        track = .zero
        thumb = .zero
        gridWidth = 0
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
        return NSSize(width: ceil(x), height: s.height)
    }

    /// The grid Down opens: `columns` across, as many rows as fit, a scrollbar
    /// when the menu continues past them.
    private func layoutGrid(_ page: CandidatePanel.Page) -> NSSize {
        let s = style
        let cols = max(page.columns, 1)
        let count = page.candidates.count
        let rows = max((count + cols - 1) / cols, 1)
        let gutter = indexSize(0).width + s.indexGap
        var columnWidth = [CGFloat](repeating: 0, count: cols)
        var contentWidth = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            let width = s.padding * 2 + gutter
                + attributed(page.candidates[i], highlighted: false).size().width
                + commentWidth(page.comments[safe: i])
            contentWidth[i] = ceil(width)
            columnWidth[i % cols] = max(columnWidth[i % cols], ceil(width))
        }
        divider = .zero
        previousArrow = .zero
        nextArrow = .zero
        let rowGap: CGFloat = 4
        var y = s.inset
        for row in 0..<rows {
            var x = s.inset
            for col in 0..<cols {
                let i = row * cols + col
                guard i < count else { break }
                cells.append(NSRect(x: x, y: y, width: contentWidth[i], height: s.cellHeight))
                x += columnWidth[col] + 8
            }
            y += s.cellHeight
            if row + 1 < rows {
                separators.append(y + rowGap / 2)
                y += rowGap
            }
        }
        gridWidth = (cells.map(\.maxX).max() ?? s.inset)
        let showScroll = page.menuCount > count
        let scrollGutter: CGFloat = showScroll ? 16 : 0
        let width = ceil(gridWidth + s.inset + scrollGutter)
        let height = ceil(y + s.inset)
        if showScroll {
            track = NSRect(x: width - 16, y: s.inset, width: 12, height: max(height - 2 * s.inset, 1))
            let total = max(page.menuCount, 1)
            let thumbH = max(22, track.height * CGFloat(count) / CGFloat(total))
            let travel = max(track.height - thumbH, 0)
            let span = CGFloat(max(total - count, 1))
            let thumbY = track.minY + travel * CGFloat(min(max(page.origin, 0), total - count)) / span
            thumb = NSRect(x: track.midX - 1.5, y: thumbY, width: 3, height: thumbH)
        } else {
            track = .zero
            thumb = .zero
        }
        return NSSize(width: width, height: height)
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
        if page.expanded {
            NSColor.separatorColor.withAlphaComponent(0.22).setFill()
            for y in separators {
                NSRect(x: style.inset, y: y, width: max(gridWidth - style.inset, 0), height: 1).fill()
            }
        }
        let cols = max(page.columns, 1)
        let numberedRow = page.expanded && page.highlighted >= 0 ? page.highlighted / cols : -1
        for (i, cell) in cells.enumerated() {
            let highlighted = i == page.highlighted
            if i == hovered && !highlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            }
            let text = attributed(page.candidates[i], highlighted: highlighted)
            let textSize = text.size()
            let onAccent = style.onAccentColor.withAlphaComponent(0.78)
            let number = page.expanded ? (i % cols) + 1 : i + 1
            let showNumber = !page.expanded || i / cols == numberedRow
            let index = NSAttributedString(string: "\(number)", attributes: [
                .font: style.indexFont,
                .foregroundColor: highlighted ? onAccent : NSColor.secondaryLabelColor,
            ])
            let indexSize = index.size()
            var x = cell.minX + style.padding
            // The index sits on the text's baseline, not centered: like a footnote numeral.
            let textY = cell.midY - textSize.height / 2
            let baseline = textY + style.textFont.ascender
            if showNumber {
                index.draw(at: NSPoint(x: x, y: baseline - style.indexFont.ascender))
            }
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
        if !thumb.isEmpty {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: thumb, xRadius: thumb.width / 2, yRadius: thumb.width / 2).fill()
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

    /// A cell's index, -1 or -2 for the page arrows, -3 or -4 for the scrollbar
    /// track above and below the thumb, -5 for the thumb, or nil.
    private func target(at point: NSPoint) -> Int? {
        if !thumb.isEmpty && thumb.insetBy(dx: -8, dy: -2).contains(point) { return -5 }
        if track.contains(point) { return point.y < thumb.midY ? -3 : -4 }
        if let i = cells.firstIndex(where: { $0.contains(point) }) { return i }
        if previousArrow.contains(point) { return -1 }
        if nextArrow.contains(point) { return -2 }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard page?.expanded == true else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        if event.hasPreciseScrollingDeltas {
            wheel += delta
            let step: CGFloat = 28
            while wheel <= -step {
                wheel += step
                onAction?(.row(1))
            }
            while wheel >= step {
                wheel -= step
                onAction?(.row(-1))
            }
        } else {
            onAction?(.row(delta > 0 ? -1 : 1))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragged = false
        let point = convert(event.locationInWindow, from: nil)
        if !thumb.isEmpty && thumb.insetBy(dx: -8, dy: -2).contains(point), let page {
            thumbDrag = (point.y, page.origin)
        } else {
            thumbDrag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag = thumbDrag, let page, page.expanded, page.columns > 0, track.height > thumb.height else { return }
        dragged = true
        let point = convert(event.locationInWindow, from: nil)
        let total = max(page.menuCount, page.candidates.count)
        let visible = page.candidates.count
        let span = CGFloat(max(total - visible, 1))
        let travel = max(track.height - thumb.height, 1)
        let delta = Int(((point.y - drag.startY) / travel * span).rounded())
        let wantRow = max(0, drag.origin + delta) / page.columns
        var safety = 0
        while safety < 40 {
            guard let current = self.page, current.columns > 0 else { return }
            let nowRow = current.origin / current.columns
            if nowRow == wantRow { return }
            onAction?(.row(nowRow < wantRow ? 1 : -1))
            safety += 1
            if self.page?.origin == current.origin { return }
        }
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
        defer { dragged = false; thumbDrag = nil }
        guard !dragged, let page, let hit = target(at: convert(event.locationInWindow, from: nil)) else { return }
        switch hit {
        case -1: if page.hasPrevious { onAction?(.previousPage) }
        case -2: if page.hasNext { onAction?(.nextPage) }
        case -3: if page.hasPrevious { onAction?(.previousPage) }
        case -4: if page.hasNext { onAction?(.nextPage) }
        case -5: break
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

/// A critically damped spring on a window frame. No overshoot: the panel
/// stays on the side of the caret it was placed, instead of bouncing past it.
private struct PanelMotion {
    var frame = NSRect.zero
    var response = 0.32
    var settled = true
    private var vx = 0.0
    private var vy = 0.0
    private var vw = 0.0
    private var vh = 0.0

    mutating func snap(_ next: NSRect) {
        frame = next
        vx = 0
        vy = 0
        vw = 0
        vh = 0
        settled = true
    }

    /// Advances toward `target`. False once the frame has arrived.
    mutating func step(to target: NSRect, dt: Double) -> Bool {
        let omega = 2 * Double.pi / response
        var left = dt
        var moving = false
        while left > 0 {
            let h = min(left, 1.0 / 60.0)
            left -= h
            let x = Self.advance(target.origin.x, &frame.origin.x, &vx, h, omega)
            let y = Self.advance(target.origin.y, &frame.origin.y, &vy, h, omega)
            let w = Self.advance(target.width, &frame.size.width, &vw, h, omega)
            let hMove = Self.advance(target.height, &frame.size.height, &vh, h, omega)
            moving = x || y || w || hMove
        }
        if !moving { snap(target) }
        else { settled = false }
        return moving
    }

    private static func advance(_ goal: CGFloat, _ value: inout CGFloat, _ velocity: inout Double,
                                _ dt: Double, _ omega: Double) -> Bool {
        let delta = Double(value) - Double(goal)
        let accel = -omega * omega * delta - 2 * omega * velocity
        velocity += accel * dt
        value += CGFloat(velocity * dt)
        return abs(Double(value) - Double(goal)) > 0.3 || abs(velocity) > 12
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
