import Testing
import SwiftUI
@testable import AppFeedback

@MainActor
struct TriageSuggestionChipSmokeTests {
    @Test func chipRendersBothSuggestionShapes() {
        let assignRec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                            feedbackNumber: 1, state: TriageState.pending.rawValue)
        assignRec.suggestedTaskNumber = 42
        let createRec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                            feedbackNumber: 2, state: TriageState.pending.rawValue)
        createRec.suggestedTitle = "Fix crash"
        _ = TriageSuggestionChip(record: assignRec, onAccept: {}, onDismiss: {}).body
        _ = TriageSuggestionChip(record: createRec, onAccept: {}, onDismiss: {}).body
    }

    @Test func chipRendersInFlightAcceptState() {
        let assignRec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                            feedbackNumber: 1, state: TriageState.pending.rawValue)
        assignRec.suggestedTaskNumber = 42
        _ = TriageSuggestionChip(record: assignRec, isAccepting: true, onAccept: {}, onDismiss: {}).body
    }
}
