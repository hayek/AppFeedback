import XCTest
@testable import AppFeedback

@MainActor
final class EmailSourceFormModelTests: XCTestCase {

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
