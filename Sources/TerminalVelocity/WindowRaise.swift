import AppKit
import ApplicationServices
import Darwin

/// RAISE ONE WINDOW, NOT THE WHOLE APP. Activating an app through Launch Services (the
/// one request macOS honours from the background) behaves like a Dock click: every window
/// of the app comes forward — "i don't like that open foregrounds the entire terminal app".
/// The window server can put a single window in front and make its app active, the way
/// window switchers do; that is what this does, with the Launch Services path kept as the
/// fallback when the private call is unavailable. And a GLOW around what came forward,
/// so the eye lands on it.
enum WindowRaise {
    private typealias SetFront = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let setFront: SetFront? = skylight.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }.map { unsafeBitCast($0, to: SetFront.self) }
    private static let getPSN: GetPSN? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetPSN.self) }
    private static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindow.self) }
    private typealias PostEvent = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private static let postEvent: PostEvent? = skylight.flatMap { dlsym($0, "SLPSPostEventRecordTo") }.map { unsafeBitCast($0, to: PostEvent.self) }
    private static let userGenerated: UInt32 = 0x200

    /// The two synthetic "make this window key" records window switchers post after
    /// SetFrontProcess: without them the window rises in its app's stack but the app
    /// never becomes active (measured: z-order "C T C C" with Chrome still frontmost).
    private static func makeKey(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID) {
        guard let postEvent else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var w = wid
        withUnsafeBytes(of: &w) { raw in for i in 0..<4 { bytes[0x3c + i] = raw[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        _ = bytes.withUnsafeMutableBufferPointer { postEvent(&psn, $0.baseAddress!) }
    }

    static var available: Bool { setFront != nil && getPSN != nil }
    /// The colour the next glows use (set per act by JuliaLink from the URL).
    static var currentTint: NSColor = .white

    /// The app's topmost on-screen window (front-to-back order from the window server).
    static func topWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) == 0 {
            if let id = w[kCGWindowNumber as String] as? CGWindowID { return id }
        }
        return nil
    }

    /// The window server's id for an accessibility window.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Bring exactly this window to the front and make its app active. True when the
    /// window server took it; the caller verifies (frontmost app) and falls back.
    @discardableResult
    static func front(pid: pid_t, windowID: CGWindowID, element: AXUIElement? = nil) -> Bool {
        guard let setFront, let getPSN else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        guard setFront(&psn, windowID, userGenerated) == .success else { return false }
        makeKey(&psn, windowID)
        // No accessibility raise here: kAXRaise on a window of a not-yet-active app made
        // Terminal bring EVERY window forward (measured: z-order T T T T after the call, T C
        // C C without it). The window server already put this one in front; making it the
        // app's main window is done after activation, by the caller, if it needs a tab.
        _ = element   // deliberately untouched here (see above)
        return true
    }

    /// The window's on-screen frame (Cocoa coordinates), from the window server.
    static func frame(of windowID: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first, let b = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 0, h > 0,
              let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(x: x, y: screenHeight - y - h, width: w, height: h)
    }

    // MARK: glow

    private static var glows: [GlowPanel] = []

    /// A soft ring in the project's colour around the window, fading over a second.
    @MainActor static func glow(windowID: CGWindowID, tint: NSColor) {
        guard let frame = frame(of: windowID) else { return }
        let panel = GlowPanel(around: frame, tint: tint)
        glows.append(panel)
        panel.orderFrontRegardless()
        panel.fadeOut { [weak panel] in
            glows.removeAll { $0 === panel }
        }
    }

    final class GlowPanel: NSPanel {
        init(around frame: NSRect, tint: NSColor) {
            let inset: CGFloat = -10
            super.init(contentRect: frame.insetBy(dx: inset, dy: inset), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false; backgroundColor = .clear; hasShadow = false
            level = .screenSaver          // above everything, briefly
            ignoresMouseEvents = true
            collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            contentView = GlowView(tint: tint)
            alphaValue = 0
        }
        func fadeOut(done: @escaping () -> Void) {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; self.animator().alphaValue = 1 }) {
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 1.1; self.animator().alphaValue = 0 }) {
                    self.orderOut(nil); done()
                }
            }
        }
    }

    final class GlowView: NSView {
        let tint: NSColor
        init(tint: NSColor) { self.tint = tint; super.init(frame: .zero); wantsLayer = true }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
            // Three rings, wide and faint to narrow and bright: a glow, not a border.
            for (width, alpha) in [(CGFloat(12), 0.18), (CGFloat(6), 0.35), (CGFloat(2.5), 0.95)] {
                tint.withAlphaComponent(alpha).setStroke()
                path.lineWidth = width
                path.stroke()
            }
        }
    }
}
