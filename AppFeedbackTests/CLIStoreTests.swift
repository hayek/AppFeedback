import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class CLIStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "clistore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var paths: CLIStore.Paths {
        CLIStore.Paths(local: directory.appending(path: "local.store"),
                       cloud: directory.appending(path: "cloud.store"))
    }

    /// Seeds through the same two-named-configuration container the app uses, so the stores on
    /// disk carry the metadata a real one would.
    private func seedStores() throws {
        let cloudConfig = ModelConfiguration("cloud", schema: CLIStore.cloudSchema,
                                             url: paths.cloud, cloudKitDatabase: .none)
        let localConfig = ModelConfiguration("local", schema: CLIStore.localSchema,
                                             url: paths.local, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(CLIStore.cloudTypes + CLIStore.localTypes),
                                           configurations: cloudConfig, localConfig)
        let context = ModelContext(container)
        context.insert(CachedIssue(repoOwner: "o", repoName: "r", number: 1, title: "Seeded",
                                   createdAt: Date(), rawBody: "b", appName: "A", appVersion: nil,
                                   device: nil, osVersion: nil, email: nil, issueDescription: "d"))
        context.insert(Product(displayName: "Seeded Product", owner: "o", repo: "r"))
        try context.save()
    }

    func testOpensBothStoresAndReads() throws {
        try seedStores()
        let store = try CLIStore.open(paths: paths)
        let issues = try store.local.fetch(FetchDescriptor<CachedIssue>())
        let products = try store.cloud.fetch(FetchDescriptor<Product>())
        XCTAssertEqual(issues.map(\.title), ["Seeded"])
        XCTAssertEqual(products.map(\.displayName), ["Seeded Product"])
    }

    func testOpenedStorePersistsNothing() throws {
        try seedStores()
        let store = try CLIStore.open(paths: paths)
        store.local.insert(CachedIssue(repoOwner: "o", repoName: "r", number: 2, title: "Nope",
                                       createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
                                       device: nil, osVersion: nil, email: nil, issueDescription: ""))
        try? store.local.save()

        // What matters is that nothing landed on disk, whether save threw or was ignored.
        let reopened = try CLIStore.open(paths: paths)
        let titles = try reopened.local.fetch(FetchDescriptor<CachedIssue>()).map(\.title)
        XCTAssertEqual(titles, ["Seeded"], "allowsSave:false must not persist writes")
    }

    func testMissingStoreThrowsNoLocalDataAndCreatesNothing() {
        XCTAssertThrowsError(try CLIStore.open(paths: paths)) { error in
            guard let cliError = error as? CLIError, case .noLocalData = cliError else {
                return XCTFail("expected .noLocalData, got \(error)")
            }
        }
        // A failed open must not have created a store file — that would mask the condition.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.local.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.cloud.path))
    }

    func testCorruptStoreThrowsNoLocalDataRatherThanCrashing() throws {
        try Data("not a database".utf8).write(to: paths.local)
        try Data("not a database".utf8).write(to: paths.cloud)
        XCTAssertThrowsError(try CLIStore.open(paths: paths)) { error in
            guard let cliError = error as? CLIError, case .noLocalData = cliError else {
                return XCTFail("expected .noLocalData, got \(error)")
            }
        }
    }

    func testSnapshotFallbackProducesAReadableCopy() throws {
        try seedStores()
        let snapshot = try CLIStore.snapshot(of: paths.local, into: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        // Read the snapshot back through the same container shape, with the cloud store left
        // in place — this is exactly how the fallback path would consume it.
        let store = try CLIStore.open(paths: CLIStore.Paths(local: snapshot, cloud: paths.cloud))
        XCTAssertEqual(try store.local.fetch(FetchDescriptor<CachedIssue>()).map(\.title), ["Seeded"])
    }

    func testDefaultPathsPointAtApplicationSupport() {
        let defaults = CLIStore.Paths.default
        XCTAssertEqual(defaults.local.lastPathComponent, "local.store")
        XCTAssertEqual(defaults.cloud.lastPathComponent, "cloud.store")
        XCTAssertTrue(defaults.local.path.contains("Application Support"))
    }

    // MARK: - Schema drift against the app

    /// `CLIStore` re-declares the app's two schemas. The day a `@Model` is added to
    /// `AppFeedbackApp`'s `cloudSchema`/`localSchema` without editing `CLIStore`, the CLI opens the
    /// store with a narrower model, SwiftData decides a migration is due, `allowsSave: false`
    /// rejects it, and EVERY command fails at once. These two tests are the tripwire.
    ///
    /// The app builds its schemas from local `let`s inside `AppFeedbackApp.init`, so the lists are
    /// not reachable as symbols from the test target. This first test therefore pins them by name:
    /// **if it fails, update BOTH `CLIStore.swift` and this list.**
    func testCLISchemasMatchThePinnedEntityNames() {
        let expectedLocal: Set<String> = [
            "CachedIssue", "MailAttachmentLocal", "MailAccountLocalState",
            "RepoFetchState", "FeedbackAttachmentLocal", "TriageVerdictRecord",
        ]
        let expectedCloud: Set<String> = [
            "Product", "Repo", "SeenIssue", "MailAccount",
            "GitHubAccount", "MailSettings", "MailThread", "MailMessage",
            "MailAttachment", "IssueTranslation", "IssueSummaryCache",
            "ProjectVersion", "SentReleaseNotification", "ReplyTemplate",
            "RepoFilterPreference", "AppStoreReviewMirror",
        ]
        XCTAssertEqual(Set(Schema(CLIStore.localTypes).entities.map(\.name)), expectedLocal)
        XCTAssertEqual(Set(Schema(CLIStore.cloudTypes).entities.map(\.name)), expectedCloud)

        // The two stores must stay disjoint: an entity in both configurations is ambiguous to
        // Core Data when it routes a fetch.
        XCTAssertTrue(expectedLocal.isDisjoint(with: expectedCloud))
    }

    /// The real drift detector: read `AppFeedbackApp.swift` off disk and compare its
    /// `Schema([...])` lists to `CLIStore`'s. Skipped when the sources are not next to the test
    /// bundle (e.g. a stripped CI checkout); the pinned test above still runs everywhere.
    func testCLISchemasMatchAppFeedbackAppSource() throws {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()      // AppFeedbackTests
            .deletingLastPathComponent()      // repo root
        let appSource = repoRoot.appending(path: "AppFeedback/App/AppFeedbackApp.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: appSource.path),
                          "app sources not available at \(appSource.path)")
        let source = try String(contentsOf: appSource, encoding: .utf8)

        for (variable, cliTypes) in [("cloudSchema", CLIStore.cloudTypes),
                                     ("localSchema", CLIStore.localTypes)] {
            guard let declared = Self.schemaTypeNames(in: source, variable: variable) else {
                return XCTFail("could not find `let \(variable) = Schema([...])` in "
                               + "AppFeedbackApp.swift — if the app now builds its container "
                               + "differently, retarget this test rather than deleting it")
            }
            XCTAssertEqual(Set(Schema(cliTypes).entities.map(\.name)), declared,
                           "CLIStore.\(variable) has drifted from AppFeedbackApp's \(variable). "
                           + "The CLI would open the store with the wrong model and every command "
                           + "would fail on a rejected migration. Update CLIStore.swift.")
        }
    }

    /// Extracts `Foo`, `Bar` from `let <variable> = Schema([Foo.self, Bar.self])`.
    private static func schemaTypeNames(in source: String, variable: String) -> Set<String>? {
        guard let open = source.range(of: "let \(variable) = Schema([") else { return nil }
        guard let close = source.range(of: "])", range: open.upperBound..<source.endIndex) else {
            return nil
        }
        let names = source[open.upperBound..<close.lowerBound]
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                     .replacingOccurrences(of: ".self", with: "") }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : Set(names)
    }

    /// The decisive check: open the REAL store this machine's app writes, from a second
    /// process, read-only. Skipped when the app has never run here.
    func testOpensTheLiveStoreReadOnly() throws {
        let paths = CLIStore.Paths.default
        try XCTSkipUnless(FileManager.default.fileExists(atPath: paths.local.path)
                          && FileManager.default.fileExists(atPath: paths.cloud.path),
                          "no live store on this machine")

        let store = try CLIStore.open(paths: paths)
        let issues = try store.local.fetch(FetchDescriptor<CachedIssue>())
        let products = try store.cloud.fetch(FetchDescriptor<Product>())
        XCTAssertFalse(products.isEmpty, "the live cloud store should hold at least one product")
        print("live store: \(issues.count) cached issues, \(products.count) products")
    }
}
#endif
