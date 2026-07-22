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

    private static let roster: [TriageTaskRosterEntry] = [
        .init(number: 503, title: "Fix login detection callback"),
        .init(number: 511, title: "Weekly in all dashboard history graph"),
    ]

    @Test func matchClaimValidWhenTitleCopiedExactly() {
        #expect(TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 503, claimedTitle: "Fix login detection callback",
            includedRoster: Self.roster))
    }

    @Test func matchClaimValidIgnoringCaseAndSurroundingWhitespace() {
        #expect(TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 503, claimedTitle: "  fix LOGIN detection callback  ",
            includedRoster: Self.roster))
    }

    @Test func matchClaimInvalidWhenTitleHasNumberPrefix() {
        #expect(!TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 503, claimedTitle: "#503 Fix login detection callback",
            includedRoster: Self.roster))
    }

    @Test func matchClaimInvalidWhenNumberNotInRoster() {
        #expect(!TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 999, claimedTitle: "Fix login detection callback",
            includedRoster: Self.roster))
    }

    @Test func matchClaimInvalidWhenTitleBelongsToDifferentEntry() {
        #expect(!TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 511, claimedTitle: "Fix login detection callback",
            includedRoster: Self.roster))
    }

    @Test func matchClaimInvalidForEmptyRoster() {
        #expect(!TriageDecisionDTO.matchClaimIsValid(
            claimedNumber: 503, claimedTitle: "Fix login detection callback",
            includedRoster: []))
    }
}
