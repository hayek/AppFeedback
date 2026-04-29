import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailAccountStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        return ModelContext(container)
    }

    func test_account_isNilWhenStoreIsEmpty() throws {
        let store = MailAccountStore(context: try makeContext())
        XCTAssertNil(store.account)
    }

    func test_upsert_createsAccountWhenAbsent() throws {
        let store = MailAccountStore(context: try makeContext())
        store.upsert { acc in
            acc.smtpUsername = "alice@x"
            acc.senderName = "Alice"
            acc.smtpHost = "smtp.gmail.com"
        }
        XCTAssertEqual(store.account?.smtpUsername, "alice@x")
        XCTAssertEqual(store.account?.senderName, "Alice")
        XCTAssertEqual(store.account?.smtpHost, "smtp.gmail.com")
    }

    func test_upsert_updatesExistingAccountInPlace() throws {
        let context = try makeContext()
        let store = MailAccountStore(context: context)
        store.upsert { $0.smtpUsername = "first@x" }
        let firstID = store.account?.id
        store.upsert { $0.smtpUsername = "second@x" }
        let secondID = store.account?.id

        let descriptor = FetchDescriptor<MailAccount>()
        let rows = try context.fetch(descriptor)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.smtpUsername, "second@x")
        XCTAssertEqual(firstID, secondID)
    }

    func test_deleteAccount_clearsBothStateAndPersistence() throws {
        let context = try makeContext()
        let store = MailAccountStore(context: context)
        store.upsert { $0.smtpUsername = "x@x" }
        store.deleteAccount()
        XCTAssertNil(store.account)
        let rows = try context.fetch(FetchDescriptor<MailAccount>())
        XCTAssertTrue(rows.isEmpty)
    }

    func test_reload_picksUpExternalChanges() throws {
        let context = try makeContext()
        let store = MailAccountStore(context: context)
        // Simulate a sibling writer (e.g., CloudKit sync) inserting a row directly.
        let external = MailAccount(smtpUsername: "external@x")
        context.insert(external)
        try context.save()

        XCTAssertNil(store.account)
        store.reload()
        XCTAssertEqual(store.account?.smtpUsername, "external@x")
    }
}
