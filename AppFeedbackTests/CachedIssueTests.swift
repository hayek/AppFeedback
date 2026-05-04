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
            email: "a@b.com", description: "desc", labels: []
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
        XCTAssertEqual(cached.state, IssueState.open.rawValue)
    }

    func test_cachedIssue_storesTranslationFields() {
        let issue = FeedbackIssue(
            number: 42, title: "Hola", createdAt: Date(),
            rawBody: "Hola mundo", appName: "App", appVersion: "1",
            device: "Mac", osVersion: "14", email: nil,
            description: "Hola mundo", labels: []
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        cached.detectedLanguageCode = "es"
        cached.translatedTitle = "Hello"
        cached.translatedBody = "Hello world"
        cached.translationTargetLanguage = "en"

        let round = cached.toFeedbackIssue()
        XCTAssertEqual(round.detectedLanguageCode, "es")
        XCTAssertEqual(round.translatedTitle, "Hello")
        XCTAssertEqual(round.translatedBody, "Hello world")
        XCTAssertEqual(round.translationTargetLanguage, "en")
    }

    func test_updateFromRemote_preservesTranslationFields() {
        let issue = FeedbackIssue(
            number: 1, title: "Hola", createdAt: Date(),
            rawBody: "raw", appName: "App", appVersion: "1",
            device: nil, osVersion: nil, email: nil,
            description: "desc", labels: []
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        cached.detectedLanguageCode = "es"
        cached.translatedTitle = "Hello"
        cached.translatedBody = "Hello world"
        cached.translationTargetLanguage = "en"

        var fresh = FeedbackIssue(
            number: 1, title: "Hola updated", createdAt: Date(),
            rawBody: "raw 2", appName: "App", appVersion: "2",
            device: "iPhone", osVersion: "17", email: "x@y.com",
            description: "new desc", labels: []
        )
        fresh.state = .closed
        cached.updateFromRemote(fresh)

        XCTAssertEqual(cached.title, "Hola updated")
        XCTAssertEqual(cached.appVersion, "2")
        XCTAssertEqual(cached.state, IssueState.closed.rawValue)
        XCTAssertEqual(cached.detectedLanguageCode, "es")
        XCTAssertEqual(cached.translatedTitle, "Hello")
        XCTAssertEqual(cached.translatedBody, "Hello world")
        XCTAssertEqual(cached.translationTargetLanguage, "en")
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
