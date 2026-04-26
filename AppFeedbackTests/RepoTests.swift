import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class RepoTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Repo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    func test_initWithValues() {
        let r = Repo(displayName: "App", owner: "acme", repo: "feedback")
        XCTAssertEqual(r.displayName, "App")
        XCTAssertEqual(r.owner, "acme")
        XCTAssertEqual(r.repo, "feedback")
        XCTAssertTrue(r.hiddenAppNames.isEmpty)
    }

    func test_insertAndFetch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(Repo(displayName: "X", owner: "o", repo: "r"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Repo>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.displayName, "X")
    }

    func test_hiddenAppNamesPersists() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repo = Repo(displayName: "X", owner: "o", repo: "r")
        context.insert(repo)
        repo.hiddenAppNames = ["AppA", "AppB"]
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Repo>())
        XCTAssertEqual(fetched.first?.hiddenAppNames.sorted(), ["AppA", "AppB"])
    }
}
