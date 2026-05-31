import XCTest
@testable import AppFeedback

final class ReleaseNotificationServiceTests: XCTestCase {
    func testChoosesMostRecentThreadFeedback() {
        let threads: [Int: Date] = [12: Date(timeIntervalSince1970: 100), 15: Date(timeIntervalSince1970: 200)]
        let chosen = ReleaseNotificationService.chooseFeedbackNumber(
            candidates: [12, 15], lastActivityByFeedback: threads)
        XCTAssertEqual(chosen, 15)
    }

    func testFallsBackToLowestWhenNoThreads() {
        let chosen = ReleaseNotificationService.chooseFeedbackNumber(candidates: [20, 12, 15], lastActivityByFeedback: [:])
        XCTAssertEqual(chosen, 12)
    }
}
