import AppKit
import ApplicationServices

/// Activation and tab selection are deliberately separate from catalog scans.
extension WindowCatalog {
    static func liveTab(for entry: WindowEntry) -> AXUIElement? {
        guard let original = entry.tab, let window = entry.element else { return nil }
        let candidates = tabs(in: window)
        if let same = candidates.first(where: { CFEqual($0.0, original) }) { return same.0 }
        // Rebuilt tab controls are safe to resolve only by a unique title.
        func normalized(_ title: String) -> String {
            title.replacingOccurrences(of: #"\[\s*[!.]\s*\]"#, with: "[!]", options: .regularExpression)
        }
        let matches = candidates.filter { normalized($0.1) == normalized(entry.title) }
        return matches.count == 1 ? matches[0].0 : nil
    }

    static func tabIsSelected(_ tab: AXUIElement) -> Bool? {
        if let value = Accessibility.attribute(tab, "AXSelected") as? NSNumber { return value.boolValue }
        if let value = Accessibility.attribute(tab, kAXValueAttribute) as? NSNumber { return value.boolValue }
        return nil
    }

    @MainActor static func selectFocusedTab(_ entry: WindowEntry) async -> Bool {
        // Browser scripting has already selected its stable tab ID.
        if let browserTab = entry.browserTab { return await BrowserTabs.select(browserTab) }
        guard entry.tab != nil else { return true }
        guard let tab = liveTab(for: entry) else { return false }
        if tabIsSelected(tab) == true { return true }
        let pressed = AXUIElementPerformAction(tab, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(60))
        if tabIsSelected(tab) == true { return true }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
        // Terminal may expose a selectable radio button instead of a pressable tab.
        let setValue = AXUIElementSetAttributeValue(tab, kAXValueAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(60))
        if let selected = tabIsSelected(tab) { return selected }
        return pressed == .success || setValue == .success
    }

    @MainActor static func focus(_ entry: WindowEntry) async -> Bool {
        guard entry.cachedTerminal == nil else { return false }
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        if let browserTab = entry.browserTab {
            // Scripting owns the exact browser destination. AX windows from the
            // scan may have been recreated or associated with another tab; never
            // raise those cached windows after selecting a stable browser ID.
            guard await BrowserTabs.select(browserTab) else { return false }
            app.unhide()
            // ONE BROWSER WINDOW: the tab is selected and its window ordered front inside the
            // browser; the window server then puts that window — the browser's topmost — in
            // front alone. Activating the app instead brought every browser window along.
            if let wid = WindowRaise.topWindowID(pid: entry.pid), WindowRaise.front(pid: entry.pid, windowID: wid) {
                for _ in 0..<12 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { WindowRaise.glow(windowID: wid, tint: WindowRaise.currentTint); JuliaLog.note("focus: one browser window via window server"); return true }
            }
            JuliaLog.note("focus: browser window server raise not honoured; activating the app")
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
                if NSApp.isActive {
                    NSApp.yieldActivation(to: app)
                    guard app.activate(from: .current, options: []) else { return false }
                } else {
                    guard app.activate(options: []) else { return false }
                }
            }
            return true
        }
        if app.isHidden { app.unhide() }
        // Only when it IS minimized: writing the attribute to an unminimized window made
        // Terminal order every window forward (measured).
        if let window = entry.element, entry.minimized {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if result == .invalidUIElement { return false }
        }
        // ONE WINDOW, NOT THE APP ("i double clicked on docs, and it foregrounded way too
        // many windows"): the window server puts exactly this window in front. The app
        // activation below stays as the fallback.
        if let window = entry.element, let wid = WindowRaise.windowID(of: window), WindowRaise.front(pid: entry.pid, windowID: wid, element: window) {
            for _ in 0..<12 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid {
                if entry.tab != nil { _ = await WindowCatalog.selectFocusedTab(entry) }
                WindowRaise.glow(windowID: wid, tint: WindowRaise.currentTint)
                JuliaLog.note("focus: one window via window server — \(entry.appName) “\(entry.title.prefix(30))”")
                return true
            }
            JuliaLog.note("focus: window server raise not honoured for \(entry.appName); activating the app")
        } else {
            JuliaLog.note("focus: no window id for \(entry.appName) “\(entry.title.prefix(30))” (element=\(entry.element != nil)); activating the app")
        }
        // Keep our palette active until macOS accepts the handoff. Hiding our
        // last window first can give activation to Finder instead.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
            let activated: Bool
            if NSApp.isActive {
                NSApp.yieldActivation(to: app)
                activated = app.activate(from: .current, options: [])
            } else {
                activated = app.activate(options: [])
            }
            guard activated else { return false }
        }
        guard let window = entry.element else { return true }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        // Some apps restore their previously focused window during activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return raised == .success
    }
}
