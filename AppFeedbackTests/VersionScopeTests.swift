import XCTest
@testable import AppFeedback

final class VersionScopeTests: XCTestCase {
    private func roundTrip(_ scope: VersionScope) throws -> VersionScope {
        let data = try JSONEncoder().encode(scope)
        return try JSONDecoder().decode(VersionScope.self, from: data)
    }

    func test_roundTrip_any() throws {
        XCTAssertEqual(try roundTrip(.any), .any)
    }

    func test_roundTrip_state() throws {
        XCTAssertEqual(try roundTrip(.state(.released)), .state(.released))
    }

    func test_roundTrip_versions() throws {
        XCTAssertEqual(try roundTrip(.versions(["1.0", "2.0"])), .versions(["1.0", "2.0"]))
    }
}
