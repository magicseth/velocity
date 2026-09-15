import SwiftUI
import AppKit

struct AccessView: View {
    @ObservedObject var broker: ResourceBroker
    let server: AccessServer
    @State private var projectName = ""
    @State private var agentName = ""
    @State private var project: UUID?
    @State private var search = ""
    @State private var error: String?
    @State private var credential: String?
    private func attempt(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent Access").font(.title2.bold())
                Spacer()
                if broker.endpoint != nil { Button("Stop access") { server.stop() } }
                else { Button("Enable local access") { attempt { try server.start() } }.disabled(broker.issue != nil) }
            }
            Text(broker.endpoint ?? "Local access is off. No resources are shared until you assign them to a project and pair an agent.")
                .font(.caption).textSelection(.enabled)
            if let issue = broker.issue ?? error { Text(issue).foregroundStyle(.red) }
            TabView {
                resources.tabItem { Text("Resources") }
                identities.tabItem { Text("Agents & projects") }
                approvals.tabItem { Text("Requests (\(broker.requests.filter { $0.status == .pending }.count))") }
                permissions.tabItem { Text("Grants") }
                List(broker.audit.reversed()) { event in
                    VStack(alignment: .leading) {
                        Text(event.event).font(.body.monospaced())
                        Text(event.date.formatted() + (event.agentID.map { " · " + agent($0) } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }.tabItem { Text("Audit") }
            }
        }.padding(20).frame(minWidth: 760, minHeight: 560)
    }
    private var resources: some View {
        VStack {
            TextField("Find a resource", text: $search).textFieldStyle(.roundedBorder)
            Text("Assigning a resource shares its name and metadata with agents paired to that project. Actions still require approval. Scope assignments reset when a target changes or Velocity restarts.")
                .font(.caption).foregroundStyle(.secondary)
            List(broker.resources.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.adapter.localizedCaseInsensitiveContains(search) }) { resource in
                HStack {
                    VStack(alignment: .leading) {
                        Text(resource.title).lineLimit(1)
                        Text(resource.kind + (resource.capabilities.isEmpty ? " · Discovery only" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Project", selection: Binding(get: { resource.projectID }, set: { value in attempt { try broker.assign(resource.id, project: value, safety: resource.safety) } })) {
                        Text("Private").tag(nil as UUID?)
                        ForEach(broker.projects) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 160)
                    Toggle("Block", isOn: Binding(get: { resource.safety == .blocked }, set: { value in attempt { try broker.assign(resource.id, project: resource.projectID, safety: value ? .blocked : .ask) } })).frame(width: 80)
                }.padding(.vertical, 3)
            }
        }.padding(12)
    }
    private var identities: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("New project", text: $projectName)
                Button("Create project") { attempt { try broker.addProject(name: projectName); projectName = "" } }.disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Divider()
            HStack {
                TextField("Agent name", text: $agentName)
                Picker("Share project", selection: $project) {
                    Text("Choose…").tag(nil as UUID?)
                    ForEach(broker.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Pair agent") {
                    if let project { attempt { credential = try broker.pair(name: agentName, project: project); agentName = "" } }
                }.disabled(project == nil || agentName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if credential != nil {
                HStack {
                    Text("Credential created. Copy it to your agent; Velocity stores only its hash.").font(.caption)
                    Button("Copy credential") {
                        if let credential { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(credential, forType: .string) }
                    }
                    Button("Dismiss") { credential = nil }
                }
            }
            Text("Pairing grants discovery of project resource names, not permission to act. Revoking disconnects this identity; it cannot undo actions already dispatched.").font(.caption).foregroundStyle(.secondary)
            List(broker.agents) { agent in
                HStack {
                    VStack(alignment: .leading) {
                        Text(agent.name)
                        Text(broker.projects.filter { agent.projects.contains($0.id) }.map(\.name).joined(separator: ", ")).font(.caption)
                    }
                    Spacer()
                    if agent.revoked { Text("Revoked").foregroundStyle(.secondary) }
                    else { Button("Revoke") { broker.revokeAgent(agent.id) } }
                }
            }
        }.padding(12)
    }
    private var approvals: some View {
        List(broker.requests.reversed()) { request in
            VStack(alignment: .leading, spacing: 8) {
                Text("\(agent(request.agentID)) requests \(request.action.rawValue)").font(.headline)
                if let resource = broker.resources.first(where: { $0.id == request.resourceID }) {
                    Text(resource.title)
                    Text(resource.kind + " · " + (broker.projects.first { $0.id == resource.projectID }?.name ?? "Private")).font(.caption)
                    if request.action == .close && resource.kind.contains("Window") {
                        Text("Closes this window, including any tabs it contains. Native save prompts remain in the app.").font(.caption)
                    }
                } else { Text("Unavailable resource") }
                if !request.reason.isEmpty { Text("Agent-provided reason: \(request.reason)").font(.caption).textSelection(.enabled) }
                HStack {
                    Text(request.status.rawValue).foregroundStyle(.secondary)
                    if request.status == .pending {
                        Button("Deny") { attempt { try broker.deny(request.id) } }
                        Button("Allow once") { approve(request.id, hour: false) }
                        if request.action == .open { Button("Allow opening for 1 hour") { approve(request.id, hour: true) } }
                    }
                }
            }.padding(.vertical, 6)
        }
    }
    private var permissions: some View {
        List(broker.grants) { grant in
            HStack {
                VStack(alignment: .leading) {
                    Text("\(agent(grant.agentID)) · \(grant.action.rawValue)")
                    Text(broker.resources.first { $0.id == grant.resourceID }?.title ?? "Unavailable resource").lineLimit(1)
                    Text("Expires \(grant.expires.formatted())").font(.caption)
                }
                Spacer()
                Button("Revoke") { broker.revokeGrant(grant.id) }
            }
        }
    }
    private func agent(_ id: UUID) -> String { broker.agents.first { $0.id == id }?.name ?? "Unknown agent" }
    private func approve(_ id: UUID, hour: Bool) {
        Task { @MainActor in
            do { try await broker.approve(id, allowOpenForHour: hour); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
