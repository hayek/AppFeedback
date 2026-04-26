import XCTest
@testable import AppFeedback

@MainActor
final class IssueListViewModelTests: XCTestCase {

    private func makeIssue(
        number: Int,
        title: String = "Issue",
        appName: String? = "TestApp",
        appVersion: String? = "1.0",
        device: String? = "Mac",
        osVersion: String? = "14.0",
        email: String? = nil,
        daysAgo: Double = 0
    ) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: title,
            createdAt: Date().addingTimeInterval(-daysAgo * 86400),
            rawBody: "", appName: appName, appVersion: appVersion,
            device: device, osVersion: osVersion, email: email,
            description: "desc \(number)"
        )
    }

    func test_visibleIssues_noFilter_returnsAll() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1), makeIssue(number: 2)]
        XCTAssertEqual(vm.visibleIssues.count, 2)
    }

    func test_visibleIssues_appFilter() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, appName: "A"), makeIssue(number: 2, appName: "B")]
        vm.appFilter = "A"
        XCTAssertEqual(vm.visibleIssues.count, 1)
        XCTAssertEqual(vm.visibleIssues.first?.number, 1)
    }

    func test_visibleIssues_versionPillFilter() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, appVersion: "1.0"), makeIssue(number: 2, appVersion: "2.0")]
        vm.filters.appVersion = "1.0"
        XCTAssertEqual(vm.visibleIssues.count, 1)
    }

    func test_visibleIssues_search_matchesTitle() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, title: "Crash on launch"), makeIssue(number: 2, title: "Dark mode")]
        vm.searchQuery = "crash"
        XCTAssertEqual(vm.visibleIssues.count, 1)
        XCTAssertEqual(vm.visibleIssues.first?.title, "Crash on launch")
    }

    func test_visibleIssues_sortNewest_first() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, daysAgo: 5), makeIssue(number: 2, daysAgo: 1)]
        vm.sortOrder = .newest
        XCTAssertEqual(vm.visibleIssues.first?.number, 2)
    }

    func test_visibleIssues_sortOldest_first() {
        let vm = IssueListViewModel()
        vm.allIssues = [makeIssue(number: 1, daysAgo: 5), makeIssue(number: 2, daysAgo: 1)]
        vm.sortOrder = .oldest
        XCTAssertEqual(vm.visibleIssues.first?.number, 1)
    }

    func test_uniqueAppVersions_forCurrentApp() {
        let vm = IssueListViewModel()
        vm.allIssues = [
            makeIssue(number: 1, appName: "A", appVersion: "1.0"),
            makeIssue(number: 2, appName: "A", appVersion: "2.0"),
            makeIssue(number: 3, appName: "B", appVersion: "3.0"),
        ]
        vm.appFilter = "A"
        XCTAssertEqual(Set(vm.uniqueValues(for: \.appVersion)), ["1.0", "2.0"])
    }
}
