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
            attachments: p.attachments.map(FeedbackAttachmentRef.init)
        )
    }
}
