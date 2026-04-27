import Foundation
import Observation

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
    var useSTARTTLS: Bool
    var username: String   // doubles as the From address
    var password: String   // not persisted in this struct's UserDefaults form; lives in Keychain
    var senderName: String

    static func defaults(for preset: Preset) -> SMTPCredentials {
        switch preset {
        case .gmail:
            return SMTPCredentials(preset: .gmail, host: "smtp.gmail.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .icloud:
            return SMTPCredentials(preset: .icloud, host: "smtp.mail.me.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .outlook:
            return SMTPCredentials(preset: .outlook, host: "smtp-mail.outlook.com",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        case .custom:
            return SMTPCredentials(preset: .custom, host: "",
                                   port: 587, useSTARTTLS: true,
                                   username: "", password: "", senderName: "")
        }
    }
}

struct MailTemplate: Codable, Equatable, Sendable {
    var headerHTML: String
    var footerHTML: String

    static let empty = MailTemplate(headerHTML: "", footerHTML: "")
}

/// Persists SMTP credential metadata + email header/footer template.
/// `credentials.password` is NOT written to UserDefaults — store/load via Keychain separately.
@MainActor
@Observable
final class MailSettings {
    var credentials: SMTPCredentials? {
        didSet { persistCredentials() }
    }
    var template: MailTemplate {
        didSet { persistTemplate() }
    }

    private let defaults: UserDefaults
    private static let credentialsKey = "mail.credentials"
    private static let templateKey = "mail.template"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.credentialsKey),
           let decoded = try? JSONDecoder().decode(SMTPCredentials.self, from: data) {
            self.credentials = decoded
        } else {
            self.credentials = nil
        }
        if let data = defaults.data(forKey: Self.templateKey),
           let decoded = try? JSONDecoder().decode(MailTemplate.self, from: data) {
            self.template = decoded
        } else {
            self.template = .empty
        }
    }

    private func persistCredentials() {
        if let credentials,
           let data = try? JSONEncoder().encode(redactingPassword(credentials)) {
            defaults.set(data, forKey: Self.credentialsKey)
        } else {
            defaults.removeObject(forKey: Self.credentialsKey)
        }
    }

    private func persistTemplate() {
        if let data = try? JSONEncoder().encode(template) {
            defaults.set(data, forKey: Self.templateKey)
        }
    }

    private func redactingPassword(_ creds: SMTPCredentials) -> SMTPCredentials {
        var copy = creds
        copy.password = ""
        return copy
    }
}
