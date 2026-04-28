import XCTest
import SwiftData
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
            description: "desc \(number)", labels: []
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

@MainActor
extension IssueListViewModelTests {
    private func makeStore() throws -> SeenIssueStore {
        let schema = Schema([SeenIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return SeenIssueStore(context: ModelContext(container))
    }

    private func issue(_ n: Int) -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: "t\(n)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)),
            rawBody: "", appName: nil, appVersion: nil,
            device: nil, osVersion: nil, email: nil, description: "", labels: []
        )
    }

    func test_applyLoaded_marksIssuesUnreadOnFirstLoad() throws {
        let vm = IssueListViewModel()
        vm.attachSeenStore(try makeStore(), owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2), issue(3)])
        XCTAssertTrue(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
    }

    func test_applyLoaded_secondLoadFlushesPreviousAsSeen() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.applyLoaded([issue(1), issue(2), issue(3)]) // flushes 1,2 as seen
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertFalse(vm.isUnread(issue(2)))
        XCTAssertTrue(vm.isUnread(issue(3)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1, 2])
    }

    func test_markSeen_clearsDotImmediately() throws {
        let vm = IssueListViewModel()
        let store = try makeStore()
        vm.attachSeenStore(store, owner: "o", repo: "r")
        vm.applyLoaded([issue(1), issue(2)])
        vm.markSeen(issue(1))
        XCTAssertFalse(vm.isUnread(issue(1)))
        XCTAssertTrue(vm.isUnread(issue(2)))
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1])
    }

    func test_isUnread_falseWhenNoStoreAttached() {
        let vm = IssueListViewModel()
        vm.applyLoaded([issue(1)])
        XCTAssertFalse(vm.isUnread(issue(1)))
    }

    func test_translation_skipsTargetLanguageIssues() async {
        let mock = MockIntelligenceProvider()
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        let englishIssue = FeedbackIssue(
            number: 1,
            title: "Crash on launch when opening settings page repeatedly",
            createdAt: Date(),
            rawBody: "App crashes",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "App crashes when I open settings repeatedly on macOS.",
            labels: []
        )
        vm.allIssues = [englishIssue]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.translateCalls.count, 0)
    }

    func test_translation_translatesNonTargetLanguage() async {
        let mock = MockIntelligenceProvider()
        let settings = IntelligenceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.targetLanguageCode = "en"

        let vm = IssueListViewModel()
        let spanishIssue = FeedbackIssue(
            number: 2,
            title: "La aplicación se cierra inesperadamente",
            createdAt: Date(),
            rawBody: "",
            appName: "App", appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "La aplicación se cierra cuando abro la página de configuración.",
            labels: []
        )
        vm.allIssues = [spanishIssue]
        let context = ModelContext(try! ModelContainer(for: CachedIssue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        vm.attachIntelligence(provider: mock, settings: settings, cacheContext: context)

        vm.startTranslationsIfNeeded()

        for _ in 0..<50 {
            if mock.translateCalls.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(mock.translateCalls.count, 2)
        XCTAssertEqual(vm.allIssues[0].translationTargetLanguage, "en")
        XCTAssertEqual(vm.allIssues[0].translatedTitle, "[t] La aplicación se cierra inesperadamente")
    }
}
