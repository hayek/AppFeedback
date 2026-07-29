import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIOutputTests: XCTestCase {

    private func makeItem(number: Int, title: String, app: String? = "Zcode",
                          rating: Int? = nil, tasks: [TaskRef] = []) -> FeedbackItem {
        FeedbackItem(number: number, title: title, app: app, appVersion: "1.0", source: "sdk",
                     type: "bug", rating: rating, state: "open",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                     updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     device: "iPhone", os: "iOS 18.6", email: nil, description: "d",
                     truncated: false, labels: ["bug"], tasks: tasks, triage: nil,
                     url: "https://github.com/o/r/issues/\(number)")
    }

    // MARK: - JSON contract

    func testJSONUsesISO8601Dates() {
        let envelope = CLIEnvelope(asOf: Date(timeIntervalSince1970: 1_700_000_000),
                                   stale: false, items: [makeItem(number: 1, title: "T")])
        XCTAssertTrue(CLIOutput.encode(envelope).contains("\"asOf\" : \"2023-11-14T22:13:20Z\""),
                      CLIOutput.encode(envelope))
    }

    func testJSONSortsKeys() throws {
        let json = CLIOutput.encode(CLIEnvelope(stale: false, items: [makeItem(number: 1, title: "T")]))
        let asOfOrItems = try XCTUnwrap(json.range(of: "\"items\""))
        let stale = try XCTUnwrap(json.range(of: "\"stale\""))
        XCTAssertTrue(asOfOrItems.lowerBound < stale.lowerBound, "sortedKeys: items precedes stale")
    }

    func testJSONDoesNotEscapeSlashesInURLs() {
        let json = CLIOutput.encode(CLIEnvelope(stale: false, items: [makeItem(number: 1, title: "T")]))
        XCTAssertTrue(json.contains("https://github.com/o/r/issues/1"))
    }

    func testNilOptionalsAreOmittedNotNulled() {
        let json = CLIOutput.encode(CLIEnvelope(stale: false, items: [makeItem(number: 1, title: "T")]))
        XCTAssertFalse(json.contains("\"page\""), "page is nil and should be omitted")
        XCTAssertFalse(json.contains("\"closedDataIncomplete\""))
        XCTAssertFalse(json.contains("null"))
    }

    func testEnvelopeCarriesPageAndProductWhenGiven() {
        let envelope = CLIEnvelope(
            stale: true,
            closedDataIncomplete: true,
            product: ProductRef(id: "id", displayName: "P", repo: "o/r"),
            page: PageInfo(limit: 20, offset: 0, total: 137, hasMore: true),
            items: [makeItem(number: 1, title: "T")])
        let json = CLIOutput.encode(envelope)
        XCTAssertTrue(json.contains("\"total\" : 137"))
        XCTAssertTrue(json.contains("\"hasMore\" : true"))
        XCTAssertTrue(json.contains("\"closedDataIncomplete\" : true"))
        XCTAssertTrue(json.contains("\"repo\" : \"o/r\""))
    }

    // MARK: - Text rendering

    func testFeedbackTextIncludesNumberTitleAndTaskMarker() {
        let tracked = makeItem(number: 559, title: "Crash on launch",
                               tasks: [TaskRef(number: 557, title: "Fix", status: "todo",
                                               priority: "high", isClosed: false)])
        let text = CLIText.render(feedback: [tracked, makeItem(number: 560, title: "Slow sync")])
        XCTAssertTrue(text.contains("559"))
        XCTAssertTrue(text.contains("Crash on launch"))
        XCTAssertTrue(text.contains("#557"), "tracked items should show their task")
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testFeedbackTextShowsRating() {
        XCTAssertTrue(CLIText.render(feedback: [makeItem(number: 1, title: "T", rating: 2)]).contains("2★"))
    }

    func testTextRenderingOfAnEmptyListIsAFriendlyLine() {
        XCTAssertEqual(CLIText.render(feedback: []), "No matching feedback.")
        XCTAssertEqual(CLIText.render(tasks: []), "No matching tasks.")
        XCTAssertEqual(CLIText.render(products: []), "No products configured.")
    }

    func testTextTruncatesLongTitlesToKeepColumnsAligned() {
        let text = CLIText.render(feedback: [makeItem(number: 1, title: String(repeating: "x", count: 200))])
        XCTAssertTrue(text.count < 150, "expected a truncated single line, got \(text.count) chars")
        XCTAssertTrue(text.contains("…"))
    }

    func testProductTextShowsRepoAndCounts() {
        let summary = ProductSummary(id: "id", displayName: "Usage for Claude",
                                     repo: "hayek/FeedbackRepo", connectedRepo: "hayek/UsageForClaude",
                                     versions: [],
                                     sources: SourceFlags(sdk: true, appStore: false, email: false),
                                     feedbackCount: 499, taskCount: 40, lastFetchedAt: nil)
        let text = CLIText.render(products: [summary])
        XCTAssertTrue(text.contains("Usage for Claude"))
        XCTAssertTrue(text.contains("hayek/FeedbackRepo"))
        XCTAssertTrue(text.contains("499"))
        XCTAssertTrue(text.contains("40"))
        XCTAssertTrue(text.contains("hayek/UsageForClaude"))
    }

    func testTaskTextShowsStatusPriorityAndFeedbackRefs() {
        let task = TaskItemDTO(number: 557, title: "Fix the crash", status: "in-progress",
                               priority: "high", isClosed: false, milestone: "1.4.0",
                               feedback: [553, 554], url: "https://github.com/o/r/issues/557")
        let text = CLIText.render(tasks: [task])
        XCTAssertTrue(text.contains("#557"))
        XCTAssertTrue(text.contains("in-progress"))
        XCTAssertTrue(text.contains("high"))
        XCTAssertTrue(text.contains("#553"))
    }

    func testTaskDetailTextIncludesNotesAndAddresses() {
        let detail = TaskDetail(number: 557, title: "Fix", status: "todo", priority: "med",
                                isClosed: false, milestone: nil, notes: "Root-cause it",
                                feedback: [LinkedFeedback(number: 553, title: "Crash", state: "open")],
                                url: "https://github.com/o/r/issues/557")
        let text = CLIText.render(taskDetail: detail)
        XCTAssertTrue(text.contains("Root-cause it"))
        XCTAssertTrue(text.contains("#553"))
        XCTAssertTrue(text.contains("no version"))
    }
}
#endif
