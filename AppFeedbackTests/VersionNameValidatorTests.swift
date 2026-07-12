import XCTest
@testable import AppFeedback

@MainActor
final class VersionNameValidatorTests: XCTestCase {
    private func version(_ name: String) -> ProjectVersion {
        ProjectVersion(repoOwner: "o", repoName: "r", name: name)
    }

    func testTrimsWhitespace() throws {
        let name = try VersionNameValidator.validate("  1.2.0 ", existing: [])
        XCTAssertEqual(name, "1.2.0")
    }

    func testRejectsEmptyAndWhitespaceOnly() {
        XCTAssertThrowsError(try VersionNameValidator.validate("", existing: [])) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .empty)
        }
        XCTAssertThrowsError(try VersionNameValidator.validate("   ", existing: [])) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .empty)
        }
    }

    func testRejectsDuplicateCaseInsensitively() {
        let existing = [version("1.2.0"), version("2.0-Beta")]
        XCTAssertThrowsError(try VersionNameValidator.validate("2.0-BETA", existing: existing)) {
            XCTAssertEqual($0 as? VersionNameValidator.Failure, .duplicate("2.0-BETA"))
        }
    }

    /// The version being renamed must not collide with itself — re-applying its own name is a no-op,
    /// not a duplicate.
    func testRenamingVersionDoesNotCollideWithItself() throws {
        let subject = version("1.2.0")
        let name = try VersionNameValidator.validate("1.2.0", existing: [subject], renaming: subject)
        XCTAssertEqual(name, "1.2.0")
    }

    func testRenamingStillRejectsAnotherVersionsName() {
        let subject = version("1.2.0")
        let other = version("1.3.0")
        XCTAssertThrowsError(
            try VersionNameValidator.validate("1.3.0", existing: [subject, other], renaming: subject))
    }
}
