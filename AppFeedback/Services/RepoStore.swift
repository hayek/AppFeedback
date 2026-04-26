import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class RepoStore {
    private(set) var repos: [RepoConfig] = []
    private(set) var hiddenApps: [UUID: Set<String>] = [:]

    private let context: ModelContext
    nonisolated(unsafe) private var didSaveObserver: NSObjectProtocol?

    init(context: ModelContext) {
        self.context = context
        reload()
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let didSaveObserver {
            NotificationCenter.default.removeObserver(didSaveObserver)
        }
    }

    // MARK: - Repos

    func add(_ repo: RepoConfig) {
        let model = Repo(
            id: repo.id,
            displayName: repo.displayName,
            owner: repo.owner,
            repo: repo.repo
        )
        context.insert(model)
        save()
        reload()
    }

    func update(_ repo: RepoConfig) {
        guard let model = fetchModel(id: repo.id) else { return }
        model.displayName = repo.displayName
        model.owner = repo.owner
        model.repo = repo.repo
        save()
        reload()
    }

    func remove(id: UUID) {
        guard let model = fetchModel(id: id) else { return }
        context.delete(model)
        save()
        reload()
    }

    // MARK: - Hidden apps

    func hideApp(_ appName: String, in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        var names = Set(model.hiddenAppNames)
        names.insert(appName)
        model.hiddenAppNames = Array(names)
        save()
        reload()
    }

    func unhideAllApps(in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        model.hiddenAppNames = []
        save()
        reload()
    }

    func hiddenAppsFor(_ repoId: UUID) -> Set<String> {
        hiddenApps[repoId] ?? []
    }

    // MARK: - Internal

    private func fetchModel(id: UUID) -> Repo? {
        let descriptor = FetchDescriptor<Repo>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        try? context.save()
    }

    private func reload() {
        let models = (try? context.fetch(FetchDescriptor<Repo>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
        repos = models.map {
            RepoConfig(id: $0.id, displayName: $0.displayName, owner: $0.owner, repo: $0.repo)
        }
        hiddenApps = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, Set($0.hiddenAppNames)) }
        )
    }
}
