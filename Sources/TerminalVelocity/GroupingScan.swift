import Foundation

struct ObjectiveAssignment: Codable {
    let objectiveID: String?
    let name: String
    let reason: String
    let confidence: String
    let memberIds: [String]
}
struct ClassificationResponse: Codable { let groups: [ObjectiveAssignment] }
struct ObjectiveCatalogItem: Codable {
    let id: String
    let name: String
    let reason: String
}
struct WindowOverview: Codable {
    let id: String
    let app: String
    let title: String
    let folder: String
}
struct ClassificationRequest: Codable {
    let candidates: [GroupingCandidate]
    let overview: [WindowOverview]
    let objectives: [ObjectiveCatalogItem]
}

/// A scan is local, resumable while the app runs, and never applies groups itself.
/// Every batch sees the full desktop overview and the accumulated objective catalog.
struct GroupingScan {
    let candidates: [GroupingCandidate]
    let endpoint: String
    var processed = 0
    var batchSize = 40
    private(set) var catalog: [ObjectiveCatalogItem] = []
    private(set) var proposals: [SuggestedObjective] = []
    var complete: Bool { processed == candidates.count }
    var suggestions: [SuggestedObjective] { proposals.filter { $0.memberIds.count >= 2 } }

    func nextRequest() throws -> ClassificationRequest {
        let overview = candidates.map {
            WindowOverview(id: $0.id, app: $0.app, title: String($0.title.prefix(160)), folder: String($0.folder.prefix(120)))
        }
        var size = min(batchSize, candidates.count - processed)
        while size > 0 {
            let request = ClassificationRequest(candidates: Array(candidates[processed..<(processed + size)]), overview: overview, objectives: catalog)
            if try JSONEncoder().encode(request).count <= 1_900_000 { return request }
            if size == 1 { break }
            size = max(1, size / 2)
        }
        throw AIGrouping.Failure("The desktop metadata exceeds the 2 MB request budget. No windows have been silently omitted.")
    }

    mutating func accept(_ output: [ObjectiveAssignment], for request: ClassificationRequest) throws {
        let ids = request.candidates.map(\.id)
        guard !ids.isEmpty, Array(candidates.dropFirst(processed).prefix(ids.count).map(\.id)) == ids else {
            throw AIGrouping.Failure("The grouping batch no longer matches this scan.")
        }
        let known = Set(ids), existing = Set(catalog.map(\.id))
        var used: Set<String> = []
        for assignment in output {
            guard !assignment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, assignment.name.count <= 80,
                  !assignment.reason.isEmpty, assignment.reason.count <= 300,
                  ["high", "medium", "low"].contains(assignment.confidence), !assignment.memberIds.isEmpty,
                  assignment.objectiveID.map({ existing.contains($0) }) ?? true else {
                throw AIGrouping.Failure("Invalid objective in this batch. Retry to continue.")
            }
            for id in assignment.memberIds {
                guard known.contains(id), used.insert(id).inserted else {
                    throw AIGrouping.Failure("Invalid or overlapping windows in this batch. Retry to continue.")
                }
            }
        }
        // Validate the entire response before changing the checkpoint.
        for assignment in output {
            if let id = assignment.objectiveID, let index = catalog.firstIndex(where: { $0.id == id }) {
                let previous = proposals[index]
                let confidence = [previous.confidence, assignment.confidence].contains("low") ? "low" :
                    [previous.confidence, assignment.confidence].contains("medium") ? "medium" : "high"
                proposals[index] = SuggestedObjective(name: previous.name, reason: previous.reason, confidence: confidence,
                                                      memberIds: previous.memberIds + assignment.memberIds)
            } else {
                catalog.append(ObjectiveCatalogItem(id: "g\(catalog.count + 1)", name: assignment.name, reason: assignment.reason))
                proposals.append(SuggestedObjective(name: assignment.name, reason: assignment.reason,
                                                    confidence: assignment.confidence, memberIds: assignment.memberIds))
            }
        }
        processed += ids.count
    }
}
