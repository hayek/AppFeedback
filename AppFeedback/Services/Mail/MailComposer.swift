import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(SwiftMail)
import SwiftMail
#endif

struct DraftMessage: @unchecked Sendable {
    var recipient: String
    var subject: String
    var body: NSAttributedString
}

struct PlaceholderContext: Sendable {
    var sender: SMTPCredentials
    var recipient: String
    var appName: String
    var issueTitle: String?
    var issueURL: URL?
    var feedbackBody: String?
    var feedbackAttachments: [FeedbackAttachmentRef] = []
    var date: Date
}

#if canImport(SwiftMail)
struct MailComposer {

    func compose(
        draft: DraftMessage,
        context: PlaceholderContext,
        template: MailTemplate,
        messageID: String? = nil,
        replyHeaders: ReplyHeaderBuilder.Output? = nil,
        attachments: [PendingAttachment] = []
    ) -> SwiftMail.Email {
        let bodyHTML = htmlForBody(draft.body)
        let bodyText = draft.body.string

        let header = applyPlaceholders(template.headerHTML, context: context)
        let footer = applyPlaceholders(template.footerHTML, context: context)

        let cleanedHeader = HTMLSanitizer.sanitize(header)
        let cleanedFooter = HTMLSanitizer.sanitize(footer)
        let cleanedBody   = HTMLSanitizer.sanitize(bodyHTML)

        let combinedHTML = """
        <html><body>
        \(cleanedHeader)
        \(cleanedBody)
        \(cleanedFooter)
        </body></html>
        """

        let combinedText = [
            HTMLSanitizer.plainText(from: cleanedHeader),
            bodyText,
            HTMLSanitizer.plainText(from: cleanedFooter)
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")

        var email = SwiftMail.Email(
            sender: EmailAddress(name: context.sender.senderName,
                                 address: context.sender.username),
            recipients: [EmailAddress(name: nil, address: draft.recipient)],
            subject: draft.subject,
            textBody: combinedText,
            htmlBody: combinedHTML
        )
        if let messageID, let parsed = SwiftMail.MessageID(messageID) {
            email.messageID = parsed
        }
        if let reply = replyHeaders {
            var headers = email.additionalHeaders ?? [:]
            if let inReplyTo = reply.inReplyTo {
                headers["In-Reply-To"] = inReplyTo
            }
            if !reply.references.isEmpty {
                headers["References"] = reply.references.joined(separator: " ")
            }
            email.additionalHeaders = headers
        }
        if !attachments.isEmpty {
            email.attachments = attachments.map { p in
                SwiftMail.Attachment(filename: p.filename, mimeType: p.mimeType, data: p.data)
            }
        }
        return email
    }

    // MARK: - Placeholders

    func applyPlaceholders(_ template: String, context: PlaceholderContext) -> String {
        let dateString = context.date.formatted(
            .dateTime.day().month(.wide).year().hour().minute()
        )
        var s = template
        s = s.replacingOccurrences(of: "{{recipient_email}}", with: context.recipient)
        s = s.replacingOccurrences(of: "{{sender_name}}",     with: context.sender.senderName)
        s = s.replacingOccurrences(of: "{{sender_email}}",    with: context.sender.username)
        s = s.replacingOccurrences(of: "{{date}}",            with: dateString)
        s = s.replacingOccurrences(of: "{{app_name}}",        with: context.appName)
        s = s.replacingOccurrences(of: "{{issue_title}}",     with: context.issueTitle ?? "")
        s = s.replacingOccurrences(of: "{{issue_url}}",       with: context.issueURL?.absoluteString ?? "")
        s = s.replacingOccurrences(of: "{{feedback_body}}",   with: context.feedbackBody ?? "")
        s = s.replacingOccurrences(of: "{{feedback_attachments}}", with: renderAttachmentsHTML(context.feedbackAttachments))
        return s
    }

    func renderAttachmentsHTML(_ attachments: [FeedbackAttachmentRef]) -> String {
        guard !attachments.isEmpty else { return "" }
        var html = "<div class=\"feedback-attachments\">"
        for a in attachments {
            let encodedURL = htmlEncode(a.url.absoluteString)
            let encodedName = htmlEncode(a.filename)
            if a.isImage {
                html += "<div><a href=\"\(encodedURL)\"><img src=\"\(encodedURL)\" alt=\"\(encodedName)\" style=\"max-width:240px;border-radius:6px\"/></a></div>"
            } else {
                let sizeText: String
                if let b = a.sizeBytes {
                    sizeText = " (\(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)))"
                } else { sizeText = "" }
                html += "<div><a href=\"\(encodedURL)\">\(encodedName)</a>\(sizeText)</div>"
            }
        }
        html += "</div>"
        return html
    }

    private func htmlEncode(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Body conversion

    private func htmlForBody(_ attributed: NSAttributedString) -> String {
        #if os(macOS)
        let opts: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let data = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: opts),
              let html = String(data: data, encoding: .utf8) else {
            return "<p>\(escape(attributed.string))</p>"
        }
        return extractBodyContent(from: html)
        #else
        return "<p>\(escape(attributed.string))</p>"
        #endif
    }

    private func extractBodyContent(from html: String) -> String {
        guard let bodyOpenRange = html.range(of: "<body", options: .caseInsensitive),
              let openCloseRange = html.range(of: ">", range: bodyOpenRange.upperBound..<html.endIndex),
              let bodyCloseRange = html.range(of: "</body>", options: .caseInsensitive,
                                              range: openCloseRange.upperBound..<html.endIndex) else {
            return html
        }
        return String(html[openCloseRange.upperBound..<bodyCloseRange.lowerBound])
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

}
#endif
