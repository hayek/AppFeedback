import Testing
@testable import AppFeedback

@MainActor
struct IntelligenceServiceTriageTests {
    @Test func triageThrowsUnavailableWhenModelNotReady() async {
        let service = IntelligenceService()   // availability defaults to .osTooOld until recomputed
        let issue = FeedbackIssue.triageTestFixture(number: 1, title: "t", body: "b")
        await #expect(throws: IntelligenceError.unavailable) {
            _ = try await service.triageClassify(issue: issue)
        }
        await #expect(throws: IntelligenceError.unavailable) {
            _ = try await service.triageMatch(feedbackTitle: "t", signal: "s", kind: .bug, roster: [])
        }
    }
}
