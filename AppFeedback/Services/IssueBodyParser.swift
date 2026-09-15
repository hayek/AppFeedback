import Foundation
import AppFeedbackCore

struct ParsedBody: Sendable {
    var description: String = ""
    var app: String?
    var appVersion: String?
    var device: String?
    var osVersion: String?
    var email: String?
    var attachments: [FeedbackAttachmentRef] = []
    /// Source-metadata marker values (`source-meta-v1` block). `source` is the
    /// raw value of the originating `FeedbackSource`; nil for legacy SDK issues.
    var source: String?
    var rating: Int?
    var reviewId: String?
    /// ISO-3166 alpha-3 storefront of an App Store review (e.g. "USA").
    var territory: String?
    /// ISO-8601 date the App Store review was written. The issue's own `createdAt` is only the
    /// time the poll synthesized it, so this is the date the UI must sort and display by.
    var reviewCreatedAt: String?
    var fromAddress: String?
    var messageId: String?
}

/// Thin shim over `AppFeedbackCore.IssueBodyParser`. Adapts the SDK's field
/// names (`appName`) to this project's (`app`) so callers and tests don't have
/// to change. The SDK is the single source of truth for the parse logic — if
/// you find a body the inbox doesn't handle correctly, fix it in the SDK.
enum IssueBodyParser {
    static func parse(_ raw: String) -> ParsedBody {
        let p = AppFeedbackCore.IssueBodyParser.parse(raw)
        return ParsedBody(
            description: p.description,
            app: p.appName,
            appVersion: p.appVersion,
            device: p.device,
            osVersion: p.osVersion,
            email: p.email,
            attachments: p.attachments.map(FeedbackAttachmentRef.init),
            source: p.source,
            rating: p.rating,
            reviewId: p.reviewId,
            territory: p.territory,
            reviewCreatedAt: p.reviewCreatedAt,
            fromAddress: p.fromAddress,
            messageId: p.messageId
        )
    }

    /// Parses a marker date. The synthesizer writes `.withInternetDateTime`; fractional seconds are
    /// accepted too so bodies written by any other producer still resolve.
    static func markerDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return isoWithFraction.date(from: value) ?? iso.date(from: value)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
