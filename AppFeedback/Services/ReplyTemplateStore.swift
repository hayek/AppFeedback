import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class ReplyTemplateStore {
    private(set) var templatesAll: [ReplyTemplate] = []

    private let context: ModelContext
    private var didSaveTask: Task<Void, Never>?
    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        reload()

        let ownContext = ObjectIdentifier(context)
        let didSaves = NotificationCenter.default.notifications(named: ModelContext.didSave)
            .compactMap { @Sendable note -> Bool? in
                let senderID = (note.object as? ModelContext).map(ObjectIdentifier.init)
                return senderID == ownContext ? nil : true
            }
        didSaveTask = Task { @MainActor [weak self] in
            for await _ in didSaves { self?.reload() }
        }
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) { self?.reload() }
        }
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded { self?.reload() }
        }
    }

    isolated deinit {
        didSaveTask?.cancel(); remoteChangeTask?.cancel(); cloudKitImportTask?.cancel()
    }

    // MARK: Queries

    /// Templates owned by one repo, newest-edited first.
    func templates(owner: String, repo: String) -> [ReplyTemplate] {
        templatesAll
            .filter { $0.repoOwner == owner && $0.repoName == repo }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Merged view across every repo (the "Global" tab), newest-edited first.
    func allTemplates() -> [ReplyTemplate] {
        templatesAll.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Mutations

    @discardableResult
    func create(owner: String, repo: String, title: String, body: String) -> ReplyTemplate {
        let t = ReplyTemplate(repoOwner: owner, repoName: repo, title: title, body: body)
        context.insert(t); save(); reload(); return t
    }

    func update(_ template: ReplyTemplate, title: String, body: String) {
        template.title = title
        template.body = body
        template.updatedAt = Date()
        save(); reload()
    }

    func delete(_ template: ReplyTemplate) {
        context.delete(template); save(); reload()
    }

    func save() { try? context.save() }

    // MARK: Internal

    private func reload() {
        templatesAll = (try? context.fetch(FetchDescriptor<ReplyTemplate>())) ?? []
    }
}
