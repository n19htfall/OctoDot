// The disk image's window background: dmg-background <out.png> <out@2x.png>.
// 660 × 400 points: OctoDot's icon goes at (165, 190) and the Applications
// link at (495, 190) (tools/build-dmg.sh), with an arrow between and the one
// instruction under it.
import AppKit

func render(_ scale: CGFloat) -> Data {
    let width = Int(660 * scale), height = Int(400 * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 660, height: 400)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let all = NSRect(x: 0, y: 0, width: 660, height: 400)
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.98, blue: 0.99, alpha: 1),
                        NSColor(srgbRed: 0.90, green: 0.93, blue: 0.96, alpha: 1)])!.draw(in: all, angle: -90)
    // The arrow, from under the app's icon to the Applications folder (Finder's y runs down; ours up).
    let y: CGFloat = 400 - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 255, y: y))
    arrow.line(to: NSPoint(x: 395, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    let tint = NSColor(srgbRed: 0.20, green: 0.42, blue: 0.62, alpha: 0.55)
    tint.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 410, y: y))
    head.line(to: NSPoint(x: 388, y: y + 16))
    head.line(to: NSPoint(x: 388, y: y - 16))
    head.close()
    tint.setFill()
    head.fill()
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag OctoDot to Applications, then open it there.\n拖到“应用程序”，再从那里打开。", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.30, blue: 0.36, alpha: 1),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 40, y: 48, width: 580, height: 44))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(1).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try! render(2).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
