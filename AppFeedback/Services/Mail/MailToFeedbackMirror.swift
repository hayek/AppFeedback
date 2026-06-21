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

    // MARK: - Closure type aliases (injected write operations)

    typealias CreateIssue = @Sendable (
        _ owner: String, _ repo: String, _ title: String, _ body: String,
        _ labels: [String], _ token: String
    ) async throws -> Int

    typealias PostComment = @Sendable (
        _ owner: String, _ repo: String, _ number: Int, _ body: String, _ token: String
    ) async throws -> Int

    // MARK: - Stored dependencies

    private let context: ModelContext
    private let productStore: ProductStore
    private let activityLog: ActivityLog
    private let createIssueOp: CreateIssue
    private let postCommentOp: PostComment
    private let tokenLoader: @Sendable (ProductConfig) async -> String?

    // MARK: - Designated init (closure-injected writes for testability)

    init(
        context: ModelContext,
        productStore: ProductStore,
        activityLog: ActivityLog,
        createIssue: @escaping CreateIssue,
        postComment: @escaping PostComment,
        tokenLoader: @Sendable @escaping (ProductConfig) async -> String?
    ) {
        self.context = context
        self.productStore = productStore
        self.activityLog = activityLog
        self.createIssueOp = createIssue
        self.postCommentOp = postComment
        self.tokenLoader = tokenLoader
    }

    /// Production convenience init: wires the real GitHub actors + Keychain token loader.
    convenience init(
        context: ModelContext,
        productStore: ProductStore,
        activityLog: ActivityLog,
        issueWriter: GitHubIssueWriter = GitHubIssueWriter(),
        commentPoster: GitHubCommentPoster = GitHubCommentPoster()
    ) {
        self.init(
            context: context,
            productStore: productStore,
            activityLog: activityLog,
            createIssue: { owner, repo, title, body, labels, token in
                try await issueWriter.createIssue(
                    owner: owner, repo: repo, title: title, body: body,
                    labels: labels, milestoneNumber: nil, token: token)
            },
            postComment: { owner, repo, number, body, token in
                try await commentPoster.postComment(
                    owner: owner, repo: repo, issueNumber: number, body: body, token: token)
            },
            tokenLoader: { @Sendable config in await KeychainService.load(for: config) }
        )
    }

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

    // MARK: - Live ingestion

    /// The product whose feedback inbox is `accountID`, or nil if none is registered.
    func product(forInbox accountID: UUID) -> ProductConfig? {
        productStore.products.first(where: { $0.feedbackInboxAccountID == accountID })
    }

    /// Processes every not-yet-synthesized inbound message for this feedback inbox:
    /// thread root → create issue; reply in a synthesized thread → comment.
    ///
    /// Idempotent: a synthesized root sets `MailThread.issueNumber`, and a mirrored message sets
    /// `MailMessage.githubCommentID`, so re-entry on the next poll is safe.
    ///
    /// NOTE: noise filtering is NOT done here — the coordinator applies `InboundNoiseFilter`
    /// on the full `ParsedInboundMessage` BEFORE `recordInbound` (Task 6). By the time this
    /// method runs, the store contains only legitimate feedback.
    func mirrorPendingFeedbackInbound(accountID: UUID) async {
        guard let product = product(forInbox: accountID) else { return }
        guard let token = await tokenLoader(product), !token.isEmpty else { return }

        let inboundRaw = MailMessage.Direction.inbound.rawValue
        let descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.directionRaw == inboundRaw && $0.accountID == accountID },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )
        let pending = (try? context.fetch(descriptor)) ?? []

        for message in pending {
            guard let thread = message.thread else { continue }

            // ROOT (brand-new thread not yet synthesized): create an issue.
            if thread.issueNumber == 0 && thread.messageIDRoot == message.messageID {
                await createIssue(forRoot: message, thread: thread, product: product, token: token)
                continue
            }

            // REPLY into a synthesized thread: post a comment (once per message).
            if thread.issueNumber > 0, message.githubCommentID == nil {
                // The thread root itself IS the issue body — never re-post it as a comment.
                if thread.messageIDRoot == message.messageID { continue }
                await postComment(forReply: message, thread: thread, product: product, token: token)
                continue
            }
            // else: reply whose root hasn't been synthesized yet → wait for the next poll.
        }
    }

    // MARK: - Private helpers

    private func createIssue(
        forRoot message: MailMessage,
        thread: MailThread,
        product: ProductConfig,
        token: String
    ) async {
        // Reconstruct a ParsedInboundMessage view ONLY to drive the body/title builders from
        // the stored row. Noise filtering is NOT done here (see mirrorPendingFeedbackInbound) —
        // a rebuilt view has nil returnPath/autoSubmitted/precedence, so re-filtering is both
        // redundant and unable to catch vacation auto-replies. Anything in the store is feedback.
        let parsed = Self.parsedView(of: message)
        let title = Self.issueTitle(subject: message.subject)
        let body = Self.issueBody(message: parsed, redactEmail: product.redactEmailAddresses)
        let logID = activityLog.start(kind: .createIssue, title: "\(product.owner)/\(product.repo) ← email")
        do {
            let number = try await createIssueOp(
                product.owner, product.repo, title, body, [Self.sourceEmailLabel], token)
            thread.issueRepoOwner = product.owner
            thread.issueRepoName = product.repo
            thread.issueNumber = number
            // Sentinel: the root message IS the issue body; mark it so it's never re-posted as a comment.
            message.githubCommentID = -1
            try? context.save()
            activityLog.finish(logID, status: .success, detail: "issue #\(number)")
        } catch {
            activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
        }
    }

    private func postComment(
        forReply message: MailMessage,
        thread: MailThread,
        product: ProductConfig,
        token: String
    ) async {
        // No re-filtering here either — coordinator is the single filtering point (see above).
        let commentBody = MailToGitHubMirror.buildCommentBody(
            message: message, redactEmail: product.redactEmailAddresses)
        let logID = activityLog.start(
            kind: .postComment,
            title: "\(product.owner)/\(product.repo)#\(thread.issueNumber)")
        do {
            let id = try await postCommentOp(
                product.owner, product.repo, thread.issueNumber, commentBody, token)
            message.githubCommentID = id
            try? context.save()
            activityLog.finish(logID, status: .success, detail: "comment #\(id)")
        } catch {
            activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
        }
    }

    /// Rebuilds the subset of `ParsedInboundMessage` that the body/title builders need,
    /// from a stored `MailMessage`. The noise-header fields (returnPath/autoSubmitted/precedence)
    /// are NOT persisted on `MailMessage`, so they read as nil here — which is exactly why this
    /// rebuilt view is never the noise-filtering point.
    private static func parsedView(of message: MailMessage) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: UInt32(max(0, message.uid)),
            folder: message.folder,
            uidValidity: UInt32(max(0, message.uidValidity)),
            messageID: message.messageID,
            inReplyTo: message.inReplyTo,
            references: [],
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            date: message.date,
            subject: message.subject,
            bodyPlain: message.bodyPlain,
            bodyHTML: message.bodyHTML,
            attachments: []
        )
    }
}

@Observable
final class MailToFeedbackMirrorHolder {
    let mirror: MailToFeedbackMirror?
    init(_ mirror: MailToFeedbackMirror?) { self.mirror = mirror }
}
