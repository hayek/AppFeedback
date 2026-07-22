import Testing
@testable import AppFeedback

struct TriagePromptBuilderTests {
    @Test func classifyPromptTruncatesBodyAndIncludesMetadata() {
        let long = String(repeating: "x", count: 2_000)
        let p = TriagePromptBuilder.buildClassifyPrompt(issue: .triageTestFixture(body: long), bodyCharCap: 300)
        #expect(!p.contains(String(repeating: "x", count: 301)))
        #expect(p.contains("MyApp"))
        #expect(p.contains("2.3"))
    }

    @Test func matchPromptCapsRosterAndReportsIncludedEntries() {
        let roster = (1...50).map { TriageTaskRosterEntry(number: $0, title: "Task \($0)") }
        let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
            signal: "Crash when exporting", kind: .bug, roster: roster, rosterCap: 10)
        let numbers = included.map(\.number)
        #expect(numbers.count == 10)
        #expect(numbers.contains(1) && numbers.contains(10) && !numbers.contains(11))
        #expect(prompt.contains("#10: \"Task 10\""))
        #expect(!prompt.contains("#11: \"Task 11\""))
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
