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

extension MailAccountMigration {
    // Stable persisted UserDefaults key. The "v1" suffix here refers to the first version of
    // the multi-account migration scheme (distinct from the legacy `mail.migration.v1.completed`
    // used by `runIfNeeded`); the constant name is what code reads to make the meaning obvious.
    private static let multiAccountMigrationCompletedKey = "mail.multiaccount.migration.v1.completed"

    /// One-shot multi-account migration. Idempotent.
    ///
    /// Steps:
    ///   1. Mark the existing single MailAccount (if any) as the default sender.
    ///   2. Copy templateHeaderHTML / templateFooterHTML / attachmentFolderBookmark /
    ///      pollIntervalSeconds into `MailSettings` (leaving the fields cleared on
    ///      `MailAccount`).
    ///   3. Read legacy fixed-slot Keychain creds and re-save them keyed by the account's UUID,
    ///      then delete the legacy slots. The legacy delete is also called on every launch via
    ///      `purgeLegacyKeychain()` to defeat a downgraded-device resurrecting the legacy slot.
    ///   4. Backfill MailMessage.accountID and MailThread.accountID with the surviving
    ///      account's UUID.
    @MainActor
    static func runV2IfNeeded(
        accountStore: MailAccountStore,
        settingsStore: MailSettingsStore,
        threadStore: MailThreadStore,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: multiAccountMigrationCompletedKey) else {
            purgeLegacyKeychain()
            return
        }
        defer {
            defaults.set(true, forKey: multiAccountMigrationCompletedKey)
            purgeLegacyKeychain()
        }

        guard let legacy = accountStore.accounts.first else {
            return
        }

        // (1) Default sender.
        if !legacy.isDefaultSender {
            accountStore.setDefaultSender(legacy)
        }

        // (2) Shared settings extraction.
        settingsStore.update { s in
            if s.templateHeaderHTML.isEmpty {
                s.templateHeaderHTML = legacy.templateHeaderHTML
            }
            if s.templateFooterHTML.isEmpty {
                s.templateFooterHTML = legacy.templateFooterHTML
            }
            if s.attachmentFolderBookmark == nil {
                s.attachmentFolderBookmark = legacy.attachmentFolderBookmark
            }
            // Only seed the poll interval the first time, so a user who later changes it
            // in MailSettings isn't reset by a re-run.
            if s.pollIntervalSeconds == 300 && legacy.pollIntervalSeconds != 300 {
                s.pollIntervalSeconds = legacy.pollIntervalSeconds
            }
        }
        accountStore.update(id: legacy.id) { a in
            a.templateHeaderHTML = ""
            a.templateFooterHTML = ""
            a.attachmentFolderBookmark = nil
        }

        // (3) Keychain reissue. We fire-and-forget because init() can't be async; the migration
        // flag is set in the synchronous defer above. If the app crashes in the microsecond
        // window between the defer firing and this Task running, the user re-enters credentials
        // once on next launch — preferable to making the migration retry forever on a transient
        // Keychain failure (e.g., errSecInteractionNotAllowed shortly after wake-from-sleep).
        let legacyID = legacy.id
        Task { @MainActor in
            if let smtp = await KeychainService.loadSMTPPassword(), !smtp.isEmpty {
                _ = await KeychainService.saveSMTPPassword(smtp, for: legacyID)
            }
            if let imap = await KeychainService.loadIMAPPassword(), !imap.isEmpty {
                _ = await KeychainService.saveIMAPPassword(imap, for: legacyID)
            }
            await KeychainService.deleteSMTPPassword()
            await KeychainService.deleteIMAPPassword()
        }

        // (4) Backfill thread / message accountID.
        threadStore.backfillAccountIDIfMissing(legacy.id)
    }

    /// Idempotently deletes the legacy fixed-slot SMTP/IMAP entries. Called on every launch
    /// after v2 has completed, so a brief downgrade-then-upgrade cycle doesn't resurrect
    /// stale credentials.
    @MainActor
    static func purgeLegacyKeychain() {
        Task { @MainActor in
            await KeychainService.deleteSMTPPassword()
            await KeychainService.deleteIMAPPassword()
        }
    }
}
