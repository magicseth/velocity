import AppKit
import SwiftUI
import LocalAuthentication

@MainActor final class TextRequestModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var candidates: [ManagedResource] = []
    @Published var selected: UUID? { didSet { updateInspection() } }
    @Published private(set) var inspection: ResourceInspection?
    @Published private(set) var intent = "open"
    @Published private(set) var recipients: [DeliveryRecipient] = []
    @Published var recipientID: String?
    @Published private(set) var links: [UUID: ResourceLink] = [:]
    var selectedRecipient: DeliveryRecipient? { recipients.first { $0.selectionKey == recipientID } }
    var selectedURL: String? { selected.flatMap { links[$0]?.url } }
    var ready: Bool { selected != nil && (intent == "open" || (selectedRecipient != nil && selectedURL != nil)) }
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var authorizing = false
    private var generation = UUID()
    private var plannedAt: Date?
    private var authentication: LAContext?
    private let resources: ResourceTools
    private let destinations: RecipientTools
    private let actions: ActionTools
    private var planning: Task<Void, Never>?
    let endpoint: () -> String
    init(broker: ResourceBroker, endpoint: @escaping () -> String) {
        resources = ResourceTools(broker: broker)
        destinations = RecipientTools(adapters: .shared)
        actions = ActionTools(broker: broker, adapters: .shared)
        self.endpoint = endpoint
    }
    func invalidate() {
        planning?.cancel(); planning = nil
        generation = UUID(); authentication?.invalidate(); authentication = nil
        candidates = []; selected = nil; recipients = []; recipientID = nil; links = [:]; intent = "open"; plannedAt = nil; busy = false; authorizing = false; message = ""
    }
    func plan() {
        guard !busy else { return }
        invalidate(); busy = true
        let generation = generation
        let text = text
        planning = Task {
            do {
                let result = try await resources.search(text, endpoint: endpoint())
                guard self.generation == generation else { return }
                candidates = result.resources
                intent = result.intent.rawValue
                links = result.links
                if result.intent == .shareLink {
                    guard let query = result.recipientQuery else { throw AccessError.unsupported }
                    let lookup = try await destinations.search(query, adapterID: result.adapterID) { capability in
                        message = "Finding \(query) in \(capability.name)…"
                    }
                    guard self.generation == generation else { return }
                    recipients = lookup.matches
                    NSApp.activate()
                    NSApp.windows.first { $0.title == "Velocity · Ask" }?.makeKeyAndOrderFront(nil)
                    recipientID = recipients.count == 1 ? recipients[0].selectionKey : nil
                    message = recipients.isEmpty ? "No destination resolved for \(query). Try their full name." : (recipients.count == 1 ? "Review the destination and exact link below. Nothing has been sent." : "Which \(query) did you mean? Choose the destination below.")
                    if !lookup.issues.isEmpty { message += " Some destinations couldn’t be checked: " + lookup.issues.map(\.message).joined(separator: " ") }
                } else {
                    message = candidates.isEmpty ? result.message : result.intent == .inspect ? "Select a result to inspect its metadata. Nothing will be opened." : "Review the matching window or tab below."
                }
                selected = candidates.count == 1 ? candidates.first?.id : nil
                plannedAt = result.created; busy = false
            } catch {
                guard self.generation == generation else { return }
                candidates = []; selected = nil; recipients = []; recipientID = nil
                message = error.localizedDescription; busy = false
            }
        }
    }
    private func updateInspection() {
        inspection = nil
        guard intent == "inspect", let target = candidates.first(where: { $0.id == selected }) else { return }
        do { inspection = try resources.inspect(target) }
        catch { message = error.localizedDescription }
    }
    func open() {
        guard !busy, ready, let target = candidates.first(where: { $0.id == selected }), let plannedAt else { return }
        busy = true; authorizing = true
        let generation = generation
        let context = LAContext(); authentication = context
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        Task {
            do {
                let share = intent == "shareLink"
                let action: PreparedLocalAction
                if share {
                    guard let recipient = selectedRecipient, let link = links[target.id] else { throw AccessError.unavailable }
                    action = try actions.prepareMessage(link, to: recipient, created: plannedAt)
                } else {
                    action = try actions.prepareOpen(target, created: plannedAt)
                }
                let success = try await actions.execute(action) { reviewed in
                    var error: NSError?
                    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                        throw error ?? AIGrouping.Failure("Touch ID is unavailable on this Mac.") as NSError
                    }
                    let approved = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                        localizedReason: reviewed.approvalReason)
                    return approved && self.generation == generation
                }
                guard self.generation == generation else { return }
                candidates = []; selected = nil; recipients = []; recipientID = nil
                message = share ? (success ? "The selected app accepted the link for sending. Delivery is not confirmed." : "The recipient changed or is unavailable. Nothing was sent.") : (success ? "Opened \(target.title)." : "The app couldn’t open that target. Try a fresh request.")
            } catch {
                guard self.generation == generation else { return }
                candidates = []; selected = nil; message = error.localizedDescription
            }
            busy = false; authorizing = false; authentication = nil
        }
    }
}

struct TextRequestView: View {
    @ObservedObject var model: TextRequestModel
    let back: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Ask Velocity", systemImage: "text.bubble").font(.title2.bold())
                Spacer()
                Button("Back to search", action: back).keyboardShortcut(.cancelAction)
            }
            TextField("Find a window, ask what it is, or share a link…", text: $model.text)
                .textFieldStyle(.roundedBorder).font(.title3).focused($focused)
                .disabled(model.authorizing)
                .onSubmit { model.plan() }
                .onChange(of: model.text) { model.invalidate() }
            HStack {
                Button("Prepare request") { model.plan() }.disabled(model.busy || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.busy { ProgressView().controlSize(.small); Text(model.authorizing ? "Authorizing your request…" : "Preparing a preview…").foregroundStyle(.secondary) }
            }
            if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let inspection = model.inspection {
                        ResourceInspectionView(inspection: inspection).padding(.bottom, 12)
                    }
                    ForEach(model.candidates) { target in
                        Button {
                            model.selected = target.id
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: model.selected == target.id ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.title).fontWeight(.medium)
                                    Text(target.kind).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selected == target.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }
            }
            if model.intent == "shareLink" && !model.recipients.isEmpty {
                if model.recipients.count > 1 {
                    Picker("Which destination?", selection: $model.recipientID) {
                        Text("Choose a destination…").tag(nil as String?)
                        ForEach(model.recipients, id: \.selectionKey) { recipient in
                            Text("\(recipient.name) · \(recipient.adapterName) · \(recipient.handle)").tag(Optional(recipient.selectionKey))
                        }
                    }.disabled(model.busy)
                } else if let recipient = model.selectedRecipient {
                    Text("To \(recipient.name) · \(recipient.adapterName) · \(recipient.handle)").font(.headline).textSelection(.enabled)
                }
                if let url = model.selectedURL {
                    Text("Exact message").font(.headline)
                    Text(url).textSelection(.enabled).font(.body.monospaced()).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08))
                }
            }
            if model.ready {
                Button { model.open() } label: { Label(model.intent == "shareLink" ? "Approve sending with Touch ID" : "Approve opening with Touch ID", systemImage: "touchid") }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                Text(model.intent == "shareLink" ? "Sends this exact link once to the selected recipient. This cannot be undone by Velocity." : "Opens only the selected window or tab. Nothing is typed or sent.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Your request and available window/tab titles are sent to your configured AI Gateway to find matches. Recipient lookup and approved actions happen locally. Recipient handles stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 620, minHeight: 450).onAppear { focused = true }
    }
}

extension AppDelegate {
    @objc func showTextRequest() {
        guard Features.experimentalAgents else { return }
        if textRequestModel == nil { textRequestModel = TextRequestModel(broker: resourceBroker, endpoint: { [weak self] in self?.model.aiEndpoint ?? "" }) }
        if textRequestWindow == nil, let requestModel = textRequestModel {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Velocity · Ask"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TextRequestView(model: requestModel, back: { [weak self] in
                self?.textRequestModel?.invalidate(); self?.textRequestWindow?.orderOut(nil); self?.show()
            }))
            window.center(); textRequestWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak requestModel] _ in
                Task { @MainActor in requestModel?.invalidate() }
            }
        }
        panel.orderOut(nil); NSApp.activate(); textRequestWindow?.makeKeyAndOrderFront(nil)
        refresh()
    }
}
