import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class IssueLoaderTests: XCTestCase {
    private let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        let schema = Schema([CachedIssue.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    private func makeLoader() -> IssueLoader {
        IssueLoader(config: repo, session: .mock, cacheContext: context)
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
        let loader = makeLoader()
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
        let loader = makeLoader()
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
        let loader = makeLoader()
        await loader.load(token: "tok")
        guard case .failed = loader.state else {
            return XCTFail("Expected .failed")
        }
    }

    func test_load_preservesCachedData_onNetworkError() async {
        let firstData = makeIssuesJSON(count: 2)
        MockURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, firstData)
        }
        let loader = makeLoader()
        await loader.load(token: "tok")
        guard case .loaded(let cached, _) = loader.state else {
            return XCTFail("Expected .loaded after first fetch")
        }
        XCTAssertEqual(cached.count, 2)

        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await loader.load(token: "tok")
        guard case .loaded(let preserved, _) = loader.state else {
            return XCTFail("Expected .loaded (stale cache) after failed refresh")
        }
        XCTAssertEqual(preserved.count, 2)
    }

    func test_load_persistsToSwiftDataCache_andReloadsOnSecondLoaderInit() async throws {
        let data = makeIssuesJSON(count: 2)
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        await makeLoader().load(token: "tok")

        // New loader, same context — should hydrate from cache before any network.
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let second = makeLoader()
        await second.load(token: "tok")
        guard case .loaded(let issues, _) = second.state else {
            return XCTFail("Expected .loaded from cache")
        }
        XCTAssertEqual(issues.count, 2)
    }
}
