import AppKit

/// The candidate window: a Liquid Glass capsule (macOS 26 and later; a
/// blurred capsule before), in a borderless, non-activating panel, so the
/// client app never loses focus to it.
///
/// One page at a time, numbered for the digit keys. The highlighted
/// candidate, what Space picks, sits in an accent-colored pill that slides
/// when the highlight moves. A glyph takes the pill's text color only where
/// the pill covers it. Candidates and the page arrows can be clicked.
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
        TranslationModifier.stopWaitingForRelease()
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

    /// Do not create a panel just to clear its temporary lookup cache.
    static func translationModifierChanged() {
        guard let instance else { return }
        instance.translations?.setTranslationHeld(false)
        instance.translationHeld = false
        instance.bar.forget()
        instance.refreshTranslationDisplay()
    }

    static func clearTranslations() { instance?.clearTranslations() }
    static func trimTranslations() { instance?.translations?.trim() }

    static func machineTranslation(of candidate: String) -> String? {
        guard let instance, let app = instance.lookupApp, instance.lookupPolicy != .disabled,
              Learning.candidateLookupPolicy(forApp: app) != .disabled else { return nil }
        return instance.translations?.committedText(for: candidate)
    }

    /// What the panel shows: Sendable, so it can be made outside the main actor.
    struct Page: Sendable, Equatable {
        var candidates: [String]
        var comments: [String]
        /// nil unless the translation key is held. An empty string keeps that candidate;
        /// any other string is drawn in its place, at the same row height.
        var translations: [String]?
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
            translations = nil
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
            self.translations = nil
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
    /// Screen x of the first candidate's index while this composition is up.
    /// A much longer candidate would shove the window left at the screen edge;
    /// the page then shows fewer candidates instead of moving this point.
    private var pinnedFirstX: CGFloat?
    private var visiblePage: Page?
    private var visibleCaret = NSRect.zero
    private var lookupApp: String?
    private var lookupPolicy: CandidateLookupPolicy = .disabled
    private var translationHeld = false
    private var modifierTimer: Timer?
    private var translations: CandidateTranslations?

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
        bar.onTextFade = { [weak self] size in self?.applyFadeSize(size) }
    }

    /// `caretRect` is the client's line rectangle in screen coordinates.
    func show(_ page: Page, near caretRect: NSRect, clientApp: String? = nil) {
        guard !page.candidates.isEmpty else { return hide() }
        bar.maximumWidth = screen(near: caretRect).map { max(1, $0.visibleFrame.width - 8) }
        var shown = fitted(page, near: caretRect)
        visiblePage = shown
        visibleCaret = caretRect
        lookupApp = clientApp
        if #available(macOS 26.0, *), let clientApp {
            let service = translationService()
            let policy = Learning.candidateLookupPolicy(forApp: clientApp)
            let down = TranslationModifier.isActive(NSEvent.modifierFlags)
            if policy != lookupPolicy || (policy == .incognito && translationHeld && !down) { bar.forget() }
            lookupPolicy = policy
            service.setPage(shown.candidates, highlighted: shown.highlighted, policy: lookupPolicy)
            translationHeld = down
            service.setTranslationHeld(translationHeld)
            if translationHeld && lookupPolicy != .disabled { shown.translations = service.replacements() }
            startModifierTimer()
        } else {
            stopModifierTimer()
            translations?.clear()
            lookupPolicy = .disabled
            translationHeld = false
        }
        render(shown, near: caretRect)
    }

    private func render(_ shown: Page, near caretRect: NSRect) {
        bar.maximumWidth = screen(near: caretRect).map { max(1, $0.visibleFrame.width - 8) }
        let switching = onScreen && panel.isVisible
            && (expanded != shown.expanded || originIndex != shown.origin)
        expanded = shown.expanded
        originIndex = shown.origin
        let size = capsule.update(shown)
        let frame = NSRect(origin: origin(for: size, near: caretRect), size: size)
        pinnedFirstX = frame.origin.x + bar.style.textInset
        // A page or the grid settles more slowly than a key that only
        // changes how wide the same row is.
        place(frame, response: switching ? 0.38 : 0.2)
    }

    /// Moves the panel, as it is, to follow the composition (a client that
    /// reported its place late). The size stays the one the layout asked for,
    /// not whatever size the ease happens to be at.
    func move(near caretRect: NSRect) {
        guard panel.isVisible else { return }
        visibleCaret = caretRect
        let width = screen(near: caretRect).map { max(1, $0.visibleFrame.width - 8) }
        if width != bar.maximumWidth {
            bar.maximumWidth = width
            refreshTranslationDisplay()
            return
        }
        let size = targetFrame.size == .zero ? panel.frame.size : targetFrame.size
        let frame = NSRect(origin: origin(for: size, near: caretRect), size: size)
        pinnedFirstX = frame.origin.x + bar.style.textInset
        place(frame, response: nil)
    }

    /// While typing, keep the first candidate near where it already is. A
    /// longer suggestion, or a longer composition, widens the window; at the
    /// screen edge that slides the whole window sideways. Drop candidates
    /// from the end of the page until that slide is small. If a narrower
    /// page does not bring the first candidate back, the caret itself moved,
    /// and the full page stays.
    private func fitted(_ page: Page, near caret: NSRect) -> Page {
        guard let pin = pinnedFirstX else { return page }
        let limit = max(40, CandidateStyle.current.fontSize * 2)
        let minCount = min(page.candidates.count, max(1, page.highlighted + 1))
        guard page.candidates.count > minCount else { return page }

        var count = page.candidates.count
        var best = page
        var placed = placement(best, near: caret)
        var bestDist = abs(placed.x - pin)
        var bestWidth = placed.width
        if bestDist <= limit { return page }

        while count > minCount {
            let next: Int
            if page.expanded && count > max(page.columns, minCount) {
                next = max(minCount, page.columns - 1)
            } else {
                next = count - 1
            }
            if next >= count { break }
            count = next
            let trial = trimmed(page, count: count)
            placed = placement(trial, near: caret)
            let dist = abs(placed.x - pin)
            if dist <= limit { return trial }
            if placed.width < bestWidth - 0.5 && dist < bestDist - 0.5 {
                best = trial
                bestDist = dist
                bestWidth = placed.width
                continue
            }
            if placed.width < bestWidth - 0.5 { break }
        }
        return best
    }

    private func trimmed(_ page: Page, count: Int) -> Page {
        var next = page
        let n = min(max(count, 1), page.candidates.count)
        next.candidates = Array(page.candidates.prefix(n))
        next.comments = Array(page.comments.prefix(n))
        if let translations = page.translations { next.translations = Array(translations.prefix(n)) }
        if next.highlighted >= n { next.highlighted = n - 1 }
        return next
    }

    /// The first candidate's index, in screen points, and the window's width.
    private func placement(_ page: Page, near caret: NSRect) -> (x: CGFloat, width: CGFloat) {
        let size = bar.measure(page)
        return (origin(for: size, near: caret).x + bar.style.textInset, size.width)
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
        Self.radius(for: height, row: bar.rowHeight)
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
        stopModifierTimer()
        translations?.clear()
        translations = nil
        visiblePage = nil
        lookupApp = nil
        bar.endTextFade()
        link?.invalidate()
        link = nil
        onScreen = false
        pinnedFirstX = nil
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

    private func screen(near caretRect: NSRect) -> NSScreen? {
        let point = caretRect == .zero ? NSEvent.mouseLocation : caretRect.origin
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Below the composition's line, with the first candidate's text under
    /// its first letter, as the system's own input methods align it; above
    /// the line when there is no room below, and kept on screen.
    private func origin(for size: NSSize, near caretRect: NSRect) -> NSPoint {
        var origin = NSPoint(x: caretRect.minX - bar.style.textInset, y: caretRect.minY - size.height - 6)
        if let visible = screen(near: caretRect)?.visibleFrame {
            if caretRect == .zero {                  // the client reported no place: near the mouse
                let mouse = NSEvent.mouseLocation
                origin = NSPoint(x: mouse.x, y: mouse.y - size.height - 16)
            }
            origin.x = max(visible.minX + 4, min(origin.x, visible.maxX - size.width - 4))
            if origin.y < visible.minY + 4 { origin.y = caretRect.maxY + 6 }   // no room below: above
        }
        return origin
    }

    func hide() {
        stopModifierTimer()
        if lookupPolicy == .incognito { translations?.clear() }
        else { translations?.setTranslationHeld(false); translations?.setPage([], highlighted: 0, policy: lookupPolicy) }
        translationHeld = false
        visiblePage = nil
        lookupApp = nil
        onScreen = false
        pinnedFirstX = nil
        pauseLink()
        panel.orderOut(nil)
        bar.forget()
    }

    private func clearTranslations() {
        translations?.clear()
    }

    @available(macOS 26.0, *)
    private func translationService() -> CandidateTranslations {
        if let translations { return translations }
        let url = URL(fileURLWithPath: Core.dataDirectory).appendingPathComponent("glossary.sqlite3")
        let service = CandidateTranslations(provider: SystemCandidateLookup(glossaryURL: url)) { [weak self] in
            self?.refreshTranslationDisplay()
        }
        translations = service
        return service
    }

    private func startModifierTimer() {
        guard modifierTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTranslationModifier() }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierTimer = timer
    }

    private func stopModifierTimer() {
        modifierTimer?.invalidate()
        modifierTimer = nil
    }

    private func checkTranslationModifier() {
        guard #available(macOS 26.0, *), onScreen, let page = visiblePage,
              let app = lookupApp, let translations else { return }
        let policy = Learning.candidateLookupPolicy(forApp: app)
        let down = TranslationModifier.isActive(NSEvent.modifierFlags)
        let needsUpdate = down != translationHeld || policy != lookupPolicy
        if policy != lookupPolicy || (policy == .incognito && translationHeld && !down) { bar.forget() }
        if policy != lookupPolicy {
            lookupPolicy = policy
            translations.setPage(page.candidates, highlighted: page.highlighted, policy: policy)
        }
        translationHeld = down
        translations.setTranslationHeld(down)
        if needsUpdate { refreshTranslationDisplay() }
    }

    private func refreshTranslationDisplay() {
        guard onScreen, var page = visiblePage else { return }
        if translationHeld && lookupPolicy != .disabled { page.translations = translations?.replacements() }
        render(page, near: visibleCaret)
    }

    /// The replacement fade owns its width. A spring on top of that curve lags behind the text.
    private func applyFadeSize(_ size: NSSize) {
        guard onScreen, panel.isVisible else { return }
        let frame = NSRect(origin: origin(for: size, near: visibleCaret), size: size)
        pinnedFirstX = frame.origin.x + bar.style.textInset
        targetFrame = frame
        motion.snap(frame)
        panel.setFrame(frame, display: true)
        capsule.applyCornerRadius(cornerRadius(for: frame.height))
        pauseLink()
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
        applyCornerRadius(CandidatePanel.radius(for: size.height, row: bar.rowHeight))
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
    private let backdrop = Passive()            // dark mode: under everything, so white text always reads
    private let pill = Passive()
    private let ink = Passive()                 // above the pill: the text
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
    /// The highlight slide. The pill's frame is the frame on screen: text takes the accent
    /// color only where this frame covers it, so the color moves with the pill.
    private var highlightLink: CADisplayLink?
    private var highlightFrom = NSRect.zero
    private var highlightTo = NSRect.zero
    private var highlightStart = CFTimeInterval(0)
    private static let highlightSlide: CFTimeInterval = 0.16

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

    /// The size `page` needs, without moving the highlight.
    func measure(_ page: CandidatePanel.Page) -> NSSize {
        style = CandidateStyle.current
        return page.expanded ? layoutGrid(page) : layoutRow(page)
    }

    /// Lays out `page`; returns the size the panel needs.
    func update(_ page: CandidatePanel.Page) -> NSSize {
        let sameStyle = style == CandidateStyle.current
        style = CandidateStyle.current
        let sameList = sameStyle && self.page?.candidates == page.candidates
            && self.page?.origin == page.origin && self.page?.expanded == page.expanded
        syncBlends(to: page, sameList: sameList)
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
            if sameList && blends.isEmpty && !pill.frame.isEmpty && displaced(pill.frame, target) {
                slideHighlight(to: target)
            } else {
                setHighlightFrame(target)
                stopHighlightSlide()
            }
        } else {
            pill.isHidden = true
            stopHighlightSlide()
        }
        ink.needsDisplay = true
        return size
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
        updateColors()
        ink.needsDisplay = true
    }

    func forget() {
        page = nil
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

    /// Moves the pill from wherever it is. Its frame stays the visible one, and each
    /// frame redraws the text against that frame.
    private func slideHighlight(to target: NSRect) {
        guard window != nil else {
            setHighlightFrame(target)
            stopHighlightSlide()
            return
        }
        highlightFrom = pill.frame
        highlightTo = target
        highlightStart = CACurrentMediaTime()
        startHighlightLink()
    }

    private func setHighlightFrame(_ rect: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.layer?.removeAllAnimations()
        pill.frame = rect
        CATransaction.commit()
    }

    private func startHighlightLink() {
        guard highlightLink == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(stepHighlight(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = false
        highlightLink = link
    }

    private func stopHighlightSlide() {
        highlightLink?.invalidate()
        highlightLink = nil
    }

    @objc nonisolated private func stepHighlight(_ link: CADisplayLink) {
        MainActor.assumeIsolated { self.tickHighlight() }
    }

    private func tickHighlight() {
        let raw = CGFloat(min(1, max(0, (CACurrentMediaTime() - highlightStart) / Self.highlightSlide)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.layer?.removeAllAnimations()
        pill.frame = Self.mix(highlightFrom, highlightTo, Self.easeOut(raw))
        ink.needsDisplay = true
        ink.displayIfNeeded()
        CATransaction.commit()
        if raw >= 1 { stopHighlightSlide() }
    }

    /// `CAMediaTimingFunction.easeOut`: cubic-bezier(0, 0, 0.58, 1).
    private static func easeOut(_ t: CGFloat) -> CGFloat {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        let x2 = 0.58
        var u = t
        for _ in 0..<8 {
            let x = 3 * (1 - u) * u * u * x2 + u * u * u
            let dx = 6 * x2 * u + (3 - 9 * x2) * u * u
            if abs(dx) < 1e-6 { break }
            u = min(1, max(0, u - (x - t) / dx))
        }
        return min(1, max(0, 3 * (1 - u) * u * u + u * u * u))
    }

    private static func mix(_ a: NSRect, _ b: NSRect, _ t: CGFloat) -> NSRect {
        func m(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * t }
        return NSRect(x: m(a.minX, b.minX), y: m(a.minY, b.minY),
                      width: m(a.width, b.width), height: m(a.height, b.height))
    }

    private func displaced(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) > 0.5 || abs(a.minY - b.minY) > 0.5
            || abs(a.width - b.width) > 0.5 || abs(a.height - b.height) > 0.5
    }

    /// Where the pill is now, in the text view's coordinates.
    private func highlightCover() -> NSRect? {
        guard !pill.isHidden else { return nil }
        let rect = pill.frame
        guard rect.width > 0.5, rect.height > 0.5 else { return nil }
        return ink.convert(rect, from: self)
    }

    private func commentWidth(_ comment: String?) -> CGFloat {
        min(commentLimit, rawCommentWidth(comment))
    }

    private func rawCommentWidth(_ comment: String?) -> CGFloat {
        guard let comment, !comment.isEmpty else { return 0 }
        return 4 + NSAttributedString(string: comment, attributes: [.font: style.smallFont]).size().width
    }

    private func indexSize(_ i: Int) -> NSSize {
        NSAttributedString(string: "\(i + 1)", attributes: [.font: style.indexFont]).size()
    }

    private func attributed(_ text: String, highlighted: Bool, alpha: CGFloat = 1) -> NSAttributedString {
        let color = (highlighted ? style.onAccentColor : NSColor.labelColor).withAlphaComponent(alpha)
        return NSAttributedString(string: text, attributes: [
            .font: style.textFont,
            .foregroundColor: color,
        ])
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
        let line = ceil(style.textFont.ascender - style.textFont.descender) + 8
        NSRect(x: x, y: y - 4, width: slot, height: line).clip()
        for (dx, dy, passAlpha) in passes {
            let string = attributed(text, highlighted: highlighted, alpha: passAlpha)
            if softness < 0.35 && string.size().width > slot + 0.5 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let clipped = NSMutableAttributedString(attributedString: string)
                clipped.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: clipped.length))
                let height = string.size().height
                clipped.draw(with: NSRect(x: x, y: y, width: slot, height: height), options: [.usesLineFragmentOrigin])
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
        let width = attributed(text, highlighted: false).size().width
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
        ink.frame = NSRect(origin: .zero, size: size)
        backdrop.frame = ink.frame
        if page.highlighted >= 0 && page.highlighted < cells.count {
            pill.layer?.removeAllAnimations()
            pill.frame = cells[page.highlighted]
            pill.isHidden = false
        }
        ink.needsDisplay = true
        onTextFade?(size)
        if blends.isEmpty { stopFadeLink() }
    }

    private func drawContent() {
        guard let page else { return }
        if page.expanded {
            NSColor.separatorColor.withAlphaComponent(0.22).setFill()
            for y in separators {
                NSRect(x: style.inset, y: y, width: max(gridWidth - style.inset, 0), height: 1).fill()
            }
        }
        drawLabels(page, covered: false)
        drawCoveredText(page)
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

    /// Resting ink, then the same ink again in the accent color, clipped to the pill.
    /// Clearing first lets the translucent index and comment composite over the pill.
    private func drawCoveredText(_ page: CandidatePanel.Page) {
        guard let cover = highlightCover(), let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        let radius = cover.height / 2
        NSBezierPath(roundedRect: cover, xRadius: radius, yRadius: radius).addClip()
        context.setFillColor(NSColor.black.cgColor)
        context.setBlendMode(.clear)
        context.fill(cover)
        context.setBlendMode(.normal)
        drawLabels(page, covered: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLabels(_ page: CandidatePanel.Page, covered: Bool) {
        let cols = max(page.columns, 1)
        let numberedRow = page.expanded && page.highlighted >= 0 ? page.highlighted / cols : -1
        for (i, cell) in cells.enumerated() {
            let selected = i == page.highlighted
            if !covered && i == hovered && !selected {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: cell, xRadius: cell.height / 2, yRadius: cell.height / 2).fill()
            }
            let blend = blends[i].flatMap { $0.candidate == page.candidates[i] ? $0 : nil }
            let raw = shownText(page, i)
            let text = attributed(raw, highlighted: covered)
            let textSize = text.size()
            let measured = shownWidth(page, i)
            let drawnWidth = blend == nil ? min(textSize.width, measured) : measured
            let onAccent = style.onAccentColor.withAlphaComponent(0.78)
            let number = page.expanded ? (i % cols) + 1 : i + 1
            let showNumber = !page.expanded || i / cols == numberedRow
            let index = NSAttributedString(string: "\(number)", attributes: [
                .font: style.indexFont,
                .foregroundColor: covered ? onAccent : NSColor.secondaryLabelColor,
            ])
            let indexSize = index.size()
            var x = cell.minX + style.padding
            // The index sits on the text's baseline, not centered: like a footnote numeral.
            let textY = cell.minY + (style.cellHeight - textSize.height) / 2
            let baseline = textY + style.textFont.ascender
            if showNumber {
                index.draw(at: NSPoint(x: x, y: baseline - style.indexFont.ascender))
            }
            x += indexSize.width + style.indexGap
            if let blend {
                let t = blend.fraction(at: CACurrentMediaTime())
                let source = blend.outgoing ?? blend.candidate
                drawWord(source, highlighted: covered, x: x, y: textY - t * 2,
                         slot: drawnWidth, alpha: 1 - t, softness: t * 1.6)
                drawWord(blend.translation, highlighted: covered, x: x, y: textY + (1 - t) * 3,
                         slot: drawnWidth, alpha: t, softness: (1 - t) * 2.2)
            } else if textSize.width > drawnWidth + 0.5 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let clipped = NSMutableAttributedString(attributedString: text)
                clipped.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: clipped.length))
                clipped.draw(with: NSRect(x: x, y: textY, width: drawnWidth, height: textSize.height),
                             options: [.usesLineFragmentOrigin])
            } else {
                text.draw(at: NSPoint(x: x, y: textY))
            }
            x += drawnWidth
            if let comment = page.comments[safe: i], !comment.isEmpty {
                let small = NSAttributedString(string: comment, attributes: [
                    .font: style.smallFont,
                    .foregroundColor: covered ? onAccent : NSColor.tertiaryLabelColor,
                ])
                let available = max(0, commentWidth(comment) - 4)
                if available > 0 {
                    let origin = NSPoint(x: x + 4, y: baseline - style.smallFont.ascender)
                    if small.size().width > available {
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byTruncatingTail
                        let clipped = NSMutableAttributedString(attributedString: small)
                        clipped.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: clipped.length))
                        clipped.draw(with: NSRect(origin: origin, size: NSSize(width: available, height: small.size().height)),
                                     options: [.usesLineFragmentOrigin])
                    } else { small.draw(at: origin) }
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
