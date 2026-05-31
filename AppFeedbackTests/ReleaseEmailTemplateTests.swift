import XCTest
@testable import AppFeedback

final class ReleaseEmailTemplateTests: XCTestCase {
    func testRendersPlaceholders() {
        let t = ReleaseEmailTemplate(
            subject: "{appName} {version} is out",
            body: "Hi! {whatsNew}\n\nYour reports: {theirFeedbacks}")
        let r = t.render(appName: "Feedbeek", version: "1.2.0", whatsNew: "Bug fixes",
                         feedbackNumbers: [12, 15])
        XCTAssertEqual(r.subject, "Feedbeek 1.2.0 is out")
        XCTAssertTrue(r.body.contains("Bug fixes"))
        XCTAssertTrue(r.body.contains("#12, #15"))
    }

    func testDefaultTemplateMentionsVersion() {
        let t = ReleaseEmailTemplate.default(appName: "Feedbeek", version: "1.2.0", whatsNew: "Notes")
        let r = t.render(appName: "Feedbeek", version: "1.2.0", whatsNew: "Notes", feedbackNumbers: [3])
        XCTAssertTrue(r.subject.contains("1.2.0"))
        XCTAssertFalse(r.body.contains("{"))   // no stray placeholders
    }
}
