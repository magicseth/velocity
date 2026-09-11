import Foundation

final class SelectionMemory {
    private let defaults: UserDefaults
    private(set) var currentKey: String?
    private(set) var recent: [String: Double]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recent = defaults.dictionary(forKey: "recentResults") as? [String: Double] ?? [:]
    }

    func observe(_ key: String, at date: Date = Date()) {
        guard currentKey != key else { return }
        currentKey = key
        record(key, at: date)
    }

    func record(_ key: String, at date: Date = Date()) {
        recent[key] = date.timeIntervalSince1970
        recent = Dictionary(uniqueKeysWithValues: recent.sorted { $0.value > $1.value }.prefix(80).map { ($0.key, $0.value) })
        defaults.set(recent, forKey: "recentResults")
    }
}
