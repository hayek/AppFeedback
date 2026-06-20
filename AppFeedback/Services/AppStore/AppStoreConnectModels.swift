import Foundation

struct ASCResponse: Sendable, Equatable {
    let id: String
    let responseBody: String
    let state: String          // "PUBLISHED" | "PENDING_PUBLISH"
    let lastModifiedDate: Date
}

struct ASCReview: Sendable, Equatable {
    let id: String
    let rating: Int            // 1…5
    let title: String?
    let body: String?
    let reviewerNickname: String?
    let createdDate: Date
    let territory: String      // ISO-3166 alpha-3
    let response: ASCResponse?
}

struct ASCReviewPage: Sendable {
    let reviews: [ASCReview]
    let nextCursor: String?    // opaque links.next cursor (full URL); nil ⇒ last page
    let rateRemaining: Int?    // X-Rate-Limit user-hour-rem
}

struct ASCApp: Sendable, Equatable {
    let id: String             // opaque ASC app id (numeric string)
    let bundleId: String
    let name: String
}

/// Errors that carry an HTTP-status hint so callers (e.g. Phase 4's 403 read-only path) can
/// branch on the wire status without switching on the concrete error type.
protocol StatusCarryingError: Error {
    var statusCode: Int { get }
}

/// Errors surfaced by the App Store Connect client, mapped from HTTP status. `statusCode` is the
/// canonical mapping consumed by Phase 4: authFailed→401, forbidden→403, rateLimited→429,
/// http(n)→n, everything else→0.
enum AppStoreConnectError: StatusCarryingError, Equatable {
    case authFailed                 // 401 — bad/expired JWT
    case forbidden                  // 403 — read-only key (write denied) / no access
    case rateLimited                // 429 RATE_LIMIT_EXCEEDED
    case http(Int)                  // any other non-2xx
    case decoding(String)           // JSON decode failure (detail is for logging only)
    case badKey(String)             // .p8 PEM not loadable (detail is for logging only)

    var statusCode: Int {
        switch self {
        case .authFailed:        return 401
        case .forbidden:         return 403
        case .rateLimited:       return 429
        case let .http(code):    return code
        case .decoding, .badKey: return 0
        }
    }
}

protocol AppStoreConnectClientProtocol: Sendable {
    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage
    func listApps() async throws -> [ASCApp]
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse  // POST upsert
    func deleteResponse(responseId: String) async throws
}

/// Thin seam so a future feedback source is a well-defined task. App Store reviews conform via
/// `AppStoreReviewCoordinator`.
protocol FeedbackSourceIngestor: Sendable {
    func poll() async throws
}
