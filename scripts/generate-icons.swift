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
    NSColor(srgbRed: 0.06, green: 0.09, blue: 0.27, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.055, green: 0.085, blue: 0.25, alpha: 1),
               ending: NSColor(srgbRed: 0.20, green: 0.32, blue: 0.82, alpha: 1))!.draw(in: tile, angle: 70)
    NSColor.white.withAlphaComponent(0.17).setStroke()
    tile.lineWidth = 3
    tile.stroke()
    // A single forward-swept V. Broad filled shapes remain legible at 16 pixels.
    func polygon(_ points: [NSPoint], color: NSColor) {
        let path = NSBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
        color.setFill()
        path.fill()
    }
    polygon([NSPoint(x: 220, y: 688), NSPoint(x: 366, y: 688),
             NSPoint(x: 495, y: 430), NSPoint(x: 690, y: 770),
             NSPoint(x: 838, y: 770), NSPoint(x: 529, y: 254),
             NSPoint(x: 439, y: 254)], color: .white)
    polygon([NSPoint(x: 622, y: 432), NSPoint(x: 725, y: 432),
             NSPoint(x: 833, y: 614), NSPoint(x: 730, y: 614)],
            color: NSColor(srgbRed: 0.27, green: 0.94, blue: 0.91, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
        try icon(points * scale).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
