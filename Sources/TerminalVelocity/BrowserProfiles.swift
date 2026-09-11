import Foundation

extension WindowCatalog {
    static func profileName(windowTitle: String, appName: String) -> String? {
        if windowTitle.hasSuffix(" - " + appName + " (Incognito)") { return "Incognito" }
        guard let range = windowTitle.range(of: " - " + appName + " - ", options: .backwards) else { return nil }
        let name = windowTitle[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func browserWindowAssociations(windows: [WindowEntry], accessibleTabs: [WindowEntry], scriptTabs: [BrowserTab], appName: String) -> [Int: WindowEntry] {
        let grouped = Dictionary(grouping: scriptTabs, by: \.windowID)
        var associations: [Int: WindowEntry] = [:]
        for (id, tabs) in grouped {
            guard let first = tabs.first else { continue }
            let exact = windows.filter { $0.title == first.windowTitle }
            let sameScriptTitle = grouped.values.filter { $0.first?.windowTitle == first.windowTitle }.count
            if exact.count == 1 && sameScriptTitle == 1 { associations[id] = exact[0]; continue }
            let normalized = browserWindowTitle(first.windowTitle, appName: appName)
            let matching = windows.filter { browserWindowTitle($0.title, appName: appName) == normalized }
            let sameNormalized = grouped.values.filter { $0.first.map { browserWindowTitle($0.windowTitle, appName: appName) == normalized } == true }.count
            if matching.count == 1 && sameNormalized == 1 { associations[id] = matching[0]; continue }
            // A unique tab in a window can identify its siblings even if their
            // titles (e.g. Gmail inboxes) occur in several profiles.
            var evidence: Set<String> = []
            for tab in tabs where scriptTabs.filter({ $0.title == tab.title }).count == 1 {
                let axMatches = accessibleTabs.filter { cleanTabTitle($0.title) == tab.title }
                if axMatches.count == 1, let key = axMatches[0].windowKey { evidence.insert(key) }
            }
            if evidence.count == 1, let window = windows.first(where: { $0.windowKey.map { evidence.contains($0) } == true }) {
                associations[id] = window
            }
        }
        // Conflicting mappings are not a basis for assigning a profile.
        let counts = Dictionary(grouping: associations.values, by: \.windowKey).mapValues(\.count)
        return associations.filter { counts[$0.value.windowKey] == 1 }
    }
}
