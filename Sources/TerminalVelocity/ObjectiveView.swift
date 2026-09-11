import SwiftUI

struct ObjectiveView: View {
    @ObservedObject var model: PaletteModel
    @FocusState private var searching: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Switch objectives").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button { model.beginAIGrouping() } label: { Label("Suggest groups", systemImage: "sparkles") }
                Button { model.objectiveMode = false } label: { Label("Windows", systemImage: "macwindow") }
            }
            TextField("Find an objective… (@done includes completed)", text: $model.objectiveQuery)
                .textFieldStyle(.roundedBorder).focused($searching)
                .onSubmit { model.openSelectedObjective() }
            HStack {
                Toggle("Focus: hide other work", isOn: $model.focusObjectives).toggleStyle(.checkbox)
                Spacer()
                Toggle("Show done", isOn: $model.showDoneObjectives).toggleStyle(.checkbox)
                Button("Restore windows") { model.restoreObjectiveFocus?() }
            }.font(.system(size: 11))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.objectiveItems.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 8) {
                                Button { model.activateObjective?(item) } label: {
                                    HStack(spacing: 12) {
                                        ObjectiveIcon(entries: item.entries, waiting: item.waiting, unread: item.unread, done: item.done)
                                        VStack(alignment: .leading, spacing: 5) {
                                        Text(item.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text("\(item.status) · \(Set(item.entries.compactMap(\.windowKey)).count) windows")
                                            .font(.caption).foregroundStyle(item.waiting || item.unread ? Color.orange : Color.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                                if item.unread { Button("Reviewed") { model.reviewObjective(item) } }
                                Button(item.done ? "Reopen" : "Done") { model.markObjective(item, done: !item.done) }
                            }.padding(12)
                                .background(index == model.objectiveSelection ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                                .id(item.id)
                        }
                    }
                    if model.objectiveItems.isEmpty {
                        Text("No active objectives. Group windows with ⌘G in window search, or show Done objectives.")
                            .foregroundStyle(.secondary).padding(24)
                    }
                }.onChange(of: model.objectiveSelection) { _, index in
                    let items = model.objectiveItems
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            Text(model.message ?? "↑↓ select · ⌃⌥O next · Return focus · ⌘D done · Escape cancel")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 680, height: 510).background(.regularMaterial)
            .onAppear { searching = true }
    }
}
