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
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "first")
        try store.create(repoOwner: "o", repoName: "other", name: "9.9", changelog: "")
        let forRepo = store.versions(owner: "o", repo: "r")
        XCTAssertEqual(forRepo.map(\.name), ["1.0.0"])
        XCTAssertEqual(v.changelog, "first")
    }

    // MARK: Create validation
    //
    // `name` is the foreign key joining tasks, sent release emails and saved filters to a version.
    // Two versions sharing a name inside one product would merge each other's task lists — and
    // renaming either would rewrite BOTH versions' cached issues. Create has to refuse.

    func testCreateRejectsADuplicateNameInTheSameProduct() throws {
        let store = VersionStore(context: try makeContext())
        try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")

        XCTAssertThrowsError(try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .duplicate("1.2.0"))
        }
        XCTAssertEqual(store.versions(owner: "o", repo: "r").count, 1)
    }

    /// The duplicate check is case-insensitive and runs on the *trimmed* name, so neither casing
    /// nor stray whitespace can smuggle a second "1.2.0" in.
    func testCreateRejectsADuplicateRegardlessOfCasingOrWhitespace() throws {
        let store = VersionStore(context: try makeContext())
        try store.create(repoOwner: "o", repoName: "r", name: "2.0-Beta", changelog: "")

        XCTAssertThrowsError(try store.create(repoOwner: "o", repoName: "r", name: "  2.0-BETA ", changelog: ""))
        XCTAssertEqual(store.versions(owner: "o", repo: "r").count, 1)
    }

    func testCreateRejectsAnEmptyName() throws {
        let store = VersionStore(context: try makeContext())
        XCTAssertThrowsError(try store.create(repoOwner: "o", repoName: "r", name: "   ", changelog: "")) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .empty)
        }
        XCTAssertTrue(store.versions(owner: "o", repo: "r").isEmpty)
    }

    func testCreateStoresTheTrimmedName() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "  1.2.0 ", changelog: "")
        XCTAssertEqual(v.name, "1.2.0")
    }

    /// Uniqueness is per product, not global — two products may each have a "1.0.0".
    func testCreateAllowsTheSameNameInAnotherProduct() throws {
        let store = VersionStore(context: try makeContext())
        try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        try store.create(repoOwner: "o", repoName: "other", name: "1.0.0", changelog: "")

        XCTAssertEqual(store.versions(owner: "o", repo: "r").count, 1)
        XCTAssertEqual(store.versions(owner: "o", repo: "other").count, 1)
    }

    func testRecordSentNotification() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("a@b.com"))
    }

    /// `recordSent` stamps the version's UUID, so the row is found by id and not by name.
    func testRecordSentStampsVersionID() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [3], threadIssueNumber: 3, status: .sent)
        XCTAssertEqual(store.sentNotifications(for: v).first?.versionID, v.id)
    }

    /// A legacy row (synced from an older build, so `versionID == nil`) is still matched by name.
    func testLegacyRowWithoutVersionIDMatchesByName() throws {
        let context = try makeContext()
        let store = VersionStore(context: context)
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
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
        let mine = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        let theirs = try store.create(repoOwner: "o", repoName: "other", name: "1.0.0", changelog: "")
        store.recordSent(version: mine, recipientEmail: "a@b.com",
                         feedbackNumbers: [], threadIssueNumber: 1, status: .sent)
        XCTAssertTrue(store.alreadyNotifiedEmails(for: mine).contains("a@b.com"))
        XCTAssertTrue(store.alreadyNotifiedEmails(for: theirs).isEmpty)
    }

    /// Only `.sent` rows count as "already notified" — a failed send must be retryable.
    func testFailedSendIsNotCountedAsAlreadyNotified() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.0.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com", feedbackNumbers: [],
                         threadIssueNumber: 1, status: .failed, errorDetail: "boom")
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).isEmpty)
        XCTAssertEqual(store.sentNotifications(for: v).count, 1)
    }

    func testRenamePersistsTheNewName() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        store.rename(v, to: "1.3.0")
        XCTAssertEqual(store.versions(owner: "o", repo: "r").map(\.name), ["1.3.0"])
    }

    /// The regression this whole feature exists to avoid: renaming must not reset the
    /// already-emailed guard, or the next release pass re-mails real users.
    func testRenameKeepsTheAlreadyEmailedGuardIntact() throws {
        let store = VersionStore(context: try makeContext())
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        store.recordSent(version: v, recipientEmail: "a@b.com",
                         feedbackNumbers: [7], threadIssueNumber: 7, status: .sent)

        store.rename(v, to: "1.3.0")

        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("a@b.com"))
        XCTAssertEqual(store.sentNotifications(for: v).count, 1)
    }

    /// A legacy row (no `versionID`) is carried across the rename by name, and stamped on the way,
    /// so it is UUID-keyed from then on.
    func testRenameRewritesAndStampsLegacyRows() throws {
        let context = try makeContext()
        let store = VersionStore(context: context)
        let v = try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        context.insert(SentReleaseNotification(
            repoOwner: "o", repoName: "r", versionName: "1.2.0", recipientEmail: "legacy@b.com",
            feedbackNumbers: [], threadIssueNumber: 1, status: .sent))
        store.saveAndReload()

        store.rename(v, to: "1.3.0")

        let rows = store.sentNotifications(for: v)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.versionID, v.id)
        XCTAssertEqual(rows.first?.versionName, "1.3.0")
        XCTAssertTrue(store.alreadyNotifiedEmails(for: v).contains("legacy@b.com"))
    }

    /// A same-named version in a different product must be untouched.
    func testRenameIsScopedToItsOwnProduct() throws {
        let store = VersionStore(context: try makeContext())
        let mine = try store.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        let theirs = try store.create(repoOwner: "o", repoName: "other", name: "1.2.0", changelog: "")
        store.recordSent(version: theirs, recipientEmail: "them@b.com",
                         feedbackNumbers: [], threadIssueNumber: 1, status: .sent)

        store.rename(mine, to: "1.3.0")

        XCTAssertEqual(store.versions(owner: "o", repo: "other").map(\.name), ["1.2.0"])
        XCTAssertEqual(store.sentNotifications(for: theirs).first?.versionName, "1.2.0")
    }
}
