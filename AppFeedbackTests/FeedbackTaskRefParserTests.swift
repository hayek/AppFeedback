import XCTest
@testable import AppFeedback

final class FeedbackTaskRefParserTests: XCTestCase {
    func testParseEmptyWhenNoBlock() {
        XCTAssertEqual(FeedbackTaskRefParser.parse("Some task body, no refs."), [])
    }

    func testParseExtractsNumbersDeduplicatedSorted() {
        let body = """
        Fix the thing.

        <!-- appfeedback:addresses -->
        Addresses: #15, #12, #12, #20
        <!-- /appfeedback:addresses -->
        """
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 15, 20])
    }

    func testFormatInsertsBlockWhenAbsent() {
        let out = FeedbackTaskRefParser.upsert(into: "Body text.", refs: [20, 12])
        XCTAssertEqual(FeedbackTaskRefParser.parse(out), [12, 20])
        XCTAssertTrue(out.contains("Addresses: #12, #20"))
    }

    func testUpsertReplacesExistingBlockAndPreservesProse() {
        let original = FeedbackTaskRefParser.upsert(into: "Hello.", refs: [1])
        let updated = FeedbackTaskRefParser.upsert(into: original, refs: [1, 2])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [1, 2])
        XCTAssertTrue(updated.hasPrefix("Hello."))
        // Exactly one block.
        XCTAssertEqual(updated.components(separatedBy: "appfeedback:addresses").count - 1, 2)
    }

    func testUpsertEmptyRefsRemovesBlock() {
        let withBlock = FeedbackTaskRefParser.upsert(into: "X", refs: [1])
        let cleared = FeedbackTaskRefParser.upsert(into: withBlock, refs: [])
        XCTAssertFalse(cleared.contains("appfeedback:addresses"))
        XCTAssertEqual(FeedbackTaskRefParser.parse(cleared), [])
    }
}
