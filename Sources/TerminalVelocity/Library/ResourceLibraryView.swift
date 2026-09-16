import AppKit
import SwiftUI

struct ResourceInspectionView: View {
    let inspection: ResourceInspection
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(inspection.resource.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(inspection.resource.kind).foregroundStyle(.secondary)
            ForEach(inspection.facts) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.name).font(.headline)
                    Text(fact.value).textSelection(.enabled)
                    Text(fact.source).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !inspection.limitations.isEmpty {
                Divider()
                Text("What isn’t known yet").font(.headline)
                ForEach(inspection.limitations, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            }
            Text("Inspected catalog · \(inspection.observed.formatted(date: .omitted, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ResourceLibraryView: View {
    @ObservedObject var broker: ResourceBroker
    @ObservedObject var library: ResourceLibrary
    let refresh: () -> Void
    @State private var scope = "all"
    @State private var query = ""
    @State private var selected: UUID?
    @State private var inspection: ResourceInspection?
    @State private var message: String?
    @State private var reviewing = false
    @State private var suggestions: [LibrarySuggestion] = []
    @State private var included: Set<String> = []
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var parent: UUID?
    private var selectedProject: UUID? { UUID(uuidString: scope) }
    private func project(_ resource: ManagedResource) -> UUID? {
        broker.libraryKey(resource).flatMap { library.configuration.assignments[$0] }
    }
    private var visible: [ManagedResource] {
        let subtree = selectedProject.map { library.descendants(of: $0) }
        let words = query.split(whereSeparator: \.isWhitespace)
        return broker.resources.filter { resource in
            guard resource.safety != .blocked else { return false }
            let projectID = project(resource)
            if scope == "unfiled" && projectID != nil { return false }
            if let subtree, !(projectID.map(subtree.contains) ?? false) { return false }
            return words.allSatisfy { (resource.title + " " + resource.kind).localizedCaseInsensitiveContains($0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var projects: [LibraryProject] {
        library.configuration.projects.sorted { library.path($0.id).localizedStandardCompare(library.path($1.id)) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Your library", systemImage: "square.stack.3d.up").font(.title2.bold())
                Spacer()
                Text("\(broker.resources.count) live resources").foregroundStyle(.secondary)
                Button("Organize by folder…") {
                    suggestions = ResourceLibrary.suggestions(broker: broker)
                    included = Set(suggestions.map(\.id)); reviewing = true
                }
                Button("Refresh", action: refresh)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    List(selection: $scope) {
                        Label("All resources", systemImage: "square.grid.2x2").tag("all")
                        Label("Unfiled", systemImage: "tray").tag("unfiled")
                        Section("Projects") {
                            ForEach(projects) { project in
                                Label(library.path(project.id), systemImage: "folder").tag(project.id.uuidString)
                                    .contextMenu {
                                        Button("Edit project…") {
                                            editingID = project.id; name = project.name; parent = project.parentID; editing = true
                                        }
                                    }
                            }
                        }
                    }
                    Button("New project…") { editingID = nil; name = ""; parent = selectedProject; editing = true }
                    Text("Projects organize your work. Agent access is managed separately.").font(.caption).foregroundStyle(.secondary)
                }.padding(12).frame(minWidth: 190, idealWidth: 215, maxWidth: 280)
                VStack(spacing: 0) {
                    TextField("Find an app, title, or conversation…", text: $query).textFieldStyle(.roundedBorder).padding(12)
                    List(selection: $selected) {
                        ForEach(Array(Set(visible.map(\.adapter))).sorted(), id: \.self) { app in
                            Section(app) {
                                ForEach(visible.filter { $0.adapter == app }) { resource in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(resource.title).lineLimit(2)
                                        Text(resource.kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.padding(.vertical, 3).tag(resource.id)
                                }
                            }
                        }
                    }
                    if visible.isEmpty { Text("No resources here yet. Find one under All resources and choose its project.").font(.callout).foregroundStyle(.secondary).padding() }
                }.frame(minWidth: 280, idealWidth: 350)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let inspection {
                            HStack {
                                Text("Project").font(.headline)
                                Picker("Project", selection: Binding(get: { project(inspection.resource) }, set: { value in
                                    perform {
                                        guard let key = broker.libraryKey(inspection.resource) else { throw AccessError.stale }
                                        try library.assign(key: key, project: value)
                                    }
                                })) {
                                    Text("Unfiled").tag(nil as UUID?)
                                    ForEach(projects) { Text(library.path($0.id)).tag(Optional($0.id)) }
                                }.labelsHidden()
                            }
                            ResourceInspectionView(inspection: inspection)
                        } else {
                            Label("What is this?", systemImage: "info.circle").font(.title2)
                            Text("Select a terminal, tab, conversation, or workspace to see its identity, location, and the source of each fact.").foregroundStyle(.secondary)
                        }
                    }.padding(20)
                }.frame(minWidth: 310, idealWidth: 370)
            }
            if let issue = message ?? library.issue {
                Divider(); Text(issue).foregroundStyle(.orange).padding(10)
            }
        }.frame(minWidth: 950, minHeight: 600)
            .onChange(of: selected) { inspectSelection() }
            .onChange(of: broker.resources) { inspectSelection() }
            .sheet(isPresented: $reviewing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Review suggested projects").font(.title2.bold())
                    Text("Grouped by document paths, workspace directories, or terminal title hints. Existing assignments are kept. This does not grant agent access.").font(.callout).foregroundStyle(.secondary)
                    List(suggestions) { suggestion in
                        Toggle(isOn: Binding(get: { included.contains(suggestion.id) }, set: { enabled in
                            if enabled { included.insert(suggestion.id) } else { included.remove(suggestion.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.folder).font(.headline).textSelection(.enabled)
                                Text("\(suggestion.resources.count) resources · " + suggestion.sources.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if suggestions.isEmpty { Text("No folder metadata is available yet. You can create projects and assign resources manually.") }
                    if let message { Text(message).foregroundStyle(.orange) }
                    HStack {
                        Button("Cancel") { reviewing = false }
                        Spacer()
                        Button("Create projects") {
                            perform { try library.apply(suggestions.filter { included.contains($0.id) }, broker: broker); reviewing = false }
                        }.disabled(included.isEmpty)
                    }
                }.padding(24).frame(width: 650, height: 480)
            }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(editingID == nil ? "New project" : "Edit project").font(.title2.bold())
                    TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
                    Picker("Inside", selection: $parent) {
                        Text("Top level").tag(nil as UUID?)
                        ForEach(projects.filter { item in editingID.map { !library.descendants(of: $0).contains(item.id) } ?? true }) {
                            Text(library.path($0.id)).tag(Optional($0.id))
                        }
                    }
                    HStack {
                        Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Save") {
                            perform {
                                if let editingID { try library.update(editingID, name: name, parent: parent) }
                                else { scope = try library.create(name: name, parent: parent).uuidString }
                                editing = false
                            }
                        }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let message { Text(message).foregroundStyle(.orange) }
                }.padding(24).frame(width: 390)
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
    }
    private func inspectSelection() {
        guard let resource = broker.resources.first(where: { $0.id == selected }) else { inspection = nil; return }
        inspection = nil
        perform { inspection = try broker.inspectLocally(resource) }
    }
}

extension AppDelegate {
    @objc func showResourceLibrary() {
        guard Features.experimentalAgents else { return }
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Velocity · Library"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ResourceLibraryView(broker: resourceBroker, library: resourceLibrary, refresh: { [weak self] in self?.refresh() }))
            window.center(); libraryWindow = window
        }
        panel.orderOut(nil); onboardingWindow?.orderOut(nil)
        NSApp.activate(); libraryWindow?.makeKeyAndOrderFront(nil); refresh()
    }
}
