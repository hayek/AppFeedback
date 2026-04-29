import XCTest
@testable import AppFeedback

final class IMAPSyntheticIDTests: XCTestCase {

    // MARK: - synthesize format

    func test_synthesize_producesExpectedFormat() {
        let id = MessageIDGenerator.synthesize(uid: 42, uidValidity: 7)
        XCTAssertEqual(id, "<uid-42.7@imap-synthetic>")
    }

    func test_synthesize_zeroUID() {
        let id = MessageIDGenerator.synthesize(uid: 0, uidValidity: 0)
        XCTAssertEqual(id, "<uid-0.0@imap-synthetic>")
    }

    func test_synthesize_largeValues() {
        let id = MessageIDGenerator.synthesize(uid: UInt32.max, uidValidity: UInt32.max)
        XCTAssertEqual(id, "<uid-4294967295.4294967295@imap-synthetic>")
    }

    // MARK: - isSynthetic round-trip

    func test_isSynthetic_trueForSynthesizedID() {
        let id = MessageIDGenerator.synthesize(uid: 12345, uidValidity: 42)
        XCTAssertTrue(MessageIDGenerator.isSynthetic(id))
    }

    func test_isSynthetic_trueForManualFormat() {
        XCTAssertTrue(MessageIDGenerator.isSynthetic("<uid-12345.42@imap-synthetic>"))
    }

    func test_isSynthetic_falseForRegularID() {
        let regular = MessageIDGenerator.generate()
        XCTAssertFalse(MessageIDGenerator.isSynthetic(regular))
    }

    func test_isSynthetic_falseForArbitraryID() {
        XCTAssertFalse(MessageIDGenerator.isSynthetic("<abc@example.com>"))
        XCTAssertFalse(MessageIDGenerator.isSynthetic("<foo@imap-not-synthetic>"))
    }

    // MARK: - uniqueness

    func test_synthesize_differentUIDsProduceDifferentIDs() {
        let a = MessageIDGenerator.synthesize(uid: 1, uidValidity: 100)
        let b = MessageIDGenerator.synthesize(uid: 2, uidValidity: 100)
        XCTAssertNotEqual(a, b)
    }

    func test_synthesize_differentUIDValiditiesProduceDifferentIDs() {
        let a = MessageIDGenerator.synthesize(uid: 1, uidValidity: 100)
        let b = MessageIDGenerator.synthesize(uid: 1, uidValidity: 200)
        XCTAssertNotEqual(a, b)
    }

    func test_synthesize_isDeterministic() {
        let first = MessageIDGenerator.synthesize(uid: 99, uidValidity: 5)
        let second = MessageIDGenerator.synthesize(uid: 99, uidValidity: 5)
        XCTAssertEqual(first, second)
    }
}
