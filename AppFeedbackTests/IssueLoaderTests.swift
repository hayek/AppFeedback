import XCTest
import SwiftData
import os
@testable import AppFeedback

@MainActor
final class IssueLoaderTests: XCTestCase {
    private let repo = ProductConfig(displayName: "Test", owner: "org", repo: "feedback")
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        let schema = Schema([CachedIssue.self, RepoFetchState.self])
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

    // MARK: - GraphQL response helpers

    /// Builds a GraphQL JSON response shaped like `{ "data": { "repository": { "issues": ... } } }`.
    private func makeGraphQLResponse(
        issues: [(number: Int, title: String, body: String, state: String)],
        hasNextPage: Bool = false,
        endCursor: String? = nil
    ) -> Data {
        let nodesJSON = issues.map { issue -> [String: Any] in
            [
                "number": issue.number,
                "title": issue.title,
                "body": issue.body,
                "createdAt": "2024-01-01T10:00:00Z",
                "updatedAt": "2024-01-01T10:00:00Z",
                "state": issue.state,
                "labels": ["nodes": [] as [Any]],
            ]
        }
        let body: [String: Any] = [
            "data": [
                "repository": [
                    "issues": [
                        "pageInfo": [
                            "hasNextPage": hasNextPage,
                            "endCursor": endCursor as Any,
                        ],
                        "nodes": nodesJSON,
                    ]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static let canonicalIssueBody = "Description\n\n---\n**Device Information:**\nApp: TestApp\nApp Version: 1.0 (1)\nDevice: Mac\nmacOS Version: 14.0"

    // MARK: - Tests

    func test_load_parsesIssues() async {
        let data = makeGraphQLResponse(
            issues: (1...3).map { (number: $0, title: "Issue \($0)", body: Self.canonicalIssueBody, state: "OPEN") }
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let loader = makeLoader()
        await loader.load(token: "tok")
        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded")
        }
        XCTAssertEqual(issues.count, 3)
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
        let firstData = makeGraphQLResponse(
            issues: (1...2).map { (number: $0, title: "Issue \($0)", body: Self.canonicalIssueBody, state: "OPEN") }
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, firstData)
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
        let data = makeGraphQLResponse(
            issues: (1...2).map { (number: $0, title: "Issue \($0)", body: Self.canonicalIssueBody, state: "OPEN") }
        )
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

    func test_translationFields_areNotWipedOnRefresh() async throws {
        // First fetch: full refresh, caches issue #1.
        let firstData = makeGraphQLResponse(
            issues: [(1, "Hola", Self.canonicalIssueBody, "OPEN")]
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, firstData)
        }
        await makeLoader().load(token: "tok")

        // Simulate a translation having been persisted on the cached row.
        let owner = repo.owner
        let name = repo.repo
        let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
            cached.repoOwner == owner && cached.repoName == name && cached.number == 1
        })
        let row = try XCTUnwrap(try context.fetch(descriptor).first)
        row.detectedLanguageCode = "es"
        row.translatedTitle = "Hello"
        row.translatedBody = "Hello world"
        row.translationTargetLanguage = "en"
        try context.save()

        // Second fetch: incremental — same issue updated upstream.
        let secondData = makeGraphQLResponse(
            issues: [(1, "Hola updated", Self.canonicalIssueBody, "OPEN")]
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, secondData)
        }
        await makeLoader().load(token: "tok")

        // Translation fields must survive the upsert.
        let after = try XCTUnwrap(try context.fetch(descriptor).first)
        XCTAssertEqual(after.title, "Hola updated")
        XCTAssertEqual(after.detectedLanguageCode, "es")
        XCTAssertEqual(after.translatedTitle, "Hello")
        XCTAssertEqual(after.translatedBody, "Hello world")
        XCTAssertEqual(after.translationTargetLanguage, "en")
    }

    func test_etagCachedResponse_returnsCachedIssues() async throws {
        // First fetch: full refresh, server returns ETag.
        let firstData = makeGraphQLResponse(
            issues: [(1, "First", Self.canonicalIssueBody, "OPEN")]
        )
        MockURLProtocol.requestHandler = { req in
            let res = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": "\"abc123\""]
            )!
            return (res, firstData)
        }
        await makeLoader().load(token: "tok")

        // Second fetch: server returns 304 — loader must return cached open issues.
        let sentIfNoneMatch = OSAllocatedUnfairLock<String?>(initialState: nil)
        MockURLProtocol.requestHandler = { req in
            sentIfNoneMatch.withLock { $0 = req.value(forHTTPHeaderField: "If-None-Match") }
            let res = HTTPURLResponse(url: req.url!, statusCode: 304, httpVersion: nil, headerFields: nil)!
            return (res, Data())
        }
        let loader = makeLoader()
        await loader.load(token: "tok")

        XCTAssertEqual(sentIfNoneMatch.withLock { $0 }, "\"abc123\"")
        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded after 304")
        }
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.title, "First")
    }

    func test_closedIssue_inIncrementalRefresh_disappearsFromOpenList() async throws {
        // First fetch: cache issue #1 as OPEN.
        let firstData = makeGraphQLResponse(
            issues: [(1, "Open", Self.canonicalIssueBody, "OPEN")]
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, firstData)
        }
        await makeLoader().load(token: "tok")

        // Second fetch (incremental): same issue now CLOSED.
        let secondData = makeGraphQLResponse(
            issues: [(1, "Open", Self.canonicalIssueBody, "CLOSED")]
        )
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, secondData)
        }
        let loader = makeLoader()
        await loader.load(token: "tok")

        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded")
        }
        XCTAssertTrue(issues.isEmpty, "closed issue should be filtered out of the open list")
    }

    func test_pagination_terminatesAndChainsCursor() async throws {
        // Two-page response where the first page advertises hasNextPage: true.
        // Verifies (a) we don't call past hasNextPage: false, and (b) the second
        // request carries the first page's endCursor as `after`.
        let firstPageData = makeGraphQLResponse(
            issues: [(1, "First", Self.canonicalIssueBody, "OPEN")],
            hasNextPage: true,
            endCursor: "cursor-1"
        )
        let secondPageData = makeGraphQLResponse(
            issues: [(2, "Second", Self.canonicalIssueBody, "OPEN")],
            hasNextPage: false,
            endCursor: "cursor-2"
        )
        let requestCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let secondAfter = OSAllocatedUnfairLock<String?>(initialState: nil)
        MockURLProtocol.requestHandler = { req in
            let n = requestCount.withLock { count -> Int in
                count += 1
                return count
            }
            // URLSession moves httpBody onto httpBodyStream before URLProtocol sees the request,
            // so reach for the stream instead of `httpBody` (which is nil here).
            let bodyData: Data? = {
                guard let stream = req.httpBodyStream else { return nil }
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    collected.append(buffer, count: read)
                }
                return collected
            }()
            let parsed = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let variables = parsed?["variables"] as? [String: Any]
            let after = variables?["after"] as? String
            if n == 2 { secondAfter.withLock { $0 = after } }
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (res, n == 1 ? firstPageData : secondPageData)
        }

        let loader = makeLoader()
        await loader.load(token: "tok")

        XCTAssertEqual(requestCount.withLock { $0 }, 2, "must paginate exactly twice")
        XCTAssertEqual(secondAfter.withLock { $0 }, "cursor-1", "second request must use first page's endCursor")
        guard case .loaded(let issues, _) = loader.state else {
            return XCTFail("Expected .loaded")
        }
        XCTAssertEqual(issues.count, 2)
    }

    func testDecodesMilestoneTitle() throws {
        let json = """
        {"data":{"repository":{"issues":{
          "pageInfo":{"hasNextPage":false,"endCursor":null},
          "nodes":[{"number":7,"title":"X","body":"b","createdAt":"2024-01-01T00:00:00Z",
            "updatedAt":"2024-01-01T00:00:00Z","state":"OPEN",
            "milestone":{"title":"1.2.0"},
            "labels":{"nodes":[{"name":"appfeedback:task","color":"5319e7"}]}}]
        }}}}
        """.data(using: .utf8)!
        let result = try IssueLoader.decodePageForTesting(data: json, owner: "o", repo: "r")
        XCTAssertEqual(result.first?.milestoneTitle, "1.2.0")
        XCTAssertTrue(result.first.map(TaskItem.isTask) ?? false)
    }
}
