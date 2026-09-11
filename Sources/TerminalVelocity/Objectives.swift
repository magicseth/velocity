import Foundation

struct ObjectiveItem: Identifiable {
    let id: String
    let name: String
    let entries: [WindowEntry]
    let waiting: Bool
    let unread: Bool
    let done: Bool
    let lastUsed: Double
    var status: String { done ? "Done" : waiting ? "Question / approval" : unread ? "New handoff" : "Active" }
}

final class ObjectiveLedger {
    struct Record: Codable {
        var done = false
        var unread = false
        var lastUsed: Double = 0
    }
    private let defaults: UserDefaults
    private(set) var records: [String: Record]
    private var priorStates: [String: AgentAttention] = [:]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = defaults.data(forKey: "objectiveLedger").flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }
    func update(_ id: String, _ change: (inout Record) -> Void) {
        var record = records[id] ?? Record()
        change(&record)
        records[id] = record
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "objectiveLedger") }
    }
    func observe(id: String, entry: WindowEntry) {
        let key = entry.id
        let previous = priorStates[key]
        priorStates[key] = entry.attention
        // An already-idle session is not evidence of an unread response.
        if entry.attention == .idle && previous == .working {
            update(id) { $0.unread = true }
        }
    }
}

@MainActor extension PaletteModel {
    var allObjectiveItems: [ObjectiveItem] {
        var assigned: Set<String> = []
        var items: [ObjectiveItem] = []
        func add(id: String, name: String, entries: [WindowEntry]) {
            let record = ledger.records[id] ?? ObjectiveLedger.Record()
            items.append(ObjectiveItem(id: id, name: name, entries: entries,
                waiting: entries.contains { $0.attention == .needsInput }, unread: record.unread,
                done: record.done, lastUsed: record.lastUsed))
        }
        for group in groups {
            let entries = all.filter { $0.windowKey.map { group.members.contains($0) } ?? false }
            entries.forEach { assigned.insert($0.memoryKey) }
            add(id: group.id.uuidString, name: group.name, entries: entries)
        }
        // Ungrouped agent sessions remain reachable before the user organizes them.
        var seen: Set<String> = []
        for entry in all.sorted(by: { $0.isTab && !$1.isTab }) where entry.terminal && entry.attention != .none {
            if !entry.isTab, let key = entry.windowKey,
               all.contains(where: { $0.isTab && $0.windowKey == key && $0.attention != .none }) { continue }
            guard !assigned.contains(entry.memoryKey), seen.insert(entry.memoryKey).inserted else { continue }
            add(id: entry.memoryKey, name: WindowCatalog.cleanTabTitle(entry.title), entries: [entry])
        }
        return items
    }
    var objectiveItems: [ObjectiveItem] {
        let items = allObjectiveItems
        let term = objectiveQuery.replacingOccurrences(of: "@done", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsDone = showDoneObjectives || objectiveQuery.lowercased().split(separator: " ").contains("@done")
        return items.filter {
            (!$0.done || wantsDone) && (term.isEmpty || $0.name.localizedStandardContains(term)
                || $0.entries.contains { $0.searchText.localizedStandardContains(term) })
        }.sorted {
            if $0.done != $1.done { return !$0.done }
            if $0.waiting != $1.waiting { return $0.waiting }
            if $0.unread != $1.unread { return $0.unread }
            if ($0.id == currentObjectiveID) != ($1.id == currentObjectiveID) { return $0.id != currentObjectiveID }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func observeObjectives() {
        let before = objectiveItems
        let selectedID = before.indices.contains(objectiveSelection) ? before[objectiveSelection].id : nil
        for item in allObjectiveItems {
            for entry in item.entries { ledger.observe(id: item.id, entry: entry) }
        }
        if let selectedID, let index = objectiveItems.firstIndex(where: { $0.id == selectedID }) { objectiveSelection = index }
        objectWillChange.send()
    }
    func markObjective(_ item: ObjectiveItem, done: Bool) {
        ledger.update(item.id) { $0.done = done; if done { $0.unread = false } }
        objectiveSelection = 0
        objectWillChange.send()
    }
    func reviewObjective(_ item: ObjectiveItem) {
        ledger.update(item.id) { $0.unread = false }
        objectWillChange.send()
    }
}
