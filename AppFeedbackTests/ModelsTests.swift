import XCTest
@testable import AppFeedback

final class ModelsTests: XCTestCase {

    func test_repoConfig_roundTrips_codable() throws {
        let repo = RepoConfig(displayName: "My App", owner: "acme", repo: "feedback")
        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: data)
        XCTAssertEqual(decoded.displayName, "My App")
        XCTAssertEqual(decoded.owner, "acme")
        XCTAssertEqual(decoded.repo, "feedback")
        XCTAssertEqual(decoded.id, repo.id)
    }

    func test_sidebarSelection_equality() {
        let id = UUID()
        XCTAssertEqual(SidebarSelection.allIssues(repoId: id), SidebarSelection.allIssues(repoId: id))
        XCTAssertNotEqual(SidebarSelection.allIssues(repoId: id), SidebarSelection.allIssues(repoId: UUID()))
    }

    func testSidebarSelectionExposesRepoID() {
        let id = UUID()
        let sel = SidebarSelection.allIssues(repoId: id)
        XCTAssertEqual(sel.repoId, id)
    }

    func test_feedbackIssue_id_equalsNumber() {
        let issue = FeedbackIssue(
            number: 42, title: "Test", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil,
            email: nil, description: "", labels: []
        )
        XCTAssertEqual(issue.id, 42)
    }

    func testProjectVersionDefaultsAndDerivedState() {
        let v = ProjectVersion(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "notes")
        XCTAssertFalse(v.releasePublished)
        XCTAssertNil(v.milestoneNumber)
        XCTAssertEqual(v.derivedState(anyTaskStarted: false), .new)
        XCTAssertEqual(v.derivedState(anyTaskStarted: true), .wip)
        v.releasePublished = true
        XCTAssertEqual(v.derivedState(anyTaskStarted: true), .released)
    }
}
