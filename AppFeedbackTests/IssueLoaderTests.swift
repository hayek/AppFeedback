import XCTest
@testable import AppFeedback

@MainActor
final class IssueLoaderTests: XCTestCase {
    private let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("AppFeedback")
            .appendingPathComponent("\(repo.owner)-\(repo.repo).json")
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        try? FileManager.default.removeItem(at: cacheURL)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func makeIssuesJSON(count: Int) -> Data {
        let items = (1...count).map { n -> String in
            """
            {
              "number": \(n),
              "title": "Issue \(n)",
              "body": "Description\\n\\n---\\n**Device Information:**\\nApp: TestApp\\nApp Version: 1.0 (1)\\nDevice: Mac\\nmacOS Version: 14.0",
              "created_at": "2024-01-01T10:00:00Z"
            }
            """
        }
        return ("[\(items.joined(separator: ","))]").data(using: .utf8)!
    }

    func test_load_parsesIssues() async {
        let data = makeIssuesJSON(count: 3)
        MockURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, data)
        }
        let loader = IssueLoader(config: repo, session: .mock)
        await loader.load(token: "tok")
        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded")
        }
        XCTAssertEqual(issues.count, 3)
    }

    func test_load_filtersPullRequests() async {
        let body = """
        [{"number":1,"title":"PR","body":null,"created_at":"2024-01-01T10:00:00Z","pull_request":{}}]
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let loader = IssueLoader(config: repo, session: .mock)
        await loader.load(token: "tok")
        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded")
        }
        XCTAssertTrue(issues.isEmpty)
    }

    func test_load_setsFailedState_onAPIError() async {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let loader = IssueLoader(config: repo, session: .mock)
        await loader.load(token: "tok")
        guard case .failed = loader.state else {
            return XCTFail("Expected .failed")
        }
    }

    func test_load_preservesCachedData_onNetworkError() async {
        // First load succeeds and populates cache
        MockURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, self.makeIssuesJSON(count: 2))
        }
        let loader = IssueLoader(config: repo, session: .mock)
        await loader.load(token: "tok")
        guard case .loaded(let cached, _) = loader.state else {
            return XCTFail("Expected .loaded after first fetch")
        }
        XCTAssertEqual(cached.count, 2)

        // Second load fails — cached data should be preserved
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await loader.load(token: "tok")
        guard case .loaded(let preserved, _) = loader.state else {
            return XCTFail("Expected .loaded (stale cache) after failed refresh")
        }
        XCTAssertEqual(preserved.count, 2)
    }
}
