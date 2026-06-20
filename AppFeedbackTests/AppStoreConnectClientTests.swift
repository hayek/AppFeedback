import XCTest
import CryptoKit
@testable import AppFeedback

final class AppStoreConnectClientTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    private func auth() -> AppStoreConnectAuth {
        AppStoreConnectAuth(issuerID: "i", keyID: "k", p8PEM: P256.Signing.PrivateKey().pemRepresentation)
    }

    private static let page1 = """
    {"data":[
      {"type":"customerReviews","id":"R1","attributes":{"rating":5,"title":"Great","body":"Love it","reviewerNickname":"sam","createdDate":"2026-06-10T12:00:00.000Z","territory":"USA"},
       "relationships":{"response":{"data":{"type":"customerReviewResponses","id":"RESP1"}}}}
    ],
    "included":[
      {"type":"customerReviewResponses","id":"RESP1","attributes":{"responseBody":"Thanks!","lastModifiedDate":"2026-06-11T09:00:00.000Z","state":"PUBLISHED"}}
    ],
    "links":{"next":"https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2"}}
    """
    private static let page2 = """
    {"data":[
      {"type":"customerReviews","id":"R2","attributes":{"rating":1,"title":null,"body":"Crashes","reviewerNickname":"lee","createdDate":"2026-06-09T08:00:00.000Z","territory":"GBR"}}
    ],
    "links":{}}
    """

    func testListReviewsParsesIncludedResponseAndCursor() async throws {
        MockURLProtocol.requestHandler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer "), true)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3490;"])!
            return (resp, Self.page1.data(using: .utf8)!)
        }
        let client = AppStoreConnectClient(auth: auth(), session: .mock)
        let page = try await client.listReviews(appAppleID: "123", page: nil)
        XCTAssertEqual(page.reviews.count, 1)
        XCTAssertEqual(page.reviews[0].id, "R1")
        XCTAssertEqual(page.reviews[0].rating, 5)
        XCTAssertEqual(page.reviews[0].territory, "USA")
        XCTAssertEqual(page.reviews[0].response?.id, "RESP1")
        XCTAssertEqual(page.reviews[0].response?.state, "PUBLISHED")
        XCTAssertEqual(page.reviews[0].response?.responseBody, "Thanks!")
        XCTAssertEqual(page.nextCursor, "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
        XCTAssertEqual(page.rateRemaining, 3490)
    }

    func testTitleAndResponseAbsenceHandled() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Self.page2.data(using: .utf8)!)
        }
        let client = AppStoreConnectClient(auth: auth(), session: .mock)
        let page = try await client.listReviews(appAppleID: "123", page: nil)
        XCTAssertEqual(page.reviews[0].id, "R2")
        XCTAssertNil(page.reviews[0].title)         // rating-with-no-title row
        XCTAssertNil(page.reviews[0].response)      // no developer response
        XCTAssertNil(page.nextCursor)               // empty links ⇒ last page
    }

    func testCursorIsUsedVerbatimAsURL() async throws {
        var seenURL: String?
        MockURLProtocol.requestHandler = { req in
            seenURL = req.url?.absoluteString
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.page2.data(using: .utf8)!)
        }
        let client = AppStoreConnectClient(auth: auth(), session: .mock)
        _ = try await client.listReviews(appAppleID: "123", page: "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
        XCTAssertEqual(seenURL, "https://api.appstoreconnect.apple.com/v1/apps/123/customerReviews?cursor=PAGE2")
    }

    func testStatusMapping() async {
        func run(_ code: Int, headers: [String: String]? = nil) async -> Error? {
            MockURLProtocol.requestHandler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: headers)!, Data("{}".utf8))
            }
            let client = AppStoreConnectClient(auth: auth(), session: .mock)
            do { _ = try await client.listReviews(appAppleID: "123", page: nil); return nil }
            catch { return error }
        }
        if case AppStoreConnectError.authFailed = (await run(401))! {} else { XCTFail("401→authFailed") }
        if case AppStoreConnectError.forbidden = (await run(403))! {} else { XCTFail("403→forbidden") }
        if case AppStoreConnectError.rateLimited = (await run(429, headers: ["X-Rate-Limit": "user-hour-rem:0;"]))! {} else { XCTFail("429→rateLimited") }
        if case AppStoreConnectError.http(500) = (await run(500))! {} else { XCTFail("500→http") }
        // statusCode mapping is the seam Phase 4 branches on.
        let err403 = await run(403)
        XCTAssertEqual((err403 as? AppStoreConnectError)?.statusCode, 403)
    }

    func testCreateOrUpdateResponseUpserts() async throws {
        var body: [String: Any]?
        MockURLProtocol.requestHandler = { req in
            if let d = req.httpBody { body = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            else if let s = req.httpBodyStream {
                s.open(); defer { s.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n > 0 { data.append(buf, count: n) } else { break } }
                body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            XCTAssertEqual(req.httpMethod, "POST")
            let json = """
            {"data":{"type":"customerReviewResponses","id":"RESP9","attributes":{"responseBody":"Hi","state":"PENDING_PUBLISH","lastModifiedDate":"2026-06-18T00:00:00.000Z"}}}
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
        }
        let client = AppStoreConnectClient(auth: auth(), session: .mock)
        let resp = try await client.createOrUpdateResponse(reviewId: "R1", body: "Hi")
        XCTAssertEqual(resp.id, "RESP9")
        XCTAssertEqual(resp.state, "PENDING_PUBLISH")
        let data = body?["data"] as? [String: Any]
        XCTAssertEqual(data?["type"] as? String, "customerReviewResponses")
        let rel = ((data?["relationships"] as? [String: Any])?["review"] as? [String: Any])?["data"] as? [String: Any]
        XCTAssertEqual(rel?["id"] as? String, "R1")
    }
}
