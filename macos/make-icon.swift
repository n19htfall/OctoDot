// Renders the input mode's icons (the label 千) as TIFFs with 1x and 2x
// representations: make-icon <outlined.tiff> <filled.tiff>
//
// macOS draws the system's own input sources' icons from their label
// (TISIconLabels), but only theirs (TISPropertyInputSourceIsFromSystem): for
// any other input method it shows the image files. So these reproduce the
// system's badges, measured from its own on 2026-11-08: 22 × 16 pt with
// 5 pt corners, the character centered by its ink. In the menu bar, the
// selected source is a 1 pt outline with the character drawn inside (the
// indicator at the caret on a switch shows it too); in the input menu, a
// filled badge with the character cut out. Both are template images
// (Info.plist's TISIconIsTemplate), which macOS tints.
import AppKit

let size = NSSize(width: 22, height: 16)
let radius: CGFloat = 5
let labelString = "千"

func labelText(_ size: CGFloat) -> NSAttributedString {
    let font = NSFont(name: "PingFangSC-Semibold", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    return NSAttributedString(string: labelString, attributes: [.font: font, .foregroundColor: NSColor.black])
}

/// Where `text` puts ink when drawn at the origin, found by drawing it and
/// looking: font metrics describe line boxes, and a CJK glyph's ink sits
/// in its own place within them.
func inkRect(_ text: NSAttributedString) -> NSRect {
    let scale: CGFloat = 8, pad: CGFloat = 20
    let box = text.size()
    let wide = Int((box.width + 2 * pad) * scale), high = Int((box.height + 2 * pad) * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: CGFloat(wide) / scale, height: CGFloat(high) / scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    text.draw(at: NSPoint(x: pad, y: pad))
    NSGraphicsContext.restoreGraphicsState()
    var minX = wide, maxX = -1, minY = high, maxY = -1
    for y in 0..<high { for x in 0..<wide where rep.colorAt(x: x, y: y)!.alphaComponent > 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    // Bitmap rows run top down; drawing coordinates run bottom up.
    return NSRect(x: CGFloat(minX) / scale - pad, y: CGFloat(high - 1 - maxY) / scale - pad,
                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
}

/// The label at the size that makes its ink `inkHeight` tall, and where its ink falls.
func label(inkHeight: CGFloat) -> (NSAttributedString, NSRect) {
    let probe = inkRect(labelText(100)).height
    let text = labelText(100 * inkHeight / probe)
    return (text, inkRect(text))
}

enum Style { case outlined, filled }

func representation(scale: Int, style: Style) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                               pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.set()
    let badge = NSRect(origin: .zero, size: size)
    if style == .outlined {
        let path = NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        path.stroke()
    } else if style == .filled {
        NSBezierPath(roundedRect: badge, xRadius: radius, yRadius: radius).fill()
    }
    // The character's ink, not its line box, sized and centered as in the
    // system's badges: 9.5 pt tall in the input menu, 9 inside the outline.
    let (text, ink) = label(inkHeight: style == .outlined ? 9 : 9.5)
    let origin = NSPoint(x: (size.width - ink.width) / 2 - ink.minX, y: (size.height - ink.height) / 2 - ink.minY)
    if style == .filled { NSGraphicsContext.current?.compositingOperation = .destinationOut }    // cut it out
    text.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icon <outlined.tiff> <filled.tiff>\n".utf8))
    exit(2)
}
for (path, style) in [(arguments[1], Style.outlined), (arguments[2], .filled)] {
    let image = NSImage(size: size)
    image.addRepresentation(representation(scale: 1, style: style))
    image.addRepresentation(representation(scale: 2, style: style))
    try image.tiffRepresentation!.write(to: URL(fileURLWithPath: path))
}
