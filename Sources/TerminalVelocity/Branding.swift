import AppKit
import SwiftUI

enum Branding {
    static func menuIcon(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            for quarter in 0..<4 {
                NSGraphicsContext.saveGraphicsState()
                let rotation = NSAffineTransform()
                rotation.translateX(by: 9, yBy: 9)
                rotation.rotate(byDegrees: CGFloat(quarter * 90))
                rotation.concat()
                let chamber = NSBezierPath()
                chamber.move(to: NSPoint(x: -6, y: 2))
                chamber.line(to: NSPoint(x: -6, y: 4.5))
                chamber.curve(to: NSPoint(x: -4.5, y: 6), controlPoint1: NSPoint(x: -6, y: 5.5), controlPoint2: NSPoint(x: -5.5, y: 6))
                chamber.line(to: NSPoint(x: -2, y: 6))
                chamber.lineWidth = 2
                chamber.lineCapStyle = .round
                chamber.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7, y: 7, width: 4, height: 4), xRadius: 1, yRadius: 1).fill()
            if attention {
                NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = attention ? "Agents need input" : "Velocity"
        return image
    }
}

struct ObjectiveIcon: View {
    let entries: [WindowEntry]
    var waiting = false
    var unread = false
    var done = false
    private var apps: [WindowEntry] {
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.appName).inserted }.prefix(3).map { $0 }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.09))
            if apps.isEmpty {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 23)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(apps.enumerated().reversed()), id: \.element.id) { index, entry in
                    Group {
                        if let icon = entry.icon { Image(nsImage: icon).resizable() }
                        else { Image(systemName: "app.fill").resizable() }
                    }
                    .frame(width: apps.count == 1 ? 34 : 27, height: apps.count == 1 ? 34 : 27)
                    .offset(x: apps.count == 1 ? 0 : CGFloat(index * 6 - 5), y: apps.count == 1 ? 0 : CGFloat(5 - index * 5))
                }
            }
        }.frame(width: 44, height: 44)
            .overlay(alignment: .bottomTrailing) {
                if waiting || unread || done {
                    Image(systemName: done ? "checkmark.circle.fill" : waiting ? "exclamationmark.circle.fill" : "circle.fill")
                        .font(.system(size: unread && !waiting && !done ? 10 : 16, weight: .semibold))
                        .foregroundStyle(done ? Color.green : waiting ? Color.orange : Color.blue)
                        .background(Circle().fill(.background).padding(-2))
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityLabel(apps.isEmpty ? "Objective" : apps.map(\.appName).joined(separator: ", "))
            .help(apps.map(\.appName).joined(separator: ", "))
    }
}
