import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailAccountMigrationTests: XCTestCase {

    private func makeStore() throws -> (MailAccountStore, UserDefaults) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        let suite = "MailAccountMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MailAccountStore(context: ModelContext(container)), defaults)
    }

    func test_noLegacyData_doesNothingButMarksCompleted() throws {
        let (store, defaults) = try makeStore()
        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)
        XCTAssertNil(store.account)
        XCTAssertTrue(defaults.bool(forKey: "mail.migration.v1.completed"))
    }

    func test_legacyCredentials_migrateIntoMailAccount() throws {
        let (store, defaults) = try makeStore()
        let creds = SMTPCredentials(
            preset: .gmail, host: "smtp.gmail.com", port: 587,
            username: "alice@x", senderName: "Alice"
        )
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")
        let template = MailTemplate(headerHTML: "<p>hi</p>", footerHTML: "<p>bye</p>")
        defaults.set(try JSONEncoder().encode(template), forKey: "mail.template")

        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)

        XCTAssertEqual(store.account?.smtpUsername, "alice@x")
        XCTAssertEqual(store.account?.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(store.account?.smtpPort, 587)
        XCTAssertEqual(store.account?.senderName, "Alice")
        XCTAssertEqual(store.account?.presetRaw, "gmail")
        XCTAssertEqual(store.account?.imapHost, "imap.gmail.com")
        XCTAssertEqual(store.account?.imapPort, 993)
        XCTAssertEqual(store.account?.imapUsername, "alice@x")
        XCTAssertEqual(store.account?.templateHeaderHTML, "<p>hi</p>")
        XCTAssertEqual(store.account?.templateFooterHTML, "<p>bye</p>")
    }

    func test_runIfNeeded_isIdempotent() throws {
        let (store, defaults) = try makeStore()
        let creds = SMTPCredentials.defaults(for: .icloud)
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")

        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)
        let firstID = store.account?.id

        // Pretend a user updated the account after migration; second run must
        // not overwrite it because the migration flag is set.
        store.upsert { $0.smtpUsername = "renamed@x" }

        MailAccountMigration.runIfNeeded(store: store, defaults: defaults)

        XCTAssertEqual(store.account?.id, firstID)
        XCTAssertEqual(store.account?.smtpUsername, "renamed@x")
    }

    func test_migration_seedsImapDefaults_perPreset() throws {
        let cases: [(SMTPCredentials.Preset, String)] = [
            (.gmail,   "imap.gmail.com"),
            (.icloud,  "imap.mail.me.com"),
            (.outlook, "outlook.office365.com")
        ]
        for (preset, expectedHost) in cases {
            let (store, defaults) = try makeStore()
            let creds = SMTPCredentials.defaults(for: preset)
            defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")
            MailAccountMigration.runIfNeeded(store: store, defaults: defaults)
            XCTAssertEqual(store.account?.imapHost, expectedHost, "preset: \(preset)")
            XCTAssertEqual(store.account?.imapPort, 993)
        }
    }

    // MARK: - v2 migration tests

    func test_v2_marksExistingAccountAsDefaultSender() async throws {
        let (store, settingsStore, threadStore, defaults, _) = try makeV2Fixtures()
        let acc = store.add { $0.smtpUsername = "old@x" }
        acc.isDefaultSender = false
        defaults.set(false, forKey: "mail.multiaccount.migration.v1.completed")

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertTrue(store.account(id: acc.id)?.isDefaultSender ?? false)
        XCTAssertTrue(defaults.bool(forKey: "mail.multiaccount.migration.v1.completed"))
    }

    func test_v2_movesSharedSettingsIntoMailSettings() async throws {
        let (store, settingsStore, threadStore, defaults, _) = try makeV2Fixtures()
        let acc = store.add { a in
            a.smtpUsername = "old@x"
            a.templateHeaderHTML = "<p>hello</p>"
            a.templateFooterHTML = "<p>cheers</p>"
            a.pollIntervalSeconds = 600
        }
        defaults.set(false, forKey: "mail.multiaccount.migration.v1.completed")

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>hello</p>")
        XCTAssertEqual(settingsStore.settings.templateFooterHTML, "<p>cheers</p>")
        XCTAssertEqual(settingsStore.settings.pollIntervalSeconds, 600)
        XCTAssertEqual(store.account(id: acc.id)?.templateHeaderHTML, "")
        XCTAssertEqual(store.account(id: acc.id)?.templateFooterHTML, "")
    }

    func test_v2_isIdempotent() async throws {
        let (store, settingsStore, threadStore, defaults, _) = try makeV2Fixtures()
        _ = store.add { a in
            a.smtpUsername = "old@x"
            a.templateHeaderHTML = "<p>once</p>"
        }
        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )
        // Mutate settings after migration; a second run must NOT overwrite them.
        settingsStore.update { $0.templateHeaderHTML = "<p>edited</p>" }
        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )
        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>edited</p>")
    }

    func test_v2_backfillsMessageAndThreadAccountID() async throws {
        let (store, settingsStore, threadStore, defaults, ctx) = try makeV2Fixtures()
        let acc = store.add { $0.smtpUsername = "old@x" }
        let thread = MailThread(messageIDRoot: "<x>", subject: "S")
        let message = MailMessage(messageID: "<x>", thread: thread)
        ctx.insert(thread)
        ctx.insert(message)
        try ctx.save()

        MailAccountMigration.runV2IfNeeded(
            accountStore: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            defaults: defaults
        )

        XCTAssertEqual(thread.accountID, acc.id)
        XCTAssertEqual(message.accountID, acc.id)
    }

    // MARK: - helpers

    private func makeV2Fixtures() throws -> (MailAccountStore, MailSettingsStore, MailThreadStore, UserDefaults, ModelContext) {
        let schema = Schema([MailAccount.self, MailSettings.self, MailThread.self, MailMessage.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let accountStore = MailAccountStore(context: ctx)
        let settingsStore = MailSettingsStore(context: ctx)
        let threadStore = MailThreadStore(context: ctx)
        let defaults = UserDefaults(suiteName: "mail.migration.v2.\(UUID().uuidString)")!
        return (accountStore, settingsStore, threadStore, defaults, ctx)
    }
}
