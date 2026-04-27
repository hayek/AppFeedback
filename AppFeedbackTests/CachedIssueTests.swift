import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class CachedIssueTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let issue = FeedbackIssue(
            number: 42, title: "Crash on launch",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawBody: "raw", appName: "Foo", appVersion: "1.2",
            device: "iPhone", osVersion: "17.0",
            email: "a@b.com", description: "desc"
        )
        let cached = CachedIssue.from(issue, repoOwner: "org", repoName: "repo")
        let restored = cached.toFeedbackIssue()
        XCTAssertEqual(restored.number, 42)
        XCTAssertEqual(restored.title, "Crash on launch")
        XCTAssertEqual(restored.appName, "Foo")
        XCTAssertEqual(restored.appVersion, "1.2")
        XCTAssertEqual(restored.device, "iPhone")
        XCTAssertEqual(restored.osVersion, "17.0")
        XCTAssertEqual(restored.email, "a@b.com")
        XCTAssertEqual(restored.description, "desc")
        XCTAssertEqual(restored.rawBody, "raw")
        XCTAssertEqual(cached.repoOwner, "org")
        XCTAssertEqual(cached.repoName, "repo")
    }

    func test_inMemoryContainer_persistsAndFetches() throws {
        let schema = Schema([CachedIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        ctx.insert(CachedIssue(
            repoOwner: "org", repoName: "repo", number: 1,
            title: "t", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil,
            email: nil, issueDescription: ""
        ))
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<CachedIssue>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.number, 1)
    }
}
