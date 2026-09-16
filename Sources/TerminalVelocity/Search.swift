import Foundation

struct SearchQuery {
    let text: String
    let commands: Set<String>
    let apps: [String]
    let folders: [String]
    static let known: Set<String> = ["@closed", "@projects", "@attention", "@ready", "@waiting", "@agents", "@audio", "@playing", "@muted", "@recent", "@tabs", "@windows", "@minimized"]

    init(_ query: String) {
        // Quotes allow app and folder names containing spaces.
        var tokens: [String] = [], token = "", quoted = false
        for character in query {
            if character == "\"" { quoted.toggle() }
            else if character.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(character) }
        }
        if !token.isEmpty { tokens.append(token) }
        commands = Set(tokens.map { $0.lowercased() }.filter { Self.known.contains($0) })
        var appNames: [String] = [], folderNames: [String] = [], words: [String] = []
        for token in tokens {
            let lower = token.lowercased()
            if Self.known.contains(lower) { continue }
            if lower.hasPrefix("app:"), token.count > 4 { appNames.append(String(token.dropFirst(4))) }
            else if lower.hasPrefix("@"), token.count > 1 { appNames.append(String(token.dropFirst())) }
            else if lower.hasPrefix("folder:"), token.count > 7 { folderNames.append(String(token.dropFirst(7))) }
            else { words.append(token) }
        }
        apps = appNames; folders = folderNames
        text = words.joined(separator: " ")
    }

    func accepts(_ entry: WindowEntry, recent: Bool) -> Bool {
        if commands.contains("@closed") && entry.closedTab == nil { return false }
        if !apps.allSatisfy({ entry.appName.localizedStandardContains($0) }) { return false }
        if !folders.allSatisfy({ entry.documentFolder.localizedStandardContains($0) }) { return false }
        if commands.contains("@projects") && entry.chatProject == nil { return false }
        if commands.contains("@attention") && !entry.attention.needsAttention { return false }
        if commands.contains("@waiting") && entry.attention != .needsInput { return false }
        if commands.contains("@ready") && entry.attention != .idle { return false }
        if commands.contains("@agents") && entry.attention == .none { return false }
        if commands.contains("@audio") && entry.audio == .none { return false }
        if commands.contains("@playing") && entry.audio != .playing && entry.audio != .appOutput { return false }
        if commands.contains("@muted") && entry.audio != .muted { return false }
        if commands.contains("@recent") && !recent { return false }
        if commands.contains("@tabs") && !entry.isTab { return false }
        if commands.contains("@windows") && (entry.isTab || entry.windowKey == nil) { return false }
        if commands.contains("@minimized") && !entry.minimized { return false }
        return true
    }
}

enum WindowSearch {
    static func score(query: String, title: String, app: String) -> Int? {
        let tokens = normalize(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty { return 0 }
        let title = normalize(title), app = normalize(app)
        var result = 0
        for token in tokens {
            if title == token { result += 150 }
            else if title.hasPrefix(token) { result += 110 }
            else if title.contains(token) { result += 85 }
            else if app.hasPrefix(token) { result += 75 }
            else if app.contains(token) { result += 60 }
            // Short abbreviations are useful; long scattered subsequences in
            // shell command lines look like unrelated search results.
            else if token.count <= 4 && (isSubsequence(token, of: title) || isSubsequence(token, of: app)) { result += 20 }
            else { return nil }
        }
        return result
    }

    static func excerpt(query: String, title: String, limit: Int = 70) -> String {
        guard title.count > limit else { return title }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let match = tokens.compactMap {
            title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        guard let match else { return title }
        let offset = title.distance(from: title.startIndex, to: match.lowerBound)
        guard offset > limit / 2 else { return title }
        let start = title.index(match.lowerBound, offsetBy: -20, limitedBy: title.startIndex) ?? title.startIndex
        return "…" + title[start...]
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle.makeIterator()
        guard var next = remaining.next() else { return true }
        for character in haystack where character == next {
            guard let following = remaining.next() else { return true }
            next = following
        }
        return false
    }
}
