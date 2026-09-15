import AppKit
import SwiftUI

enum Branding {
    static func menuIcon(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let mark = NSBezierPath()
            for (index, point) in [NSPoint(x: 1, y: 13), NSPoint(x: 4.5, y: 13),
                                   NSPoint(x: 8, y: 5.5), NSPoint(x: 14, y: 16),
                                   NSPoint(x: 18, y: 16), NSPoint(x: 9, y: 1),
                                   NSPoint(x: 7, y: 1)].enumerated() {
                if index == 0 { mark.move(to: point) } else { mark.line(to: point) }
            }
            mark.close()
            mark.fill()
            if attention {
                NSBezierPath(ovalIn: NSRect(x: 15, y: 1, width: 4, height: 4)).fill()
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
