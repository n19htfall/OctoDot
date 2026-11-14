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
