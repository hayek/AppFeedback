import Foundation

/// Rewrites cryptic SwiftMail/SwiftNIO error messages into actionable copy that names
/// the provider and points at app-specific passwords — the cause of the vast majority
/// of IMAP/SMTP failures we see from users.
enum MailErrorTranslator {

    /// User-facing description for `error`, biased toward the most likely cause:
    /// the user supplied an account password where the provider requires an app-specific one.
    static func describe(_ error: Error, preset: SMTPCredentials.Preset) -> String {
        if let imap = error as? IMAPClientError {
            return imap.errorDescription ?? "\(imap)"
        }

        let raw = error.localizedDescription
        let lower = raw.lowercased()

        // NIO emits this when the SMTP server closes the channel after AUTH —
        // some servers (notably iCloud) don't return a clean 535, they just hang up.
        if lower.contains("channel context is nil")
            || lower.contains("channel is closed")
            || lower.contains("ioonclosedchannel")
            || lower.contains("connectionclosed") {
            return appPasswordHint(for: preset, prefix: "Lost the connection during sign-in.")
        }

        // Direct authentication rejection.
        if lower.contains("authentication") && lower.contains("fail")
            || lower.contains("login") && lower.contains("reject")
            || lower.contains("535") {
            return appPasswordHint(for: preset, prefix: "The server rejected your credentials.")
        }

        return raw
    }

    private static func appPasswordHint(for preset: SMTPCredentials.Preset, prefix: String) -> String {
        guard let help = preset.help else {
            return "\(prefix) Double-check the mailbox password and host settings."
        }
        return "\(prefix) \(help.providerName) requires an app-specific password — open the link under the password field to generate one."
    }
}
