import Foundation
@testable import AppFeedback

extension FeedbackIssue {
    /// Shared minimal fixture for triage tests: a bug-shaped issue with the metadata
    /// TriagePromptBuilder reads (app/version/os/rating).
    static func triageTestFixture(number: Int = 1, title: String = "Crash", body: String = "It crashes") -> FeedbackIssue {
        FeedbackIssue(number: number, title: title, createdAt: .now, rawBody: body,
                      appName: "MyApp", appVersion: "2.3", device: nil, osVersion: "iOS 26",
                      email: nil, description: body, labels: [], updatedAt: nil, state: .open,
                      milestoneTitle: nil, detectedLanguageCode: nil,
                      attachments: [], source: .appStore, rating: 2)
    }

    /// A task-issue fixture: carries the `appfeedback:task` label and a body whose
    /// machine-managed addresses block is produced via `FeedbackTaskRefParser.upsert`,
    /// so `TaskItem(issue:)` parses `refs` back out correctly.
    static func triageTaskFixture(number: Int, title: String = "Task", refs: [Int] = [],
                                  closed: Bool = false) -> FeedbackIssue {
        let body = FeedbackTaskRefParser.upsert(into: "Task prose", refs: refs)
        return FeedbackIssue(number: number, title: title, createdAt: .now, rawBody: body,
                             appName: nil, appVersion: nil, device: nil, osVersion: nil,
                             email: nil, description: body,
                             labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "5319e7")],
                             updatedAt: nil, state: closed ? .closed : .open,
                             milestoneTitle: nil, detectedLanguageCode: nil,
                             attachments: [], source: .appStore, rating: nil)
    }
}
