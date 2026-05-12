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

    func test_accountsIsEmptyWhenStoreIsEmpty() throws {
        let store = MailAccountStore(context: try makeContext())
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.defaultSender)
    }

    func test_updateMutatesExistingAccountInPlace() throws {
        let store = MailAccountStore(context: try makeContext())
        let a = store.add { $0.smtpUsername = "first@x" }
        let firstID = a.id
        store.update(id: a.id) { $0.smtpUsername = "second@x" }
        XCTAssertEqual(store.accounts.first?.id, firstID, "update should not change the id")
        XCTAssertEqual(store.accounts.first?.smtpUsername, "second@x")
    }

    func test_reload_picksUpExternalChanges() throws {
        let context = try makeContext()
        let store = MailAccountStore(context: context)
        // Simulate a sibling writer (e.g., CloudKit sync) inserting a row directly.
        let external = MailAccount(smtpUsername: "external@x")
        context.insert(external)
        try context.save()

        XCTAssertTrue(store.accounts.isEmpty)
        store.reload()
        XCTAssertEqual(store.accounts.first?.smtpUsername, "external@x")
    }

    // MARK: - Multi-account API tests

    private func makeStore() throws -> MailAccountStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        return MailAccountStore(context: ModelContext(container))
    }

    func test_addReturnsAccountAndAppends() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "first@x" }
        let b = store.add { $0.smtpUsername = "second@x" }
        XCTAssertEqual(store.accounts.map(\.smtpUsername), ["first@x", "second@x"])
        XCTAssertNotEqual(a.id, b.id)
    }

    func test_firstAccountBecomesDefaultSender() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        XCTAssertTrue(a.isDefaultSender)
        XCTAssertEqual(store.defaultSender?.id, a.id)
    }

    func test_secondAccountDoesNotBecomeDefault() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        XCTAssertTrue(a.isDefaultSender)
        XCTAssertFalse(b.isDefaultSender)
    }

    func test_setDefaultSenderEnforcesSingleFlag() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        store.setDefaultSender(b)
        XCTAssertFalse(store.account(id: a.id)?.isDefaultSender ?? true)
        XCTAssertTrue(store.account(id: b.id)?.isDefaultSender ?? false)
    }

    func test_deletingDefaultReassignsToOldestRemaining() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x"; $0.createdAt = .init(timeIntervalSince1970: 1) }
        let b = store.add { $0.smtpUsername = "b@x"; $0.createdAt = .init(timeIntervalSince1970: 2) }
        store.delete(a)
        XCTAssertEqual(store.defaultSender?.id, b.id)
        XCTAssertTrue(store.account(id: b.id)?.isDefaultSender ?? false)
    }

    func test_deletingNonDefaultKeepsExistingDefault() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        let b = store.add { $0.smtpUsername = "b@x" }
        store.delete(b)
        XCTAssertEqual(store.defaultSender?.id, a.id)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func test_updateMutatesTargetAccount() throws {
        let store = try makeStore()
        let a = store.add { $0.smtpUsername = "a@x" }
        store.update(id: a.id) { $0.senderName = "Alice" }
        XCTAssertEqual(store.account(id: a.id)?.senderName, "Alice")
    }
}
