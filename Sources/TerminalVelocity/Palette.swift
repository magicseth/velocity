import AppKit
import SwiftUI
import ApplicationServices

struct SearchResults {
    var entries: [WindowEntry] = []
    var selectedID: String?
    var selectedEntry: WindowEntry? { entries.first { $0.id == selectedID } }
}

@MainActor final class PaletteModel: ObservableObject {
    @Published var showCleanup = false
    let cleanup = TabCleanupModel()
    @Published var showAIGrouping = false
    @Published var aiCandidates: [GroupingCandidate] = []
    @Published var aiSelectedCandidates: Set<String> = []
    @Published var aiSuggestions: [SuggestedObjective] = []
    @Published var aiChosenGroups: Set<String> = []
    @Published var aiLoading = false
    @Published var aiProcessed = 0
    var aiScan: GroupingScan?
    var aiTask: Task<Void, Never>?
    @Published var aiError: String?
    @Published var aiEndpoint = UserDefaults.standard.string(forKey: "groupingEndpoint") ?? ""
    @Published var aiTokenInput = ""
    var aiSnapshot: [String: WindowEntry] = [:]
    let ledger = ObjectiveLedger()
    @Published var objectiveMode = false
    @Published var objectiveQuery = "" { didSet { objectiveSelection = 0 } }
    @Published var objectiveSelection = 0
    @Published var showDoneObjectives = false
    @Published var focusObjectives = false
    @Published var currentObjectiveID: String?
    var activateObjective: ((ObjectiveItem) -> Void)?
    var restoreObjectiveFocus: (() -> Void)?
    func openSelectedObjective() {
        let items = objectiveItems
        if items.indices.contains(objectiveSelection) { activateObjective?(items[objectiveSelection]) }
    }
    func moveObjective(_ delta: Int) {
        let count = objectiveItems.count
        guard count > 0 else { return }
        objectiveSelection = (objectiveSelection + delta + count) % count
    }
    @Published var query = "" { didSet { if query != oldValue { filter() } } }
    @Published private(set) var resultState = SearchResults()
    var results: [WindowEntry] { resultState.entries }
    var selected: Int { results.firstIndex { $0.id == resultState.selectedID } ?? -1 }
    @Published var loading = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var message: String?
    @Published var browserTabsEnabled = UserDefaults.standard.bool(forKey: "browserTabsEnabled")
    @Published var browserNotice: String?
    @Published var showHelp = false
    @Published var previewEntry: WindowEntry?
    @Published var previewText = ""
    var inspect: ((WindowEntry) -> Void)?
    @Published var groups: [WindowGroup] = []
    @Published var editingGroup = false
    @Published var groupName = ""
    @Published var groupMembers: Set<String> = []
    @Published var groupQuery = ""
    var editingGroupID: UUID?

    func editGroup(_ entry: WindowEntry) {
        guard Features.experimentalAgents else { return }
        guard let key = entry.windowKey else { return }
        let group = groups.first { $0.members.contains(key) }
        editingGroupID = group?.id
        groupName = group?.name ?? "New group"
        groupMembers = group?.members ?? [key]
        groupQuery = ""
        editingGroup = true
    }

    func saveGroup() {
        guard Features.experimentalAgents else { return }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, groupMembers.count >= 2 else { return }
        // Each window belongs to one group; reassignment removes its old membership.
        groups = groups.filter { $0.id != editingGroupID }.compactMap { group in
            var updated = group
            updated.members.subtract(groupMembers)
            return updated.members.count >= 2 ? updated : nil
        }
        groups.append(WindowGroup(id: editingGroupID ?? UUID(), name: name, members: groupMembers))
        persistGroups()
        editingGroup = false
    }

    var groupWindows: [WindowEntry] {
        var seen: Set<String> = []
        return all.filter {
            guard !$0.isTab, let key = $0.windowKey, seen.insert(key).inserted else { return false }
            return WindowSearch.score(query: groupQuery, title: $0.searchText, app: $0.appName) != nil
        }
    }
    let memory: SelectionMemory
    init(memory: SelectionMemory = SelectionMemory()) {
        self.memory = memory
        if Features.experimentalAgents, let data = UserDefaults.standard.data(forKey: "objectiveGroups"),
           let restored = try? JSONDecoder().decode([WindowGroup].self, from: data) {
            groups = restored.map { var group = $0; group.members = []; return group }
        }
    }
    func persistGroups() {
        guard Features.experimentalAgents else { return }
        for index in groups.indices {
            let fingerprints = all.filter { !$0.isTab && $0.windowKey.map { groups[index].members.contains($0) } == true }.map(\.groupFingerprint)
            if !fingerprints.isEmpty { groups[index].rememberedMembers = Set(fingerprints) }
        }
        if let data = try? JSONEncoder().encode(groups) { UserDefaults.standard.set(data, forKey: "objectiveGroups") }
    }
    func reconnectGroups() {
        guard Features.experimentalAgents else { return }
        let candidates = Dictionary(grouping: all.filter { !$0.isTab && $0.windowKey != nil }, by: \.groupFingerprint)
        for index in groups.indices where groups[index].members.isEmpty {
            groups[index].members = Set(groups[index].rememberedMembers.compactMap { fingerprint in
                guard let matches = candidates[fingerprint], matches.count == 1 else { return nil }
                return matches[0].windowKey
            })
        }
    }
    var all: [WindowEntry] = []
    var choose: (() -> Void)?
    var chooseEntry: ((WindowEntry) -> Void)?
    var closeEntry: ((WindowEntry) -> Void)?
    @Published var closingEntries: Set<String> = []
    var refresh: (() -> Void)?
    var shortcut = "⌘⇧A"

    func openAllApps() {
        query = ""
        filter()
    }

    func filter(preserveSelection: Bool = false) {
        let selectedID = preserveSelection ? resultState.selectedID : nil
        let parsed = SearchQuery(query)
        var nextResults = all.enumerated().compactMap { index, entry -> (Int, Double, Int, WindowEntry)? in
            let key = entry.memoryKey
            let recent = memory.recent[key] ?? 0
            guard parsed.accepts(entry, recent: recent > 0) else { return nil }
            let searchText = entry.searchText
            guard let score = WindowSearch.score(query: parsed.text, title: searchText, app: entry.appName) else { return nil }
            // Like Command-Tab: the current item follows the previous destination.
            let rank = parsed.text.isEmpty && key == memory.currentKey ? 0.5 : recent
            return (score, rank == 0 && entry.launchURL != nil ? -1 : rank, index, entry)
        }.sorted {
            if ($0.3.launchURL != nil) != ($1.3.launchURL != nil) {
                return $0.3.launchURL == nil
            }
            if parsed.text.isEmpty {
                let first = $0.3.attention.needsAttention ? 2 : ($0.3.audio != .none ? 1 : 0)
                let second = $1.3.attention.needsAttention ? 2 : ($1.3.audio != .none ? 1 : 0)
                if first != second { return first > second }
            }
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.2 < $1.2
        }.map { $0.3 }
        nextResults = ResultDeduplication.apply(nextResults)
        // Publish rows and selection together. A vanished selection must not silently
        // become a different app occupying the same row after a background scan.
        resultState = SearchResults(entries: nextResults, selectedID: selectedID ?? nextResults.first?.id)
    }



    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = selected < 0 ? (delta < 0 ? results.count - 1 : 0) : (selected + delta + results.count) % results.count
        resultState = SearchResults(entries: results, selectedID: results[index].id)
    }

    func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func enableBrowserTabs() {
        browserTabsEnabled = true
        UserDefaults.standard.set(true, forKey: "browserTabsEnabled")
        refresh?()
    }
}

struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var searching: Bool

    var body: some View {
        if model.showCleanup { TabCleanupView(model: model, cleanup: model.cleanup) } else if Features.experimentalAgents && model.showAIGrouping { AIGroupingView(model: model) } else if Features.experimentalAgents && model.objectiveMode { ObjectiveView(model: model) } else { windowPalette }
    }

    private var windowPalette: some View {
        let displayed = model.resultState
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
                TextField("Find a window or app…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 23)).focused($searching)
                    .accessibilityLabel("Search windows and apps")
                     .onSubmit {
                        if let entry = model.resultState.selectedEntry { model.chooseEntry?(entry) }
                        else { model.message = "That result is no longer available. Select a result or refresh." }
                    }
                Text("esc").help("Close search and return to your previous app")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary).padding(5).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }.padding(24)

            Divider()

            if model.trusted && (!model.browserTabsEnabled || model.browserNotice != nil) {
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                    Text(model.browserNotice ?? "Include every Chrome and Safari tab")
                        .font(.system(size: 11)).lineLimit(2)
                    Spacer()
                    Button(model.browserTabsEnabled ? "Automation Settings" : "Enable") {
                        if model.browserTabsEnabled {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        } else { model.enableBrowserTabs() }
                    }.controlSize(.small)
                }.padding(.horizontal, 20).padding(.vertical, 10).background(Color.accentColor.opacity(0.06))
            }

            if let entry = model.previewEntry {
                preview(entry)
            } else if Features.experimentalAgents && model.editingGroup {
                groupEditor
            } else if model.showHelp {
                helpView
            } else if !model.trusted {
                VStack(spacing: 14) {
                    Image(systemName: "macwindow.badge.plus").font(.system(size: 35)).foregroundStyle(.blue)
                    Text("Your windows, one shortcut away").font(.system(size: 19, weight: .semibold))
                    Text("Allow Accessibility access so Terminal Velocity can read window titles and bring the window you choose to the front.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Button("Open Accessibility Settings") { model.openAccessibility() }.buttonStyle(.borderedProminent)
                    Button("I’ve enabled access — refresh") { model.refresh?() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else if model.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.loading ? "rectangle.stack" : "magnifyingglass").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.loading ? "Finding your windows…" : "No matching windows").font(.headline)
                    Text(model.loading ? "Checking running applications" : "Try an app, project, folder, or window title.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    // Native list virtualization uses a fixed row height rather than
                    // estimated lazy-stack geometry as hundreds of results refresh.
                    List {
                            ForEach(Array(displayed.entries.enumerated()), id: \.element.id) { index, entry in
                                HStack(spacing: 0) {
                                    Button { model.chooseEntry?(entry) } label: { row(entry, index: index) }
                                        .buttonStyle(.plain).focusable(false)
                                    if entry.canClose {
                                        Button { model.closeEntry?(entry) } label: {
                                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(.secondary).frame(width: 28, height: 32)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).focusable(false)
                                            .help(entry.closeLabel).accessibilityLabel(entry.closeLabel + ": " + entry.title)
                                            .disabled(model.closingEntries.contains(entry.id))
                                            .padding(.trailing, 8)
                                    }
                                }.frame(height: 58)
                                    .background(entry.id == displayed.selectedID ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                    .contextMenu {
                                        if entry.terminal { Button("Inspect prompt…") { model.inspect?(entry) } }
                                        if Features.experimentalAgents && entry.windowKey != nil {
                                            Button("Edit window group…") { model.editGroup(entry) }
                                        }
                                    }
                                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 3, trailing: 10))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .id(entry.id)
                            }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 58)
                    .transaction { $0.animation = nil }
                    .onChange(of: [model.query, displayed.selectedID ?? "", String(model.selected)]) { _, _ in
                        guard let id = displayed.selectedEntry?.id else { return }
                        // Scroll once, after the native list commits its new rows.
                        // Separate query/selection callbacks can fight each other.
                        DispatchQueue.main.async {
                            guard model.resultState.selectedEntry?.id == id else { return }
                            proxy.scrollTo(id)
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 16) {
                Button { model.showCleanup = true } label: { Label("Clean up tabs", systemImage: "rectangle.stack.badge.minus") }.buttonStyle(.plain)
                if Features.experimentalAgents {
                    Button { model.beginAIGrouping() } label: { Label("AI groups", systemImage: "sparkles") }.buttonStyle(.plain)
                }
                Text(model.message ?? (model.trusted ? "\(model.results.count) results" : "Permission needed"))
                    .lineLimit(1)
                Spacer()
                Text("↑↓ select    ↵ open    ⌘/ help")
                Button { model.showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).help("Keyboard shortcuts (⌘/)").accessibilityLabel("Shortcut help")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 680, height: 510)
        .background(.regularMaterial)
        .onAppear { searching = true }
    }

    private func row(_ entry: WindowEntry, index: Int) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = entry.icon { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                else { Image(systemName: "app").frame(width: 32, height: 32) }
                if let avatar = entry.browserProfileIcon {
                    Image(nsImage: avatar).resizable().scaledToFill().frame(width: 19, height: 19)
                        .clipShape(Circle()).overlay(Circle().stroke(.background, lineWidth: 2))
                        .offset(x: 5, y: 5).help(entry.browserProfile ?? "Browser profile")
                } else if let profile = entry.browserProfile, profile != "Profile unavailable" {
                    Text(profile == "Incognito" ? "◉" : String(profile.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .bold)).frame(width: 19, height: 19)
                        .background(.background, in: Circle()).overlay(Circle().stroke(.secondary.opacity(0.3)))
                        .offset(x: 5, y: 5).help(profile)
                }
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(WindowSearch.excerpt(query: SearchQuery(model.query).text, title: entry.displayTitle))
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .help(entry.title)
                    .accessibilityLabel(entry.title)
                Text(entry.subtitle + (model.groups.first(where: { group in entry.windowKey.map { group.members.contains($0) } ?? false }).map { " · " + $0.name } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.attention != .none {
                Text(entry.attention.label).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.attention == .needsInput ? Color.orange : Color.secondary)
                    .help(entry.attention == .idle ? "Claude’s title appears idle. This can mean finished, waiting, or paused; it is not proof of an approval prompt." : "State inferred from the terminal title. Press ⌘I to inspect.")
            }
            if entry.audio != .none {
                Label(entry.audio.label, systemImage: entry.audio.symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(entry.audio == .muted ? Color.secondary : Color.green)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background((entry.audio == .muted ? Color.secondary : Color.green).opacity(0.1), in: Capsule())
                    .help(entry.audio == .appOutput ? "This application has an active audio output stream. macOS does not identify the individual window, and the stream may contain silence." : entry.audio.label)
            }
            if index < 9 {
                Text("⌥⌘\(index + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func preview(_ entry: WindowEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.attention.label.isEmpty ? "Terminal preview" : entry.attention.label).font(.headline)
                Spacer()
                Button("Refresh") { model.inspect?(entry) }
                Button("Back") { model.previewEntry = nil; searching = true }
                Button("Open to answer") { model.chooseEntry?(entry) }.buttonStyle(.borderedProminent)
            }
            Text(entry.title).font(.caption).lineLimit(2)
            Text("Recent terminal text · snapshot, not a live approval control")
                .font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.previewText).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }.onChange(of: model.previewText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }.padding(20)
    }

    private var groupEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Group name", text: $model.groupName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Group name")
                Button("Cancel") { model.editingGroup = false; searching = true }
                Button("Save group") { model.saveGroup(); searching = true }
                    .disabled(model.groupMembers.count < 2 || model.groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Choose windows to bring forward together. Applies to clicks, app switching, and dragging too. Objectives are saved. Changed or ambiguous windows may need regrouping.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Find windows to add…", text: $model.groupQuery).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Find group windows")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.groupWindows) { entry in
                        if let key = entry.windowKey {
                            Toggle(isOn: Binding(get: { model.groupMembers.contains(key) }, set: { selected in
                                if selected { model.groupMembers.insert(key) } else { model.groupMembers.remove(key) }
                            })) {
                                Text(entry.appName + " · " + entry.title).lineLimit(1).help(entry.title)
                            }.toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                Text("\(model.groupMembers.count) windows selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let id = model.editingGroupID {
                    Button("Dissolve group") { model.groups.removeAll { $0.id == id }; model.persistGroups(); model.editingGroup = false; searching = true }
                }
            }
        }.padding(20)
    }

    private var helpView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Move around without slowing down").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Done") { model.showHelp = false; searching = true }.controlSize(.small)
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    helpRow("⌘I", "Inspect the selected terminal’s prompt")
                    helpRow("⌥⌘1–9", "Open that numbered result")
                    helpRow("↑↓ / ↵ / esc", "Select / open / return to previous app")
                    if Features.experimentalAgents { helpRow("⌘G", "Group the selected window") }
                    helpRow("⌘R / ⌘/", "Refresh / show this help")
                }.font(.system(size: 12))
                Divider()
                Text("SEARCH COMMANDS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("@Notes ideas    app:\"Visual Studio Code\" waveshare\n@attention    @waiting    @ready    @agents\n@audio    @playing    @muted    @recent\n@tabs    @windows    @minimized\nfolder:\"My Projects\"    waveshare")
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(7)
                Text("Use @ followed by any app name. Plain words match app names, titles, URLs, and exposed document paths. folder: matches document parent folders when available. Recently used windows rise to the top, including switches outside this app; the current window follows previous destinations. Filters combine.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func helpRow(_ keys: String, _ description: String) -> some View {
        GridRow {
            Text(keys).fontDesign(.monospaced).foregroundStyle(.secondary)
            Text(description)
        }
    }
}
