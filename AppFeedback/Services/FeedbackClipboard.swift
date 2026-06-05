import Foundation

/// Builds the plain-text clipboard representation of a feedback issue, optionally
/// followed by the full reply conversation from any attached mail threads.
///
/// Extracted from `IssueCardView` so the formatting is unit-testable and so the
/// "Copy issue" button can include the reply thread alongside the issue itself.
///
/// `@MainActor` because the badge formatters (`DeviceName.friendly`,
/// `OSVersionFormat.display`) are main-actor isolated; it's only ever called from
/// the view and the tests, both of which run on the main actor.
@MainActor
enum FeedbackClipboard {
    static func text(for issue: FeedbackIssue, threads: [MailThread] = [], translated: Bool = false) -> String {
        var lines: [String] = []
        lines.append(issue.displayedTitle(translated: translated))

        let body = issue.displayedBody(translated: translated)
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        }

        var badges: [String] = []
        if let typed = issue.labels.issueType {
            badges.append(typed.type.displayName)
        }
        for label in issue.labels.withoutTypeAndUserSubmitted {
            badges.append(label.name)
        }
        if let app = issue.appName { badges.append(app) }
        if let version = issue.appVersion { badges.append("v\(version)") }
        if let device = issue.device { badges.append("device: \(DeviceName.friendly(device))") }
        if let os = issue.osVersion { badges.append("os: \(OSVersionFormat.display(os))") }
        if let email = issue.email { badges.append("✉ \(email)") }
        if !badges.isEmpty {
            lines.append("")
            lines.append(badges.joined(separator: " • "))
        }

        let messages = dedupedMessages(from: threads)
        if !messages.isEmpty {
            lines.append("")
            lines.append(messages.count == 1 ? "Replies (1):" : "Replies (\(messages.count)):")
            for message in messages {
                lines.append("")
                lines.append(replyHeader(for: message))
                // Match the card, which shows the quoted-reply tail stripped by default,
                // so the copied transcript stays readable instead of carrying nested quotes.
                let cleaned = HTMLSanitizer.stripQuotedReply(message.bodyPlain).cleaned
                // Always emit a body line so a reply with no copyable text (e.g. an
                // attachment-only message, or one that was entirely a quoted reply) stays
                // represented and the count stays truthful — never a dangling header.
                lines.append(cleaned.isEmpty ? "(no text)" : cleaned)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// All messages from the given threads, sorted chronologically with duplicate
    /// `messageID`s collapsed. Mirrors `MailThread.sortedDedupedMessages` but spans
    /// every thread, since CloudKit can sync the same inbound message from more than
    /// one device and an issue can (rarely) carry more than one matched thread.
    private static func dedupedMessages(from threads: [MailThread]) -> [MailMessage] {
        let all = threads
            .flatMap { $0.sortedDedupedMessages }
            .sorted { $0.date < $1.date }
        var seen: Set<String> = []
        return all.filter { msg in
            guard !msg.messageID.isEmpty else { return true }
            return seen.insert(msg.messageID).inserted
        }
    }

    /// "Name (address) · date" when a display name exists, otherwise "address · date".
    /// Mirrors `MailMessageRowView.senderLine` so the transcript reads like the card.
    private static func replyHeader(for message: MailMessage) -> String {
        let sender: String
        if let name = message.fromName, !name.isEmpty {
            sender = "\(name) (\(message.fromAddress))"
        } else {
            sender = message.fromAddress
        }
        let date = message.date.formatted(date: .abbreviated, time: .shortened)
        return "\(sender) · \(date)"
    }
}
