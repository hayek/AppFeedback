import XCTest
@testable import AppFeedback

@MainActor
final class ActivityLogTests: XCTestCase {

    private func makeLog() -> ActivityLog {
        ActivityLog(persistenceURL: nil)
    }

    func test_start_appendsInProgressEntry() {
        let log = makeLog()
        let id = log.start(kind: .sendEmail, title: "to alice@example.com")

        XCTAssertEqual(log.entries.count, 1)
        let entry = log.entries[0]
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.kind, .sendEmail)
        XCTAssertEqual(entry.title, "to alice@example.com")
        XCTAssertEqual(entry.status, .inProgress)
        XCTAssertNil(entry.detail)
    }

    func test_finish_updatesStatusAndDetail() {
        let log = makeLog()
        let id = log.start(kind: .sendEmail, title: "to alice@example.com")
        log.finish(id, status: .success, detail: nil)

        XCTAssertEqual(log.entries[0].status, .success)
        XCTAssertNil(log.entries[0].detail)
    }

    func test_finish_failureCarriesDetail() {
        let log = makeLog()
        let id = log.start(kind: .fetchIssues, title: "owner/repo")
        log.finish(id, status: .failure, detail: "Server returned 503")

        XCTAssertEqual(log.entries[0].status, .failure)
        XCTAssertEqual(log.entries[0].detail, "Server returned 503")
    }

    func test_entries_orderedNewestFirst() {
        let log = makeLog()
        _ = log.start(kind: .fetchIssues, title: "first")
        _ = log.start(kind: .fetchIssues, title: "second")

        XCTAssertEqual(log.entries.first?.title, "second")
        XCTAssertEqual(log.entries.last?.title, "first")
    }

    func test_capEnforced_oldestDropped() {
        let log = ActivityLog(persistenceURL: nil, cap: 3)
        for i in 1...5 {
            _ = log.start(kind: .fetchIssues, title: "n=\(i)")
        }

        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.map(\.title), ["n=5", "n=4", "n=3"])
    }

    func test_clearAll_emptiesEntries() {
        let log = makeLog()
        _ = log.start(kind: .sendEmail, title: "a")
        _ = log.start(kind: .sendEmail, title: "b")
        log.clearAll()

        XCTAssertTrue(log.entries.isEmpty)
    }
}
