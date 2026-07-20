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
}
