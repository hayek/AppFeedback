import Foundation
import Observation
import SwiftData
import CoreData

@Observable @MainActor
final class ProductStore {
    private(set) var repos: [ProductConfig] = []
    /// Preferred name in all NEW code. Mirrors the stored `repos` array (the stored
    /// name is kept to avoid churning existing `store.repos` call sites). Reading
    /// `products` registers the same Observation dependency as reading `repos`.
    var products: [ProductConfig] { repos }
    private(set) var hiddenApps: [UUID: Set<String>] = [:]
    private(set) var appColors: [UUID: [String: String]] = [:]

    private let context: ModelContext
    private let hiddenAppStore: HiddenAppStore?
    private var didSaveTask: Task<Void, Never>?
    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext, hiddenAppStore: HiddenAppStore? = nil) {
        self.context = context
        self.hiddenAppStore = hiddenAppStore
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

        // Belt-and-suspenders alongside NSPersistentStoreRemoteChange: that notification can
        // be missed or arrive before imported rows are visible to fetches on a fresh install.
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded {
                self?.reload()
            }
        }
    }

    isolated deinit {
        didSaveTask?.cancel()
        remoteChangeTask?.cancel()
        cloudKitImportTask?.cancel()
    }

    // MARK: - Products

    func add(_ repo: ProductConfig) {
        let model = Product(
            id: repo.id,
            displayName: repo.displayName,
            owner: repo.owner,
            repo: repo.repo,
            colorHex: repo.colorHex,
            mirrorEmailsToGitHub: repo.mirrorEmailsToGitHub,
            redactEmailAddresses: repo.redactEmailAddresses,
            connectedRepoOwner: repo.connectedRepoOwner,
            connectedRepoName: repo.connectedRepoName,
            appStoreIssuerID: repo.appStoreIssuerID,
            appStoreKeyID: repo.appStoreKeyID,
            appStoreAppAppleID: repo.appStoreAppAppleID,
            feedbackInboxAccountID: repo.feedbackInboxAccountID
        )
        context.insert(model)
        save()
        reload()
    }

    func update(_ repo: ProductConfig) {
        guard let model = fetchModel(id: repo.id) else { return }
        model.displayName = repo.displayName
        model.owner = repo.owner
        model.repo = repo.repo
        model.mirrorEmailsToGitHub = repo.mirrorEmailsToGitHub
        model.redactEmailAddresses = repo.redactEmailAddresses
        model.connectedRepoOwner = repo.connectedRepoOwner
        model.connectedRepoName = repo.connectedRepoName
        model.colorHex = repo.colorHex
        model.appStoreIssuerID = repo.appStoreIssuerID
        model.appStoreKeyID = repo.appStoreKeyID
        model.appStoreAppAppleID = repo.appStoreAppAppleID
        model.feedbackInboxAccountID = repo.feedbackInboxAccountID
        save()
        reload()
    }

    func remove(id: UUID) async {
        guard let model = fetchModel(id: id) else { return }
        let config = ProductConfig(
            id: model.id,
            displayName: model.displayName,
            owner: model.owner,
            repo: model.repo,
            mirrorEmailsToGitHub: model.mirrorEmailsToGitHub,
            redactEmailAddresses: model.redactEmailAddresses,
            connectedRepoOwner: model.connectedRepoOwner,
            connectedRepoName: model.connectedRepoName
        )
        await KeychainService.delete(for: config)
        context.delete(model)
        save()
        reload()
    }

    // MARK: - Hidden apps

    func hideApp(_ appName: String, in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        hiddenAppStore?.hide(owner: model.owner, repo: model.repo, appName: appName)
        reload()
    }

    func unhideAllApps(in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        hiddenAppStore?.unhideAll(owner: model.owner, repo: model.repo)
        reload()
    }

    func hiddenAppsFor(_ repoId: UUID) -> Set<String> {
        hiddenApps[repoId] ?? []
    }

    // MARK: - App colors

    func setColor(_ hex: String, forApp appName: String, in repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        if model.appColors[appName] == hex { return }
        model.appColors[appName] = hex
        save()
        reload()
    }

    func colorHexFor(app appName: String, in repoId: UUID) -> String? {
        appColors[repoId]?[appName]
    }

    // MARK: - Product color

    /// Set (or clear, with `nil`) the sidebar accent color for a product.
    func setColor(_ hex: String?, forRepo repoId: UUID) {
        guard let model = fetchModel(id: repoId) else { return }
        if model.colorHex == hex { return }
        model.colorHex = hex
        save()
        reload()
    }

    func colorHexFor(repo repoId: UUID) -> String? {
        repos.first { $0.id == repoId }?.colorHex
    }

    // MARK: - Internal

    private func fetchModel(id: UUID) -> Product? {
        let descriptor = FetchDescriptor<Product>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func save() {
        try? context.save()
    }

    private func reload() {
        let models = (try? context.fetch(FetchDescriptor<Product>(
            sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
        let newRepos = models.map {
            ProductConfig(
                id: $0.id,
                displayName: $0.displayName,
                owner: $0.owner,
                repo: $0.repo,
                mirrorEmailsToGitHub: $0.mirrorEmailsToGitHub,
                redactEmailAddresses: $0.redactEmailAddresses,
                connectedRepoOwner: $0.connectedRepoOwner,
                connectedRepoName: $0.connectedRepoName,
                colorHex: $0.colorHex,
                appStoreIssuerID: $0.appStoreIssuerID,
                appStoreKeyID: $0.appStoreKeyID,
                appStoreAppAppleID: $0.appStoreAppAppleID,
                feedbackInboxAccountID: $0.feedbackInboxAccountID
            )
        }
        // Build hidden-app map from HiddenAppStore (CloudKit-synced) with one-time
        // best-effort migration from legacy Product.hiddenAppNames into HiddenApp rows.
        var newHiddenApps: [UUID: Set<String>] = [:]
        for model in models {
            if let store = hiddenAppStore {
                store.migrateLegacy(owner: model.owner, repo: model.repo, legacyNames: model.hiddenAppNames)
                newHiddenApps[model.id] = store.hiddenApps(owner: model.owner, repo: model.repo)
            } else {
                // Fallback for tests that don't inject a store: read from legacy field.
                newHiddenApps[model.id] = Set(model.hiddenAppNames)
            }
        }
        let newAppColors = Dictionary(
            uniqueKeysWithValues: models.map { ($0.id, $0.appColors) }
        )
        if repos != newRepos { repos = newRepos }
        if hiddenApps != newHiddenApps { hiddenApps = newHiddenApps }
        if appColors != newAppColors { appColors = newAppColors }
    }
}

extension NotificationCenter {
    /// Successful `.import` events from `NSPersistentCloudKitContainer`, signaling that
    /// remote rows have been merged into the local store and a refetch will see them.
    static var cloudKitImportSucceeded: AsyncCompactMapSequence<NotificationCenter.Notifications, Bool> {
        NotificationCenter.default
            .notifications(named: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { @Sendable note -> Bool? in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      event.type == .import,
                      event.succeeded
                else { return nil }
                return true
            }
    }
}
