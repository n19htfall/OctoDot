import AppKit

/// The row of candidates: draws the text, holds the highlight pill, and
/// turns clicks into actions.
@MainActor
final class CandidateBar: NSView {
    /// The fonts, colors and measured sizes of the last layout's style: the
    /// user's, read again at every update.
    private var typesetter = CandidateTypesetter(style: CandidateStyle.current)
    var style: CandidateStyle { typesetter.style }
    var rowHeight: CGFloat { style.height }
    /// Keep a long translation on the candidate's line.
    private var replacementLimit: CGFloat { style.fontSize * 20 }
    /// Set from the display containing the caret. Only translated pages use
    /// this limit; a long result must not push other candidates off-screen.
    var maximumWidth: CGFloat?
    private var textLimit: CGFloat = .greatestFiniteMagnitude
    private var commentLimit: CGFloat = .greatestFiniteMagnitude

    var onAction: ((CandidatePanel.Action) -> Void)?
    /// Width follows the replacement fade. The panel snaps to each size; the fade curve is the motion.
    var onTextFade: ((NSSize) -> Void)?

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
    private let backdrop = Passive()
    private let plain = Passive()
    private let pill = HighlightPill()
    private let accent = Passive()
    private let chrome = Passive()
    private var trackingArea: NSTrackingArea?
    /// Candidate ↔ translation. `fraction` is how much of the translation is showing.
    private struct LabelBlend {
        var candidate: String
        var translation: String
        /// Set when one translation replaces another, so the fade is between those two strings.
        var outgoing: String? = nil
        var from: CGFloat
        var to: CGFloat
        var started: CFTimeInterval
        static let duration: CFTimeInterval = 0.42

        func fraction(at now: CFTimeInterval) -> CGFloat {
            guard now > started else { return from }
            let raw = min(1, (now - started) / Self.duration)
            let eased = 1 - pow(1 - raw, 3)
            return from + (to - from) * CGFloat(eased)
        }

        func finished(at now: CFTimeInterval) -> Bool { now - started >= Self.duration }
    }
    private var blends: [Int: LabelBlend] = [:]
    /// Translations that have finished fading in, so a later layout does not play them again.
    private var resting: [Int: String] = [:]
    private var fadeLink: CADisplayLink?
    private var drawnNumberRow: Int?
    private var drawnCells: [NSRect] = []
    private static let highlightSlide: CFTimeInterval = 0.16

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        pill.wantsLayer = true
        pill.layer?.cornerCurve = .continuous
        pill.layer?.masksToBounds = true
        backdrop.wantsLayer = true
        backdrop.layer?.cornerCurve = .continuous
        plain.wantsLayer = true
        accent.wantsLayer = true
        chrome.wantsLayer = true
        plain.draws = { [weak self] in self?.drawPlain() }
        accent.draws = { [weak self] in self?.drawAccent() }
        chrome.draws = { [weak self] in self?.drawChrome() }
        pill.onFrameChange = { [weak self] in self?.placeAccentInk() }
        addSubview(backdrop)
        addSubview(plain)
        addSubview(pill)
        pill.addSubview(accent)
        addSubview(chrome)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The size `page` needs, without moving the highlight.
    func measure(_ page: CandidatePanel.Page) -> NSSize {
        adoptCurrentStyle()
        return page.expanded ? layoutGrid(page) : layoutRow(page)
    }

    /// Lays out `page`; returns the size the panel needs.
    func update(_ page: CandidatePanel.Page) -> NSSize {
        let sameStyle = adoptCurrentStyle()
        let previous = self.page
        let sameList = sameStyle && previous?.candidates == page.candidates
            && previous?.origin == page.origin && previous?.expanded == page.expanded
        syncBlends(to: page, sameList: sameList)
        let clearHover = hovered != nil
        self.page = page
        hovered = nil
        cells.removeAll()
        separators.removeAll()
        let size = page.expanded ? layoutGrid(page) : layoutRow(page)
        frame.size = size
        let full = NSRect(origin: .zero, size: size)
        plain.frame = full
        chrome.frame = full
        backdrop.frame = full
        backdrop.layer?.cornerRadius = page.expanded ? min(18, size.height / 2) : size.height / 2
        updateColors()

        if page.highlighted >= 0 && page.highlighted < cells.count {
            let target = cells[page.highlighted]
            pill.isHidden = false
            if sameList && blends.isEmpty && !pill.frame.isEmpty && displaced(pill.frame, target) {
                slideHighlight(to: target)
            } else {
                setHighlightFrame(target)
            }
        } else {
            pill.isHidden = true
            stopHighlightSlide()
        }
        let row = numberRow(page)
        let textSame = sameList && blends.isEmpty && !clearHover && drawnNumberRow == row
            && drawnCells == cells && previous?.comments == page.comments
            && previous?.translations == page.translations
        if textSame {
            if previous?.hasPrevious != page.hasPrevious || previous?.hasNext != page.hasNext
                || previous?.menuCount != page.menuCount {
                chrome.needsDisplay = true
            }
        } else {
            invalidateText()
        }
        return size
    }

    /// The user's style, from this layout on: a new one starts a new
    /// typesetter. False if the style changed.
    @discardableResult
    private func adoptCurrentStyle() -> Bool {
        guard typesetter.style != CandidateStyle.current else { return true }
        typesetter = CandidateTypesetter(style: CandidateStyle.current)
        return false
    }

    /// One row, with page arrows when the menu has another page.
    private func layoutRow(_ page: CandidatePanel.Page) -> NSSize {
        let s = style
        fitText(page, grid: false)
        var x = s.inset
        let cellHeight = s.cellHeight
        track = .zero
        thumb = .zero
        gridWidth = 0
        for i in page.candidates.indices {
            let width = s.padding * 2 + indexSize(i).width + s.indexGap
                + shownWidth(page, i) + commentWidth(page.comments[safe: i])
            cells.append(NSRect(x: x, y: s.inset, width: ceil(width), height: cellHeight))
            x += ceil(width) + s.gap
        }
        if page.hasPrevious || page.hasNext {
            x += 4
            let dividerHeight = round(cellHeight * 0.6)
            divider = NSRect(x: x, y: s.inset + cellHeight / 2 - dividerHeight / 2, width: 1, height: dividerHeight)
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
        return NSSize(width: ceil(x), height: cellHeight + 2 * s.inset)
    }

    /// The grid Down opens: `columns` across, as many rows as fit, a scrollbar
    /// when the menu continues past them.
    private func layoutGrid(_ page: CandidatePanel.Page) -> NSSize {
        let s = style
        fitText(page, grid: true)
        let cols = max(page.columns, 1)
        let count = page.candidates.count
        let rows = max((count + cols - 1) / cols, 1)
        let cellHeight = s.cellHeight
        let gutter = indexSize(0).width + s.indexGap
        var columnWidth = [CGFloat](repeating: 0, count: cols)
        var contentWidth = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            let width = s.padding * 2 + gutter + shownWidth(page, i) + commentWidth(page.comments[safe: i])
            contentWidth[i] = ceil(width)
            columnWidth[i % cols] = max(columnWidth[i % cols], contentWidth[i])
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
                cells.append(NSRect(x: x, y: y, width: contentWidth[i], height: cellHeight))
                x += columnWidth[col] + 8
            }
            y += cellHeight
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
        typesetter.appearanceChanged()
        updateColors()
        invalidateText()
    }

    func forget() {
        page = nil
        drawnNumberRow = nil
        drawnCells = []
        stopHighlightSlide()
        setHighlightFrame(.zero)
        endTextFade()
    }

    /// Drops the fade link. It retains this view, so a core unload has to stop it.
    func endTextFade() {
        blends.removeAll()
        resting.removeAll()
        fadeLink?.invalidate()
        fadeLink = nil
        stopHighlightSlide()
    }

    private func slideHighlight(to target: NSRect) {
        guard window != nil, let pillLayer = pill.layer else {
            setHighlightFrame(target)
            return
        }
        let fromPosition = pillLayer.presentation()?.position ?? pillLayer.position
        let fromBounds = pillLayer.presentation()?.bounds ?? pillLayer.bounds
        let fromAccent = accent.layer?.presentation()?.position ?? accent.layer?.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.removeAllAnimations()
        accent.layer?.removeAllAnimations()
        pill.frame = target
        pillLayer.cornerRadius = target.height / 2
        CATransaction.commit()
        slide(pillLayer, "position", from: NSValue(point: fromPosition))
        slide(pillLayer, "bounds", from: NSValue(rect: fromBounds))
        if let accentLayer = accent.layer, let fromAccent {
            slide(accentLayer, "position", from: NSValue(point: fromAccent))
        }
    }

    private func slide(_ layer: CALayer, _ keyPath: String, from: NSValue) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.duration = Self.highlightSlide
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "highlight-" + keyPath)
    }

    private func setHighlightFrame(_ rect: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.layer?.removeAllAnimations()
        accent.layer?.removeAllAnimations()
        pill.frame = rect
        if rect.height > 0.5 { pill.layer?.cornerRadius = rect.height / 2 }
        CATransaction.commit()
    }

    private func stopHighlightSlide() {
        guard let pillLayer = pill.layer,
              pillLayer.animation(forKey: "highlight-position") != nil
                || pillLayer.animation(forKey: "highlight-bounds") != nil,
              let shown = pillLayer.presentation() else {
            pill.layer?.removeAllAnimations()
            accent.layer?.removeAllAnimations()
            return
        }
        let frame = Self.viewFrame(position: shown.position, bounds: shown.bounds, anchor: pillLayer.anchorPoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.removeAllAnimations()
        accent.layer?.removeAllAnimations()
        pill.frame = frame
        if frame.height > 0.5 { pillLayer.cornerRadius = frame.height / 2 }
        CATransaction.commit()
    }

    private static func viewFrame(position: CGPoint, bounds: CGRect, anchor: CGPoint) -> NSRect {
        NSRect(x: position.x - anchor.x * bounds.width, y: position.y - anchor.y * bounds.height,
               width: bounds.width, height: bounds.height)
    }

    private func placeAccentInk() {
        let next = NSRect(x: -pill.frame.minX, y: -pill.frame.minY, width: bounds.width, height: bounds.height)
        guard accent.frame != next else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accent.frame = next
        CATransaction.commit()
    }

    private func numberRow(_ page: CandidatePanel.Page) -> Int {
        guard page.expanded, page.highlighted >= 0 else { return -1 }
        return page.highlighted / max(page.columns, 1)
    }

    private func invalidateText() {
        if let page { drawnNumberRow = numberRow(page) }
        drawnCells = cells
        plain.needsDisplay = true
        accent.needsDisplay = true
        chrome.needsDisplay = true
    }

    private func displaced(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    private func commentWidth(_ comment: String?) -> CGFloat {
        min(commentLimit, rawCommentWidth(comment))
    }

    private func rawCommentWidth(_ comment: String?) -> CGFloat {
        guard let comment, !comment.isEmpty else { return 0 }
        return 4 + typesetter.smallSize(comment).width
    }

    private func indexSize(_ i: Int) -> NSSize { typesetter.indexSize(i + 1) }

    private func attributed(_ text: String, highlighted: Bool, alpha: CGFloat = 1) -> NSAttributedString {
        let color = (highlighted ? typesetter.onAccentColor : NSColor.labelColor).withAlphaComponent(alpha)
        return NSAttributedString(string: text, attributes: [
            .font: typesetter.textFont,
            .foregroundColor: color,
        ])
    }

    /// `text` drawn into `rect`, cut with an ellipsis where it does not fit.
    private func drawTruncated(_ text: NSAttributedString, in rect: NSRect) {
        let clipped = NSMutableAttributedString(attributedString: text)
        clipped.addAttribute(.paragraphStyle, value: CandidateTypesetter.truncating,
                             range: NSRange(location: 0, length: clipped.length))
        clipped.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    /// Soft while it is appearing or leaving: a few offset copies stand in for a blur.
    private func drawWord(_ text: String, highlighted: Bool, x: CGFloat, y: CGFloat, slot: CGFloat,
                          alpha: CGFloat, softness: CGFloat) {
        guard alpha > 0.02, slot > 0.5, !text.isEmpty else { return }
        let passes: [(CGFloat, CGFloat, CGFloat)] = softness < 0.35
            ? [(0, 0, alpha)]
            : [(0, 0, alpha * 0.46), (softness, 0, alpha * 0.135), (-softness, 0, alpha * 0.135),
               (0, softness, alpha * 0.135), (0, -softness, alpha * 0.135)]
        NSGraphicsContext.current?.saveGraphicsState()
        NSRect(x: x, y: y - 4, width: slot, height: typesetter.lineHeight + 8).clip()
        let size = typesetter.textSize(text)
        for (dx, dy, passAlpha) in passes {
            let string = attributed(text, highlighted: highlighted, alpha: passAlpha)
            if softness < 0.35 && size.width > slot + 0.5 {
                drawTruncated(string, in: NSRect(x: x, y: y, width: slot, height: size.height))
            } else {
                string.draw(at: NSPoint(x: x + dx, y: y + dy))
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// The candidate, or its translation once that lookup has something to show.
    private func shownText(_ page: CandidatePanel.Page, _ index: Int) -> String {
        if let translation = replacementText(page, index) { return translation }
        return page.candidates[index]
    }

    private func replacementText(_ page: CandidatePanel.Page, _ index: Int) -> String? {
        guard let text = page.translations?[safe: index], !text.isEmpty, text != page.candidates[index] else { return nil }
        return text
    }

    private func textWidth(_ text: String, capped: Bool) -> CGFloat {
        let width = typesetter.textSize(text).width
        return capped ? min(width, replacementLimit) : width
    }

    private func shownWidth(_ page: CandidatePanel.Page, _ index: Int) -> CGFloat {
        min(textLimit, rawShownWidth(page, index))
    }

    private func rawShownWidth(_ page: CandidatePanel.Page, _ index: Int) -> CGFloat {
        if let blend = blends[index], blend.candidate == page.candidates[index] {
            let t = blend.fraction(at: CACurrentMediaTime())
            let source = blend.outgoing ?? blend.candidate
            let from = textWidth(source, capped: blend.outgoing != nil)
            let to = textWidth(blend.translation, capped: true)
            return from + (to - from) * t
        }
        let text = shownText(page, index)
        return textWidth(text, capped: replacementText(page, index) != nil)
    }

    /// Find the largest shared text width that keeps all cells on the screen.
    /// Short labels retain their natural width, leaving more room for longer
    /// ones. Recalculate as a replacement fades or the display changes.
    private func fitText(_ page: CandidatePanel.Page, grid: Bool) {
        textLimit = .greatestFiniteMagnitude
        commentLimit = .greatestFiniteMagnitude
        guard (page.translations != nil || !blends.isEmpty), let maximumWidth,
              !page.candidates.isEmpty else { return }
        let s = style
        let labels = page.candidates.indices.map { rawShownWidth(page, $0) }
        let fixed = page.candidates.indices.map { s.padding * 2 + indexSize(grid ? 0 : $0).width + s.indexGap }
        let comments = page.candidates.indices.map { rawCommentWidth(page.comments[safe: $0]) }
        func width(_ labelLimit: CGFloat, _ commentLimit: CGFloat) -> CGFloat {
            if !grid {
                var x = s.inset
                for i in labels.indices {
                    x += ceil(fixed[i] + min(comments[i], commentLimit) + min(labels[i], labelLimit)) + s.gap
                }
                if page.hasPrevious || page.hasNext { x += 10 + 2 * s.arrowWidth }
                return ceil(x + s.inset - s.gap)
            }
            let cols = max(1, min(page.columns, labels.count))
            var columnWidths = [CGFloat](repeating: 0, count: cols)
            for i in labels.indices {
                let column = i % cols
                columnWidths[column] = max(columnWidths[column],
                                           ceil(fixed[i] + min(comments[i], commentLimit) + min(labels[i], labelLimit)))
            }
            let scroll: CGFloat = page.menuCount > labels.count ? 16 : 0
            return ceil(2 * s.inset + columnWidths.reduce(0, +) + CGFloat(cols - 1) * 8 + scroll)
        }
        let natural = labels.max() ?? 0
        let naturalComment = comments.max() ?? 0
        guard width(natural, naturalComment) > maximumWidth else { return }
        let minimumLabel = min(natural, s.fontSize * 3)
        if width(minimumLabel, naturalComment) > maximumWidth {
            var low: CGFloat = 0
            var high = naturalComment
            for _ in 0..<20 {
                let middle = (low + high) / 2
                if width(minimumLabel, middle) <= maximumWidth { low = middle } else { high = middle }
            }
            commentLimit = low
        }
        var low: CGFloat = 0
        var high = natural
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if width(middle, commentLimit) <= maximumWidth { low = middle } else { high = middle }
        }
        textLimit = low
    }

    /// Plays a fade when a translation arrives or the translation key is released. A new candidate list snaps.
    private func syncBlends(to page: CandidatePanel.Page, sameList: Bool) {
        guard sameList, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            blends.removeAll()
            resting.removeAll()
            stopFadeLink()
            return
        }
        let now = CACurrentMediaTime()
        var nextBlends: [Int: LabelBlend] = [:]
        var nextResting: [Int: String] = [:]
        for i in page.candidates.indices {
            let candidate = page.candidates[i]
            let translation = replacementText(page, i)
            let want: CGFloat = translation == nil ? 0 : 1
            if var blend = blends[i], blend.candidate == candidate {
                let progress = blend.fraction(at: now)
                if let translation, translation != blend.translation {
                    if progress > 0.5 {
                        blend.outgoing = blend.translation
                        blend.from = 0
                    } else {
                        blend.outgoing = nil
                        blend.from = progress
                    }
                    blend.translation = translation
                    blend.to = 1
                    blend.started = now
                    nextBlends[i] = blend
                    continue
                }
                if blend.to == want {
                    nextBlends[i] = blends[i]
                    continue
                }
                if abs(progress - want) < 0.02 {
                    if want == 1 { nextResting[i] = blend.translation }
                    continue
                }
                blend.outgoing = nil
                blend.from = progress
                blend.to = want
                blend.started = now
                nextBlends[i] = blend
                continue
            }
            if let translation {
                if resting[i] == translation {
                    nextResting[i] = translation
                } else if let shown = resting[i] {
                    nextBlends[i] = LabelBlend(candidate: candidate, translation: translation, outgoing: shown,
                                               from: 0, to: 1, started: now)
                } else {
                    let delay = min(Double(i), 5) * 0.04
                    nextBlends[i] = LabelBlend(candidate: candidate, translation: translation,
                                               from: 0, to: 1, started: now + delay)
                }
            } else if let shown = resting[i] {
                nextBlends[i] = LabelBlend(candidate: candidate, translation: shown,
                                           from: 1, to: 0, started: now)
            }
        }
        blends = nextBlends
        resting = nextResting
        if blends.isEmpty { stopFadeLink() } else { startFadeLink() }
    }

    private func startFadeLink() {
        guard fadeLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepTextFade(_:)))
        link.add(to: .main, forMode: .common)
        fadeLink = link
    }

    private func stopFadeLink() {
        fadeLink?.invalidate()
        fadeLink = nil
    }

    @objc nonisolated private func stepTextFade(_ link: CADisplayLink) {
        MainActor.assumeIsolated { self.tickTextFade() }
    }

    private func tickTextFade() {
        guard let page else { endTextFade(); return }
        let now = CACurrentMediaTime()
        for (i, blend) in blends where blend.finished(at: now) {
            if blend.to >= 0.5 { resting[i] = blend.translation }
            else { resting[i] = nil }
            blends[i] = nil
        }
        cells.removeAll()
        separators.removeAll()
        let size = page.expanded ? layoutGrid(page) : layoutRow(page)
        frame.size = size
        let full = NSRect(origin: .zero, size: size)
        plain.frame = full
        chrome.frame = full
        backdrop.frame = full
        if page.highlighted >= 0 && page.highlighted < cells.count {
            setHighlightFrame(cells[page.highlighted])
            pill.isHidden = false
        }
        invalidateText()
        onTextFade?(size)
        if blends.isEmpty { stopFadeLink() }
    }

    private func drawPlain() {
        guard let page else { return }
        if page.expanded {
            NSColor.separatorColor.withAlphaComponent(0.22).setFill()
            for y in separators {
                NSRect(x: style.inset, y: y, width: max(gridWidth - style.inset, 0), height: 1).fill()
            }
        }
        drawLabels(page, covered: false)
    }

    private func drawAccent() {
        guard let page else { return }
        drawLabels(page, covered: true)
    }

    private func drawChrome() {
        guard let page else { return }
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

    private func drawLabels(_ page: CandidatePanel.Page, covered: Bool) {
        let cols = max(page.columns, 1)
        let numberedRow = page.expanded && page.highlighted >= 0 ? page.highlighted / cols : -1
        let onAccent = typesetter.onAccentColor.withAlphaComponent(0.78)
        let textFont = typesetter.textFont, indexFont = typesetter.indexFont, smallFont = typesetter.smallFont
        for (i, cell) in cells.enumerated() {
            let selected = i == page.highlighted
            if !covered && i == hovered && !selected {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            }
            let blend = blends[i].flatMap { $0.candidate == page.candidates[i] ? $0 : nil }
            let raw = shownText(page, i)
            let text = attributed(raw, highlighted: covered)
            let textSize = typesetter.textSize(raw)
            let measured = shownWidth(page, i)
            let drawnWidth = blend == nil ? min(textSize.width, measured) : measured
            let number = page.expanded ? (i % cols) + 1 : i + 1
            let showNumber = !page.expanded || i / cols == numberedRow
            var x = cell.minX + style.padding
            // The index sits on the text's baseline, not centered: like a footnote numeral.
            let textY = cell.minY + (style.cellHeight - textSize.height) / 2
            let baseline = textY + textFont.ascender
            if showNumber {
                NSAttributedString(string: "\(number)", attributes: [
                    .font: indexFont,
                    .foregroundColor: covered ? onAccent : NSColor.secondaryLabelColor,
                ]).draw(at: NSPoint(x: x, y: baseline - indexFont.ascender))
            }
            x += typesetter.indexSize(number).width + style.indexGap
            if let blend {
                let t = blend.fraction(at: CACurrentMediaTime())
                let source = blend.outgoing ?? blend.candidate
                drawWord(source, highlighted: covered, x: x, y: textY - t * 2,
                         slot: drawnWidth, alpha: 1 - t, softness: t * 1.6)
                drawWord(blend.translation, highlighted: covered, x: x, y: textY + (1 - t) * 3,
                         slot: drawnWidth, alpha: t, softness: (1 - t) * 2.2)
            } else if textSize.width > drawnWidth + 0.5 {
                drawTruncated(text, in: NSRect(x: x, y: textY, width: drawnWidth, height: textSize.height))
            } else {
                text.draw(at: NSPoint(x: x, y: textY))
            }
            x += drawnWidth
            if let comment = page.comments[safe: i], !comment.isEmpty {
                let small = NSAttributedString(string: comment, attributes: [
                    .font: smallFont,
                    .foregroundColor: covered ? onAccent : NSColor.tertiaryLabelColor,
                ])
                let available = max(0, commentWidth(comment) - 4)
                if available > 0 {
                    let origin = NSPoint(x: x + 4, y: baseline - smallFont.ascender)
                    let size = typesetter.smallSize(comment)
                    if size.width > available {
                        drawTruncated(small, in: NSRect(origin: origin, size: NSSize(width: available, height: size.height)))
                    } else {
                        small.draw(at: origin)
                    }
                }
            }
        }
    }

    private func drawArrow(_ symbol: String, in rect: NSRect, enabled: Bool, hovered: Bool) {
        if hovered && enabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            let circle = rect.insetBy(dx: 1, dy: (rect.height - rect.width + 2) / 2)
            NSBezierPath(ovalIn: circle).fill()
        }
        guard let image = typesetter.arrow(symbol, enabled: enabled) else { return }
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
            plain.needsDisplay = true
            chrome.needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        plain.needsDisplay = true
        chrome.needsDisplay = true
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
class Passive: NSView {
    var draws: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { draws?() }
}

@MainActor
private final class HighlightPill: Passive {
    var onFrameChange: (() -> Void)?

    override var frame: NSRect {
        get { super.frame }
        set {
            let before = frame
            super.frame = newValue
            if before != frame { onFrameChange?() }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
