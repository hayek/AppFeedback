import XCTest
@testable import AppFeedback

@MainActor
final class UnreadSummaryViewModelTests: XCTestCase {

    private func issue(_ n: Int) -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: "T\(n)", createdAt: Date(),
            rawBody: "", appName: "A", appVersion: nil, device: nil,
            osVersion: nil, email: nil, description: "D\(n)", labels: []
        )
    }

    func test_skipped_whenLessThanTwo() async {
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(issues: [issue(1)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .skipped = vm.state { } else { XCTFail("expected .skipped, got \(vm.state)") }
        XCTAssertEqual(mock.summarizeCalls.count, 0)
    }

    func test_unavailable_whenProviderUnavailable() async {
        let mock = MockIntelligenceProvider()
        mock.availability = .appleIntelligenceNotEnabled
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(issues: [issue(1), issue(2)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .unavailable = vm.state { } else { XCTFail("expected .unavailable, got \(vm.state)") }
    }

    func test_ready_whenSummarizeSucceeds() async {
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(issues: [issue(1), issue(2), issue(3)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        for _ in 0..<50 {
            if case .ready = vm.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .ready(let summary) = vm.state else {
            XCTFail("expected .ready, got \(vm.state)"); return
        }
        XCTAssertEqual(summary.headline, "3 issues (stub)")
    }

    func test_failed_whenSummarizeThrows() async {
        let mock = MockIntelligenceProvider()
        struct Boom: Error {}
        mock.summarizeHandler = { _, _ in throw Boom() }
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(issues: [issue(1), issue(2)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        for _ in 0..<50 {
            if case .failed = vm.state { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .failed = vm.state { } else { XCTFail("expected .failed, got \(vm.state)") }
    }

    func test_skipped_whenAllUnreadIssuesAreFromHiddenApps() async {
        // Hidden-app filtering trims `IssueListViewModel.issuesRecentForSummary`;
        // upstream can leave fewer than two issues suitable for summaries.
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        // Pass only one issue (the hidden-app issues have been filtered out upstream).
        await vm.update(issues: [issue(1)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        try? await Task.sleep(nanoseconds: 30_000_000)
        if case .skipped = vm.state { } else { XCTFail("expected .skipped, got \(vm.state)") }
        XCTAssertEqual(mock.summarizeCalls.count, 0)
    }

    func test_update_replacesInFlightTask() async {
        let mock = MockIntelligenceProvider()
        mock.summarizeHandler = { issues, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return IssueSummaryDTO(headline: "\(issues.count)", pros: "", cons: "")
        }
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(issues: [issue(1), issue(2)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await vm.update(issues: [issue(1), issue(2), issue(3), issue(4)], targetLanguage: "en", promptContext: .rollingLastThirtyDays)
        for _ in 0..<50 {
            if case .ready(let s) = vm.state, s.headline == "4" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .ready(let s) = vm.state {
            XCTAssertEqual(s.headline, "4")
        } else {
            XCTFail("expected .ready, got \(vm.state)")
        }
    }
}
