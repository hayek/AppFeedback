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

    @Test func assignChipWithTitleAndOpenButtonRenders() {
        let rec = TriageVerdictRecord(repoOwner: "o", repoName: "r",
                                      feedbackNumber: 3, state: TriageState.pending.rawValue)
        rec.suggestedTaskNumber = 511
        let chip = TriageSuggestionChip(
            record: rec,
            taskTitle: "Unable to log in to the app",
            onAccept: {}, onDismiss: {},
            onOpenTask: {}
        )
        _ = chip.body
    }
}
