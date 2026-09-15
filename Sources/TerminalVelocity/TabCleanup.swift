import AppKit
import SwiftUI
import CryptoKit

struct CleanupCandidate: Identifiable {
    let entry: WindowEntry
    let duplicate: Bool
    var id: String { entry.id }
}

/// Activity is observed locally, not imported from browser history. Hashes avoid
/// persisting a browsing log. Navigation starts a new observation record.
final class TabActivity {
    struct Record: Codable { var used: Double; var seen: Double }
    let defaults: UserDefaults
    var records: [String: Record]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: "tabCleanupActivity").flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    static func key(_ tab: BrowserTab) -> String {
        let identity = "\(tab.browserID):\(tab.windowID):\(tab.tabID):\(tab.url)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func observe(_ tabs: [BrowserTab], now: Double = Date().timeIntervalSince1970) {
        for tab in tabs {
            let key = Self.key(tab)
            var record = records[key] ?? Record(used: now, seen: now)
            if tab.isActive { record.used = now }
            record.seen = now
            records[key] = record
        }
        records = records.filter { now - $0.value.seen < 90 * 86400 }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "tabCleanupActivity") }
    }
    func old(_ tab: BrowserTab, days: Int, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let record = records[Self.key(tab)], now - record.seen <= 300 else { return false }
        return now - record.used >= Double(days) * 86400
    }
}

enum TabCleanup {
    static func metadataEligible(_ tab: BrowserTab, audio: AudioBadge, hasAX: Bool, pinned: Bool) -> Bool {
        guard let url = URL(string: tab.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil,
              !tab.isActive, !tab.loading, audio == .none, hasAX, !pinned else { return false }
        return true
    }
    static func eligible(_ entry: WindowEntry) -> Bool {
        guard let tab = entry.browserTab else { return false }
        return metadataEligible(tab, audio: entry.audio, hasAX: entry.tab != nil, pinned: entry.browserPinned)
    }

    static func duplicateIDs(_ entries: [WindowEntry], isEligible: (WindowEntry) -> Bool = eligible) -> Set<String> {
        let groups = Dictionary(grouping: entries.filter { $0.browserTab != nil }) { entry in
            let tab = entry.browserTab!
            // Same window means no accidental merging across browser profiles.
            return "\(tab.browserID):\(tab.windowID):\(tab.url)"
        }
        var result: Set<String> = []
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted {
                if isEligible($0) != isEligible($1) { return !isEligible($0) }
                return $0.browserTab!.index < $1.browserTab!.index
            }
            for entry in ordered.dropFirst() where isEligible(entry) { result.insert(entry.id) }
        }
        return result
    }
    static func candidates(_ entries: [WindowEntry], activity: TabActivity, days: Int) -> [CleanupCandidate] {
        let duplicates = duplicateIDs(entries)
        return entries.compactMap { entry in
            guard let tab = entry.browserTab, eligible(entry) else { return nil }
            if duplicates.contains(entry.id) { return CleanupCandidate(entry: entry, duplicate: true) }
            if activity.old(tab, days: days) { return CleanupCandidate(entry: entry, duplicate: false) }
            return nil
        }.sorted { lhs, rhs in
            if lhs.duplicate != rhs.duplicate { return lhs.duplicate }
            return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
        }
    }

    /// Identity and selected-tab checks execute in the browser immediately before
    /// closing. A duplicate close also requires another copy in that same window.
    static func closeSource(_ tab: BrowserTab, duplicate: Bool) -> String {
        let chrome = tab.browserID == "com.google.Chrome"
        let target = chrome ? "id of t as integer" : "n"
        let title = chrome ? "title" : "name"
        return """
        with timeout of 5 seconds
            tell application id "\(tab.browserID)"
                set w to window id \(tab.windowID)
                set wantedURL to \(BrowserTabs.quote(tab.url))
                set wantedTitle to \(BrowserTabs.quote(tab.title))
                set chosen to 0
                set copies to 0
                repeat with n from 1 to count of tabs of w
                    set t to tab n of w
                    if URL of t is wantedURL then set copies to copies + 1
                    if (\(target)) is \(tab.tabID) and URL of t is wantedURL and \(title) of t is wantedTitle then set chosen to n
                end repeat
                if chosen is 0 then return false
                \(duplicate ? "if copies < 2 then return false" : "")
                if chosen is (\(chrome ? "active tab index" : "index of current tab") of w) then return false
                \(chrome ? "if loading of tab chosen of w then return false" : "")
                close tab chosen of w
                return true
            end tell
        end timeout
        """
    }
    static func close(_ tab: BrowserTab, duplicate: Bool) -> Bool {
        guard BrowserTabs.supported.contains(tab.browserID) else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: closeSource(tab, duplicate: duplicate))?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}

@MainActor final class TabCleanupModel: ObservableObject {
    struct Closed: Codable, Identifiable {
        var id = UUID()
        let title: String
        let url: String
        let browserID: String
    }
    let activity = TabActivity()
    @Published var entries: [WindowEntry] = []
    @Published var selected: Set<String> = []
    @Published var days = 30
    @Published var busy = false
    @Published var message: String?
    @Published var closed: [Closed] = []
    var apply: (([CleanupCandidate]) -> Void)?
    init() {
        closed = UserDefaults.standard.data(forKey: "cleanupClosedTabs").flatMap { try? JSONDecoder().decode([Closed].self, from: $0) } ?? []
    }
    var candidates: [CleanupCandidate] { TabCleanup.candidates(entries, activity: activity, days: days) }
    func observe(_ entries: [WindowEntry]) {
        let previous = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        activity.observe(entries.compactMap(\.browserTab))
        self.entries = entries
        selected = Set(candidates.filter { candidate in
            guard selected.contains(candidate.id), let old = previous[candidate.id] else { return false }
            return old.entry.browserTab?.url == candidate.entry.browserTab?.url && old.entry.browserTab?.title == candidate.entry.browserTab?.title && old.duplicate == candidate.duplicate
        }.map(\.id))
    }
    func saveClosed() {
        closed = Array(closed.prefix(100))
        if let data = try? JSONEncoder().encode(closed) { UserDefaults.standard.set(data, forKey: "cleanupClosedTabs") }
    }
    func reopen(_ item: Closed) {
        guard let url = URL(string: item.url), ["https", "http"].contains(url.scheme ?? ""),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.browserID) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        // Retain recovery entries: browser may have refused the request.
    }
}

struct TabCleanupView: View {
    @ObservedObject var model: PaletteModel
    @ObservedObject var cleanup: TabCleanupModel
    @State private var history = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Clean up tabs", systemImage: "rectangle.stack.badge.minus").font(.title2.bold())
                Spacer()
                Button("Back") { model.showCleanup = false }.disabled(cleanup.busy)
            }
            Text("Exact URLs, within each browser window. No extension or tab rearranging.").foregroundStyle(.secondary)
            HStack {
                Picker("Not seen active for", selection: $cleanup.days) {
                    ForEach([7, 14, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
                }.frame(width: 240)
                Spacer()
                Button(history ? "Review tabs" : "Recently closed") { history.toggle() }.disabled(cleanup.busy)
                Button("Refresh") { model.refresh?() }.disabled(cleanup.busy || model.loading)
            }
            if history {
                Text("Reopen restores the URL, not unsaved page state or the original profile.").font(.caption).foregroundStyle(.secondary)
                List(cleanup.closed) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.title).lineLimit(1); Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Button("Reopen") { cleanup.reopen(item) }
                    }
                }
            } else {
                Text("Selected, loading, audio, and unverified tabs are excluded. Age uses activity observed while Velocity runs; activity between scans can be missed. Detected pinned tabs are excluded, but browsers do not expose every pinned state.").font(.caption).foregroundStyle(.secondary)
                if !model.browserTabsEnabled {
                    Button("Enable browser tab access") { model.enableBrowserTabs() }
                } else if cleanup.candidates.isEmpty {
                    Spacer()
                    Text(model.loading ? "Checking tabs…" : "No eligible duplicates or old tabs.").frame(maxWidth: .infinity).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List(cleanup.candidates) { candidate in
                        Toggle(isOn: Binding(get: { cleanup.selected.contains(candidate.id) }, set: { on in
                            if on { cleanup.selected.insert(candidate.id) } else { cleanup.selected.remove(candidate.id) }
                        })) {
                            HStack {
                                if let icon = candidate.entry.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.entry.title).lineLimit(1)
                                    Text(candidate.entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Text(candidate.entry.browserTab?.url ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(candidate.duplicate ? "Exact duplicate" : "Not seen active \(cleanup.days)+ days").font(.caption).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).disabled(cleanup.busy)
                    }
                }
            }
            if let notice = model.browserNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            if let message = cleanup.message { Text(message).font(.caption) }
            HStack {
                Text(cleanup.busy ? "Rechecking and closing…" : "\(cleanup.candidates.count) candidates").foregroundStyle(.secondary)
                Spacer()
                if !history {
                    Button("Remove exact duplicates") { cleanup.apply?(cleanup.candidates.filter(\.duplicate)) }
                        .disabled(cleanup.busy || !cleanup.candidates.contains(where: \.duplicate))
                    Button("Close \(cleanup.selected.count) selected") { cleanup.apply?(cleanup.candidates.filter { cleanup.selected.contains($0.id) }) }
                        .disabled(cleanup.busy || cleanup.selected.isEmpty)
                }
            }
        }.padding(20).frame(width: 680, height: 540)
    }
}

extension AppDelegate {
    @MainActor func cleanUpTabs(_ proposed: [CleanupCandidate]) {
        let cleanup = model.cleanup
        guard !cleanup.busy, !proposed.isEmpty else { return }
        cleanup.busy = true
        cleanup.message = nil
        Task { @MainActor in
            let fresh: WindowSnapshot = await withCheckedContinuation { continuation in
                scanner.async { continuation.resume(returning: WindowCatalog.scan(frontmost: nil, browserTabsEnabled: true)) }
            }
            cleanup.observe(fresh.entries)
            let eligible = Dictionary(uniqueKeysWithValues: cleanup.candidates.map { ($0.id, $0) })
            var requests = 0
            var skipped = 0
            // Closing right-to-left preserves Safari's snapshot indices.
            for candidate in proposed.sorted(by: { ($0.entry.browserTab?.index ?? 0) > ($1.entry.browserTab?.index ?? 0) }) {
                guard let current = eligible[candidate.id], let tab = current.entry.browserTab,
                      let reviewed = candidate.entry.browserTab,
                      reviewed.url == tab.url, reviewed.title == tab.title,
                      reviewed.windowID == tab.windowID, reviewed.browserID == tab.browserID,
                      current.duplicate == candidate.duplicate else { skipped += 1; continue }
                let recovery = TabCleanupModel.Closed(title: tab.title, url: tab.url, browserID: tab.browserID)
                cleanup.closed.insert(recovery, at: 0)
                cleanup.saveClosed()
                let accepted: Bool = await withCheckedContinuation { continuation in
                    scanner.async {
                        guard TabCleanup.eligible(current.entry),
                              let ax = current.entry.tab,
                              Accessibility.attribute(ax, "AXRole") != nil,
                              WindowCatalog.tabAudio(ax) == .none, !WindowCatalog.tabPinned(ax) else {
                            continuation.resume(returning: false); return
                        }
                        continuation.resume(returning: TabCleanup.close(tab, duplicate: candidate.duplicate))
                    }
                }
                if accepted { requests += 1 } else {
                    skipped += 1
                    cleanup.closed.removeAll { $0.id == recovery.id }
                    cleanup.saveClosed()
                }
            }
            cleanup.selected.removeAll()
            cleanup.busy = false
            cleanup.message = "Requested closing \(requests) tabs; skipped \(skipped) changed or protected tabs. Browser confirmation dialogs remain yours to answer."
            refresh()
        }
    }
}
