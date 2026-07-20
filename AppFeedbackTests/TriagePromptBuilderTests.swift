import Testing
@testable import AppFeedback

struct TriagePromptBuilderTests {
    private func issue(number: Int = 1, title: String = "Crash", body: String = "It crashes") -> FeedbackIssue {
        // Use the same fixture helper style as SummaryPromptBuilderTests; if a shared
        // fixture exists in Fakes/, reuse it instead of this local builder.
        FeedbackIssue(number: number, title: title, createdAt: .now, rawBody: body,
                      appName: "MyApp", appVersion: "2.3", device: nil, osVersion: "iOS 26",
                      email: nil, description: body, labels: [], updatedAt: nil, state: .open,
                      milestoneTitle: nil, detectedLanguageCode: nil,
                      attachments: [], source: .appStore, rating: 2)
    }

    @Test func classifyPromptTruncatesBodyAndIncludesMetadata() {
        let long = String(repeating: "x", count: 2_000)
        let p = TriagePromptBuilder.buildClassifyPrompt(issue: issue(body: long), bodyCharCap: 300)
        #expect(!p.contains(String(repeating: "x", count: 301)))
        #expect(p.contains("MyApp"))
        #expect(p.contains("2.3"))
    }

    @Test func matchPromptCapsRosterAndReportsIncludedNumbers() {
        let roster = (1...50).map { TriageTaskRosterEntry(number: $0, title: "Task \($0)") }
        let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
            signal: "Crash when exporting", kind: .bug, roster: roster, rosterCap: 10)
        #expect(included.count == 10)
        #expect(included.contains(1) && included.contains(10) && !included.contains(11))
        #expect(prompt.contains("#10 Task 10"))
        #expect(!prompt.contains("#11 Task 11"))
        #expect(prompt.contains("Crash when exporting"))
    }

    @Test func matchPromptHandlesEmptyRoster() {
        let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
            signal: "Dark mode wanted", kind: .featureRequest, roster: [], rosterCap: 10)
        #expect(included.isEmpty)
        #expect(prompt.contains("no existing tasks"))
    }

    @Test func configLaddersShrink() {
        let c = TriagePromptBuilder.classifyConfigs()
        let m = TriagePromptBuilder.matchConfigs()
        #expect(c == c.sorted(by: >) && !c.isEmpty)
        #expect(m == m.sorted(by: >) && !m.isEmpty)
    }
}
