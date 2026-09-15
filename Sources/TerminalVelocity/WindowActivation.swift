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
        if let browserTab = entry.browserTab { return BrowserTabs.select(browserTab) }
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

    @MainActor static func focus(_ entry: WindowEntry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        if let browserTab = entry.browserTab {
            // Scripting owns the exact browser destination. AX windows from the
            // scan may have been recreated or associated with another tab; never
            // raise those cached windows after selecting a stable browser ID.
            app.unhide()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != entry.pid {
                if NSApp.isActive {
                    NSApp.yieldActivation(to: app)
                    guard app.activate(from: .current, options: []) else { return false }
                } else {
                    guard app.activate(options: []) else { return false }
                }
            }
            return BrowserTabs.select(browserTab)
        }
        app.unhide()
        if let window = entry.element {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if result == .invalidUIElement { return false }
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
