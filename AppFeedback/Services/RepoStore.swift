import Foundation
import Observation

@Observable @MainActor
final class RepoStore {
    var repos: [RepoConfig] = []

    private let defaults: UserDefaults
    private let key = "feedbackviewer.repos"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(_ repo: RepoConfig) {
        repos.append(repo)
        save()
    }

    func update(_ repo: RepoConfig) {
        guard let index = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        repos[index] = repo
        save()
    }

    func remove(id: UUID) {
        repos.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(repos) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RepoConfig].self, from: data)
        else { return }
        repos = decoded
    }
}
