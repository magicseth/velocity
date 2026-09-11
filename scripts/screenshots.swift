// Render the shipping SwiftUI views with fictional data; no window scan or AI requests.
import AppKit
import SwiftUI
import ApplicationServices

@main struct Screenshots {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let model = PaletteModel()
        model.trusted = true
        model.browserTabsEnabled = true
        model.groups = []
        func entry(_ id: Int32, _ name: String, _ title: String, _ bundle: String, terminal: Bool = false) -> WindowEntry {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
            return WindowEntry(id: "sample-\(id)", pid: id, appName: name, title: title, icon: icon,
                element: AXUIElementCreateApplication(id), minimized: false, hidden: false, terminal: terminal)
        }
        var agent = entry(100001, "Terminal", "[ ! ] Action Required | Ship the new checkout — codex", "com.apple.Terminal", terminal: true)
        agent.tab = AXUIElementCreateApplication(200001)
        var music = entry(100002, "Google Chrome", "Late night coding — Focus playlist", "com.google.Chrome")
        music.browser = true
        music.browserProfile = "Personal"
        music.audio = .playing
        music.browserTab = BrowserTab(browserID: "com.google.Chrome", windowID: 1, tabID: 1, title: music.title,
            url: "https://www.youtube.com/watch?v=sample", minimized: false, windowTitle: music.title, index: 1)
        let code = entry(100003, "TextEdit", "Release notes — storefront", "com.apple.TextEdit")
        var docs = entry(100004, "Safari", "Convex Docs — Realtime apps", "com.apple.Safari")
        docs.browser = true
        docs.browserTab = BrowserTab(browserID: "com.apple.Safari", windowID: 2, tabID: 1, title: docs.title,
            url: "https://docs.convex.dev", minimized: false, windowTitle: docs.title, index: 1)
        let design = entry(100005, "Notes", "Launch checklist", "com.apple.Notes")
        let worker = entry(100006, "Terminal", "◐ Polish the landing page — claude", "com.apple.Terminal", terminal: true)
        model.all = [agent, music, code, docs, design]
        model.openAllApps()

        func render(_ name: String) throws {
            let view = NSHostingView(rootView: PaletteView(model: model).environment(\.colorScheme, .light))
            view.frame = NSRect(x: 0, y: 0, width: 680, height: 510)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1360, pixelsHigh: 1020,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/screenshots/\(name).png"))
            window.orderOut(nil)
        }
        try render("window-switcher")
        let backend = entry(100007, "Terminal", "◐ Add realtime inventory — claude", "com.apple.Terminal", terminal: true)
        model.all += [worker, backend]
        model.groups = [
            WindowGroup(id: UUID(), name: "Ship the new checkout", members: Set([agent.windowKey!, code.windowKey!])),
            WindowGroup(id: UUID(), name: "Polish the landing page", members: Set([worker.windowKey!, design.windowKey!])),
            WindowGroup(id: UUID(), name: "Add realtime inventory", members: Set([backend.windowKey!, docs.windowKey!]))
        ]
        model.objectiveMode = true
        model.focusObjectives = true
        if Features.experimentalAgents { try render("objectives") }
    }
}
