import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class ProductMigrationTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        // Register BOTH the legacy Repo and the new Product so the migration can copy across.
        let schema = Schema([Repo.self, Product.self, CachedIssue.self, MailThread.self, RepoFilterPreference.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        defaults = UserDefaults(suiteName: "ProductMigrationTests-\(UUID().uuidString)")!
    }

    override func tearDown() async throws {
        context = nil; container = nil; defaults = nil
        try await super.tearDown()
    }

    func test_migration_copiesRepoToProductPreservingIdentity() throws {
        let id = UUID()
        let legacy = Repo(id: id, displayName: "My App", owner: "octo", repo: "feedback",
                          colorHex: "ff0000", mirrorEmailsToGitHub: false, redactEmailAddresses: true,
                          connectedRepoOwner: "octo", connectedRepoName: "code")
        context.insert(legacy)
        // Foreign-key rows keyed by owner/repo (not Repo.id). NOTE: `CachedIssue.init` has NO
        // defaulted middle params (verified against AppFeedback/Models/CachedIssue.swift) — every
        // arg through `issueDescription` is required, so the four-arg form does NOT compile.
        let issue = CachedIssue(
            repoOwner: "octo", repoName: "feedback", number: 7, title: "Crash",
            createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
            device: nil, osVersion: nil, email: nil, issueDescription: ""
        )
        context.insert(issue)
        // `MailThread.init` is all-defaulted (verified against AppFeedback/Models/MailThread.swift),
        // so the labeled subset below compiles as-is.
        let thread = MailThread(issueRepoOwner: "octo", issueRepoName: "feedback", issueNumber: 7)
        context.insert(thread)
        let pref = RepoFilterPreference(repoOwner: "octo", repoName: "feedback")
        context.insert(pref)
        try context.save()

        ProductMigration.run(context: context, defaults: defaults)

        let products = try context.fetch(FetchDescriptor<Product>())
        XCTAssertEqual(products.count, 1)
        let p = products[0]
        XCTAssertEqual(p.id, id)
        XCTAssertEqual(p.owner, "octo")
        XCTAssertEqual(p.repo, "feedback")
        XCTAssertEqual(p.displayName, "My App")
        XCTAssertEqual(p.colorHex, "ff0000")
        XCTAssertFalse(p.mirrorEmailsToGitHub)
        XCTAssertEqual(p.connectedRepoName, "code")
        // New source fields default nil.
        XCTAssertNil(p.appStoreIssuerID)
        XCTAssertNil(p.feedbackInboxAccountID)
        // Legacy row retired.
        XCTAssertTrue(try context.fetch(FetchDescriptor<Repo>()).isEmpty)
        // Foreign keys still resolve by owner/repo.
        let issues = try context.fetch(FetchDescriptor<CachedIssue>())
        XCTAssertEqual(issues.first?.repoOwner, "octo")
        XCTAssertEqual(issues.first?.repoName, "feedback")
        let threads = try context.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.first?.issueRepoOwner, "octo")
        XCTAssertEqual(threads.first?.issueNumber, 7)
        let prefs = try context.fetch(FetchDescriptor<RepoFilterPreference>())
        XCTAssertEqual(prefs.first?.repoOwner, "octo")
    }

    func test_migration_isIdempotentOnSecondRun() throws {
        let id = UUID()
        context.insert(Repo(id: id, displayName: "A", owner: "o", repo: "r"))
        try context.save()

        ProductMigration.run(context: context, defaults: defaults)
        ProductMigration.run(context: context, defaults: defaults)   // second run no-ops

        let products = try context.fetch(FetchDescriptor<Product>())
        XCTAssertEqual(products.count, 1, "second run must not duplicate")
        XCTAssertEqual(products.first?.id, id)
    }

    func test_migration_defensivelySkipsRepoWithExistingProduct() throws {
        // Flag NOT set, but a Product already exists for this id (e.g. partial prior run).
        let id = UUID()
        context.insert(Repo(id: id, displayName: "A", owner: "o", repo: "r"))
        context.insert(Product(id: id, displayName: "A", owner: "o", repo: "r"))
        try context.save()

        ProductMigration.run(context: context, defaults: defaults)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Product>()).count, 1)
    }
}
