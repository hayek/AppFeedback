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

        /// Whether the provider's SMTP submission already files a copy in the Sent folder.
        /// Gmail and Outlook/Office365 do this server-side, so the app must NOT also IMAP-APPEND
        /// (it would create a duplicate). iCloud and generic/custom IMAP servers do not — the
        /// sending client is expected to APPEND the sent copy itself.
        var autosavesSentMail: Bool {
            switch self {
            case .gmail, .outlook: return true
            case .icloud, .custom: return false
            }
        }

        var displayName: String {
            switch self {
            case .gmail:   return "Gmail"
            case .icloud:  return "iCloud"
            case .outlook: return "Outlook"
            case .custom:  return "Custom SMTP"
            }
        }

        /// Strip whitespace from app passwords. Gmail/iCloud display 16-char app passwords as
        /// four space-separated groups; users routinely paste them with spaces, which the IMAP
        /// LOGIN command then rejects as invalid credentials. Plain SMTP/IMAP passwords cannot
        /// legitimately contain whitespace, so this is safe across providers.
        func sanitize(password: String) -> String {
            password.filter { !$0.isWhitespace && !$0.isNewline }
        }

        /// Renderable guidance for providers that require an app-specific password.
        /// Absent for `.custom`, which has no provider-specific story to tell.
        struct Help: Sendable, Equatable {
            let providerName: String
            let title: String
            let body: String
            let linkLabel: String
            let baseURL: URL
        }

        var passwordPrompt: String {
            switch self {
            case .gmail:   return "16-character app password"
            case .icloud:  return "App-specific password"
            case .outlook: return "App password"
            case .custom:  return "Mailbox password"
            }
        }

        var help: Help? {
            switch self {
            case .gmail:
                return Help(
                    providerName: "Gmail",
                    title: "Gmail needs an app password.",
                    body: "Account passwords are rejected over IMAP and SMTP. Generate a 16-character app password and paste it here — 2-Step Verification must be enabled first.",
                    linkLabel: "Open Google App Passwords",
                    baseURL: URL(string: "https://myaccount.google.com/apppasswords")!
                )
            case .icloud:
                return Help(
                    providerName: "iCloud",
                    title: "iCloud needs an app-specific password.",
                    body: "Your Apple ID password will not work over IMAP or SMTP. Generate an app-specific password at appleid.apple.com under Sign-In and Security — 2-Factor Authentication on your Apple ID is required.",
                    linkLabel: "Open Apple ID Sign-In Settings",
                    baseURL: URL(string: "https://account.apple.com/account/manage/section/security")!
                )
            case .outlook:
                return Help(
                    providerName: "Outlook",
                    title: "Outlook may need an app password.",
                    body: "If two-step verification is on, your account password is rejected over IMAP and SMTP. Generate an app password in your Microsoft account and paste it here.",
                    linkLabel: "Open Microsoft App Passwords",
                    baseURL: URL(string: "https://account.live.com/proofs/AppPassword")!
                )
            case .custom:
                return nil
            }
        }

        /// Personalised URL that preselects this email on Google's app-password page;
        /// other providers don't accept a hint, so the bare URL is returned.
        func appPasswordsURL(forEmail email: String) -> URL? {
            guard let base = help?.baseURL else { return nil }
            let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard self == .gmail, trimmed.contains("@") else { return base }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "authuser", value: trimmed)]
            return components?.url ?? base
        }

        /// Best-effort match of an email's domain to a known preset.
        static func detect(fromEmail email: String) -> Preset? {
            guard let host = email.emailDomain else { return nil }
            switch host {
            case "gmail.com", "googlemail.com":
                return .gmail
            case "icloud.com", "me.com", "mac.com":
                return .icloud
            case "outlook.com", "hotmail.com", "live.com", "msn.com":
                return .outlook
            default:
                return nil
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

extension String {
    /// Lowercased domain part of an email-shaped string, or nil if there's no `@`.
    var emailDomain: String? {
        guard let at = firstIndex(of: "@") else { return nil }
        let domain = self[index(after: at)...]
        guard !domain.isEmpty else { return nil }
        return domain.lowercased()
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
        // iOS lacks NSAttributedString HTML rendering; fall back to regex tag-strip so
        // template previews show readable plain text rather than raw markup.
        return HTMLSanitizer.plainText(from: html)
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
