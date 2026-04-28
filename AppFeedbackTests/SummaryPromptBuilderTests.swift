import XCTest
@testable import AppFeedback

final class SummaryPromptBuilderTests: XCTestCase {

    private func issue(number: Int, title: String, body: String, app: String? = "App", labels: [IssueLabel] = []) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: title, createdAt: Date(),
            rawBody: body, appName: app, appVersion: nil,
            device: nil, osVersion: nil, email: nil,
            description: body, labels: labels
        )
    }

    func test_build_capsAtThirty() {
        let many = (1...50).map { issue(number: $0, title: "T\($0)", body: "B") }
        let prompt = SummaryPromptBuilder.build(issues: many, targetLanguage: "en")
        XCTAssertTrue(prompt.contains("+20 more"))
        XCTAssertEqual(prompt.components(separatedBy: "\n- #").count - 1, 30)
    }

    func test_build_truncatesBodyTo200Chars() {
        let long = String(repeating: "Z", count: 500)
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: long)],
            targetLanguage: "en"
        )
        let zCount = prompt.filter { $0 == "Z" }.count
        XCTAssertLessThanOrEqual(zCount, 200)
    }

    func test_build_stripsFencedCodeBlocks() {
        let body = "before\n```swift\nlet x = 1\n```\nafter"
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: body)],
            targetLanguage: "en"
        )
        XCTAssertFalse(prompt.contains("let x = 1"))
        XCTAssertTrue(prompt.contains("before"))
        XCTAssertTrue(prompt.contains("after"))
    }

    func test_build_includesLabels() {
        let issueWithLabel = issue(
            number: 1, title: "T", body: "B",
            labels: [IssueLabel(name: "crash", colorHex: "#f00")]
        )
        let prompt = SummaryPromptBuilder.build(issues: [issueWithLabel], targetLanguage: "en")
        XCTAssertTrue(prompt.contains("crash"))
    }

    func test_build_includesTargetLanguage() {
        let prompt = SummaryPromptBuilder.build(
            issues: [issue(number: 1, title: "T", body: "B")],
            targetLanguage: "fr"
        )
        XCTAssertTrue(prompt.lowercased().contains("french") || prompt.contains("fr"))
    }
}
