import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("resources/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func icon(_ size: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
    NSGradient(starting: NSColor(srgbRed: 0.055, green: 0.11, blue: 0.22, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.20, blue: 0.35, alpha: 1))!.draw(in: tile, angle: 65)
    NSColor.white.withAlphaComponent(0.14).setStroke(); tile.lineWidth = 3; tile.stroke()
    // Two window corners surround a bold velocity chevron.
    let windows = NSBezierPath()
    windows.move(to: NSPoint(x: 272, y: 658)); windows.line(to: NSPoint(x: 272, y: 730)); windows.line(to: NSPoint(x: 666, y: 730))
    windows.lineWidth = 28; windows.lineCapStyle = .round; windows.lineJoinStyle = .round
    NSColor(srgbRed: 0.31, green: 0.52, blue: 0.86, alpha: 1).setStroke(); windows.stroke()
    let v = NSBezierPath()
    v.move(to: NSPoint(x: 288, y: 597)); v.line(to: NSPoint(x: 470, y: 324)); v.line(to: NSPoint(x: 739, y: 669))
    v.lineWidth = 96; v.lineCapStyle = .round; v.lineJoinStyle = .round
    NSColor(srgbRed: 0.36, green: 0.96, blue: 0.80, alpha: 1).setStroke(); v.stroke()
    let underline = NSBezierPath()
    underline.move(to: NSPoint(x: 625, y: 324)); underline.line(to: NSPoint(x: 746, y: 324))
    underline.lineWidth = 42; underline.lineCapStyle = .round
    NSColor(srgbRed: 0.42, green: 0.64, blue: 1, alpha: 1).setStroke(); underline.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try icon(points * scale).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
