import XCTest
@testable import AppFeedback

@MainActor
final class CloudSyncStatusTests: XCTestCase {
    func test_stub_reportsConfiguredState() {
        let stub = StubCloudSyncStatus(state: .syncing)
        XCTAssertEqual(stub.state, .syncing)
    }

    func test_unavailableReasonsAreEquatable() {
        XCTAssertEqual(
            SyncState.unavailable(reason: .notSignedIn),
            SyncState.unavailable(reason: .notSignedIn)
        )
        XCTAssertNotEqual(
            SyncState.unavailable(reason: .notSignedIn),
            SyncState.unavailable(reason: .restricted)
        )
    }
}

@MainActor
final class StubCloudSyncStatus: CloudSyncStatusProviding {
    var state: SyncState
    init(state: SyncState) { self.state = state }
}
