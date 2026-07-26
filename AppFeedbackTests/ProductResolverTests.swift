import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class ProductResolverTests: XCTestCase {

    private var context: ModelContext!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(
            for: Product.self, HiddenApp.self, ProjectVersion.self,
                CachedIssue.self, RepoFetchState.self, TriageVerdictRecord.self,
            configurations: config))
    }

    @discardableResult
    private func makeProduct(_ name: String, owner: String = "o", repo: String = "r",
                             connected: (String, String)? = nil) -> Product {
        let product = Product(displayName: name, owner: owner, repo: repo)
        product.connectedRepoOwner = connected?.0
        product.connectedRepoName = connected?.1
        context.insert(product)
        return product
    }

    private func makeIssue(number: Int, app: String?, labels: [String] = [], state: IssueState = .open) {
        context.insert(CachedIssue(
            repoOwner: "o", repoName: "r", number: number, title: "T\(number)",
            createdAt: Date(), state: state, rawBody: "", appName: app,
            appVersion: nil, device: nil, osVersion: nil, email: nil, issueDescription: "",
            labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") }))
    }

    // MARK: - Resolution order

    func testResolvesByDisplayNameCaseInsensitively() throws {
        makeProduct("Usage for Claude")
        XCTAssertEqual(try ProductResolver.resolve("usage FOR claude", cloud: context).displayName,
                       "Usage for Claude")
    }

    func testResolvesByUUID() throws {
        let product = makeProduct("Zcode")
        XCTAssertEqual(try ProductResolver.resolve(product.id.uuidString, cloud: context).id, product.id)
    }

    func testResolvesByOwnerSlashRepo() throws {
        makeProduct("Only One", owner: "hayek", repo: "FeedbackRepo")
        XCTAssertEqual(try ProductResolver.resolve("hayek/FeedbackRepo", cloud: context).displayName,
                       "Only One")
    }

    func testUUIDBeatsDisplayName() throws {
        let first = makeProduct("A")
        makeProduct(first.id.uuidString)      // a product literally named like a UUID
        XCTAssertEqual(try ProductResolver.resolve(first.id.uuidString, cloud: context).id, first.id)
    }

    func testAmbiguousRepoQueryListsCandidates() {
        makeProduct("Usage for Claude", owner: "hayek", repo: "FeedbackRepo")
        makeProduct("FeedbackRepo", owner: "hayek", repo: "FeedbackRepo")
        XCTAssertThrowsError(try ProductResolver.resolve("hayek/FeedbackRepo", cloud: context)) { error in
            guard let cliError = error as? CLIError,
                  case .notFound(let code, _, _, let candidates) = cliError else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(code, "product_ambiguous")
            XCTAssertEqual(candidates.count, 2)
            XCTAssertTrue(candidates.contains { $0.contains("Usage for Claude") })
        }
    }

    func testUnknownProductIsNotFoundWithCandidates() {
        makeProduct("Zcode")
        XCTAssertThrowsError(try ProductResolver.resolve("Nope", cloud: context)) { error in
            guard let cliError = error as? CLIError,
                  case .notFound(let code, _, _, let candidates) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "product_not_found")
            XCTAssertTrue(candidates.contains { $0.contains("Zcode") })
        }
    }

    func testNoProductsConfiguredIsItsOwnError() {
        XCTAssertThrowsError(try ProductResolver.resolve("anything", cloud: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "no_products")
        }
    }

    // MARK: - Summaries

    func testSummaryReportsAppsWithCountsAndHiddenFlag() throws {
        makeProduct("P", connected: ("hayek", "UsageForClaude"))
        makeIssue(number: 1, app: "Zcode")
        makeIssue(number: 2, app: "Zcode")
        makeIssue(number: 3, app: "Secret")
        context.insert(HiddenApp(repoOwner: "o", repoName: "r", appName: "Secret"))

        let apps = try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first).apps
        XCTAssertEqual(apps.first(where: { $0.name == "Zcode" })?.count, 2)
        XCTAssertEqual(apps.first(where: { $0.name == "Zcode" })?.hidden, false)
        XCTAssertEqual(apps.first(where: { $0.name == "Secret" })?.hidden, true)
    }

    func testSummarySeparatesFeedbackFromTaskCounts() throws {
        makeProduct("P")
        makeIssue(number: 1, app: "A")
        makeIssue(number: 2, app: "A", labels: [AppFeedbackLabels.task])
        makeIssue(number: 3, app: "A", labels: [AppFeedbackLabels.task])

        let summary = try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first)
        XCTAssertEqual(summary.feedbackCount, 1)
        XCTAssertEqual(summary.taskCount, 2)
    }

    func testSummaryCountsOnlyOpenIssues() throws {
        makeProduct("P")
        makeIssue(number: 1, app: "A")
        makeIssue(number: 2, app: "A", state: .closed)
        XCTAssertEqual(try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first).feedbackCount, 1)
    }

    func testSummaryIncludesConnectedRepoAndVersions() throws {
        makeProduct("P", connected: ("hayek", "UsageForClaude"))
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0", milestoneNumber: 12))

        let summary = try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first)
        XCTAssertEqual(summary.connectedRepo, "hayek/UsageForClaude")
        XCTAssertEqual(summary.versions.first?.name, "1.4.0")
        XCTAssertEqual(summary.versions.first?.milestoneNumber, 12)
        XCTAssertEqual(summary.versions.first?.released, false)
    }

    func testSummaryReportsSourceFlagsFromProductConfig() throws {
        let product = makeProduct("P")
        product.appStoreAppAppleID = "12345"
        let summary = try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first)
        XCTAssertTrue(summary.sources.sdk)
        XCTAssertTrue(summary.sources.appStore)
        XCTAssertFalse(summary.sources.email)
    }

    func testSummaryReportsLastFetchedAt() throws {
        makeProduct("P")
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(RepoFetchState(repoOwner: "o", repoName: "r", lastFetchedAt: stamp))
        XCTAssertEqual(try XCTUnwrap(ProductResolver.all(cloud: context, local: context).first).lastFetchedAt,
                       stamp)
    }
}
#endif
