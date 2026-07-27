import Foundation

/// Real App Store Connect API client. Authenticates each request with an ES256 JWT from
/// `AppStoreConnectAuth`, decodes the documented `customerReviews` JSON (folding `included`
/// response resources into each review), follows the opaque `links.next` cursor, parses the
/// `X-Rate-Limit` `user-hour-rem` header, and maps 401/403/429 to typed errors.
final class AppStoreConnectClient: AppStoreConnectClientProtocol {
    private let auth: AppStoreConnectAuth
    private let session: URLSession
    private let activityLog: ActivityLog?                  // @MainActor
    private static let base = "https://api.appstoreconnect.apple.com"

    init(auth: AppStoreConnectAuth, session: URLSession = .shared, activityLog: ActivityLog? = nil) {
        self.auth = auth
        self.session = session
        self.activityLog = activityLog
    }

    // MARK: - Reviews

    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
        // links.next is a full URL; the first page is built from the field-selection query.
        let urlString = cursor ?? "\(Self.base)/v1/apps/\(appAppleID)/customerReviews"
            + "?sort=-createdDate&limit=200&include=response"
            + "&fields[customerReviews]=rating,title,body,reviewerNickname,createdDate,territory"
            + "&fields[customerReviewResponses]=responseBody,lastModifiedDate,state"
        guard let url = URL(string: urlString) else { throw AppStoreConnectError.http(0) }
        let title = "GET reviews · app \(appAppleID)" + (cursor == nil ? "" : " (next page)")
        return try await logged(title) {
            let (data, http) = try await self.send(url: url, method: "GET", body: nil)
            let rateRemaining = Self.parseRateRemaining(http)
            try Self.mapStatus(http.statusCode, rateRemaining: rateRemaining, data: data)
            let decoded: ReviewsEnvelope
            do { decoded = try Self.decoder.decode(ReviewsEnvelope.self, from: data) }
            catch { throw AppStoreConnectError.decoding(String(describing: error)) }
            let responsesByID = Dictionary(uniqueKeysWithValues:
                (decoded.included ?? [])
                    .filter { $0.type == "customerReviewResponses" }
                    .compactMap { inc -> (String, ASCResponse)? in
                        guard let a = inc.attributes else { return nil }
                        return (inc.id, ASCResponse(id: inc.id, responseBody: a.responseBody ?? "",
                                                    state: a.state ?? "", lastModifiedDate: a.lastModifiedDate ?? .distantPast))
                    })
            let reviews: [ASCReview] = decoded.data.map { row in
                let respID = row.relationships?.response?.data?.id
                return ASCReview(
                    id: row.id,
                    rating: row.attributes?.rating ?? 0,
                    title: row.attributes?.title,
                    body: row.attributes?.body,
                    reviewerNickname: row.attributes?.reviewerNickname,
                    createdDate: row.attributes?.createdDate ?? .distantPast,
                    territory: row.attributes?.territory ?? "",
                    response: respID.flatMap { responsesByID[$0] }
                )
            }
            let next = decoded.links?.next
            let page = ASCReviewPage(reviews: reviews, nextCursor: (next?.isEmpty == false) ? next : nil, rateRemaining: rateRemaining)
            let detail = Self.detail(status: http.statusCode, rateRemaining: rateRemaining,
                                     summary: "\(reviews.count) review\(reviews.count == 1 ? "" : "s")"
                                        + (page.nextCursor == nil ? "" : ", more pages"))
            return (page, detail)
        }
    }

    // MARK: - Apps

    func listApps() async throws -> [ASCApp] {
        guard let url = URL(string: "\(Self.base)/v1/apps?fields[apps]=bundleId,name&limit=200") else {
            throw AppStoreConnectError.http(0)
        }
        return try await logged("GET apps") {
            let (data, http) = try await self.send(url: url, method: "GET", body: nil)
            let rateRemaining = Self.parseRateRemaining(http)
            try Self.mapStatus(http.statusCode, rateRemaining: rateRemaining, data: data)
            do {
                let env = try Self.decoder.decode(AppsEnvelope.self, from: data)
                let apps = env.data.map { ASCApp(id: $0.id, bundleId: $0.attributes?.bundleId ?? "", name: $0.attributes?.name ?? "") }
                let detail = Self.detail(status: http.statusCode, rateRemaining: rateRemaining,
                                         summary: "\(apps.count) app\(apps.count == 1 ? "" : "s")")
                return (apps, detail)
            } catch { throw AppStoreConnectError.decoding(String(describing: error)) }
        }
    }

    // MARK: - Responses (write-back; Phase 4 UI consumes these)

    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
        guard let url = URL(string: "\(Self.base)/v1/customerReviewResponses") else { throw AppStoreConnectError.http(0) }
        let payload: [String: Any] = ["data": [
            "type": "customerReviewResponses",
            "attributes": ["responseBody": body],
            "relationships": ["review": ["data": ["type": "customerReviews", "id": reviewId]]],
        ]]
        let json = try JSONSerialization.data(withJSONObject: payload)
        return try await logged("POST response · review \(reviewId)") {
            let (data, http) = try await self.send(url: url, method: "POST", body: json)
            let rateRemaining = Self.parseRateRemaining(http)
            try Self.mapStatus(http.statusCode, rateRemaining: rateRemaining, data: data)
            do {
                let env = try Self.decoder.decode(SingleResponseEnvelope.self, from: data)
                guard let a = env.data.attributes else { throw AppStoreConnectError.decoding("missing response attributes") }
                let response = ASCResponse(id: env.data.id, responseBody: a.responseBody ?? body,
                                           state: a.state ?? "PENDING_PUBLISH", lastModifiedDate: a.lastModifiedDate ?? Date())
                return (response, Self.detail(status: http.statusCode, rateRemaining: rateRemaining, summary: response.state))
            } catch let e as AppStoreConnectError { throw e }
            catch { throw AppStoreConnectError.decoding(String(describing: error)) }
        }
    }

    func deleteResponse(responseId: String) async throws {
        guard let url = URL(string: "\(Self.base)/v1/customerReviewResponses/\(responseId)") else { throw AppStoreConnectError.http(0) }
        try await logged("DELETE response \(responseId)") {
            let (data, http) = try await self.send(url: url, method: "DELETE", body: nil)
            let rateRemaining = Self.parseRateRemaining(http)
            // 204 No Content on success.
            if http.statusCode != 204 {
                try Self.mapStatus(http.statusCode, rateRemaining: rateRemaining, data: data)
            }
            return ((), Self.detail(status: http.statusCode, rateRemaining: rateRemaining, summary: "deleted"))
        }
    }

    // MARK: - Activity logging

    /// Records one App Store Connect API call in the shared activity log: an in-progress entry when
    /// the call starts, resolved with the HTTP status + a short summary, or with the error. Every
    /// failure path is covered — JWT minting, transport, non-2xx mapping and decoding all run inside
    /// `work`. A nil `activityLog` (tests, CLI) makes this a straight pass-through.
    private func logged<T>(_ title: String, _ work: () async throws -> (T, String?)) async throws -> T {
        guard let activityLog else { return try await work().0 }
        let id = await MainActor.run { activityLog.start(kind: .appStoreAPI, title: title) }
        do {
            let (value, detail) = try await work()
            await MainActor.run { activityLog.finish(id, status: .success, detail: detail) }
            return value
        } catch {
            await MainActor.run { activityLog.finish(id, status: .failure, detail: Self.describe(error)) }
            throw error
        }
    }

    /// "200 · 42 reviews · 3490 calls left" — the status code first so a glance at the log answers
    /// "did the call go through".
    private static func detail(status: Int, rateRemaining: Int?, summary: String?) -> String {
        var parts = ["\(status)"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        if let rateRemaining { parts.append("\(rateRemaining) calls left") }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case AppStoreConnectError.authFailed:      return "401 authentication failed — check the Issuer ID, Key ID and .p8 key"
        case AppStoreConnectError.forbidden:       return "403 forbidden — key not authorized for this request"
        case AppStoreConnectError.rateLimited:     return "429 rate limited"
        case let AppStoreConnectError.http(code):  return code == 0 ? "request failed" : "HTTP \(code)"
        case let AppStoreConnectError.decoding(d): return "decoding failed — \(d)"
        case let AppStoreConnectError.badKey(d):   return "bad .p8 key — \(d)"
        default: return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: - Transport

    private func send(url: URL, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let token = try await auth.token()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppStoreConnectError.http(0) }
        return (data, http)
    }

    private static func mapStatus(_ code: Int, rateRemaining: Int?, data: Data) throws {
        switch code {
        case 200...299: return
        case 401: throw AppStoreConnectError.authFailed
        case 403: throw AppStoreConnectError.forbidden
        case 429: throw AppStoreConnectError.rateLimited
        default:  throw AppStoreConnectError.http(code)
        }
    }

    /// Parses `user-hour-rem:<n>` out of the `X-Rate-Limit` header
    /// (e.g. "user-hour-lim:3500;user-hour-rem:3490;").
    static func parseRateRemaining(_ http: HTTPURLResponse) -> Int? {
        guard let raw = http.value(forHTTPHeaderField: "X-Rate-Limit") else { return nil }
        for part in raw.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces) == "user-hour-rem" {
                return Int(kv[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: - Decoding shapes

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFraction = ISO8601DateFormatter()
        isoNoFraction.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: s) ?? isoNoFraction.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "bad date \(s)")
        }
        return d
    }()

    private struct ReviewsEnvelope: Decodable {
        let data: [ReviewRow]
        let included: [IncludedRow]?
        let links: Links?
    }
    private struct ReviewRow: Decodable {
        let id: String
        let attributes: ReviewAttributes?
        let relationships: ReviewRelationships?
    }
    private struct ReviewAttributes: Decodable {
        let rating: Int?
        let title: String?
        let body: String?
        let reviewerNickname: String?
        let createdDate: Date?
        let territory: String?
    }
    private struct ReviewRelationships: Decodable {
        let response: RelationshipBox?
    }
    private struct RelationshipBox: Decodable { let data: RelationshipRef? }
    private struct RelationshipRef: Decodable { let id: String; let type: String }
    private struct IncludedRow: Decodable { let id: String; let type: String; let attributes: ResponseAttributes? }
    private struct ResponseAttributes: Decodable {
        let responseBody: String?
        let state: String?
        let lastModifiedDate: Date?
    }
    private struct Links: Decodable { let next: String? }
    private struct AppsEnvelope: Decodable { let data: [AppRow] }
    private struct AppRow: Decodable { let id: String; let attributes: AppAttributes? }
    private struct AppAttributes: Decodable { let bundleId: String?; let name: String? }
    private struct SingleResponseEnvelope: Decodable { let data: IncludedRow }
}
