import AppKit
import ApplicationServices

extension WindowEntry {
    var canClose: Bool { cachedTerminal == nil && closedTab == nil && launchURL == nil && chatProject == nil && conversation == nil }
    var closeLabel: String { isTab ? "Close tab" : element != nil ? "Close window" : "Quit app" }
}

@MainActor enum CloseResult {
    static func close(_ entry: WindowEntry) async -> Bool {
        guard entry.canClose, let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return false }
        if let tab = entry.browserTab { return BrowserTabs.close(tab) }
        guard let window = entry.element else { return app.terminate() }
        if let tab = entry.tab {
            // Only close the exact current control, never substitute a whole-window close.
            guard let live = WindowCatalog.liveTab(for: entry), CFEqual(live, tab) else { return false }
            if pressCloseControl(live) { return true }
            guard await WindowCatalog.focus(entry) else { return false }
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard await WindowCatalog.selectFocusedTab(entry), WindowCatalog.tabIsSelected(live) == true else { return false }
            let axApp = AXUIElementCreateApplication(entry.pid)
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid,
                  let focused = Accessibility.attribute(axApp, kAXFocusedWindowAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window),
                  let raw = Accessibility.attribute(axApp, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            // Invoke the app's ordinary Command-W menu action. Native unsaved-work
            // and running-process prompts are left for the user to answer.
            let menu = unsafeBitCast(raw, to: AXUIElement.self)
            guard let closeItem = closeMenuItem(menu, depth: 0),
                  WindowCatalog.tabIsSelected(live) == true,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else { return false }
            return AXUIElementPerformAction(closeItem, kAXPressAction as CFString) == .success
        }
        guard await WindowCatalog.focus(entry) else { return false }
        return pressCloseControl(window)
    }

    static func pressCloseControl(_ element: AXUIElement) -> Bool {
        if let raw = Accessibility.attribute(element, kAXCloseButtonAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            return AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString) == .success
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success, (actions as? [String])?.contains("AXClose") == true {
            return AXUIElementPerformAction(element, "AXClose" as CFString) == .success
        }
        let children = Accessibility.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        for child in children.prefix(30) {
            if Accessibility.attribute(child, kAXSubroleAttribute) as? String == kAXCloseButtonSubrole {
                return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    static func closeMenuItem(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 5 else { return nil }
        if (Accessibility.attribute(element, "AXMenuItemCmdChar") as? String)?.lowercased() == "w",
           (Accessibility.attribute(element, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue == 0,
           (Accessibility.attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true { return element }
        for child in (Accessibility.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(100) {
            if let found = closeMenuItem(child, depth: depth + 1) { return found }
        }
        return nil
    }
}
