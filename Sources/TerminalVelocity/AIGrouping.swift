import Foundation
import Security
import Darwin

struct GroupingCandidate: Codable, Identifiable, Equatable {
    let id: String
    let app: String
    let title: String
    let folder: String
    let tabs: [String]
}
struct SuggestedObjective: Codable, Identifiable {
    var name: String
    let reason: String
    let confidence: String
    let memberIds: [String]
    var id: String { memberIds.sorted().joined(separator: "|") }
}
struct GroupingResponse: Codable { let groups: [SuggestedObjective] }

enum AIGrouping {
    static func metadata(_ value: String, limit: Int) -> String {
        let title = value.components(separatedBy: " ◂ ")[0]
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            .replacingOccurrences(of: #"(?i)(sk-[a-z0-9_-]+|(?:token|api_key|password|secret)\s*[=:]\s*\S+)"#, with: "[redacted]", options: .regularExpression)
            .replacingOccurrences(of: #"(https?://[^\s?#]+)[?#][^\s]*"#, with: "$1", options: .regularExpression)
        return String(title.prefix(limit))
    }
    static func validate(_ groups: [SuggestedObjective], known: Set<String>) throws {
        var used: Set<String> = []
        guard groups.count <= known.count / 2 else { throw Failure("Too many suggested objectives.") }
        for group in groups {
            guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, group.name.count <= 80,
                  group.memberIds.count >= 2, group.memberIds.count <= known.count,
                  ["high", "medium", "low"].contains(group.confidence), !group.reason.isEmpty, group.reason.count <= 300 else {
                throw Failure("The gateway returned an invalid objective.")
            }
            for id in group.memberIds {
                guard known.contains(id), used.insert(id).inserted else { throw Failure("The gateway returned unknown or overlapping windows.") }
            }
        }
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    static func token(_ replacement: String? = nil) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.seth.terminal-velocity.grouping", kSecAttrAccount as String: "device-token"]
        if let replacement {
            let data = Data(replacement.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query; item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw Failure("Couldn’t save the device token in Keychain (\(status)).") }
            return replacement
        }
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure("Couldn’t read the device token from Keychain.")
        }
        return value
    }
    static func endpointURL(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host?.hasSuffix(".convex.site") == true,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/suggest-objectives" else { throw Failure("Enter your HTTPS Convex site URL ending in /suggest-objectives.") }
        return url
    }
    static func importConfiguration(arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: "--configure-grouping"), arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 99999 < 4096 else {
            throw Failure("Grouping setup requires a private configuration file owned by you.")
        }
        struct Configuration: Decodable { let endpoint: String; let token: String }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        _ = try endpointURL(configuration.endpoint)
        guard configuration.token.count >= 32 else { throw Failure("The device token is too short.") }
        _ = try token(configuration.token)
        UserDefaults.standard.set(configuration.endpoint, forKey: "groupingEndpoint")
        try FileManager.default.removeItem(atPath: path)
        return configuration.endpoint
    }
    static func responseError(status: Int?, data: Data) -> String {
        let detail: String
        if data.count <= 120000, let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"], !message.isEmpty {
            detail = String(message.prefix(300))
        } else {
            switch status {
            case 401, 403: detail = "Check the device token in Connection settings."
            case 404: detail = "Check the endpoint: use the deployment’s .convex.site URL followed by /suggest-objectives."
            case 413: detail = "The metadata request exceeded the server’s size limit."
            case 429: detail = "The gateway is busy. Wait a moment and try again."
            case 500, 502, 503, 504: detail = "The grouping service failed. Retry to continue from the last completed batch."
            default: detail = "Check the grouping endpoint in Connection settings and try again."
            }
        }
        return "Grouping failed" + (status.map { " (HTTP \($0))" } ?? "") + ": " + detail
    }
    static func classify(_ batch: ClassificationRequest, endpoint: String, token: String) async throws -> [ObjectiveAssignment] {
        guard Features.experimentalAgents else { throw Failure("Experimental agent features are disabled in this build.") }
        let base = try endpointURL(endpoint)
        let url = base.deletingLastPathComponent().appendingPathComponent("classify-objectives")
        guard token.count >= 32 else { throw Failure("A device token of at least 32 characters is required.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(batch)
        guard (request.httpBody?.count ?? 0) <= 2_000_000 else { throw Failure("The metadata request exceeded 2 MB.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 160
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(responseError(status: (response as? HTTPURLResponse)?.statusCode, data: data))
        }
        guard data.count <= 200000 else { throw Failure("The gateway response was too large.") }
        return try JSONDecoder().decode(ClassificationResponse.self, from: data).groups
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor extension PaletteModel {
    func beginAIGrouping() {
        guard Features.experimentalAgents else { return }
        guard !aiLoading else { showAIGrouping = true; return }
        aiScan = nil
        aiProcessed = 0
        aiSnapshot = [:]
        aiCandidates = []
        aiSuggestions = []
        aiChosenGroups = []
        aiError = nil
        var seen: Set<String> = []
        let assigned = Set(groups.flatMap(\.members))
        // Interleave apps so a large browser session cannot crowd out terminals and editors.
        let buckets = Dictionary(grouping: all.filter { !$0.isTab && $0.launchURL == nil && $0.windowKey.map { !assigned.contains($0) } == true }, by: \.appName)
        let apps = buckets.keys.sorted()
        let ordered = (0..<(buckets.values.map(\.count).max() ?? 0)).flatMap { index in
            apps.compactMap { app -> WindowEntry? in
                guard let entries = buckets[app], entries.indices.contains(index) else { return nil }
                return entries[index]
            }
        }
        for entry in ordered {
            guard let key = entry.windowKey, !assigned.contains(key), seen.insert(key).inserted else { continue }
            let id = "w\(aiCandidates.count + 1)"
            let tabs = all.filter { $0.isTab && ($0.windowKey == key || ($0.pid == entry.pid && $0.browserTab?.windowTitle == entry.title)) }
                .map { AIGrouping.metadata($0.title, limit: 200) + ($0.browserTab.flatMap { URL(string: $0.url)?.host }.map { " (" + $0 + ")" } ?? "") }
            let candidate = GroupingCandidate(id: id, app: AIGrouping.metadata(entry.appName, limit: 100),
                title: AIGrouping.metadata(entry.title, limit: 400),
                folder: String(entry.documentFolder.split(separator: "/").suffix(3).joined(separator: "/").prefix(200)), tabs: tabs.map { String($0.prefix(250)) })
            aiSnapshot[id] = entry
            aiCandidates.append(candidate)
        }
        aiSelectedCandidates = Set(aiCandidates.map(\.id))
        showAIGrouping = true
    }
    func requestAIGrouping() {
        guard Features.experimentalAgents, !aiLoading else { return }
        let candidates = aiCandidates.filter { aiSelectedCandidates.contains($0.id) }
        guard candidates.count >= 2 else { aiError = "Select at least two windows."; return }
        if aiScan?.candidates != candidates || aiScan?.endpoint != aiEndpoint {
            aiScan = GroupingScan(candidates: candidates, endpoint: aiEndpoint)
        }
        aiProcessed = aiScan?.processed ?? 0
        aiLoading = true; aiError = nil; aiSuggestions = []
        aiTask = Task { @MainActor in
            defer { aiLoading = false; aiTask = nil }
            do {
                let token = try AIGrouping.token(aiTokenInput.isEmpty ? nil : aiTokenInput)
                aiTokenInput = ""
                UserDefaults.standard.set(aiEndpoint, forKey: "groupingEndpoint")
                while let scan = aiScan, !scan.complete {
                    try Task.checkCancellation()
                    let request = try scan.nextRequest()
                    let assignments = try await AIGrouping.classify(request, endpoint: scan.endpoint, token: token)
                    try Task.checkCancellation()
                    try aiScan?.accept(assignments, for: request)
                    aiProcessed = aiScan?.processed ?? 0
                }
                aiSuggestions = aiScan?.suggestions ?? []
                try AIGrouping.validate(aiSuggestions, known: Set(candidates.map(\.id)))
                aiChosenGroups = Set(aiSuggestions.filter { $0.confidence == "high" }.map(\.id))
                if aiSuggestions.isEmpty { aiError = "All selected windows were checked; no convincing shared objectives were found." }
            } catch {
                // A failed batch gets smaller on the next user-initiated retry;
                // the remaining windows stay in the queue and none are dropped.
                if Task.isCancelled { aiError = "Paused after \(aiProcessed) of \(candidates.count) windows. Resume to continue." }
                else {
                    let reducedSize = max(1, (aiScan?.batchSize ?? 40) / 2)
                    aiScan?.batchSize = reducedSize
                    aiError = error.localizedDescription
                }
            }
        }
    }
    func applyAISuggestions() {
        guard Features.experimentalAgents else { return }
        var added: [WindowGroup] = []
        var used = Set(groups.flatMap(\.members))
        do {
            try AIGrouping.validate(aiSuggestions.filter { aiChosenGroups.contains($0.id) }, known: Set(aiSnapshot.keys))
            for suggestion in aiSuggestions where aiChosenGroups.contains(suggestion.id) {
                var keys: Set<String> = []
                for id in suggestion.memberIds {
                    guard let original = aiSnapshot[id], let key = original.windowKey,
                          all.contains(where: { $0.windowKey == key && !$0.isTab && $0.groupFingerprint == original.groupFingerprint }),
                          used.insert(key).inserted else { throw AIGrouping.Failure("A window changed or was already grouped. Refresh the suggestions before applying them.") }
                    keys.insert(key)
                }
                added.append(WindowGroup(id: UUID(), name: suggestion.name, members: keys))
            }
            groups.append(contentsOf: added)
            persistGroups()
            showAIGrouping = false
            objectiveMode = true
        } catch { aiError = error.localizedDescription }
    }
}
