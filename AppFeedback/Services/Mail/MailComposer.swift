import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(SwiftMail)
import SwiftMail
#endif

struct DraftMessage: Sendable {
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
    var date: Date
}

#if canImport(SwiftMail)
struct MailComposer {

    func compose(draft: DraftMessage, context: PlaceholderContext, template: MailTemplate) -> SwiftMail.Email {
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
            plainText(from: cleanedHeader),
            bodyText,
            plainText(from: cleanedFooter)
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")

        return SwiftMail.Email(
            sender: EmailAddress(name: context.sender.senderName,
                                 address: context.sender.username),
            recipients: [EmailAddress(name: nil, address: draft.recipient)],
            subject: draft.subject,
            textBody: combinedText,
            htmlBody: combinedHTML
        )
    }

    // MARK: - Placeholders

    private func applyPlaceholders(_ template: String, context: PlaceholderContext) -> String {
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
        return s
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

    private func plainText(from html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
