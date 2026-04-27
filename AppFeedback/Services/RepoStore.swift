import Foundation
import Observation
import SwiftData
import CoreData

@Observable @MainActor
final class RepoStore {
    private(set) var repos: [RepoConfig] = []
    private(set) var hiddenApps: [UUID: Set<String>] = [:]

    private let context: ModelContext
    private var didSaveTask: Task<Void, Never>?
    private var remoteChangeTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        reload()

        // Filter out notifications from our own context — those mutations already called reload().
        let ownContext = ObjectIdentifier(context)
        let didSaves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            .compactMap { @Sendable note -> Bool? in
                let senderID = (note.object as? ModelContext).map(ObjectIdentifier.init)
                return senderID == ownContext ? nil : true
            }
        didSaveTask = Task { @MainActor [weak self] in
            for await _ in didSaves {
                self?.reload()
            }
        }

        // CloudKit pulls merge into the persistent store coordinator and post this notification,
        // not ModelContext.didSave. Without it, remote changes wouldn't surface to the UI.
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                self?.reload()
            }
        }
    }

    isolated deinit {
        didSaveTask?.cancel()
        remoteChangeTask?.cancel()
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

    func remove(id: UUID) async {
        guard let model = fetchModel(id: id) else { return }
        let config = RepoConfig(id: model.id, displayName: model.displayName, owner: model.owner, repo: model.repo)
        await KeychainService.delete(for: config)
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
        let newRepos = models.map {
            RepoConfig(id: $0.id, displayName: $0.displayName, owner: $0.owner, repo: $0.repo)
        }
        let newHiddenApps = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, Set($0.hiddenAppNames)) }
        )
        if repos != newRepos { repos = newRepos }
        if hiddenApps != newHiddenApps { hiddenApps = newHiddenApps }
    }
}
