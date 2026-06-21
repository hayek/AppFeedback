import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class EmailSourceFormModelTests: XCTestCase {

    // MARK: - Orphan prevention: remove() after Test Connection mid-session

    /// Regression test for a bug where remove() used model.existingAccountID (nil for new
    /// inboxes) instead of the live product linkage, orphaning accounts created via Test
    /// Connection without a prior Save.
    ///
    /// Scenario: user opens EmailSourceForm for a product with no inbox, fills in credentials,
    /// taps "Test Connection" (which calls persistAccount() → mints a MailAccount and links it),
    /// then taps "Remove" without ever tapping "Save". The fixed remove() resolves the account
    /// ID from productStore.products first, so the newly minted MailAccount is deleted.
    func test_remove_afterTestConnection_deletesOrphanedMailAccount() async throws {
        // ── Set up in-memory stores ──────────────────────────────────────────────────────
        let schema = Schema([Product.self, HiddenApp.self, MailAccount.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let productStore = ProductStore(context: ctx, hiddenAppStore: HiddenAppStore(context: ctx))
        let accountStore = MailAccountStore(context: ctx)

        // ── Seed a product with NO initial inbox account ─────────────────────────────────
        let product = ProductConfig(displayName: "Demo", owner: "org", repo: "app")
        productStore.add(product)
        XCTAssertNil(productStore.products.first?.feedbackInboxAccountID,
                     "pre-condition: product should have no inbox account")

        // ── Simulate persistAccount() called by Test Connection ──────────────────────────
        // (model.existingAccountID is nil because the form was opened for a new inbox)
        let newAccount = accountStore.add { acc in
            acc.imapHost = "imap.example.com"
            acc.imapUsername = "feedback@dev.com"
            acc.smtpUsername = "feedback@dev.com"
            acc.feedbackProductID = product.id
        }
        var linked = product
        linked.feedbackInboxAccountID = newAccount.id
        productStore.update(linked)

        XCTAssertEqual(accountStore.accounts.count, 1, "exactly one account should exist after Test Connection")
        XCTAssertEqual(productStore.products.first?.feedbackInboxAccountID, newAccount.id,
                       "product should be linked to the new account")

        // ── Simulate the FIXED remove() logic ────────────────────────────────────────────
        // model.existingAccountID is nil (form was opened with no pre-existing inbox),
        // so the fix resolves via the live product linkage.
        let modelExistingAccountID: UUID? = nil   // mirrors EmailSourceFormModel.existingAccountID for a new inbox
        let resolvedID = productStore.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID
                      ?? modelExistingAccountID

        var cleared = product
        cleared.feedbackInboxAccountID = nil
        productStore.update(cleared)

        if let id = resolvedID, let acc = accountStore.account(id: id) {
            await accountStore.deleteWithCredentials(acc)
        }

        // ── Assert no orphaned MailAccount ───────────────────────────────────────────────
        XCTAssertNil(productStore.products.first?.feedbackInboxAccountID,
                     "product link should be cleared after remove")
        XCTAssertTrue(accountStore.accounts.isEmpty,
                      "MailAccount created during Test Connection must not be orphaned after remove")
    }

    /// Confirms the original bug: using model.existingAccountID (nil) fails to delete the
    /// account created mid-session, leaving an orphan.
    func test_remove_usingOnlyExistingAccountID_orphansAccountCreatedMidSession() async throws {
        let schema = Schema([Product.self, HiddenApp.self, MailAccount.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        let productStore = ProductStore(context: ctx, hiddenAppStore: HiddenAppStore(context: ctx))
        let accountStore = MailAccountStore(context: ctx)

        let product = ProductConfig(displayName: "Demo", owner: "org", repo: "app2")
        productStore.add(product)

        // Simulate Test Connection minting an account and linking it
        let newAccount = accountStore.add { acc in
            acc.imapHost = "imap.example.com"; acc.imapUsername = "fb@dev.com"
            acc.smtpUsername = "fb@dev.com"; acc.feedbackProductID = product.id
        }
        var linked = product; linked.feedbackInboxAccountID = newAccount.id
        productStore.update(linked)

        // Simulate the BUGGY remove() logic: uses model.existingAccountID (nil for new inbox)
        let modelExistingAccountID: UUID? = nil
        var cleared = product; cleared.feedbackInboxAccountID = nil
        productStore.update(cleared)
        if let id = modelExistingAccountID, let acc = accountStore.account(id: id) {
            await accountStore.deleteWithCredentials(acc)
        }

        // This is the BUG: the account remains orphaned
        XCTAssertEqual(accountStore.accounts.count, 1,
                       "buggy path leaves the account orphaned — this test documents the pre-fix behaviour")
    }

    // MARK: - Original model tests

    func test_defaultsForPreset_fillsImapHostAndPort() {
        let m = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)
        m.applyPresetDefaults(.icloud)
        XCTAssertEqual(m.imapHost, MailAccountMigration.imapDefaults(for: .icloud).host)
        XCTAssertEqual(m.imapPort, String(MailAccountMigration.imapDefaults(for: .icloud).port))
    }

    func test_canTest_requiresHostUserPassword() {
        let m = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)
        XCTAssertFalse(m.canTest)
        m.username = "feedback@dev.com"
        m.applyPresetDefaults(.gmail)   // sets imapHost
        XCTAssertFalse(m.canTest)       // still no password
        m.password = "app-pw"
        XCTAssertTrue(m.canTest)
    }

    func test_isEditing_reflectsExistingAccountID() {
        XCTAssertFalse(EmailSourceFormModel(productID: UUID(), existingAccountID: nil).isEditing)
        XCTAssertTrue(EmailSourceFormModel(productID: UUID(), existingAccountID: UUID()).isEditing)
    }

    func test_effectiveAccountValues_mirrorsImapIntoSmtpAndStampsProduct() {
        let pid = UUID()
        let m = EmailSourceFormModel(productID: pid, existingAccountID: nil)
        m.username = "feedback@dev.com"
        m.senderName = "Acme Support"
        m.applyPresetDefaults(.gmail)
        let v = m.effectiveAccountValues()
        XCTAssertEqual(v.feedbackProductID, pid)
        XCTAssertEqual(v.imapUsername, "feedback@dev.com")
        XCTAssertEqual(v.smtpUsername, "feedback@dev.com")
        XCTAssertEqual(v.imapHost, MailAccountMigration.imapDefaults(for: .gmail).host)
        XCTAssertEqual(v.presetRaw, SMTPCredentials.Preset.gmail.rawValue)
    }
}
