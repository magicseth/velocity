import SwiftUI

struct AIGroupingView: View {
    @ObservedObject var model: PaletteModel
    @State private var showConnection = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggest objectives").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("Back") { model.showAIGrouping = false }.disabled(model.aiLoading)
            }
            Text("Convex AI Gateway groups selected windows by shared work. Review the metadata below before sending. Whole windows are grouped; tab titles provide context. All ungrouped windows are included. Batches share a desktop overview and objective catalog to connect related windows across apps.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if model.aiSuggestions.isEmpty {
                DisclosureGroup("Connection settings", isExpanded: $showConnection) {
                TextField("Convex endpoint: https://…convex.site/suggest-objectives", text: $model.aiEndpoint)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("AI grouping endpoint").disabled(model.aiLoading)
                SecureField("Device token (stored in Keychain; leave blank to reuse)", text: $model.aiTokenInput)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("AI grouping device token").disabled(model.aiLoading)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(model.aiCandidates) { candidate in
                            Toggle(isOn: Binding(get: { model.aiSelectedCandidates.contains(candidate.id) }, set: { selected in
                                if selected { model.aiSelectedCandidates.insert(candidate.id) } else { model.aiSelectedCandidates.remove(candidate.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 7) {
                                        if let icon = model.aiSnapshot[candidate.id]?.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                                        Text(candidate.app + " · " + candidate.title).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !candidate.folder.isEmpty { Text(candidate.folder).font(.caption).foregroundStyle(.secondary) }
                                    ForEach(Array(candidate.tabs.enumerated()), id: \.offset) { _, tab in Text(tab).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.disabled(model.aiLoading)
                Text("Sends this metadata to your Convex backend and its model provider. Terminal output and document/page contents are excluded. Existing groups are excluded.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.aiLoading {
                    HStack {
                        ProgressView(value: Double(model.aiProcessed), total: Double(max(1, model.aiSelectedCandidates.count)))
                        Text("\(model.aiProcessed) / \(model.aiSelectedCandidates.count) windows").font(.caption)
                        Button("Pause") { model.aiTask?.cancel() }
                    }
                } else {
                    Button(model.aiProcessed > 0 && model.aiScan?.complete == false ? "Resume grouping" : "Suggest from \(model.aiSelectedCandidates.count) windows") { model.requestAIGrouping() }
                        .disabled(model.aiSelectedCandidates.count < 2).buttonStyle(.borderedProminent)
                }
            } else {
                Text("Reviewed \(model.aiProcessed) windows").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach($model.aiSuggestions) { $suggestion in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 10) {
                                    ObjectiveIcon(entries: suggestion.memberIds.compactMap { model.aiSnapshot[$0] })
                                Toggle(isOn: Binding(get: { model.aiChosenGroups.contains(suggestion.id) }, set: { value in
                                    if value { model.aiChosenGroups.insert(suggestion.id) } else { model.aiChosenGroups.remove(suggestion.id) }
                                })) { TextField("Objective name", text: $suggestion.name) }.toggleStyle(.checkbox)
                                }
                                Text(suggestion.confidence.capitalized + " confidence · " + suggestion.reason).font(.caption).foregroundStyle(.secondary)
                                ForEach(suggestion.memberIds, id: \.self) { id in
                                    if let candidate = model.aiCandidates.first(where: { $0.id == id }) {
                                        Text(candidate.app + " · " + candidate.title).font(.system(size: 11)).lineLimit(2)
                                    }
                                }
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack {
                    Button("Start over") { model.beginAIGrouping() }
                    Spacer()
                    Button("Create \(model.aiChosenGroups.count) objectives") { model.applyAISuggestions() }
                        .disabled(model.aiChosenGroups.isEmpty || model.aiSuggestions.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = model.aiError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(20).frame(width: 680, height: 510).background(.regularMaterial)
            .onAppear { showConnection = model.aiEndpoint.isEmpty }
    }
}
