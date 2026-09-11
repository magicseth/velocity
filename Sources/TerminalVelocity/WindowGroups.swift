import Foundation

struct WindowGroup: Identifiable, Codable {
    let id: UUID
    var name: String
    var members: Set<String>
    var rememberedMembers: Set<String> = []

    static func companions(of entry: WindowEntry, groups: [WindowGroup], entries: [WindowEntry]) -> [WindowEntry] {
        guard let key = entry.windowKey, let group = groups.first(where: { $0.members.contains(key) }) else { return [] }
        var seen: Set<String> = [key]
        return entries.filter {
            guard !$0.isTab, $0.launchURL == nil, let member = $0.windowKey, group.members.contains(member), seen.insert(member).inserted else { return false }
            return true
        }
    }
}
