import AppKit
import ApplicationServices

/// Notification-owned routing survives Velocity restarts, but not terminal
/// process replacement. Never resolve a destination by title across windows.
struct AttentionDestination: Codable {
    let pid: pid_t
    let launch: Date
    let entryID: String
    let windowKey: String
    let task: String
    /// The terminal device the conversation's agent is attached to ("ttys001") — the one
    /// identity that survives title changes and tells two tabs in one folder apart.
    /// Optional so handles minted before it decode unchanged.
    var tty: String? = nil

    init?(entry: WindowEntry, launch: Date, tty: String? = nil) {
        guard entry.terminal, let key = entry.windowKey else { return nil }
        self.pid = entry.pid; self.launch = launch; entryID = entry.id
        windowKey = key; task = entry.attentionTaskTitle; self.tty = tty
    }

    func resolve(_ entries: [WindowEntry], launch: Date) -> WindowEntry? {
        guard launch == self.launch else { return nil }
        let matches = entries.filter {
            $0.pid == pid && $0.windowKey == windowKey && $0.attentionTaskTitle == task
        }
        let exact = matches.filter { $0.id == entryID }
        if exact.count == 1 { return exact[0] }
        let tabs = matches.filter(\.isTab)
        if tabs.count == 1 { return tabs[0] }
        return matches.count == 1 ? matches[0] : nil
    }

    func liveEntry() -> WindowEntry? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.launchDate == launch,
              WindowCatalog.terminalIDs.contains(app.bundleIdentifier ?? "") else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windows = Accessibility.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows where "\(pid):\(CFHash(window))" == windowKey {
            AXUIElementSetMessagingTimeout(window, 0.2)
            func entry(_ id: String, _ title: String, _ tab: AXUIElement? = nil) -> WindowEntry {
                WindowEntry(id: id, pid: pid, appName: app.localizedName ?? "Terminal", title: title,
                    icon: nil, element: window,
                    minimized: Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
                    hidden: app.isHidden, terminal: true, tab: tab)
            }
            let windowID = "\(pid):window:\(CFHash(window))"
            var entries = [entry(windowID, Accessibility.string(window, kAXTitleAttribute))]
            entries += WindowCatalog.tabs(in: window).map {
                entry(windowID + ":tab:\(CFHash($0.0))", $0.1, $0.0)
            }
            return resolve(entries, launch: launch)
        }
        return nil
    }
}
