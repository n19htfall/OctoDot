import AppKit

// CandidateBar uses these only through the surrounding panel. The layout
// checks exercise real AppKit measurements without starting an input method.
@MainActor enum Core { static let dataDirectory = "" }
@MainActor enum Learning {
    static func candidateLookupPolicy(forApp: String) -> CandidateLookupPolicy { .normal }
}

@main
@MainActor
private enum CandidateLayoutTests {
    static func main() {
        _ = NSApplication.shared
        let bar = CandidateBar()
        bar.maximumWidth = 640
        var page = CandidatePanel.Page(candidates: Array(repeating: "电脑", count: 6), highlighted: 0,
                                       hasPrevious: true, hasNext: true)
        page.translations = Array(repeating: "a very long phrase in a translation result", count: 6)
        let row = bar.update(page)
        check(row.width <= 640, "long translated candidates fit the available row width")

        page.expanded = true
        page.columns = 6
        page.candidates = Array(repeating: "电脑", count: 24)
        page.comments = Array(repeating: "comment", count: 24)
        page.translations = Array(repeating: "a very long phrase in a translation result", count: 24)
        page.menuCount = 40
        let grid = bar.update(page)
        check(grid.width <= 640, "a translated grid, including comments and its scrollbar, fits the display")

        bar.maximumWidth = 420
        let smaller = bar.update(page)
        check(smaller.width <= 420, "the layout adapts when the window moves to a narrower display")
        bar.endTextFade()
        checkHighlightFollowsPill()
    }

    /// The accent color covers a glyph only where the highlight pill covers it:
    /// settled on one candidate, partway across the next, and mid-slide.
    private static func checkHighlightFollowsPill() {
        let saved = CandidateStyle.current
        CandidateStyle.current = CandidateStyle(fontSize: 18, accent: "blue", inset: 3)
        defer { CandidateStyle.current = saved }

        let long = String(repeating: "国", count: 10)
        let page = CandidatePanel.Page(candidates: ["中", long], highlighted: 0, hasPrevious: false, hasNext: false)
        let (bar, window) = host(page)
        defer { window.close(); bar.endTextFade() }
        guard let settled = raster(bar), let pill = highlightView(bar) else {
            check(false, "the candidate bar draws")
            return
        }
        let light = samples(settled, isLightText)
        let dark = samples(settled, isDarkText)
        guard let toView = viewMapper(light: light, pill: pill.frame, rep: settled, viewSize: bar.bounds.size) else {
            dump(settled, "octodot-highlight-settled")
            check(false, "highlighted text is readable on the pill")
            return
        }
        let around = pill.frame.insetBy(dx: -3, dy: -3)
        let lightOutside = light.filter { !around.contains(toView($0)) }.count
        let darkInside = dark.filter { around.contains(toView($0)) }.count
        check(light.count > 30 && lightOutside < light.count / 10, "the selected candidate is drawn in the accent color")
        check(dark.count > 30 && darkInside == 0, "the other candidate stays in the label color")

        let home = pill.frame
        let word = dark.map { toView($0) }
        let minX = word.map(\.x).min() ?? 0
        let maxX = word.map(\.x).max() ?? 0
        let span = max(maxX - minX, 1)
        let width = max(pill.frame.height + 4, span * 0.28)
        let middle = NSRect(x: (minX + maxX) / 2 - width / 2, y: pill.frame.minY,
                            width: width, height: pill.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = middle
        CATransaction.commit()
        bar.needsDisplay = true
        guard let partial = raster(bar) else {
            check(false, "a partial highlight draws")
            return
        }
        let core = middle.insetBy(dx: middle.height / 2, dy: 3)
        let covered = dark.filter { core.contains(toView($0)) }
        let uncovered = dark.filter { !middle.insetBy(dx: -2, dy: -2).contains(toView($0)) }
        let coveredLight = covered.filter { isLightText(partial.colorAt(x: $0.x, y: $0.y) ?? .clear) }.count
        let uncoveredDark = uncovered.filter { isDarkText(partial.colorAt(x: $0.x, y: $0.y) ?? .clear) }.count
        if covered.count < 20 || uncovered.count < 20 || coveredLight < covered.count * 8 / 10
            || uncoveredDark < uncovered.count * 8 / 10 {
            dump(partial, "octodot-highlight-partial")
            print("partial cover \(coveredLight)/\(covered.count) still dark \(uncoveredDark)/\(uncovered.count) pill \(middle)")
        }
        check(covered.count >= 20 && coveredLight >= covered.count * 8 / 10,
              "text under the highlight turns to the accent color")
        check(uncovered.count >= 20 && uncoveredDark >= uncovered.count * 8 / 10,
              "text outside the highlight keeps the label color")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.frame = home
        CATransaction.commit()
        var slidingPage = page
        slidingPage.highlighted = 1
        _ = bar.update(slidingPage)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        bar.endTextFade()
        guard let pillNow = highlightView(bar), let sliding = raster(bar) else {
            check(false, "the highlight slide draws")
            return
        }
        let slideCover = pillNow.frame.insetBy(dx: pillNow.frame.height / 2, dy: 3)
        let slideOutside = pillNow.frame.insetBy(dx: -2, dy: -2)
        let reached = dark.filter { slideCover.contains(toView($0)) }
        let waiting = dark.filter { !slideOutside.contains(toView($0)) }
        let reachedLight = reached.filter { isLightText(sliding.colorAt(x: $0.x, y: $0.y) ?? .clear) }.count
        let waitingDark = waiting.filter { isDarkText(sliding.colorAt(x: $0.x, y: $0.y) ?? .clear) }.count
        if reached.count < 15 || waiting.count < 15 || reachedLight < reached.count * 8 / 10
            || waitingDark < waiting.count * 8 / 10 {
            dump(sliding, "octodot-highlight-slide")
            print("slide reached \(reachedLight)/\(reached.count) waiting \(waitingDark)/\(waiting.count) pill \(pillNow.frame)")
        }
        check(reached.count >= 15 && reachedLight >= reached.count * 8 / 10,
              "during the slide, covered text has already changed color")
        check(waiting.count >= 15 && waitingDark >= waiting.count * 8 / 10,
              "during the slide, text the pill has not reached stays dark")
    }

    private static func host(_ page: CandidatePanel.Page) -> (CandidateBar, NSWindow) {
        let bar = CandidateBar()
        bar.appearance = NSAppearance(named: .aqua)
        bar.autoresizingMask = []
        let size = bar.update(page)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.addSubview(bar)
        bar.frame = host.bounds
        let window = QuietWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = host
        bar.frame = NSRect(origin: .zero, size: size)
        if let visible = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: visible.minX + 8, y: visible.minY + 8))
        }
        window.orderFrontRegardless()
        return (bar, window)
    }

    private static func highlightView(_ bar: CandidateBar) -> NSView? {
        bar.subviews.first { $0.frame.width > 1 && $0.frame.width < bar.bounds.width - 1 }
    }

    private static func raster(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        for sub in view.subviews { sub.needsDisplay = true }
        view.display()
        let bounds = view.bounds
        guard bounds.width > 1, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private struct Sample { var x: Int; var y: Int }

    private static func samples(_ rep: NSBitmapImageRep, _ match: (NSColor) -> Bool) -> [Sample] {
        var found: [Sample] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y), match(color) else { continue }
                found.append(Sample(x: x, y: y))
            }
        }
        return found
    }

    private static func srgb(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    private static func isLightText(_ color: NSColor) -> Bool {
        guard let c = srgb(color) else { return false }
        let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        return c.3 > 0.85 && y > 0.82
    }

    private static func isDarkText(_ color: NSColor) -> Bool {
        guard let c = srgb(color) else { return false }
        let y = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        return c.3 > 0.85 && y < 0.28
    }

    private static func viewMapper(light: [Sample], pill: NSRect, rep: NSBitmapImageRep,
                                   viewSize: NSSize) -> ((Sample) -> NSPoint)? {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let sx = viewSize.width / CGFloat(rep.pixelsWide)
        let sy = viewSize.height / CGFloat(rep.pixelsHigh)
        func point(_ sample: Sample, top: Bool) -> NSPoint {
            let x = (CGFloat(sample.x) + 0.5) * sx
            let down = (CGFloat(sample.y) + 0.5) * sy
            return NSPoint(x: x, y: top ? down : viewSize.height - down)
        }
        func hits(_ top: Bool) -> Int {
            light.reduce(0) { $0 + (pill.contains(point($1, top: top)) ? 1 : 0) }
        }
        let topHits = hits(true)
        let bottomHits = hits(false)
        guard max(topHits, bottomHits) >= max(8, light.count / 5) else { return nil }
        let top = topHits >= bottomHits
        return { point($0, top: top) }
    }

    private final class QuietWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static func dump(_ rep: NSBitmapImageRep, _ name: String) {
        let url = URL(fileURLWithPath: "/tmp/\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }

    private static func check(_ passed: Bool, _ description: String) {
        print(passed ? "ok    \(description)" : "FAIL  \(description)")
        if !passed { exit(1) }
    }
}
