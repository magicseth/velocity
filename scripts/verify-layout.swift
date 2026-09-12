// Exercise the real palette with 400 fictional results and repeated list changes.
// Compile alongside Sources/TerminalVelocity/*.swift, excluding App.swift.
import AppKit
import SwiftUI

@main struct LayoutCheck {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let model = PaletteModel()
        model.trusted = true; model.browserTabsEnabled = true; model.groups = []
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome").map { NSWorkspace.shared.icon(forFile: $0.path) }
        model.all = (0..<400).map { index in
            var entry = WindowEntry(id: "fixture-\(index)", pid: 1, appName: "Google Chrome",
                title: String(format: "Task %03d — A browser tab with a long title to exercise truncation", index),
                icon: icon, element: nil, minimized: false, hidden: false, terminal: false)
            entry.browser = true
            entry.browserProfile = index % 2 == 0 ? "Work" : "Personal"
            entry.browserProfileIcon = index % 3 == 0 ? icon : nil
            entry.browserTab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: index + 1,
                title: entry.title, url: "https://example.com/task/\(index)", minimized: false, windowTitle: entry.title, index: index + 1)
            return entry
        }
        model.openAllApps()
        let view = NSHostingView(rootView: PaletteView(model: model).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 510)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func capture(_ name: String) throws {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            view.layoutSubtreeIfNeeded()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1360, pixelsHigh: 1020, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            let path = "/private/tmp/velocity-layout-\(name).png"
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
            print("\(name): \(model.results.count) rows, selected \(model.selected), \(path)")
        }
        try capture("initial")
        model.move(8)
        try capture("ninth")
        model.query = "Task 0"
        model.all.reverse()
        model.filter(preserveSelection: true)
        try capture("filtered")
        model.query = ""
        model.move(200)
        model.all.reverse()
        model.filter(preserveSelection: true)
        try capture("refreshed")
        window.orderOut(nil)
    }
}
