import AppKit

struct MenuBarVisibility {
    static func accessible(button: NSRect?, screen: NSRect, menuHeight: CGFloat, left: NSRect?, right: NSRect?, visible: Bool) -> Bool {
        guard visible, let button, button.width > 0, button.height > 0,
              screen.contains(button), button.minY >= screen.maxY - menuHeight - 1 else { return false }
        if let left, let right { return left.contains(button) || right.contains(button) }
        return true
    }
    static func fallbackFrame(screen: NSRect, visible: NSRect, safeTop: CGFloat) -> NSRect {
        let top = min(visible.maxY, screen.maxY - safeTop)
        return NSRect(x: max(visible.minX, visible.maxX - 112), y: max(visible.minY, top - 40), width: 104, height: 32)
    }
    var hiddenSamples = 0
    var visibleSamples = 0
    private(set) var showing = false
    mutating func observe(accessible: Bool) -> Bool {
        if accessible {
            hiddenSamples = 0
            visibleSamples += 1
            if visibleSamples >= 3 { showing = false }
        } else {
            visibleSamples = 0
            hiddenSamples += 1
            if hiddenSamples >= 2 { showing = true }
        }
        return showing
    }
}

private final class MenuBarFallbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class MenuBarFallback: NSObject {
    private weak var status: NSStatusItem?
    private var timer: Timer?
    private var visibility = MenuBarVisibility()
    private let panel: NSPanel
    private let button: NSButton
    var menu: (() -> NSMenu)?

    init(status: NSStatusItem) {
        self.status = status
        panel = MenuBarFallbackPanel(contentRect: NSRect(x: 0, y: 0, width: 104, height: 32),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        button = NSButton(title: "Velocity", target: nil, action: nil)
        super.init()
        panel.title = "Velocity — menu bar fallback"
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
        button.frame = background.bounds
        button.autoresizingMask = [.width, .height]
        button.isBordered = false
        button.image = Branding.menuIcon()
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.setAccessibilityLabel("Open Velocity")
        button.toolTip = "Velocity’s menu-bar icon is hidden. Click for search and settings."
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        background.addSubview(button)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer?.tolerance = 0.2
    }

    func update() {
        guard let status, let primary = NSScreen.screens.first else { panel.orderOut(nil); return }
        let statusButton = status.button
        let window = statusButton?.window
        let rect = statusButton.flatMap { button in window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        let screen = rect.flatMap { rect in NSScreen.screens.first { $0.frame.contains(rect) } } ?? primary
        let accessible = MenuBarVisibility.accessible(button: rect, screen: screen.frame,
            menuHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top),
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea,
            visible: status.isVisible && window?.isVisible == true && window?.occlusionState.contains(.visible) == true)
        guard visibility.observe(accessible: accessible) else { panel.orderOut(nil); return }
        button.image = statusButton?.image ?? Branding.menuIcon()
        button.contentTintColor = statusButton?.contentTintColor
        let frame = MenuBarVisibility.fallbackFrame(screen: screen.frame, visible: screen.visibleFrame, safeTop: screen.safeAreaInsets.top)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func clicked() {
        menu?().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }
}
