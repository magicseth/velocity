import AppKit
import ApplicationServices

/// One open tab (page) in Notion's native tab bar.
struct NotionTab: Equatable, Sendable {
    let title: String
    var key: String { "notion:" + title }
}

/// Reads Notion's tab strip only — never the page body. Notion (Electron) exposes each open
/// tab as an `AXButton` named by its page title inside an `AXWebArea` titled "Tab Bar"; the
/// per-tab close control is a sibling `AXButton` whose description starts "Close Tab,". Page
/// bodies are their own `AXWebArea`s (named by the page) and are skipped entirely, so the walk
/// stays in the small tab-bar subtree instead of the huge document tree.
enum NotionTabs {
    static let appID = "notion.id"

    static func current(window: AXUIElement) -> [(NotionTab, AXUIElement)] {
        let deadline = Date().addingTimeInterval(1)
        var visited = Set<CFHashCode>()
        var tabBar: AXUIElement?
        func findBar(_ node: AXUIElement, depth: Int) {
            guard tabBar == nil, depth < 26, visited.count < 2500, Date() < deadline,
                  visited.insert(CFHash(node)).inserted else { return }
            AXUIElementSetMessagingTimeout(node, 0.05)
            if Accessibility.string(node, kAXRoleAttribute) == "AXWebArea" {
                // The tab bar is the ONE web area named "Tab Bar"; every other web area is a
                // page body — do not descend into document content.
                if Accessibility.string(node, kAXTitleAttribute) == "Tab Bar" { tabBar = node }
                return
            }
            for child in Accessibility.children(node) { findBar(child, depth: depth + 1) }
        }
        findBar(window, depth: 0)
        guard let tabBar else { return [] }
        var result: [(NotionTab, AXUIElement)] = []
        var seen = Set<CFHashCode>()
        func collect(_ node: AXUIElement, depth: Int) {
            guard depth < 14, seen.count < 2000, Date() < deadline, seen.insert(CFHash(node)).inserted else { return }
            if Accessibility.string(node, kAXRoleAttribute) == "AXButton" {
                let name = Accessibility.string(node, kAXTitleAttribute)
                let desc = Accessibility.string(node, kAXDescriptionAttribute)
                // A tab is a named button; the sidebar/nav controls carry a description and no
                // name, and the close control's description starts "Close Tab,".
                if !name.isEmpty, !desc.hasPrefix("Close Tab") {
                    result.append((NotionTab(title: name), node))
                    return   // the tab's own glyph/favicon children are not more tabs
                }
            }
            for child in Accessibility.children(node) { collect(child, depth: depth + 1) }
        }
        collect(tabBar, depth: 0)
        // Two tabs with the same title can't be told apart — omit rather than jump to the wrong one.
        let counts = Dictionary(grouping: result, by: { $0.0.key }).mapValues(\.count)
        return result.filter { counts[$0.0.key] == 1 }
    }

    static func scan(window: AXUIElement, app: NSRunningApplication) -> [WindowEntry] {
        guard app.bundleIdentifier == appID else { return [] }
        let tabs = current(window: window)
        // One tab is just the window the generic scan already produced — nothing to add.
        guard tabs.count > 1 else { return [] }
        let windowTitle = Accessibility.string(window, kAXTitleAttribute)
        return tabs.map { tab, _ in
            WindowEntry(id: "\(app.processIdentifier):notiontab:\(CFHash(window)):\(tab.key)",
                        pid: app.processIdentifier, appName: app.localizedName ?? "Notion", title: tab.title,
                        icon: app.icon, element: window,
                        minimized: Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                        hidden: app.isHidden, terminal: false, notionTab: tab,
                        representedWindowTitle: tab.title == windowTitle && !windowTitle.isEmpty ? windowTitle : nil)
        }
    }

    @MainActor static func select(_ tab: NotionTab, window: AXUIElement) -> Bool {
        let matches = current(window: window).filter { $0.0 == tab }
        guard matches.count == 1 else { return false }
        let node = matches[0].1
        var pid: pid_t = 0
        AXUIElementGetPid(node, &pid)
        // Press the tab button; the button carries its own press action, so no hit-test is needed.
        if AXUIElementPerformAction(node, kAXPressAction as CFString) == .success { return true }
        // Fallback: a real click at its center, only while Notion is foreground and on screen.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let frame = Accessibility.frame(node) else { return false }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
        return true
    }
}
