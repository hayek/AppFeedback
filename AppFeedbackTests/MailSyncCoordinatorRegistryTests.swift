import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailSyncCoordinatorRegistryTests: XCTestCase {
    func test_buildsOneCoordinatorPerAccount() throws {
        let fixtures = try makeFixtures()
        _ = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
    }

    func test_addingAccountSpinsUpCoordinator() throws {
        let fixtures = try makeFixtures()
        _ = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 1)
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
    }

    func test_deletingAccountTearsDownCoordinator() throws {
        let fixtures = try makeFixtures()
        let a = fixtures.accountStore.add { $0.smtpUsername = "a@x" }
        _ = fixtures.accountStore.add { $0.smtpUsername = "b@x" }
        let registry = MailSyncCoordinatorRegistry.makeForTests(fixtures: fixtures)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 2)
        fixtures.accountStore.delete(a)
        registry.syncWithAccounts()
        XCTAssertEqual(registry.coordinatorCount, 1)
    }

    // Helpers -----------------------------------------------------------------

    struct Fixtures {
        let context: ModelContext
        let accountStore: MailAccountStore
        let settingsStore: MailSettingsStore
        let threadStore: MailThreadStore
        let localStateStore: MailAccountLocalStateStore
        let activityLog: ActivityLog
    }

    private func makeFixtures() throws -> Fixtures {
        let schema = Schema([MailAccount.self, MailSettings.self, MailAccountLocalState.self,
                             MailThread.self, MailMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        return Fixtures(
            context: ctx,
            accountStore: MailAccountStore(context: ctx),
            settingsStore: MailSettingsStore(context: ctx),
            threadStore: MailThreadStore(context: ctx),
            localStateStore: MailAccountLocalStateStore(context: ctx),
            activityLog: ActivityLog(persistenceURL: nil)
        )
    }
}

fileprivate struct NoopIMAPClient: IMAPClientProtocol {
    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult { InboxPollResult(messages: [], uidValidity: 0) }
    func listAllInbox(sinceUID: UInt32, expectedUIDValidity: UInt32) async throws -> InboxPollResult { InboxPollResult(messages: [], uidValidity: 0) }
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] { [] }
    func listSentForEnrichment(sinceDate: Date, messageIDs: Set<String>) async throws -> [ParsedInboundMessage] { [] }
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String, expectedUIDValidity: UInt32) async throws -> Data { Data() }
    func testConnection() async throws {}
}

extension MailSyncCoordinatorRegistry {
    static func makeForTests(fixtures: MailSyncCoordinatorRegistryTests.Fixtures) -> MailSyncCoordinatorRegistry {
        MailSyncCoordinatorRegistry(accountStore: fixtures.accountStore) { id in
            MailSyncCoordinator(
                client: NoopIMAPClient(),
                accountID: id,
                threadStore: fixtures.threadStore,
                accountStore: fixtures.accountStore,
                settingsStore: fixtures.settingsStore,
                localState: fixtures.localStateStore,
                activityLog: fixtures.activityLog,
                knownIssueTitlesProvider: { [] }
            )
        }
    }
}
