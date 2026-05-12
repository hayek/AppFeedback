import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailAccountMigrationTests: XCTestCase {

    private func makeStore() throws -> (MailAccountStore, MailSettingsStore, UserDefaults) {
        let schema = Schema([MailAccount.self, MailSettings.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let suite = "MailAccountMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MailAccountStore(context: ctx), MailSettingsStore(context: ctx), defaults)
    }

    func test_noLegacyData_doesNothingButMarksCompleted() throws {
        let (store, settingsStore, defaults) = try makeStore()
        MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "mail.migration.v1.completed"))
    }

    func test_legacyCredentials_migrateIntoMailAccount() throws {
        let (store, settingsStore, defaults) = try makeStore()
        let creds = SMTPCredentials(
            preset: .gmail, host: "smtp.gmail.com", port: 587,
            username: "alice@x", senderName: "Alice"
        )
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")
        let template = MailTemplate(headerHTML: "<p>hi</p>", footerHTML: "<p>bye</p>")
        defaults.set(try JSONEncoder().encode(template), forKey: "mail.template")

        MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)

        XCTAssertEqual(store.accounts.first?.smtpUsername, "alice@x")
        XCTAssertEqual(store.accounts.first?.smtpHost, "smtp.gmail.com")
        XCTAssertEqual(store.accounts.first?.smtpPort, 587)
        XCTAssertEqual(store.accounts.first?.senderName, "Alice")
        XCTAssertEqual(store.accounts.first?.presetRaw, "gmail")
        XCTAssertEqual(store.accounts.first?.imapHost, "imap.gmail.com")
        XCTAssertEqual(store.accounts.first?.imapPort, 993)
        XCTAssertEqual(store.accounts.first?.imapUsername, "alice@x")
        // Templates now live in MailSettings, not on MailAccount.
        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>hi</p>")
        XCTAssertEqual(settingsStore.settings.templateFooterHTML, "<p>bye</p>")
    }

    func test_v1_movesTemplateToMailSettings() throws {
        let (store, settingsStore, defaults) = try makeStore()
        let template = MailTemplate(headerHTML: "<p>v1 header</p>", footerHTML: "<p>v1 footer</p>")
        defaults.set(try JSONEncoder().encode(template), forKey: "mail.template")
        defaults.set(false, forKey: "mail.migration.v1.completed")

        MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)

        XCTAssertEqual(settingsStore.settings.templateHeaderHTML, "<p>v1 header</p>")
        XCTAssertEqual(settingsStore.settings.templateFooterHTML, "<p>v1 footer</p>")
    }

    func test_runIfNeeded_isIdempotent() throws {
        let (store, settingsStore, defaults) = try makeStore()
        let creds = SMTPCredentials.defaults(for: .icloud)
        defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")

        MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)
        let firstID = store.accounts.first?.id

        // Pretend a user updated the account after migration; second run must
        // not overwrite it because the migration flag is set.
        if let id = store.accounts.first?.id {
            store.update(id: id) { $0.smtpUsername = "renamed@x" }
        }

        MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)

        XCTAssertEqual(store.accounts.first?.id, firstID)
        XCTAssertEqual(store.accounts.first?.smtpUsername, "renamed@x")
    }

    func test_migration_seedsImapDefaults_perPreset() throws {
        let cases: [(SMTPCredentials.Preset, String)] = [
            (.gmail,   "imap.gmail.com"),
            (.icloud,  "imap.mail.me.com"),
            (.outlook, "outlook.office365.com")
        ]
        for (preset, expectedHost) in cases {
            let (store, settingsStore, defaults) = try makeStore()
            let creds = SMTPCredentials.defaults(for: preset)
            defaults.set(try JSONEncoder().encode(creds), forKey: "mail.credentials")
            MailAccountMigration.runIfNeeded(store: store, settingsStore: settingsStore, defaults: defaults)
            XCTAssertEqual(store.accounts.first?.imapHost, expectedHost, "preset: \(preset)")
            XCTAssertEqual(store.accounts.first?.imapPort, 993)
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

    func test_v2_isIdempotent() async throws {
        let (store, settingsStore, threadStore, defaults, _) = try makeV2Fixtures()
        _ = store.add { a in
            a.smtpUsername = "old@x"
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
