import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class AppStoreReviewMirrorStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
        return ModelContext(container)
    }

    func testUpsertCreatesThenUpdatesSameRow() throws {
        let store = AppStoreReviewMirrorStore(context: try makeContext())
        let pid = UUID()
        let v0 = store.version
        let m1 = store.upsert(reviewId: "R1", productID: pid, issueNumber: 42, contentHash: "h1")
        XCTAssertEqual(m1.issueNumber, 42)
        XCTAssertGreaterThan(store.version, v0)
        let m2 = store.upsert(reviewId: "R1", productID: pid, issueNumber: 42, contentHash: "h2")
        XCTAssertEqual(m2.contentHash, "h2")
        XCTAssertEqual(store.allFor(productID: pid).count, 1, "upsert keys on (reviewId, productID)")
    }

    func testMirrorLookupByReviewIdIsGloballyUnique() throws {
        // reviewId is globally unique in ASC: mirror(reviewId:) takes no productID.
        let store = AppStoreReviewMirrorStore(context: try makeContext())
        let pidA = UUID(); let pidB = UUID()
        _ = store.upsert(reviewId: "R1", productID: pidA, issueNumber: 1, contentHash: "a")
        _ = store.upsert(reviewId: "R2", productID: pidB, issueNumber: 2, contentHash: "b")
        XCTAssertEqual(store.mirror(reviewId: "R1")?.issueNumber, 1)
        XCTAssertEqual(store.mirror(reviewId: "R2")?.issueNumber, 2)
        XCTAssertEqual(store.allFor(productID: pidA).count, 1)
        XCTAssertEqual(store.mirror(productID: pidA, issueNumber: 1)?.reviewId, "R1")
        XCTAssertNil(store.mirror(productID: pidA, issueNumber: 999))
    }

    func testSetResponseClearResponseAndDeleteByIssue() throws {
        let store = AppStoreReviewMirrorStore(context: try makeContext())
        let pid = UUID()
        _ = store.upsert(reviewId: "R1", productID: pid, issueNumber: 7, contentHash: "h")
        store.setResponse(reviewId: "R1", responseId: "RESP1", state: "PENDING_PUBLISH")
        XCTAssertEqual(store.mirror(reviewId: "R1")?.responseState, "PENDING_PUBLISH")
        XCTAssertEqual(store.mirror(reviewId: "R1")?.responseId, "RESP1")
        store.clearResponse(reviewId: "R1")
        XCTAssertNil(store.mirror(reviewId: "R1")?.responseState)
        XCTAssertNil(store.mirror(reviewId: "R1")?.responseId)
        store.deleteByIssue(productID: pid, issueNumber: 7)
        XCTAssertNil(store.mirror(reviewId: "R1"))
    }

    func testDeleteByIssueRemovesOnlyTheTargetedRow() throws {
        // Two rows for the same reviewId (cross-device dupes after CloudKit sync, issues 42 & 43).
        let store = AppStoreReviewMirrorStore(context: try makeContext())
        let pid = UUID()
        _ = store.upsert(reviewId: "DUP", productID: pid, issueNumber: 42, contentHash: "h")
        // Insert a SECOND row with the same reviewId via the model directly (upsert would update #42).
        store.insertRawForTest(reviewId: "DUP", productID: pid, issueNumber: 43, contentHash: "h")
        XCTAssertEqual(store.allFor(productID: pid).count, 2)
        store.deleteByIssue(productID: pid, issueNumber: 43)
        let rows = store.allFor(productID: pid)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.issueNumber, 42, "kept row (lowest issue) survives")
    }
}
