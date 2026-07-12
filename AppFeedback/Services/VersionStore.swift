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

    /// Emails already successfully notified for `version` — the only guard against re-emailing a
    /// user on a second release pass.
    func alreadyNotifiedEmails(for version: ProjectVersion) -> Set<String> {
        Set(sentAll
            .filter { matches($0, version) && $0.status == .sent }
            .map(\.recipientEmail))
    }

    func sentNotifications(for version: ProjectVersion) -> [SentReleaseNotification] {
        sentAll
            .filter { matches($0, version) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// Does `row` belong to `version`?
    ///
    /// Stamped rows match by UUID, so a rename can never hide them. Only rows *unclaimed* by any
    /// version (legacy rows from builds before `versionID` existed) fall back to matching by name —
    /// and `rename` stamps those as it rewrites them, so the fallback shrinks to nothing over time.
    ///
    /// Deliberately side-effect-free: `VersionDetailView` calls `sentNotifications` from a computed
    /// property during view body evaluation, so stamping here would mutate models mid-update.
    private func matches(_ row: SentReleaseNotification, _ version: ProjectVersion) -> Bool {
        if let rowVersionID = row.versionID { return rowVersionID == version.id }
        return row.repoOwner == version.repoOwner
            && row.repoName == version.repoName
            && row.versionName == version.name
    }

    // MARK: Mutations

    /// Creates a version, rejecting an empty or duplicate name.
    ///
    /// Validation lives here, not just in the sheet, because `name` is the foreign key that joins
    /// tasks, sent release emails, and saved filters to a version. Two versions sharing a name
    /// inside one product silently merge each other's task lists — and a rename of either one
    /// rewrites *both* versions' cached issues, migrating the other's tasks away. `rename` has
    /// always validated; create is the door that was left open.
    @discardableResult
    func create(repoOwner: String, repoName: String, name: String, releaseTitle: String = "", changelog: String) throws -> ProjectVersion {
        let validated = try VersionNameValidator.validate(
            name, existing: versions(owner: repoOwner, repo: repoName))
        let v = ProjectVersion(repoOwner: repoOwner, repoName: repoName, name: validated, releaseTitle: releaseTitle, changelog: changelog)
        context.insert(v); save(); reload(); return v
    }

    /// Renames `version` and re-points the sent-email rows that belong to it.
    ///
    /// Local only — the caller is responsible for having already PATCHed the GitHub milestone title
    /// (see `VersionService.rename`), because `TaskItem.milestoneTitle` is sourced *from* GitHub and
    /// a local-only rename would be reverted by the next sync.
    ///
    /// The rows are resolved *before* the name changes, so legacy rows (which match by name) are
    /// still found; each is then stamped with the version's id so it will never need the name again.
    func rename(_ version: ProjectVersion, to newName: String) {
        let rows = sentAll.filter { matches($0, version) }
        version.name = newName
        for row in rows {
            row.versionID = version.id
            row.versionName = newName
        }
        saveAndReload()
    }

    func save() { try? context.save() }   // call after mutating a ProjectVersion in place, then reload()
    func saveAndReload() { save(); reload() }

    func recordSent(version: ProjectVersion, recipientEmail: String,
                    feedbackNumbers: [Int], threadIssueNumber: Int, status: SentReleaseNotification.Status,
                    errorDetail: String? = nil) {
        let row = SentReleaseNotification(
            repoOwner: version.repoOwner, repoName: version.repoName,
            versionID: version.id, versionName: version.name,
            recipientEmail: recipientEmail, feedbackNumbers: feedbackNumbers,
            threadIssueNumber: threadIssueNumber, status: status, errorDetail: errorDetail)
        context.insert(row); save(); reload()
    }

    func delete(_ version: ProjectVersion) { context.delete(version); save(); reload() }

    // MARK: Internal

    private func reload() {
        versionsAll = (try? context.fetch(FetchDescriptor<ProjectVersion>())) ?? []
        sentAll = (try? context.fetch(FetchDescriptor<SentReleaseNotification>())) ?? []
    }
}
