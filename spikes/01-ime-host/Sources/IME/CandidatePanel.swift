import AppKit

/// A minimal candidate window: a borderless, non-activating panel, so the
/// client app never loses focus to it. M0 selects by keyboard only.
@MainActor
final class CandidatePanel {
    static let shared = CandidatePanel()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        label.font = .systemFont(ofSize: 16)
        background.addSubview(label)
        panel.contentView = background
    }

    /// `caretRect` is the client's line rectangle in screen coordinates.
    func update(candidates: [String], highlighted: Int, near caretRect: NSRect) {
        guard !candidates.isEmpty else { return hide() }
        label.stringValue = candidates.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "   ")
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 10, y: 6))
        let size = NSSize(width: label.frame.width + 20, height: label.frame.height + 12)

        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 4)
        let screen = NSScreen.screens.first { $0.frame.contains(caretRect.origin) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            if origin.y < visible.minY { origin.y = caretRect.maxY + 4 }  // no room below: go above
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
