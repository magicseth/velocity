import AppKit
import ApplicationServices

/// Revalidate live handles at the dispatch boundary, not just a cached title from
/// the catalog. Browser URL/title checks execute inside the selection/close script.
enum ResourceTarget {
    static func isCurrent(_ entry: WindowEntry) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated,
              let window = entry.element else { return false }
        if let tab = entry.browserTab { return app.bundleIdentifier == tab.browserID }
        let axApp = AXUIElementCreateApplication(entry.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        AXUIElementSetMessagingTimeout(window, 0.2)
        guard let windows = Accessibility.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { CFEqual($0, window) }) else { return false }
        // These adapters re-resolve an exact unique destination when opening it.
        if let conversation = entry.conversation { return app.bundleIdentifier == conversation.appID }
        if let project = entry.chatProject {
            return app.bundleIdentifier == (project.mode == "Workspace" ? ConductorWorkspaces.bundleID : ChatProjects.claudeID)
        }
        if let tab = entry.tab {
            guard let live = WindowCatalog.liveTab(for: entry), CFEqual(tab, live) else { return false }
            return Accessibility.label(live) == entry.title
        }
        return Accessibility.string(window, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines) == entry.title &&
            WindowCatalog.documentPath(window) == entry.documentPath
    }
}
