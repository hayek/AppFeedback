import Foundation

/// In-memory projection of a GitHub issue that carries the `appfeedback:task` label.
/// Not persisted — derived from a loaded `FeedbackIssue` on every fetch.
struct TaskItem: Identifiable, Sendable, Hashable {
    let number: Int
    let title: String
    let body: String
    let feedbackRefs: [Int]
    let status: TaskStatus
    let priority: TaskPriority
    let milestoneTitle: String?
    let isClosed: Bool

    var id: Int { number }

    /// "Completed" for notification purposes: the issue is closed or explicitly status:done.
    var isCompleted: Bool { isClosed || status == .done }

    init(issue: FeedbackIssue) {
        self.number = issue.number
        self.title = issue.title
        self.body = issue.rawBody
        self.feedbackRefs = FeedbackTaskRefParser.parse(issue.rawBody)
        let labelNames = issue.labels.map(\.name)
        self.status = TaskStatus(labels: labelNames)
        self.priority = TaskPriority(labels: labelNames)
        self.milestoneTitle = issue.milestoneTitle
        self.isClosed = (issue.state == .closed)
    }

    /// True when a loaded issue should be treated as a task rather than feedback.
    static func isTask(_ issue: FeedbackIssue) -> Bool {
        issue.labels.contains { $0.name == AppFeedbackLabels.task }
    }
}
