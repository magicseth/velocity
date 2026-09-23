import AppKit
import ApplicationServices

/// Searchable metadata only: never terminal output or serialized Accessibility handles.
struct CachedTerminal: Codable {
    let id: String
    let pid: pid_t
    let bundleID: String
    let launch: Date
    let appName: String
    let title: String
    let windowTitle: String
    let tabTitle: String?
    let documentPath: String?
    let saved: Date

    func isCurrent(bundleID: String?, launch: Date?, now: Date = Date()) -> Bool {
        self.bundleID == bundleID && self.launch == launch && now.timeIntervalSince(saved) < 86400
    }
    func entry() -> WindowEntry? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              isCurrent(bundleID: app.bundleIdentifier, launch: app.launchDate) else { return nil }
        var result = WindowEntry(id: "cached:" + id, pid: pid, appName: appName, title: title,
            icon: app.icon, element: nil, minimized: false, hidden: app.isHidden, terminal: true, documentPath: documentPath)
        result.cachedTerminal = self
        return result
    }
    /// Resolve only an unambiguous destination in the original terminal process.
    func resolve() -> WindowEntry? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              isCurrent(bundleID: app.bundleIdentifier, launch: app.launchDate) else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        let windows = Accessibility.attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches = windows.filter { Accessibility.string($0, kAXTitleAttribute) == windowTitle }
        guard matches.count == 1, let window = matches.first else { return nil }
        var tab: AXUIElement?
        if let tabTitle {
            let tabs = WindowCatalog.tabs(in: window).filter { $0.1 == tabTitle }
            guard tabs.count == 1 else { return nil }
            tab = tabs[0].0
        }
        return WindowEntry(id: id, pid: pid, appName: appName, title: title, icon: app.icon,
            element: window, minimized: Accessibility.attribute(window, kAXMinimizedAttribute) as? Bool ?? false,
            hidden: app.isHidden, terminal: true, tab: tab, documentPath: documentPath)
    }
}
struct TerminalCache {
    let file: URL
    init(file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Velocity/TerminalCache/windows.json")) { self.file = file }
    func load() -> [WindowEntry] {
        guard let data = try? Data(contentsOf: file), let records = try? JSONDecoder().decode([CachedTerminal].self, from: data) else { return [] }
        return records.prefix(500).compactMap { $0.entry() }
    }
    func save(_ entries: [WindowEntry]) {
        let records = ResultDeduplication.apply(entries).filter { $0.terminal && $0.element != nil && $0.cachedTerminal == nil }.prefix(500).compactMap { entry -> CachedTerminal? in
            guard let app = NSRunningApplication(processIdentifier: entry.pid), let bundle = app.bundleIdentifier,
                  let launch = app.launchDate, let window = entry.element else { return nil }
            return CachedTerminal(id: entry.id, pid: entry.pid, bundleID: bundle, launch: launch,
                appName: entry.appName, title: entry.title, windowTitle: Accessibility.string(window, kAXTitleAttribute),
                tabTitle: entry.tab == nil ? nil : entry.title, documentPath: entry.documentPath, saved: Date())
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Discovery continues if the local cache cannot be saved. */ }
    }
}
