import XCTest
@testable import AppFeedback

final class GitHubMilestoneReleaseClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    func testCreateMilestoneReturnsNumberAndTitle() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/o/r/milestones")
            XCTAssertEqual(req.httpMethod, "POST")
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"number":5,"title":"1.2.0","state":"open","description":"notes"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let ms = try await client.createMilestone(owner: "o", repo: "r", title: "1.2.0", description: "notes", token: "t")
        XCTAssertEqual(ms.number, 5)
        XCTAssertEqual(ms.title, "1.2.0")
        XCTAssertEqual(ms.state, "open")
    }

    func testListMilestonesParsesArray() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             #"[{"number":1,"title":"1.0","state":"closed","description":""},{"number":2,"title":"1.1","state":"open","description":"x"}]"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let all = try await client.listMilestones(owner: "o", repo: "r", token: "t")
        XCTAssertEqual(all.map(\.number), [1, 2])
    }

    /// `VersionService.rename` disambiguates a milestone-PATCH 404 (deleted milestone vs. a repo
    /// the token can no longer see) by re-querying this list — pin that a repo-invisible 404
    /// surfaces here too, rather than being swallowed into an empty array, since that's what makes
    /// the disambiguation trustworthy.
    func testListMilestonesSurfaces404WhenRepoIsInvisible() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             #"{"message":"Not Found"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        do {
            _ = try await client.listMilestones(owner: "o", repo: "r", token: "t")
            XCTFail("expected a 404 to throw")
        } catch let GitHubMilestoneReleaseClient.ClientError.apiError(code, _) {
            XCTAssertEqual(code, 404)
        }
    }

    func testCreateReleaseDraftThenPublishFlags() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                capturedBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                    #"{"id":900,"tag_name":"v1.2.0","draft":false}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let rel = try await client.createRelease(owner: "o", repo: "r", tag: "v1.2.0",
            name: "1.2.0", body: "notes", draft: false, target: "main", token: "t")
        XCTAssertEqual(rel.id, 900)
        XCTAssertEqual(capturedBody?["tag_name"] as? String, "v1.2.0")
        XCTAssertEqual(capturedBody?["draft"] as? Bool, false)
    }

    func testUpdateMilestoneSendsTitleInPatchBody() async throws {
        var capturedBody: [String: Any]?
        var capturedMethod: String?
        var capturedURL: String?
        MockURLProtocol.requestHandler = { req in
            capturedMethod = req.httpMethod
            capturedURL = req.url?.absoluteString
            if let stream = req.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                capturedBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            } else if let d = req.httpBody { capturedBody = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"number":5,"title":"1.3.0","state":"open","description":"notes"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        let ms = try await client.updateMilestone(owner: "o", repo: "r", number: 5, title: "1.3.0", token: "t")

        XCTAssertEqual(capturedMethod, "PATCH")
        XCTAssertEqual(capturedURL, "https://api.github.com/repos/o/r/milestones/5")
        XCTAssertEqual(capturedBody?["title"] as? String, "1.3.0")
        // A rename must not blank the changelog: the description key is absent, not empty.
        XCTAssertNil(capturedBody?["description"])
        XCTAssertEqual(ms.title, "1.3.0")
    }

    /// GitHub 422s on a duplicate milestone title — the backstop behind the local uniqueness check.
    func testUpdateMilestoneSurfacesDuplicateTitleError() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
             #"{"message":"Validation Failed"}"#.data(using: .utf8)!)
        }
        let client = GitHubMilestoneReleaseClient(session: .mock)
        do {
            _ = try await client.updateMilestone(owner: "o", repo: "r", number: 5, title: "1.3.0", token: "t")
            XCTFail("expected a 422 to throw")
        } catch let GitHubMilestoneReleaseClient.ClientError.apiError(code, _) {
            XCTAssertEqual(code, 422)
        }
    }
}
