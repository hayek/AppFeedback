import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class EmailSourceFormModelTests: XCTestCase {

    // MARK: - Orphan prevention: resolvedAccountID helper

    /// `resolvedAccountID` prefers the live product linkage over the model's
    /// init-time existingAccountID. This is the production logic used by both
    /// `remove()` and the `onDisappear` cleanup.
    func test_resolvedAccountID_prefersLiveOverExisting() {
        let existingID = UUID()
        let liveID = UUID()
        let model = EmailSourceFormModel(productID: UUID(), existingAccountID: existingID)

        // Live linkage present → use it (covers mid-session account minted by Test Connection).
        XCTAssertEqual(model.resolvedAccountID(liveProductAccountID: liveID), liveID)
    }

    func test_resolvedAccountID_fallsBackToExistingWhenLiveIsNil() {
        let existingID = UUID()
        let model = EmailSourceFormModel(productID: UUID(), existingAccountID: existingID)

        // No live linkage → fall back to form-init existingAccountID.
        XCTAssertEqual(model.resolvedAccountID(liveProductAccountID: nil), existingID)
    }

    func test_resolvedAccountID_returnsNilWhenBothNil() {
        let model = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)
        XCTAssertNil(model.resolvedAccountID(liveProductAccountID: nil))
    }

    // MARK: - Orphan prevention: remove() after Test Connection mid-session

    /// Regression test for the scenario: user opens EmailSourceForm for a product with no inbox,
    /// fills in credentials, taps "Test Connection" (which calls persistAccount() → mints a
    /// MailAccount and links it to the product), then taps "Remove" without ever tapping "Save".
    ///
    /// The fixed remove() resolves the account ID via model.resolvedAccountID(liveProductAccountID:),
    /// which checks the live product linkage first. This test calls that same helper directly
    /// (the production code calls it with liveAccountID, which reads from productStore.products —
    /// the exact same ID we set up in the "simulate Test Connection" step below).
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

        // ── Simulate the FIXED remove() logic via the production helper ───────────────────
        // model.existingAccountID is nil (form was opened with no pre-existing inbox),
        // but liveProductAccountID reflects what Test Connection just minted.
        let model = EmailSourceFormModel(productID: product.id, existingAccountID: nil)
        let liveAccountID = productStore.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID
        let resolvedID = model.resolvedAccountID(liveProductAccountID: liveAccountID)

        // This is what remove() does internally after resolving the ID:
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
        // instead of the production resolvedAccountID(liveProductAccountID:) helper.
        let model = EmailSourceFormModel(productID: product.id, existingAccountID: nil)
        let buggyID = model.resolvedAccountID(liveProductAccountID: nil) // ignores live linkage
        var cleared = product; cleared.feedbackInboxAccountID = nil
        productStore.update(cleared)
        if let id = buggyID, let acc = accountStore.account(id: id) {
            await accountStore.deleteWithCredentials(acc)
        }

        // This is the BUG: the account remains orphaned because buggyID is nil
        XCTAssertEqual(accountStore.accounts.count, 1,
                       "buggy path leaves the account orphaned — this test documents the pre-fix behaviour")
    }

    // MARK: - Cancel/navigate-away path: onDisappear orphan cleanup

    /// Documents the onDisappear path: a mid-session account (minted by Test Connection on a
    /// new-inbox form) is cleaned up when the form is dismissed via Cancel/navigate-away.
    /// The cleanup guard is: !didSaveOrRemove && model.existingAccountID == nil && liveAccountID != nil.
    func test_resolvedAccountID_newInbox_midSession_cleanupReachableViaLiveID() {
        // A new-inbox model (existingAccountID nil) after Test Connection has minted a live ID.
        let mintedID = UUID()
        let model = EmailSourceFormModel(productID: UUID(), existingAccountID: nil)

        // The onDisappear cleanup uses liveAccountID (from productStore) as the source,
        // same as resolvedAccountID(liveProductAccountID:).
        let resolved = model.resolvedAccountID(liveProductAccountID: mintedID)
        XCTAssertEqual(resolved, mintedID,
                       "onDisappear cleanup resolves the minted account via the live product linkage")
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
