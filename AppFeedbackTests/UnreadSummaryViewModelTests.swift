import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class UnreadSummaryViewModelTests: XCTestCase {

    nonisolated private static let demoScope = SummaryCacheScope(repoOwner: "o", repoName: "r", targetLanguage: "en")

    private func makeBinding(scope: SummaryCacheScope = demoScope) throws -> SummaryCacheBinding {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: IssueSummaryCache.self, configurations: config)
        return SummaryCacheBinding(scope: scope, context: ModelContext(container))
    }

    /// Polls `vm.state` until it becomes `.ready`, sleeping briefly between checks.
    /// Bound: ~1s total. Tests using a 0ms-debounce mock provider settle within tens of ms.
    private func waitUntilReady(_ vm: UnreadSummaryViewModel) async {
        for _ in 0..<50 {
            if case .ready = vm.state { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

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
        await waitUntilReady(vm)
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

    // MARK: - iCloud cache

    func test_rollingMode_persistsSummaryToCache() async throws {
        let binding = try makeBinding()
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(
            issues: [issue(1), issue(2)],
            targetLanguage: "en",
            promptContext: .rollingLastThirtyDays,
            cache: binding
        )
        await waitUntilReady(vm)
        let rows = try binding.context.fetch(FetchDescriptor<IssueSummaryCache>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.headline, "2 issues (stub)")
        XCTAssertEqual(rows.first?.inputFingerprint, "1,2")
    }

    func test_rollingMode_hydratesFromCacheWhenProviderUnavailable() async throws {
        let binding = try makeBinding()
        binding.context.insert(IssueSummaryCache(
            repoOwner: "o", repoName: "r", targetLanguage: "en",
            headline: "cached headline", pros: "cached pros", cons: "cached cons",
            inputFingerprint: "1,2"
        ))
        try binding.context.save()

        let mock = MockIntelligenceProvider()
        mock.availability = .appleIntelligenceNotEnabled
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(
            issues: [issue(1), issue(2)],
            targetLanguage: "en",
            promptContext: .rollingLastThirtyDays,
            cache: binding
        )
        guard case .ready(let dto) = vm.state else {
            XCTFail("expected .ready from cache, got \(vm.state)"); return
        }
        XCTAssertEqual(dto.headline, "cached headline")
        XCTAssertEqual(mock.summarizeCalls.count, 0)
    }

    func test_rollingMode_freshCacheSkipsRecompute() async throws {
        let binding = try makeBinding()
        binding.context.insert(IssueSummaryCache(
            repoOwner: "o", repoName: "r", targetLanguage: "en",
            headline: "cached", pros: "p", cons: "c",
            inputFingerprint: "1,2"
        ))
        try binding.context.save()

        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(
            issues: [issue(1), issue(2)],
            targetLanguage: "en",
            promptContext: .rollingLastThirtyDays,
            cache: binding
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.summarizeCalls.count, 0, "fingerprint match should skip recompute")
        if case .ready(let dto) = vm.state {
            XCTAssertEqual(dto.headline, "cached")
        } else {
            XCTFail("expected .ready, got \(vm.state)")
        }
    }

    func test_rollingMode_staleCacheRecomputesAndKeepsCachedVisible() async throws {
        let binding = try makeBinding()
        binding.context.insert(IssueSummaryCache(
            repoOwner: "o", repoName: "r", targetLanguage: "en",
            headline: "stale", pros: "p", cons: "c",
            inputFingerprint: "1,2"
        ))
        try binding.context.save()

        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(
            issues: [issue(1), issue(2), issue(3)],
            targetLanguage: "en",
            promptContext: .rollingLastThirtyDays,
            cache: binding
        )
        if case .ready(let dto) = vm.state {
            XCTAssertEqual(dto.headline, "stale", "stale cache should be visible immediately")
        } else {
            XCTFail("expected stale .ready, got \(vm.state)")
        }
        for _ in 0..<50 {
            if case .ready(let dto) = vm.state, dto.headline == "3 issues (stub)" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .ready(let dto) = vm.state else {
            XCTFail("expected fresh .ready, got \(vm.state)"); return
        }
        XCTAssertEqual(dto.headline, "3 issues (stub)")
        let rows = try binding.context.fetch(FetchDescriptor<IssueSummaryCache>())
        XCTAssertEqual(rows.first?.inputFingerprint, "1,2,3")
    }

    func test_unreadMode_doesNotTouchCache() async throws {
        let binding = try makeBinding()
        let mock = MockIntelligenceProvider()
        let vm = UnreadSummaryViewModel(provider: mock, debounceMs: 0)
        await vm.update(
            issues: [issue(1), issue(2)],
            targetLanguage: "en",
            promptContext: .unreadIssues,
            cache: binding
        )
        await waitUntilReady(vm)
        let rows = try binding.context.fetch(FetchDescriptor<IssueSummaryCache>())
        XCTAssertTrue(rows.isEmpty, "unread-mode summaries should not be cached")
    }
}
