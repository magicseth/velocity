import AppKit

struct ClosedTab: Codable, Identifiable {
    var id = UUID()
    let title: String
    let url: String
    let profile: String?
    let windowID: Int
    let pid: pid_t
    let launch: Date
    let closed: Date

    var entry: WindowEntry {
        var result = WindowEntry(id: "closed:\(id)", pid: pid, appName: "Google Chrome", title: title,
            icon: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome").map { NSWorkspace.shared.icon(forFile: $0.path) },
            element: nil, minimized: false, hidden: false, terminal: false,
            browser: true, browserProfile: profile)
        result.closedTab = self
        return result
    }
    var reopenSource: String {
        """
        with timeout of 5 seconds
            tell application id "com.google.Chrome"
                repeat with w in windows
                    if (id of w as integer) is \(windowID) and mode of w is "normal" then
                        make new tab at end of tabs of w with properties {URL:\(BrowserTabs.quote(url))}
                        set active tab index of w to count of tabs of w
                        set minimized of w to false
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
                return false
            end tell
        end timeout
        """
    }
    func reopen() -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "com.google.Chrome",
              app.launchDate == launch, ClosedTabs.validURL(url) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: reopenSource)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}

/// Bounded local history of observed closures, never browser history ingestion.
@MainActor final class ClosedTabs {
    private(set) var records: [ClosedTab] = []
    private var previous: [Int: WindowEntry] = [:]
    private var missing: Set<Int> = []
    private var epoch: Date?
    private let file: URL?
    init(file: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Velocity/ClosedTabs/history.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([ClosedTab].self, from: data) {
            records = Self.deduplicated(saved).filter { Self.validURL($0.url) && Date().timeIntervalSince($0.closed) < 7 * 86400 }.prefix(100).map { $0 }
            persist()
        }
    }
    // A known profile plus exact URL is a destination, regardless of window or browser restart.
    // Unknown profiles stay window-scoped rather than conflating separate accounts.
    nonisolated static func destinationKey(url: String, profile: String?, pid: pid_t, windowID: Int, launch: Date) -> String {
        let scope = profile.flatMap { $0.isEmpty || $0 == "Profile unavailable" ? nil : $0 }
            ?? "unknown:\(pid):\(windowID):\(launch.timeIntervalSince1970)"
        return scope + "\n" + url
    }
    nonisolated static func deduplicated(_ records: [ClosedTab]) -> [ClosedTab] {
        var seen = Set<String>()
        return records.sorted { $0.closed > $1.closed }.filter {
            seen.insert(destinationKey(url: $0.url, profile: $0.profile, pid: $0.pid, windowID: $0.windowID, launch: $0.launch)).inserted
        }
    }
    func entries(excludingOpen entries: [WindowEntry], showOpenHistory: Bool = false) -> [WindowEntry] {
        if showOpenHistory { return Self.deduplicated(records).map(\.entry) }
        return Self.deduplicated(records).filter { closed in
            !entries.contains { entry in
                guard let tab = entry.browserTab, tab.browserID == "com.google.Chrome",
                      let profile = closed.profile, !profile.isEmpty, profile != "Profile unavailable" else { return false }
                return tab.url == closed.url && entry.browserProfile == profile
            }
        }.map(\.entry)
    }
    nonisolated static func validURL(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), ["https", "http"].contains(url.scheme),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
    func observe(_ entries: [WindowEntry], complete: Bool, launch: Date?, now: Date = Date()) {
        guard complete, let launch else { previous = [:]; missing = []; epoch = nil; return }
        if epoch != launch { previous = [:]; missing = []; epoch = launch }
        let eligible = entries.filter { $0.browserTab?.browserID == "com.google.Chrome" && $0.browserTab?.historyEligible == true }
        var current: [Int: WindowEntry] = [:]
        for entry in eligible { if let tab = entry.browserTab { current[tab.tabID] = entry } }
        let disappeared = Set(previous.keys).subtracting(current.keys)
        // Confirm absence twice; a failed scan resets the baseline entirely.
        for id in disappeared.intersection(missing) {
            guard let entry = previous[id], let tab = entry.browserTab, Self.validURL(tab.url) else { continue }
            records.removeAll { $0.url == tab.url && $0.windowID == tab.windowID && $0.launch == launch }
            records.insert(ClosedTab(title: tab.title, url: tab.url, profile: entry.browserProfile,
                windowID: tab.windowID, pid: entry.pid, launch: launch, closed: now), at: 0)
        }
        let pending = disappeared.subtracting(missing)
        for id in pending { current[id] = previous[id] }
        previous = current; missing = pending
        records = Array(Self.deduplicated(records).filter { now.timeIntervalSince($0.closed) < 7 * 86400 }.prefix(100))
        persist()
    }
    func remove(_ id: UUID) { records.removeAll { $0.id == id }; persist() }
    func clear() { records = []; previous = [:]; missing = []; persist() }
    private func persist() {
        guard let file, let data = try? JSONEncoder().encode(records) else { return }
        let dir = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? Data(contentsOf: file)) == data { return }
            try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Session history remains usable if local persistence is unavailable. */ }
    }
}
