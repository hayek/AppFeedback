import XCTest
import UserNotifications
@testable import AppFeedback

@MainActor
final class NotificationServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var center: MockUserNotificationCenter!
    private var notified: NotifiedIssueStore!
    private let suiteName = "NotificationServiceTests"

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
        center = MockUserNotificationCenter()
        notified = NotifiedIssueStore(defaults: defaults, cap: 1_000)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func service() -> NotificationService {
        NotificationService(
            center: center,
            notifiedStore: notified,
            settings: { let s = NotificationSettings(defaults: defaults); s.isEnabled = true; return s }(),
            router: NotificationRouter()
        )
    }

    private func issue(_ n: Int, title: String = "title") -> FeedbackIssue {
        FeedbackIssue(
            number: n, title: title, createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil,
            osVersion: nil, email: nil, description: "", labels: []
        )
    }

    func test_diffAndNotify_postsZeroWhenNoNew() async {
        notified.snapshot(["foo/bar#1"])
        await service().diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 0)
    }

    func test_diffAndNotify_postsOnePerIssueWhenAtMostThree() async {
        await service().diffAndNotify(loadedByRepo: [
            ("foo", "bar", [issue(1, title: "Crash"), issue(2, title: "Slow"), issue(3, title: "Bug")])
        ])
        XCTAssertEqual(center.addedRequests.count, 3)
        let titles = center.addedRequests.map(\.content.title)
        XCTAssertEqual(Set(titles), ["Crash", "Slow", "Bug"])
        XCTAssertTrue(center.addedRequests.allSatisfy { $0.content.subtitle == "foo/bar" })
        XCTAssertEqual(center.addedRequests.first?.content.userInfo["issueKey"] as? String, "foo/bar#1")
    }

    func test_diffAndNotify_doesNotRenotifyOnSecondCall() async {
        let svc = service()
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 1)
    }

    func test_diffAndNotify_doesNothingWhenSettingsDisabled() async {
        let settings = NotificationSettings(defaults: defaults)
        settings.isEnabled = false
        let svc = NotificationService(
            center: center,
            notifiedStore: notified,
            settings: settings,
            router: NotificationRouter()
        )
        await svc.diffAndNotify(loadedByRepo: [("foo", "bar", [issue(1)])])
        XCTAssertEqual(center.addedRequests.count, 0)
    }
}
