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

    init(number: Int, title: String, body: String, feedbackRefs: [Int],
         status: TaskStatus, priority: TaskPriority, milestoneTitle: String?, isClosed: Bool) {
        self.number = number
        self.title = title
        self.body = body
        self.feedbackRefs = feedbackRefs
        self.status = status
        self.priority = priority
        self.milestoneTitle = milestoneTitle
        self.isClosed = isClosed
    }

    /// A copy with selected fields changed. Setting status to `.done` also marks the task closed
    /// (matching `TaskService.setStatus`). Changing `body` re-derives the feedback refs.
    func with(status newStatus: TaskStatus? = nil, priority newPriority: TaskPriority? = nil,
              title newTitle: String? = nil, body newBody: String? = nil,
              milestone newMilestone: String?? = nil) -> TaskItem {
        let resolvedBody = newBody ?? body
        let resolvedRefs = newBody != nil ? FeedbackTaskRefParser.parse(resolvedBody) : feedbackRefs
        let resolvedStatus = newStatus ?? status
        let resolvedClosed = newStatus.map { $0 == .done } ?? isClosed
        let resolvedMilestone: String? = newMilestone ?? milestoneTitle    // .some(nil) clears it
        return TaskItem(number: number, title: newTitle ?? title, body: resolvedBody, feedbackRefs: resolvedRefs,
                        status: resolvedStatus, priority: newPriority ?? priority,
                        milestoneTitle: resolvedMilestone, isClosed: resolvedClosed)
    }

    /// True when a loaded issue should be treated as a task rather than feedback.
    static func isTask(_ issue: FeedbackIssue) -> Bool {
        issue.labels.contains { $0.name == AppFeedbackLabels.task }
    }
}
