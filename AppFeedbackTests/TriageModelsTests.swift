import Testing
@testable import AppFeedback

struct TriageModelsTests {
    @Test func kindParsesLenientModelOutput() {
        #expect(TriageKind(modelOutput: "bug") == .bug)
        #expect(TriageKind(modelOutput: "Bug Report") == .bug)
        #expect(TriageKind(modelOutput: "feature request") == .featureRequest)
        #expect(TriageKind(modelOutput: "featureRequest") == .featureRequest)
        #expect(TriageKind(modelOutput: "usability complaint") == .usability)
        #expect(TriageKind(modelOutput: "none") == nil)
        #expect(TriageKind(modelOutput: "praise") == nil)
    }

    @Test func validatedKeepsAssignWhenNumberInRoster() {
        let d = TriageDecisionDTO.assign(taskNumber: 42)
        #expect(d.validated(againstRoster: [7, 42], fallbackTitle: "t", fallbackSummary: "s") == d)
    }

    @Test func validatedDemotesHallucinatedAssignToCreate() {
        let d = TriageDecisionDTO.assign(taskNumber: 99)
        let v = d.validated(againstRoster: [7, 42], fallbackTitle: "Fix crash", fallbackSummary: "Crash on export")
        #expect(v == .createNew(title: "Fix crash", summary: "Crash on export"))
    }

    @Test func validatedLeavesCreateAlone() {
        let d = TriageDecisionDTO.createNew(title: "a", summary: "b")
        #expect(d.validated(againstRoster: [], fallbackTitle: "t", fallbackSummary: "s") == d)
    }
}
