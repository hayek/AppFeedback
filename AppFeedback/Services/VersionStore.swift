import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class VersionStore {
    private(set) var versionsAll: [ProjectVersion] = []
    private(set) var sentAll: [SentReleaseNotification] = []

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

    func versions(owner: String, repo: String) -> [ProjectVersion] {
        versionsAll
            .filter { $0.repoOwner == owner && $0.repoName == repo }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func alreadyNotifiedEmails(owner: String, repo: String, versionName: String) -> Set<String> {
        Set(sentAll
            .filter { $0.repoOwner == owner && $0.repoName == repo && $0.versionName == versionName && $0.status == .sent }
            .map(\.recipientEmail))
    }

    func sentNotifications(owner: String, repo: String, versionName: String) -> [SentReleaseNotification] {
        sentAll
            .filter { $0.repoOwner == owner && $0.repoName == repo && $0.versionName == versionName }
            .sorted { $0.sentAt > $1.sentAt }
    }

    // MARK: Mutations

    @discardableResult
    func create(repoOwner: String, repoName: String, name: String, changelog: String) -> ProjectVersion {
        let v = ProjectVersion(repoOwner: repoOwner, repoName: repoName, name: name, changelog: changelog)
        context.insert(v); save(); reload(); return v
    }

    func save() { try? context.save() }   // call after mutating a ProjectVersion in place, then reload()
    func saveAndReload() { save(); reload() }

    func recordSent(repoOwner: String, repoName: String, versionName: String, recipientEmail: String,
                    feedbackNumbers: [Int], threadIssueNumber: Int, status: SentReleaseNotification.Status,
                    errorDetail: String? = nil) {
        let row = SentReleaseNotification(repoOwner: repoOwner, repoName: repoName, versionName: versionName,
            recipientEmail: recipientEmail, feedbackNumbers: feedbackNumbers, threadIssueNumber: threadIssueNumber,
            status: status, errorDetail: errorDetail)
        context.insert(row); save(); reload()
    }

    func delete(_ version: ProjectVersion) { context.delete(version); save(); reload() }

    // MARK: Internal

    private func reload() {
        versionsAll = (try? context.fetch(FetchDescriptor<ProjectVersion>())) ?? []
        sentAll = (try? context.fetch(FetchDescriptor<SentReleaseNotification>())) ?? []
    }
}
