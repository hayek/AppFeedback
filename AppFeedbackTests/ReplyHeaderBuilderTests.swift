import XCTest
@testable import AppFeedback

final class ReplyHeaderBuilderTests: XCTestCase {

    func test_noParent_returnsNil() {
        let out = ReplyHeaderBuilder.build(parent: nil, newMessageID: "<n@x>")
        XCTAssertNil(out)
    }

    func test_parentWithoutReferences_setsInReplyToAndReferences() {
        let parent = MailMessageHeaders(messageID: "<p@x>", inReplyTo: nil, references: [])
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertEqual(out?.inReplyTo, "<p@x>")
        XCTAssertEqual(out?.references, ["<p@x>"])
    }

    func test_parentWithChain_appendsToReferences() {
        let parent = MailMessageHeaders(
            messageID: "<p@x>",
            inReplyTo: "<root@x>",
            references: ["<root@x>", "<mid@x>"]
        )
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertEqual(out?.inReplyTo, "<p@x>")
        XCTAssertEqual(out?.references, ["<root@x>", "<mid@x>", "<p@x>"])
    }

    func test_parentWithSyntheticID_skipsInReplyToAndDoesNotAppend() {
        let parent = MailMessageHeaders(
            messageID: "<uid-1.1@imap-synthetic>",
            inReplyTo: nil,
            references: ["<root@x>"]
        )
        let out = ReplyHeaderBuilder.build(parent: parent, newMessageID: "<n@x>")
        XCTAssertNil(out?.inReplyTo)
        XCTAssertEqual(out?.references, ["<root@x>"])
    }
}
