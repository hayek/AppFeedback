import Foundation
import SwiftData
import Observation
import AppFeedbackCore

/// Turns inbound mail arriving at a feedback-inbox account (a `MailAccount` whose
/// `feedbackProductID != nil`) into synthesized GitHub issues and comments:
///   • thread ROOT  → create a new issue (label `source:email`, markers source/fromAddress/messageId
///     written via `IssueBodyFormatter.sourceMetadataBlock` — the Phase-1 source-meta-v1 block)
///   • reply in a known thread → comment on that issue
/// Runs as a detached Task from `MailSyncCoordinator.pollOnce()`, parallel to `MailToGitHubMirror`.
/// Never throws to the caller; surfaces via `ActivityLog`. Dedup is free: `recordInbound` dedups by
/// Message-ID, and a synthesized issue is recorded on the CloudKit-synced `MailThread.issueNumber`,
/// so a re-poll (even cross-device) won't re-create.
@MainActor
@Observable
final class MailToFeedbackMirror {

    // MARK: - Contract constants

    /// The Phase-1 GitHub label string for email-sourced feedback.
    static let sourceEmailLabel: String = FeedbackSource.email.githubLabel ?? "source:email"

    // MARK: - Pure builders

    static func issueTitle(subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(no subject)" : trimmed
    }

    /// Prefer `text/plain`; fall back to HTML stripped to plain text via `HTMLSanitizer`.
    static func preferredBodyText(message: ParsedInboundMessage) -> String {
        let plain = message.bodyPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !plain.isEmpty { return message.bodyPlain }
        if let html = message.bodyHTML, !html.isEmpty {
            return HTMLSanitizer.plainText(from: html)
        }
        return ""
    }

    /// Builds the issue body: free text first, then the Phase-1 source-meta-v1 markers rendered via
    /// `IssueBodyFormatter.sourceMetadataBlock` (HTML-comment-fenced block so `IssueBodyParser`
    /// reads them back). `fromAddress` is redacted per the product's preference.
    ///
    /// The ★ MARKER FORMAT CORRECTION means we use the SDK's HTML-comment-fenced block (not
    /// ad-hoc `**Key:**` lines) — this is the same mechanism Phase 3's App Store synthesizer uses,
    /// and the format `IssueBodyParser` (and its SDK backing) actually reads back.
    static func issueBody(message: ParsedInboundMessage, redactEmail: Bool) -> String {
        let bodyText = preferredBodyText(message: message)
        let from = redactEmail ? MailToGitHubMirror.redact(message.fromAddress) : message.fromAddress
        let block = IssueBodyFormatter.sourceMetadataBlock(
            source: FeedbackSource.email.rawValue,
            fromAddress: from,
            messageId: message.messageID
        )
        if bodyText.isEmpty {
            return block
        }
        return bodyText + "\n\n" + block
    }
}

@Observable
final class MailToFeedbackMirrorHolder {
    let mirror: MailToFeedbackMirror?
    init(_ mirror: MailToFeedbackMirror?) { self.mirror = mirror }
}
