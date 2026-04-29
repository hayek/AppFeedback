import Foundation
#if os(macOS)
import AppKit
#endif

struct SMTPCredentials: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Identifiable, Sendable {
        case gmail
        case icloud
        case outlook
        case custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gmail:   return "Gmail"
            case .icloud:  return "iCloud"
            case .outlook: return "Outlook"
            case .custom:  return "Custom SMTP"
            }
        }
    }

    var preset: Preset
    var host: String
    var port: Int
    var username: String   // doubles as the From address
    var senderName: String

    static func defaults(for preset: Preset) -> SMTPCredentials {
        switch preset {
        case .gmail:
            return SMTPCredentials(preset: .gmail, host: "smtp.gmail.com",
                                   port: 587,
                                   username: "", senderName: "")
        case .icloud:
            return SMTPCredentials(preset: .icloud, host: "smtp.mail.me.com",
                                   port: 587,
                                   username: "", senderName: "")
        case .outlook:
            return SMTPCredentials(preset: .outlook, host: "smtp-mail.outlook.com",
                                   port: 587,
                                   username: "", senderName: "")
        case .custom:
            return SMTPCredentials(preset: .custom, host: "",
                                   port: 587,
                                   username: "", senderName: "")
        }
    }
}

struct MailTemplate: Codable, Equatable, Sendable {
    var headerHTML: String
    var footerHTML: String

    static let empty = MailTemplate(headerHTML: "", footerHTML: "")
}

enum MailTemplatePlainText {
    static func from(html: String) -> String {
        guard !html.isEmpty else { return "" }
        #if os(macOS)
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil) {
            return attr.string
                .replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
        }
        #endif
        return html
    }

    static func toHTML(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let withBreaks = escaped.replacingOccurrences(of: "\n", with: "<br>")
        return "<p>\(withBreaks)</p>"
    }
}
