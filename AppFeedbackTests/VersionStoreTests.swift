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
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("a@b.com"))
    }

    /// `recordSent` stamps the version's UUID, so the row is found by id and not by name.
    func testRecordSentStampsVersionID() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertEqual(store.sentNotifications(for: v).first?.versionID, v.id)
    }

    /// A legacy row (synced from an older build, so `versionID == nil`) is still matched by name.
    func testLegacyRowWithoutVersionIDMatchesByName() throws {
        let context = try makeContext()
        let store = VersionStore(context: context)
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        context.insert(SentReleaseNotification(
            repoOwner: "o", repoName: "r", versionName: "1.0.0", recipientEmail: "legacy@b.com",
            feedbackNumbers: [], threadIssueNumber: 1, status: .sent))
        store.saveAndReload()
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("legacy@b.com"))
    }

    /// A stamped row belongs to its version by id — a *different* version that happens to share the
    /// name must not pick it up.
    func testStampedRowDoesNotLeakToASameNamedVersionInAnotherProduct() throws {
        let store = VersionStore(context: try makeContext())
        let mine = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        let theirs = store.create(repoOwner: "o", repoName: "other", name: "1.0.0", changelog: "")
        store.recordSent(version: mine, recipientEmail: "a@b.com",
                         feedbackNumbers: [], threadIssueNumber: 1, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: mine).contains("a@b.com"))
        XCTAssertTrue(store.alreadyNotifiedEmails(for: theirs).isEmpty)
    }

    /// Only `.sent` rows count as "already notified" — a failed send must be retryable.
    func testFailedSendIsNotCountedAsAlreadyNotified() throws {
        let store = VersionStore(context: try makeContext())
        let v = store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com", feedbackNumbers: [],
                         threadIssueNumber: 1, status: .failed, errorDetail: "boom")
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).isEmpty)
        XCTAssertEqual(store.sentNotifications(for: v).count, 1)
    }
}
