import Foundation

struct MatchWindow: Codable, Equatable { let id: String; let app: String; let title: String }
struct WindowMatches: Decodable {
    let ids: [String]
    func resolve(_ windows: [MatchWindow], entryIDs: [String]) throws -> [String] {
        guard ids.count <= 12, Set(ids).count == ids.count, windows.count == entryIDs.count, Set(windows.map(\.id)).count == windows.count else { throw AccessError.unsupported }
        let known = Dictionary(uniqueKeysWithValues: zip(windows.map(\.id), entryIDs))
        return try ids.map { guard let id = known[$0] else { throw AccessError.unavailable }; return id }
    }
}
@MainActor final class LiveWindowMatcher {
    typealias Fetch = (String, [MatchWindow], String) async throws -> WindowMatches
    private var task: Task<Void, Never>?
    private var key: String?
    private var generation = UUID()
    private var cache: [String: [String]] = [:]
    private var cacheOrder: [String] = []
    private let fetch: Fetch
    private let delay: UInt64
    init(delay: UInt64 = 350_000_000, fetch: @escaping Fetch = LiveWindowMatcher.fetch) { self.delay = delay; self.fetch = fetch }
    func cancel() { task?.cancel(); task = nil; key = nil; generation = UUID() }
    func schedule(query: String, windows: [MatchWindow], entryIDs: [String], endpoint: String,
                  status: @escaping (String?) -> Void, apply: @escaping ([String]) -> Void) {
        guard query.count >= 3, query.count <= 500, !windows.isEmpty, !endpoint.isEmpty else { cancel(); status(nil); return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = AccessStorage.digest(endpoint + "|" + query + "|" + (String(data: (try? encoder.encode(windows)) ?? Data(), encoding: .utf8) ?? "") + "|" + entryIDs.joined(separator: "|"))
        guard key != digest else { return }
        cancel(); key = digest
        let current = generation
        if let cached = cache[digest] { status("AI cached"); apply(cached); return }
        status("Waiting to search…")
        task = Task {
            do {
                try await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, generation == current else { return }
                status("AI matching…")
                let started = Date()
                let result = try await fetch(query, windows, endpoint)
                guard !Task.isCancelled, generation == current else { return }
                let resolved = try result.resolve(windows, entryIDs: entryIDs)
                cache[digest] = resolved; cacheOrder.append(digest)
                if cacheOrder.count > 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                status(String(format: "AI %.1fs", Date().timeIntervalSince(started)))
                apply(resolved)
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                status("AI unavailable · local search")
            }
        }
    }
    static func fetch(query: String, windows: [MatchWindow], endpoint: String) async throws -> WindowMatches {
        struct Input: Encodable { let query: String; let windows: [MatchWindow] }
        let base = try AIGrouping.endpointURL(endpoint)
        let token = try AIGrouping.token()
        guard token.count >= 32 else { throw AccessError.unauthorized }
        var request = URLRequest(url: base.deletingLastPathComponent().appendingPathComponent("match-windows"))
        request.httpMethod = "POST"; request.timeoutInterval = 12
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Input(query: query, windows: windows))
        guard request.httpBody!.count <= 2_000_000 else { throw AccessError.limited }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 10000 else { throw AccessError.unavailable }
        return try JSONDecoder().decode(WindowMatches.self, from: data)
    }
}

@MainActor extension PaletteModel {
    func scheduleLiveMatching() {
        guard Features.experimentalAgents, liveMatchingEnabled, liveMatchingActive else { liveMatcher.cancel(); liveMatchStatus = nil; return }
        let parsed = SearchQuery(query)
        let entries = ResultDeduplication.apply(all.filter { $0.launchURL == nil && parsed.accepts($0, recent: (memory.recent[$0.memoryKey] ?? 0) > 0) })
        let windows = entries.enumerated().map { index, entry in
            MatchWindow(id: String(index), app: String(entry.appName.prefix(100)), title: AIGrouping.metadata(entry.title, limit: 250))
        }
        liveMatcher.schedule(query: parsed.text.trimmingCharacters(in: .whitespacesAndNewlines), windows: windows, entryIDs: entries.map(\.id), endpoint: aiEndpoint,
            status: { [weak self] in self?.liveMatchStatus = $0 }, apply: { [weak self] ids in
                guard let self else { return }
                self.liveMatchIDs = ids
                self.filter(preserveSelection: true)
            })
    }
}
