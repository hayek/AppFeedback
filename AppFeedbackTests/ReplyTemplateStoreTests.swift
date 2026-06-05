import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class ReplyTemplateStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ReplyTemplate.self, configurations: config)
        return ModelContext(container)
    }

    func testCreateIsScopedToRepo() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        store.create(owner: "o", repo: "r", title: "Thanks", body: "Thanks for the report")
        store.create(owner: "o", repo: "other", title: "Other", body: "x")

        let forRepo = store.templates(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.title), ["Thanks"])
        XCTAssertEqual(forRepo.first?.body, "Thanks for the report")
    }

    func testAllTemplatesMergesAcrossRepos() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        store.create(owner: "o", repo: "r", title: "A", body: "a")
        store.create(owner: "o", repo: "other", title: "B", body: "b")

        XCTAssertEqual(Set(store.allTemplates().map(\.title)), ["A", "B"])
    }

    func testUpdateChangesFields() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        let t = store.create(owner: "o", repo: "r", title: "Old", body: "old body")
        store.update(t, title: "New", body: "new body")

        let reloaded = store.templates(owner: "o", repo: "r")
        XCTAssertEqual(reloaded.map(\.title), ["New"])
        XCTAssertEqual(reloaded.first?.body, "new body")
        XCTAssertGreaterThanOrEqual(reloaded.first!.updatedAt, reloaded.first!.createdAt)
    }

    func testDeleteRemovesTemplate() throws {
        let store = ReplyTemplateStore(context: try makeContext())
        let t = store.create(owner: "o", repo: "r", title: "A", body: "a")
        store.delete(t)

        XCTAssertTrue(store.templates(owner: "o", repo: "r").isEmpty)
        XCTAssertTrue(store.allTemplates().isEmpty)
    }
}
