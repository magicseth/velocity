import ApplicationServices
import Foundation

/// Reduce only the already-filtered results. Never hide a window when its more
/// specific destination is absent, and never merge separate underlying windows.
enum ResultDeduplication {
    static func apply(_ entries: [WindowEntry]) -> [WindowEntry] {
        var nextResults = entries
        let tabs = nextResults.filter { $0.isTab && ($0.terminal || $0.attention.needsAttention) }
        nextResults.removeAll { entry in
            guard !entry.isTab, let key = entry.windowKey else { return false }
            return tabs.contains { tab in
                guard tab.windowKey == key else { return false }
                if tab.attention.needsAttention && tab.attentionTaskTitle == entry.attentionTaskTitle { return true }
                guard tab.terminal && entry.terminal else { return false }
                if terminalTitle(tab.title) == terminalTitle(entry.title) { return true }
                // Window titles add folder/process details that the displayed task
                // label omits. Use the same parser, only within this owning window.
                guard let task = entry.agentTaskTitle, let tabTask = tab.agentTaskTitle else { return false }
                return task == tabTask
            }
        }
        nextResults = removingBrowserWindowDuplicates(nextResults)
        nextResults = removingRepresentedWindows(nextResults)
        return nextResults
    }

    static func terminalTitle(_ title: String) -> String {
        let stripped = title.replacingOccurrences(of: #"\s+—\s+\d+[×x]\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = stripped.components(separatedBy: " — ")
        // Terminal uses a full folder path in its tab label and a basename in
        // the owning window title. Preserve every remaining title component.
        if parts.count > 1, parts[0].hasPrefix("/") || parts[0].hasPrefix("~/") {
            parts[0] = (parts[0] as NSString).lastPathComponent
        }
        return parts.joined(separator: " — ")
    }
    static func removingRepresentedWindows(_ entries: [WindowEntry]) -> [WindowEntry] {
        let destinations = entries.filter { $0.representedWindowTitle != nil }
        return entries.filter { window in
            guard window.windowKey != nil, !window.isTab, window.launchURL == nil else { return true }
            return !destinations.contains { destination in
                guard destination.pid == window.pid,
                      destination.representedWindowTitle == window.title,
                      let parent = destination.element, let element = window.element else { return false }
                return CFEqual(parent, element)
            }
        }
    }

    static func removingBrowserWindowDuplicates(_ entries: [WindowEntry]) -> [WindowEntry] {
        let tabs = entries.filter { $0.browser && $0.isTab && $0.windowKey != nil }
        return entries.filter { window in
            guard window.browser, !window.isTab, let key = window.windowKey else { return true }
            return !tabs.contains { tab in
                tab.windowKey == key && (
                    tab.browserTab?.isActive == true ||
                    (window.audio == .playing && tab.audio == .playing) ||
                    WindowCatalog.browserWindowTitle(window.title, appName: window.appName) == WindowCatalog.browserWindowTitle(tab.title, appName: tab.appName)
                )
            }
        }
    }

}
