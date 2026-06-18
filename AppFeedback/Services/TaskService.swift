import Foundation

/// Orchestrates task-issue writes: resolves the GitHub token for a repo, ensures labels exist,
/// and delegates to `GitHubIssueWriter`. @MainActor because it reads `ProductConfig` from the UI layer.
@MainActor
final class TaskService {
    enum ServiceError: LocalizedError {
        case noToken
        var errorDescription: String? { "No GitHub token for this repo. Re-authenticate in Settings." }
    }

    private let writer: GitHubIssueWriter
    private let labelClient: GitHubMilestoneReleaseClient

    init(writer: GitHubIssueWriter = GitHubIssueWriter(),
         labelClient: GitHubMilestoneReleaseClient = GitHubMilestoneReleaseClient()) {
        self.writer = writer
        self.labelClient = labelClient
    }

    nonisolated static func labels(status: TaskStatus, priority: TaskPriority) -> [String] {
        [AppFeedbackLabels.task, status.label, priority.label]
    }
    nonisolated static func body(prose: String, feedbackRefs: [Int]) -> String {
        FeedbackTaskRefParser.upsert(into: prose, refs: feedbackRefs)
    }

    /// Creates a task issue. Returns its number. Requires online.
    func createTask(repo: ProductConfig, title: String, prose: String, feedbackRefs: [Int],
                    status: TaskStatus, priority: TaskPriority, milestoneNumber: Int?) async throws -> Int {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await ensureLabels(repo: repo, token: token)
        return try await writer.createIssue(
            owner: repo.owner, repo: repo.repo, title: title,
            body: Self.body(prose: prose, feedbackRefs: feedbackRefs),
            labels: Self.labels(status: status, priority: priority),
            milestoneNumber: milestoneNumber, token: token)
    }

    func setStatus(repo: ProductConfig, task: TaskItem, status: TaskStatus) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let labels = [AppFeedbackLabels.task, status.label, task.priority.label]
        // status:done also closes the issue; reopening on any other status.
        let state = (status == .done) ? "closed" : "open"
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            labels: labels, state: state, token: token)
    }

    func setPriority(repo: ProductConfig, task: TaskItem, priority: TaskPriority) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            labels: [AppFeedbackLabels.task, task.status.label, priority.label], token: token)
    }

    func setFeedbackRefs(repo: ProductConfig, task: TaskItem, refs: [Int]) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let newBody = FeedbackTaskRefParser.upsert(into: task.body, refs: refs)
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number, body: newBody, token: token)
    }

    func assignVersion(repo: ProductConfig, task: TaskItem, milestoneNumber: Int?) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            milestoneNumber: .some(milestoneNumber), token: token)
    }

    /// Updates the task's title and notes, preserving the machine-managed feedback-refs block.
    func updateContent(repo: ProductConfig, task: TaskItem, title: String, prose: String) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        let body = FeedbackTaskRefParser.upsert(into: prose, refs: task.feedbackRefs)
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            title: title, body: body, token: token)
    }

    /// Applies a full set of edits (title, notes, status, priority, version) in a single PATCH.
    /// Used by the task detail's Apply action so everything commits atomically.
    func applyEdits(repo: ProductConfig, task: TaskItem, title: String, prose: String,
                    status: TaskStatus, priority: TaskPriority, milestoneNumber: Int?) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await ensureLabels(repo: repo, token: token)
        let body = FeedbackTaskRefParser.upsert(into: prose, refs: task.feedbackRefs)
        let state = (status == .done) ? "closed" : "open"
        try await writer.updateIssue(owner: repo.owner, repo: repo.repo, number: task.number,
            title: title, body: body, labels: Self.labels(status: status, priority: priority),
            milestoneNumber: .some(milestoneNumber), state: state, token: token)
    }

    /// Permanently deletes the task's GitHub issue.
    func deleteTask(repo: ProductConfig, task: TaskItem) async throws {
        guard let token = KeychainService.loadSync(for: repo) else { throw ServiceError.noToken }
        try await writer.deleteIssue(owner: repo.owner, repo: repo.repo, number: task.number, token: token)
    }

    private func ensureLabels(repo: ProductConfig, token: String) async throws {
        for label in AppFeedbackLabels.managed {
            try await labelClient.ensureLabel(owner: repo.owner, repo: repo.repo, name: label.name, color: label.color, token: token)
        }
    }
}
