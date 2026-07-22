import Testing
import Foundation
@testable import AppFeedback

/// Manual harness for the on-device triage matcher — exercises the PRODUCTION
/// `triageClassify` + `triageMatch` path against real FoundationModels and prints
/// TRIAGE-DIAG evidence lines for grepping from xcodebuild output. Gated behind
/// TRIAGE_DIAG=1 so full-suite runs never burn minutes on model calls. No
/// assertions — this gathers behavioral evidence, it does not gate.
@MainActor
struct TriageMatchDiagnostics {
    private static let roster: [TriageTaskRosterEntry] = [
        .init(number: 503, title: "Fix login detection callback"),
        .init(number: 505, title: "remaining precentage in widgets"),
        .init(number: 508, title: "tapping on the date switches modes"),
        .init(number: 511, title: "Weekly in all dashboard history graph"),
    ]

    @Test func matcherEvidence() async throws {
        guard ProcessInfo.processInfo.environment["TRIAGE_DIAG"] == "1" else {
            print("TRIAGE-DIAG skipped (set TRIAGE_DIAG=1 to run against the real model)")
            return
        }
        let service = IntelligenceService()
        service.recomputeAvailability()
        guard service.availability.isReady else {
            print("TRIAGE-DIAG model unavailable, skipping")
            return
        }
        let cases: [(title: String, body: String)] = [
            ("iOS dynamic island for reset time",
             "Hello, I would like to suggest that whenever I hit my limit, the app automatically creates a dynamic island progress bar to let me know when it will be reset."),
            ("the app keep crashing silently and dissapearing",
             "no idea why, have to re open at least three times a day on mi mac"),
            ("Support for Codex and Z.AI",
             "Please support more genai provider. I will be more confident in supporting lifetime package when you do so. I'm not sure if Claude will still be here after 3 years."),
            // Control: genuinely covered by #511 — the matcher SHOULD assign this one.
            ("weekly graph lost my history",
             "the weekly dashboard history graph stopped showing older weeks after the update"),
        ]
        for (index, c) in cases.enumerated() {
            let issue = FeedbackIssue.triageTestFixture(number: 900 + index, title: c.title, body: c.body)
            for attempt in 1...3 {
                do {
                    let classification = try await service.triageClassify(issue: issue)
                    guard classification.isActionable, let kind = classification.kind else {
                        print("TRIAGE-DIAG case=\(index) attempt=\(attempt) NOT-ACTIONABLE signal='\(classification.signal)'")
                        continue
                    }
                    let decision = try await service.triageMatch(
                        signal: classification.signal, kind: kind, roster: Self.roster)
                    print("TRIAGE-DIAG case=\(index) attempt=\(attempt) kind=\(kind) signal='\(classification.signal)' decision=\(decision)")
                } catch {
                    print("TRIAGE-DIAG case=\(index) attempt=\(attempt) ERROR=\(error)")
                }
            }
        }
    }
}
