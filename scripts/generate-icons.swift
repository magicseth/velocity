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
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.045, green: 0.14, blue: 0.16, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.035, green: 0.12, blue: 0.15, alpha: 1),
               ending: NSColor(srgbRed: 0.10, green: 0.32, blue: 0.36, alpha: 1))!.draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.17).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    // Four chambers frame a protected resource. The open gaps suggest scoped access.
    for quarter in 0..<4 {
        NSGraphicsContext.saveGraphicsState()
        let rotation = NSAffineTransform()
        rotation.translateX(by: 512, yBy: 512)
        rotation.rotate(byDegrees: CGFloat(quarter * 90))
        rotation.concat()
        let chamber = NSBezierPath()
        chamber.move(to: NSPoint(x: -218, y: 60))
        chamber.line(to: NSPoint(x: -218, y: 164))
        chamber.curve(to: NSPoint(x: -164, y: 218), controlPoint1: NSPoint(x: -218, y: 202), controlPoint2: NSPoint(x: -202, y: 218))
        chamber.line(to: NSPoint(x: -85, y: 218))
        chamber.lineWidth = 86
        chamber.lineCapStyle = .round
        chamber.lineJoinStyle = .round
        NSColor(srgbRed: 0.87, green: 0.96, blue: 0.94, alpha: 1).setStroke()
        chamber.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSColor(srgbRed: 1, green: 0.73, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 437, y: 437, width: 150, height: 150), xRadius: 42, yRadius: 42).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try icon(points * scale).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
