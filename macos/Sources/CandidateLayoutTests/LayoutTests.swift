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
    }

    private static func check(_ passed: Bool, _ description: String) {
        print(passed ? "ok    \(description)" : "FAIL  \(description)")
        if !passed { exit(1) }
    }
}
