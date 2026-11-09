// Renders the companion app's icon: make-app-icon <AppIcon.iconset>, then
// iconutil -c icns. A rounded square in the macOS icon grid (824 of 1024,
// corners of 185), a deep teal-to-indigo gradient, the input method's label
// 千 in white, centered by its ink, and the "dot" of OctoDot beside it.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSShadow().apply {
        $0.shadowColor = NSColor.black.withAlphaComponent(0.25)
        $0.shadowOffset = NSSize(width: 0, height: -10 * s)
        $0.shadowBlurRadius = 24 * s
    }
    NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.55, blue: 0.62, alpha: 1),
                        NSColor(srgbRed: 0.20, green: 0.24, blue: 0.62, alpha: 1)])!.draw(in: shape, angle: -60)
    NSShadow().apply { $0.shadowColor = nil }
    let font = NSFont(name: "PingFangSC-Semibold", size: 520 * s) ?? .systemFont(ofSize: 520 * s, weight: .semibold)
    let label = NSAttributedString(string: "千", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = label.size()
    label.draw(at: NSPoint(x: body.midX - size.width / 2 - 40 * s, y: body.midY - size.height / 2 - 10 * s))
    let dot = NSRect(x: body.maxX - 250 * s, y: body.minY + 150 * s, width: 110 * s, height: 110 * s)
    NSColor(srgbRed: 1.0, green: 0.78, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}

for points in [16, 32, 128, 256, 512] {
    try! render(points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(points * 2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
