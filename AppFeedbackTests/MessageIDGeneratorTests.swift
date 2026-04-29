import XCTest
@testable import AppFeedback

final class MessageIDGeneratorTests: XCTestCase {

    func test_generate_returnsAngleWrappedRFC5322Form() {
        let id = MessageIDGenerator.generate()
        XCTAssertTrue(id.hasPrefix("<"))
        XCTAssertTrue(id.hasSuffix("@app-feedback.local>"))
    }

    func test_generate_returnsUniqueIDs() {
        let ids = (0..<1000).map { _ in MessageIDGenerator.generate() }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func test_isSynthetic_detectsSyntheticIDs() {
        XCTAssertTrue(MessageIDGenerator.isSynthetic("<uid-12345.42@imap-synthetic>"))
        XCTAssertFalse(MessageIDGenerator.isSynthetic(MessageIDGenerator.generate()))
        XCTAssertFalse(MessageIDGenerator.isSynthetic("<abc@example.com>"))
    }
}
