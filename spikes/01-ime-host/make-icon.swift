// Renders the input-menu icon (八, "eight", for Octo) as a 16 pt TIFF with
// 1x and 2x representations: make-icon <output.tiff>
import AppKit

func representation(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let glyph = NSAttributedString(string: "八", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.black,
    ])
    let size = glyph.size()
    glyph.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: 16, height: 16))
image.addRepresentation(representation(pixels: 16))
image.addRepresentation(representation(pixels: 32))
guard let tiff = image.tiffRepresentation, CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.tiff>\n".utf8))
    exit(2)
}
try tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
