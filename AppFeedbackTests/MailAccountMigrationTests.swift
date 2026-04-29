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
}
