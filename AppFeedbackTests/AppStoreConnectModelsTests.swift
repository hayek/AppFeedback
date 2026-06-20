import XCTest
@testable import AppFeedback

final class AppStoreConnectModelsTests: XCTestCase {
    func testAppStoreConnectErrorStatusCodeMapping() {
        XCTAssertEqual(AppStoreConnectError.authFailed.statusCode, 401)
        XCTAssertEqual(AppStoreConnectError.forbidden.statusCode, 403)
        XCTAssertEqual(AppStoreConnectError.rateLimited.statusCode, 429)
        XCTAssertEqual(AppStoreConnectError.http(500).statusCode, 500)
        XCTAssertEqual(AppStoreConnectError.http(409).statusCode, 409)
        XCTAssertEqual(AppStoreConnectError.decoding("x").statusCode, 0)
        XCTAssertEqual(AppStoreConnectError.badKey("x").statusCode, 0)
    }

    func testErrorIsStatusCarrying() {
        // The seam Phase 4 branches on: a 403 must be detectable through the protocol.
        let err: any StatusCarryingError = AppStoreConnectError.forbidden
        XCTAssertEqual(err.statusCode, 403)
    }
}
