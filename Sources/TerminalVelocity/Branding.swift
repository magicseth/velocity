import AppKit
import SwiftUI

enum Branding {
    static func menuIcon(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 2.5, y: 11)); mark.line(to: NSPoint(x: 8, y: 3.5)); mark.line(to: NSPoint(x: 16, y: 14.5))
            mark.lineWidth = 2.6; mark.lineCapStyle = .round; mark.lineJoinStyle = .round; mark.stroke()
            let corner = NSBezierPath()
            corner.move(to: NSPoint(x: 2.5, y: 14)); corner.line(to: NSPoint(x: 2.5, y: 16)); corner.line(to: NSPoint(x: 11, y: 16))
            corner.lineWidth = 1.3; corner.lineCapStyle = .round; corner.lineJoinStyle = .round; corner.stroke()
            NSColor.black.setFill()
            if attention { NSBezierPath(ovalIn: NSRect(x: 15, y: 1, width: 4.5, height: 4.5)).fill() }
            else { NSBezierPath(roundedRect: NSRect(x: 14, y: 2.5, width: 5, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = attention ? "Agents need input" : "Terminal Velocity"
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
