import Foundation
import Observation
import SwiftData
import CoreData

@Observable @MainActor
final class RepoStore {
    private(set) var repos: [RepoConfig] = []
    private(set) var hiddenApps: [UUID: Set<String>] = [:]

    private let context: ModelContext
    nonisolated(unsafe) private var didSaveObserver: NSObjectProtocol?
    nonisolated(unsafe) private var remoteChangeObserver: NSObjectProtocol?

    init(context: ModelContext) {
        self.context = context
        reload()
        didSaveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Ignore notifications from our own context — those mutations already called reload().
            if let sender = note.object as? ModelContext, sender === self.context { return }
            Task { @MainActor in self.reload() }
        }
        // CloudKit pulls merge into the persistent store coordinator and post this notification,
        // not ModelContext.didSave. Without it, remote changes wouldn't surface to the UI.
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
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
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
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
        guard let model = fetchModel(id: repoId),
              !model.hiddenAppNames.contains(appName) else { return }
        model.hiddenAppNames.append(appName)
        save()
        reload()
    }

    func unhideAllApps(in repoId: UUID) {
        guard let model = fetchModel(id: repoId),
              !model.hiddenAppNames.isEmpty else { return }
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
