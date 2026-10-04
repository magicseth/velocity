import Foundation

/// CODEX MIRRORS ONE APPROVAL INTO EVERY OPEN CODEX WINDOW ("Thread: Agent (01a10539)" … "or o
/// to open thread"). Eleven windows showed the same dialog and read as eleven things waiting
/// on him ("it is actually showing the same prompt in multiple windows"). The dialog names its
/// thread; the thread's rollout file names its folder — so the ask is ONE, and it belongs to
/// the window working in that folder.
enum CodexThreads {
    /// "Thread: Agent (01a10539)" → "01a10539".
    static func threadId(inPrompt prompt: String) -> String? {
        guard let r = prompt.range(of: #"Thread:[^\n]*\(([0-9a-f]{6,})\)"#, options: .regularExpression) else { return nil }
        let s = String(prompt[r])
        guard let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        return String(s[s.index(after: open)..<close])
    }

    nonisolated(unsafe) private static var cwdCache: [String: String] = [:]
    private static let lock = NSLock()

    /// The working folder of the Codex thread whose id starts with `prefix` — from its rollout's
    /// session_meta (~/.codex/sessions/YYYY/MM/DD/rollout-…-<id>.jsonl), newest days first.
    static func cwd(threadPrefix prefix: String) -> String? {
        lock.lock(); if let hit = cwdCache[prefix] { lock.unlock(); return hit }; lock.unlock()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        for back in 0..<4 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            guard let name = files.first(where: { $0.contains("-\(prefix)") && $0.hasSuffix(".jsonl") }),
                  let handle = FileHandle(forReadingAtPath: dir.appendingPathComponent(name).path) else { continue }
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 8192)
            guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any], let cwd = payload["cwd"] as? String else { continue }
            lock.lock(); cwdCache[prefix] = cwd; lock.unlock()
            return cwd
        }
        return nil
    }

    /// Collapse mirrors: of reports showing the same thread's dialog, keep ONE — the window whose
    /// title names the thread's folder, else the first. Reports without a thread are untouched.
    static func collapse<T>(_ items: [(report: JuliaReport, title: String, extra: T)], cwd: (String) -> String? = cwd(threadPrefix:)) -> [JuliaReport] {
        var out: [JuliaReport] = []
        var groups: [String: [(report: JuliaReport, title: String, extra: T)]] = [:]
        var order: [String] = []
        for item in items {
            guard let prompt = item.report.prompt, let id = threadId(inPrompt: prompt) else { out.append(item.report); continue }
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(item)
        }
        for id in order {
            let group = groups[id]!
            let folder = cwd(id).map { ($0 as NSString).lastPathComponent.lowercased() }
            let owner = folder.flatMap { f in group.first { $0.title.lowercased().contains(f) } } ?? group[0]
            out.append(owner.report)
        }
        return out.sorted { $0.externalId < $1.externalId }
    }
}
