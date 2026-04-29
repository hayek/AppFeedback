import Foundation

enum MailAccountMigration {
    private static let completedKey = "mail.migration.v1.completed"
    private static let legacyCredentialsKey = "mail.credentials"
    private static let legacyTemplateKey = "mail.template"

    @MainActor
    static func runIfNeeded(store: MailAccountStore, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }
        defer { defaults.set(true, forKey: completedKey) }

        let legacyCreds = defaults.data(forKey: legacyCredentialsKey)
            .flatMap { try? JSONDecoder().decode(SMTPCredentials.self, from: $0) }
        let legacyTemplate = defaults.data(forKey: legacyTemplateKey)
            .flatMap { try? JSONDecoder().decode(MailTemplate.self, from: $0) }

        guard legacyCreds != nil || legacyTemplate != nil else { return }

        store.upsert { acc in
            if let creds = legacyCreds {
                acc.presetRaw = creds.preset.rawValue
                acc.smtpHost = creds.host
                acc.smtpPort = creds.port
                acc.smtpUsername = creds.username
                acc.senderName = creds.senderName
                let imap = imapDefaults(for: creds.preset)
                acc.imapHost = imap.host
                acc.imapPort = imap.port
                acc.imapUsername = creds.username
            }
            if let tmpl = legacyTemplate {
                acc.templateHeaderHTML = tmpl.headerHTML
                acc.templateFooterHTML = tmpl.footerHTML
            }
        }
    }

    static func imapDefaults(for preset: SMTPCredentials.Preset) -> (host: String, port: Int) {
        switch preset {
        case .gmail:   return ("imap.gmail.com",       993)
        case .icloud:  return ("imap.mail.me.com",     993)
        case .outlook: return ("outlook.office365.com", 993)
        case .custom:  return ("",                     993)
        }
    }
}
