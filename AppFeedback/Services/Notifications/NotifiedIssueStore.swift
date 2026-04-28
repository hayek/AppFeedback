import Foundation

final class NotifiedIssueStore {
    static func issueKey(owner: String, repo: String, number: Int) -> String {
        "\(owner)/\(repo)#\(number)"
    }

    private let defaults: UserDefaults
    private let cap: Int
    private let key = "appfeedback.notifiedIssueIDs"

    init(defaults: UserDefaults = .standard, cap: Int = 5_000) {
        self.defaults = defaults
        self.cap = cap
    }

    func contains(_ id: String) -> Bool {
        loadOrdered().contains(id)
    }

    func insert(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var ordered = loadOrdered()
        let existing = Set(ordered)
        for id in ids where !existing.contains(id) {
            ordered.append(id)
        }
        if ordered.count > cap {
            ordered.removeFirst(ordered.count - cap)
        }
        defaults.set(ordered, forKey: key)
    }

    func snapshot(_ ids: [String]) {
        insert(ids)
    }

    private func loadOrdered() -> [String] {
        defaults.array(forKey: key) as? [String] ?? []
    }
}
