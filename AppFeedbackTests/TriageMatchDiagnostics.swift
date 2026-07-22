import Testing
import Foundation
@testable import AppFeedback

/// Manual harness for the on-device triage matcher — exercises the PRODUCTION
/// `triageClassify` + `triageMatch` path (now including pairwise verification of
/// assign claims) against real FoundationModels and prints TRIAGE-DIAG evidence
/// lines for grepping from xcodebuild output. Uses the user's REAL production-scale
/// 14-task roster and real failing feedback. Gated behind TRIAGE_DIAG=1 so
/// full-suite runs never burn minutes on model calls. No assertions — this gathers
/// behavioral evidence, it does not gate.
@MainActor
struct TriageMatchDiagnostics {
    private static let roster: [TriageTaskRosterEntry] = [
        .init(number: 392, title: "apple watch complications"),
        .init(number: 395, title: "Discard notifications",
              coveredFeedbackTitles: ["Discard notifications ability"]),
        .init(number: 396, title: "crash fix",
              coveredFeedbackTitles: ["Login issues", "unexpected crashes",
                                      "Have been having to restart the application often"]),
        .init(number: 436, title: "Plan in dash",
              coveredFeedbackTitles: ["number of token in dashboard"]),
        .init(number: 444, title: "multiple accounts"),
        .init(number: 461, title: "API token usage", coveredFeedbackTitles: ["API"]),
        .init(number: 490, title: "Fable status"),
        .init(number: 491, title: "faq redesign", coveredFeedbackTitles: ["FAQ layout"]),
        .init(number: 492, title: "auto start session"),
        .init(number: 508, title: "tapping on the date switches modes"),
        .init(number: 511, title: "Weekly in all dashboard history graph",
              coveredFeedbackTitles: ["Weekly Usage in Usage History", "Add Weekly Usage View"]),
        .init(number: 521, title: "remaining precentage in widgets",
              coveredFeedbackTitles: ["Remaining Percentage in macOS widget"]),
        .init(number: 539, title: "copy to clipboard on usage"),
        .init(number: 540, title: "fix cpu on claude code status"),
    ]

    // Real cases from the user's screenshots. expected: nil = should create-new,
    // a number = should assign there.
    private static let cases: [(title: String, body: String, expected: Int?)] = [
        ("Callouts are hard to read.",
         "Thanks for the great app. I love it. To improve the readability, can you please change the callout colors (yellow and orange) for the messages in the menu icon popover. I the light mode it's hard to read the text. Dark mode is fine. Thank you.",
         nil),
        ("Claude Design Usage",
         "It would be really grate if we could get Claude Design usage in here",
         nil),
        ("Usage not shown in real time",
         "doesnt show my usage at the moment, dont know since when it doesnt work",
         nil),
        ("cant start using it - it doesnt work",
         "i cant sign in to our work claude. i think i am one of the 5 seats...",
         nil),
        ("Design tokens",
         "Can you add the new Design tokens usage?",
         nil),
        // Controls that genuinely match existing tasks:
        ("widget should show whats left",
         "the widget shows used percentage, i want the remaining percentage in the widget like the menu bar",
         521),
        ("claude code makes my fans spin",
         "when the claude code status is on, cpu usage goes crazy and the fans spin up",
         540),
    ]

    @Test func dedupVerifierEvidence() async throws {
        guard ProcessInfo.processInfo.environment["TRIAGE_DIAG"] == "1" else {
            print("TRIAGE-DEDUP skipped (set TRIAGE_DIAG=1 to run against the real model)")
            return
        }
        let service = IntelligenceService()
        service.recomputeAvailability()
        guard service.availability.isReady else {
            print("TRIAGE-DEDUP model unavailable")
            return
        }
        // The black-hole candidate from the user's screenshots: a pending suggestion
        // whose title is a signal-style complaint sentence (the raw-signal fallback the
        // fix now avoids). Kept to demonstrate the collapse it used to cause.
        let blackHole = TriageTaskRosterEntry(
            number: 0, title: "manual refreshing is not working, it shows 2 hours old data",
            coveredFeedbackTitles: ["manual refreshing is not working, it shows 2 hours old"])
        // The re-proposed, imperative-shaped version of the SAME suggestion — what the
        // demotion re-proposal now produces. Verdicts against this measure the fix.
        let imperative = TriageTaskRosterEntry(
            number: 0, title: "Fix manual refresh showing stale data",
            coveredFeedbackTitles: ["manual refreshing is not working, it shows 2 hours old"])
        // A terse, real-task-style control candidate for comparison.
        let terse = TriageTaskRosterEntry(number: 0, title: "faq redesign",
                                          coveredFeedbackTitles: ["FAQ layout"])
        let pairs: [(title: String, signal: String, kind: TriageKind, expected: Bool)] = [
            ("Android App", "wants the app as an android app/widget", .featureRequest, false),
            ("pro", "keeps getting signed out and restore purchase won't restore pro features", .bug, false),
            ("Add the time or the countdown for the session reset to the mc-book widget.",
             "wants session reset countdown in the macbook widget", .featureRequest, false),
            ("The plan name shows Free on the Teams plan", "plan label shows Free for Teams plan", .bug, false),
            ("refresh button stuck on old data", "manual refresh shows hours-old data", .bug, true),
        ]
        for (index, p) in pairs.enumerated() {
            for attempt in 1...3 {
                let vBlackHole = (try? await service.triageVerify(
                    feedbackTitle: p.title, signal: p.signal, kind: p.kind, candidate: blackHole)) ?? false
                let vImperative = (try? await service.triageVerify(
                    feedbackTitle: p.title, signal: p.signal, kind: p.kind, candidate: imperative)) ?? false
                let vTerse = (try? await service.triageVerify(
                    feedbackTitle: p.title, signal: p.signal, kind: p.kind, candidate: terse)) ?? false
                print("TRIAGE-DEDUP pair=\(index) attempt=\(attempt) expected=\(p.expected) blackHole=\(vBlackHole)\(vBlackHole == p.expected ? "✓" : "✗") imperative=\(vImperative)\(vImperative == p.expected ? "✓" : "✗") terse=\(vTerse)")
            }
        }
    }

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
        for (index, c) in Self.cases.enumerated() {
            let issue = FeedbackIssue.triageTestFixture(number: 900 + index, title: c.title, body: c.body)
            for attempt in 1...3 {
                do {
                    let classification = try await service.triageClassify(issue: issue)
                    guard classification.isActionable, let kind = classification.kind else {
                        print("TRIAGE-DIAG case=\(index) attempt=\(attempt) NOT-ACTIONABLE signal='\(classification.signal)'")
                        continue
                    }
                    let decision = try await service.triageMatch(
                        feedbackTitle: c.title, signal: classification.signal,
                        kind: kind, roster: Self.roster)
                    let assigned: Int? = { if case .assign(let n) = decision { return n }; return nil }()
                    let ok = assigned == c.expected
                    print("TRIAGE-DIAG case=\(index) attempt=\(attempt) kind=\(kind) expected=\(c.expected.map(String.init) ?? "create") decision=\(decision) \(ok ? "OK" : "WRONG") signal='\(classification.signal)'")
                } catch {
                    print("TRIAGE-DIAG case=\(index) attempt=\(attempt) ERROR=\(error)")
                }
            }
        }
    }
}
