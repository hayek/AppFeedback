import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class SeenIssueStoreTests: XCTestCase {
    private func makeStore() throws -> (SeenIssueStore, ModelContext) {
        let schema = Schema([SeenIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        return (SeenIssueStore(context: ctx), ctx)
    }

    func test_seenNumbers_isEmptyInitially() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.seenNumbers(owner: "o", repo: "r").isEmpty)
    }

    func test_markSeen_persistsAndIsIdempotent() throws {
        let (store, ctx) = try makeStore()
        store.markSeen(owner: "o", repo: "r", issueNumber: 1)
        store.markSeen(owner: "o", repo: "r", issueNumber: 1)
        let rows = try ctx.fetch(FetchDescriptor<SeenIssue>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1])
    }

    func test_markSeenBulk_skipsExisting() throws {
        let (store, ctx) = try makeStore()
        store.markSeen(owner: "o", repo: "r", issueNumber: 2)
        store.markSeenBulk(owner: "o", repo: "r", issueNumbers: [1, 2, 3])
        let rows = try ctx.fetch(FetchDescriptor<SeenIssue>())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r"), [1, 2, 3])
    }

    func test_seenNumbers_isolatedByRepo() throws {
        let (store, _) = try makeStore()
        store.markSeen(owner: "o", repo: "r1", issueNumber: 5)
        store.markSeen(owner: "o", repo: "r2", issueNumber: 6)
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r1"), [5])
        XCTAssertEqual(store.seenNumbers(owner: "o", repo: "r2"), [6])
    }
}
