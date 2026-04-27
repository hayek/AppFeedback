import XCTest
@testable import AppFeedback

@MainActor
final class MailSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "MailSettingsTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func test_credentials_roundTripThroughDefaults() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        let creds = SMTPCredentials(
            preset: .gmail,
            host: "smtp.gmail.com",
            port: 587,
            username: "alice@gmail.com",
            senderName: "Alice"
        )

        settings.credentials = creds

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertEqual(reloaded.credentials?.username, "alice@gmail.com")
        XCTAssertEqual(reloaded.credentials?.host, "smtp.gmail.com")
        XCTAssertEqual(reloaded.credentials?.port, 587)
        XCTAssertEqual(reloaded.credentials?.preset, .gmail)
    }

    func test_template_roundTrip() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        settings.template = MailTemplate(headerHTML: "<p>Hi {{recipient_email}}</p>", footerHTML: "<p>Bye</p>")

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertEqual(reloaded.template.headerHTML, "<p>Hi {{recipient_email}}</p>")
        XCTAssertEqual(reloaded.template.footerHTML, "<p>Bye</p>")
    }

    func test_presetDefaults_gmail() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .gmail).host, "smtp.gmail.com")
        XCTAssertEqual(SMTPCredentials.defaults(for: .gmail).port, 587)
    }

    func test_presetDefaults_icloud() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .icloud).host, "smtp.mail.me.com")
        XCTAssertEqual(SMTPCredentials.defaults(for: .icloud).port, 587)
    }

    func test_presetDefaults_outlook() {
        XCTAssertEqual(SMTPCredentials.defaults(for: .outlook).host, "smtp-mail.outlook.com")
    }

    func test_credentials_clearedWhenSetToNil() {
        let defaults = makeDefaults()
        let settings = MailSettings(defaults: defaults)
        settings.credentials = SMTPCredentials.defaults(for: .gmail)
        settings.credentials = nil

        let reloaded = MailSettings(defaults: defaults)
        XCTAssertNil(reloaded.credentials)
    }
}
