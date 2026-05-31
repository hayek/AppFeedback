import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ProjectVersion.self, SentReleaseNotification.self, configurations: config)
        return ModelContext(container)
    }

    func testAddAndFetchScopedToRepo() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "first")
        store.create(repoOwner: "o", repoName: "other", name: "9.9", changelog: "")
        let forRepo = store.versions(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.name), ["1.0.0"])
        XCTAssertEqual(v.changelog, "first")
    }

    func testRecordSentNotification() throws {
        let store = VersionStore(context: try makeContext())
        store.recordSent(repoOwner: "o", repoName: "r", versionName: "1.0.0",
                         recipientEmail: "a@b.com", feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        let already = store.alreadyNotifiedEmails(owner: "o", repo: "r", versionName: "1.0.0")
        XCTAssertTrue(already.contains("a@b.com"))
    }
}
