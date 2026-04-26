import XCTest
@testable import AppFeedback

final class IssueBodyParserTests: XCTestCase {

    let sampleBody = """
    The app crashes when I tap the sync button.

    ---
    **Device Information:**
    App: ClaudeUsage
    App Version: 2.4 (42)
    Device: MacBookPro18,1
    macOS Version: macOS 14.4.1 (Build 23E224)

    **Contact Email:**
    user@example.com

    ---
    \u{1F44D} Votes: 0
    """

    func test_parse_extractsDescription() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertTrue(result.description.contains("crashes when I tap"))
        XCTAssertFalse(result.description.contains("Device Information"))
    }

    func test_parse_extractsAppName() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertEqual(result.app, "ClaudeUsage")
    }

    func test_parse_extractsAppVersion() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertEqual(result.appVersion, "2.4 (42)")
    }

    func test_parse_extractsDevice() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertEqual(result.device, "MacBookPro18,1")
    }

    func test_parse_extractsOSVersion() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertNotNil(result.osVersion)
        XCTAssertTrue(result.osVersion!.contains("14.4.1"))
    }

    func test_parse_extractsEmail() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertEqual(result.email, "user@example.com")
    }

    func test_parse_stripsHorizontalRulesFromDescription() {
        let result = IssueBodyParser.parse(sampleBody)
        XCTAssertFalse(result.description.contains("---"))
    }

    func test_parse_emptyBody_returnsEmptyResult() {
        let result = IssueBodyParser.parse("")
        XCTAssertTrue(result.description.isEmpty)
        XCTAssertNil(result.app)
    }

    func test_parse_iOSBody_detectsiOSVersion() {
        let body = """
        Bug description

        ---
        **Device Information:**
        App: MyApp
        App Version: 1.0 (1)
        Device: iPhone
        iOS Version: 17.4
        """
        let result = IssueBodyParser.parse(body)
        XCTAssertEqual(result.osVersion, "17.4")
    }

    func test_parse_emailOnSameLine_asContactEmail() {
        let body = """
        Desc

        **Device Information:**
        App: X
        App Version: 1
        Device: Mac
        macOS Version: 14.0
        Contact Email: inline@test.com
        """
        let result = IssueBodyParser.parse(body)
        XCTAssertEqual(result.email, "inline@test.com")
    }
}
