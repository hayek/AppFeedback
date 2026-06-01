import XCTest
import SwiftMail
@testable import AppFeedback

/// Unit tests for `IMAPClient.classifyAttachments(in:)`.
///
/// `MessagePart` is a public struct with a public `sectionString:` initialiser, so synthetic
/// parts can be constructed directly — no protocol/fake-struct indirection is needed.
///
/// Test path chosen: **direct instantiation** of SwiftMail value types.
final class IMAPClientInlineImageTests: XCTestCase {

    // MARK: - 1. Inline image with Content-ID + image/png is captured with contentID set

    func test_classifyAttachments_inlineImageWithContentID_isCaptured() {
        let part = MessagePart(
            sectionString: "1.2",
            contentType: "image/png",
            disposition: "inline",
            filename: nil,
            contentId: "abc123@mail.example.com"
        )

        let result = IMAPClient.classifyAttachments(in: [part])

        XCTAssertEqual(result.count, 1, "Inline image with Content-ID should be captured")
        XCTAssertEqual(result[0].contentID, "abc123@mail.example.com")
        XCTAssertEqual(result[0].partID, "1.2")
        XCTAssertEqual(result[0].mimeType, "image/png")
    }

    // MARK: - 2. Inline non-image (text/html, no Content-ID) is still excluded

    func test_classifyAttachments_inlineHTMLWithoutContentID_isExcluded() {
        let part = MessagePart(
            sectionString: "1",
            contentType: "text/html; charset=utf-8",
            disposition: "inline",
            filename: nil,
            contentId: nil
        )

        let result = IMAPClient.classifyAttachments(in: [part])

        XCTAssertTrue(result.isEmpty, "Inline text/html without Content-ID should be excluded")
    }

    // MARK: - 3. Explicit attachment still passes through unchanged

    func test_classifyAttachments_explicitAttachment_isIncluded() {
        let part = MessagePart(
            sectionString: "1.3",
            contentType: "application/pdf",
            disposition: "attachment",
            filename: "report.pdf",
            contentId: nil
        )

        let result = IMAPClient.classifyAttachments(in: [part])

        XCTAssertEqual(result.count, 1, "Explicit attachment should be included")
        XCTAssertEqual(result[0].filename, "report.pdf")
        XCTAssertNil(result[0].contentID)
    }

    // MARK: - 4. Empty Content-ID is treated as nil (defensive symmetry)

    func test_classifyAttachments_inlineImageWithEmptyContentID_isExcluded() {
        let part = MessagePart(
            sectionString: "1.4",
            contentType: "image/jpeg",
            disposition: "inline",
            filename: nil,
            contentId: ""
        )

        let result = IMAPClient.classifyAttachments(in: [part])

        // An empty contentId is treated as nil, so isInlineImage is false.
        // Without a filename or explicit attachment disposition, the part is excluded.
        XCTAssertTrue(result.isEmpty, "Inline image with empty Content-ID should be excluded")
    }

    // MARK: - 5. Mixed structure: only qualifying parts are returned

    func test_classifyAttachments_mixedStructure_returnsOnlyQualifyingParts() {
        let htmlBody = MessagePart(
            sectionString: "1",
            contentType: "text/html; charset=utf-8",
            disposition: "inline",
            filename: nil,
            contentId: nil
        )
        let inlineImage = MessagePart(
            sectionString: "2",
            contentType: "image/gif",
            disposition: "inline",
            filename: nil,
            contentId: "logo@company.com"
        )
        let pdfAttachment = MessagePart(
            sectionString: "3",
            contentType: "application/pdf",
            disposition: "attachment",
            filename: "doc.pdf",
            contentId: nil
        )

        let result = IMAPClient.classifyAttachments(in: [htmlBody, inlineImage, pdfAttachment])

        XCTAssertEqual(result.count, 2, "Should capture inline image and explicit attachment only")

        let partIDs = result.map(\.partID).sorted()
        XCTAssertEqual(partIDs, ["2", "3"])

        let imageResult = result.first { $0.partID == "2" }
        XCTAssertEqual(imageResult?.contentID, "logo@company.com")

        let pdfResult = result.first { $0.partID == "3" }
        XCTAssertNil(pdfResult?.contentID)
    }

    // MARK: - 6. Outlook HTML body (Content-ID + name, no inline disposition) is NOT an attachment

    /// Regression: Outlook/Exchange stamps the HTML body part with a Content-ID and a `name` and
    /// omits an "inline" disposition. That tripped `hasFileNotInline`, so the message body was
    /// surfaced as a bogus attachment chip labeled with its Content-ID. The body must be excluded.
    func test_classifyAttachments_outlookHTMLBodyWithNameAndContentID_isExcluded() {
        let outlookBody = MessagePart(
            sectionString: "1",
            contentType: "text/html; charset=utf-8",
            disposition: nil,
            filename: "8917BA14ADC8EE4A8D12CCECFC9D43C0@SWEP280.PROD.OUTLOOK.COM",
            contentId: "8917BA14ADC8EE4A8D12CCECFC9D43C0@SWEP280.PROD.OUTLOOK.COM"
        )
        let plainBody = MessagePart(
            sectionString: "2",
            contentType: "text/plain; charset=utf-8",
            disposition: nil,
            filename: "body.txt",
            contentId: nil
        )

        let result = IMAPClient.classifyAttachments(in: [outlookBody, plainBody])
        XCTAssertTrue(result.isEmpty, "Text body parts must never be classified as attachments")
    }

    // MARK: - 7. A genuinely attached .html file (disposition: attachment) is still included

    func test_classifyAttachments_explicitHTMLAttachment_isStillIncluded() {
        let attached = MessagePart(
            sectionString: "2",
            contentType: "text/html",
            disposition: "attachment",
            filename: "page.html",
            contentId: nil
        )

        let result = IMAPClient.classifyAttachments(in: [attached])
        XCTAssertEqual(result.count, 1, "An explicitly attached .html file is a real attachment")
        XCTAssertEqual(result[0].filename, "page.html")
    }
}
