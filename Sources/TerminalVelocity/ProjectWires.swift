import AppKit
import SwiftUI

/// THE THREADS TO A PROJECT'S WINDOWS. Mouse over a project — in Julia's floating bar, on a
/// card, or on the project tag floating over a window — and a glowing wire runs from the
/// pointer to every window and terminal of that project, a bright bead flowing along each,
/// a soft ring around each window. The same thread Julia draws from the bar to its card
/// ("the line with animation from the floaty to the cards"), now reaching the desktop.
///
/// One transparent, click-through panel spanning every screen; shown while hovered, gone on
/// exit. Purely visual: never raises, focuses or reorders anything.
@MainActor enum ProjectWires {
    private static var panel: NSPanel?
    private static var hosting: NSHostingView<WiresView>?
    private static var hideTask: Task<Void, Never>?
    private static var shownKey: String?

    /// Draw wires from `origin` (Cocoa screen coords) to `targets` (Cocoa window frames).
    static func show(key: String, from origin: NSPoint, to targets: [NSRect], tint: NSColor) {
        hideTask?.cancel(); hideTask = nil
        guard !targets.isEmpty else { hide(); return }
        let union = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        guard !union.isNull else { return }
        // Cocoa (y up, bottom-left) → the view's (y down, top-left of the union).
        let flip: (NSPoint) -> CGPoint = { CGPoint(x: $0.x - union.minX, y: union.maxY - $0.y) }
        let rects = targets.map { r in CGRect(origin: flip(NSPoint(x: r.minX, y: r.maxY)), size: r.size) }
        let model = WiresModel(origin: flip(origin), targets: rects, tint: Color(nsColor: tint), born: Date())
        if panel == nil {
            let p = NSPanel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            let h = NSHostingView(rootView: WiresView(model: model))
            h.frame = NSRect(origin: .zero, size: union.size)
            p.contentView = h
            panel = p; hosting = h
        }
        if panel?.frame != union { panel?.setFrame(union, display: false); hosting?.frame = NSRect(origin: .zero, size: union.size) }
        // Same project again (the hover re-reported): keep the animation's clock, just move the ends.
        hosting?.rootView = WiresView(model: shownKey == key ? WiresModel(origin: model.origin, targets: model.targets, tint: model.tint, born: hosting?.rootView.model.born ?? model.born) : model)
        shownKey = key
        panel?.orderFrontRegardless()
    }

    /// Clear — after a beat, so sliding from one project to the next doesn't flash.
    static func hide(after delay: Double = 0.12) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil); shownKey = nil
        }
    }

    /// The on-screen frames (Cocoa) of these windows — skips minimized/off-space ones.
    static func frames(of entries: [WindowEntry]) -> [NSRect] {
        let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        var seen = Set<CGWindowID>()
        return entries.compactMap { e in
            guard let el = e.element, let wid = WindowRaise.windowID(of: el), onScreen.contains(wid), seen.insert(wid).inserted else { return nil }
            return WindowRaise.frame(of: wid)
        }
    }
}

struct WiresModel {
    let origin: CGPoint
    let targets: [CGRect]
    let tint: Color
    let born: Date
}

struct WiresView: View {
    let model: WiresModel
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(model.born)
            // The wires DRAW OUT from the pointer over 0.35 s, then the bead flows every 1.4 s.
            let grow = CGFloat(min(1, t / 0.35))
            let phase = CGFloat((t / 1.4).truncatingRemainder(dividingBy: 1))
            ZStack {
                ForEach(Array(model.targets.enumerated()), id: \.offset) { i, r in
                    let b = anchor(on: r, from: model.origin)
                    let path = curve(from: model.origin, to: b)
                    let wire = path.trimmedPath(from: 0, to: grow)
                    // Stagger the beads so several wires shimmer rather than pulse in lockstep.
                    let p = (phase + CGFloat(i) * 0.17).truncatingRemainder(dividingBy: 1)
                    let bead = path.trimmedPath(from: max(0, p - 0.18), to: p)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(model.tint.opacity(0.22 * grow), lineWidth: 9)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(model.tint.opacity(0.8 * grow), lineWidth: 2))
                        .frame(width: r.width + 6, height: r.height + 6)
                        .position(x: r.midX, y: r.midY)
                    wire.stroke(model.tint.opacity(0.35), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    wire.stroke(model.tint.opacity(0.95), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    if grow >= 1 {
                        bead.stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        bead.stroke(model.tint.opacity(0.6), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        dot.position(b)
                    }
                }
                dot.position(model.origin)
            }
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }

    private var dot: some View {
        Circle().fill(model.tint).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
    }

    /// Where the wire lands: the middle of the window's edge facing the pointer.
    private func anchor(on r: CGRect, from a: CGPoint) -> CGPoint {
        if r.contains(a) { return CGPoint(x: r.midX, y: r.minY + 14) }
        let dx = a.x < r.minX ? r.minX - a.x : a.x > r.maxX ? a.x - r.maxX : 0
        let dy = a.y < r.minY ? r.minY - a.y : a.y > r.maxY ? a.y - r.maxY : 0
        if dy >= dx { return CGPoint(x: min(max(a.x, r.minX + 24), r.maxX - 24), y: a.y < r.minY ? r.minY : r.maxY) }
        return CGPoint(x: a.x < r.minX ? r.minX : r.maxX, y: min(max(a.y, r.minY + 24), r.maxY - 24))
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        Path { p in
            p.move(to: a)
            let vertical = abs(b.y - a.y) >= abs(b.x - a.x)
            if vertical {
                let dy = (b.y - a.y) * 0.55
                p.addCurve(to: b, control1: CGPoint(x: a.x, y: a.y + dy), control2: CGPoint(x: b.x, y: b.y - dy))
            } else {
                let dx = (b.x - a.x) * 0.55
                p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
            }
        }
    }
}
