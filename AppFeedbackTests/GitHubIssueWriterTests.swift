import XCTest
@testable import AppFeedback

final class GitHubIssueWriterTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testCreateIssuePostsLabelsAndBodyAndReturnsNumber() async throws {
        var captured: URLRequest?
        var capturedBody: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            captured = req
            if let stream = req.httpBodyStream { capturedBody = Self.readJSON(stream) }
            else if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, #"{"number":42}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        let number = try await writer.createIssue(
            owner: "o", repo: "r", title: "Fix bug",
            body: "details", labels: [AppFeedbackLabels.task, "status:todo", "priority:med"],
            milestoneNumber: 3, token: "tok"
        )
        XCTAssertEqual(number, 42)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.github.com/repos/o/r/issues")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(capturedBody?["title"] as? String, "Fix bug")
        XCTAssertEqual(capturedBody?["milestone"] as? Int, 3)
        XCTAssertEqual((capturedBody?["labels"] as? [String])?.contains(AppFeedbackLabels.task), true)
    }

    func testApiErrorThrows() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
             #"{"message":"Validation failed"}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        do {
            _ = try await writer.createIssue(owner: "o", repo: "r", title: "t", body: "b", labels: [], milestoneNumber: nil, token: "x")
            XCTFail("expected throw")
        } catch { /* expected */ }
    }

    func testIsNotFoundDetectsDeletedIssue() {
        // REST 404
        XCTAssertTrue(GitHubIssueWriter.WriteError.apiError(404, message: "Not Found").isNotFound)
        // GraphQL "could not resolve" (deleteIssue id lookup on a deleted issue) — code 0
        XCTAssertTrue(GitHubIssueWriter.WriteError.apiError(0, message: "Could not resolve to an Issue with the number of 386.").isNotFound)
        // Unrelated failures are not treated as not-found
        XCTAssertFalse(GitHubIssueWriter.WriteError.apiError(422, message: "Validation failed").isNotFound)
        XCTAssertFalse(GitHubIssueWriter.WriteError.apiError(403, message: "rate limit").isNotFound)
        XCTAssertFalse(GitHubIssueWriter.WriteError.apiError(500, message: nil).isNotFound)
    }

    private static func readJSON(_ stream: InputStream) -> [String: Any]? {
        stream.open(); defer { stream.close() }
        var data = Data(); let size = 4096; var buf = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: size); if n > 0 { data.append(buf, count: n) } else { break } }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - milestoneNumber: Int?? contract (updateIssue's PATCH body)
    //
    // These pin the writer's existing (correct) behavior: the OUTER optional decides whether the
    // "milestone" key appears in the PATCH at all, and the INNER optional decides what it says.
    // `nil` (outer)      -> key omitted entirely -> GitHub leaves the milestone untouched.
    // `.some(nil)`       -> key present as NSNull -> GitHub clears the milestone.
    // `.some(n)`         -> key present as the number -> GitHub sets the milestone.
    // TaskService/TaskDetailView must preserve this distinction rather than collapsing an
    // unresolvable version into `.some(nil)`, which would silently clear a task's milestone.

    private func capturedPatchBody(milestoneNumber: Int??) async throws -> [String: Any]? {
        var captured: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if let stream = req.httpBodyStream { captured = Self.readJSON(stream) }
            else if let d = req.httpBody { captured = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"number":1}"#.data(using: .utf8)!)
        }
        let writer = GitHubIssueWriter(session: .mock)
        try await writer.updateIssue(owner: "o", repo: "r", number: 1, title: "t",
                                     milestoneNumber: milestoneNumber, token: "tok")
        return captured
    }

    /// `nil` (the outer optional) means "say nothing about the milestone" — the key must be absent,
    /// so GitHub leaves the task's existing milestone alone.
    func testOuterNilOmitsTheMilestoneKeyEntirely() async throws {
        let body = try await capturedPatchBody(milestoneNumber: nil)
        XCTAssertFalse(body?.keys.contains("milestone") ?? true,
                       "an unresolvable version must not touch the milestone")
    }

    /// `.some(nil)` is the explicit "None" choice — that, and only that, clears the milestone.
    func testSomeNilClearsTheMilestone() async throws {
        let body = try await capturedPatchBody(milestoneNumber: .some(nil))
        XCTAssertTrue(body?["milestone"] is NSNull)
    }

    func testSomeNumberSetsTheMilestone() async throws {
        let body = try await capturedPatchBody(milestoneNumber: .some(7))
        XCTAssertEqual(body?["milestone"] as? Int, 7)
    }
}
