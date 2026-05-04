import Foundation
import SwiftData
import Observation

/// Bridges email traffic into GitHub issue comments. When a repo has
/// `mirrorEmailsToGitHub` enabled, every outbound and inbound mail message tied to an
/// issue is posted as a comment so the issue thread carries a complete conversation
/// backup independent of any user's mailbox.
///
/// Failure handling: never throws to the caller. Surfaces success/failure exclusively
/// via `ActivityLog`. The `githubCommentID` field on `MailMessage` is the dedupe key —
/// once set, that message is considered mirrored and never re-posted.
@MainActor
@Observable
final class MailToGitHubMirror {
    private let context: ModelContext
    private let repoStore: RepoStore
    private let activityLog: ActivityLog
    private let poster: GitHubCommentPoster
    private let tokenLoader: @Sendable (RepoConfig) async -> String?

    init(
        context: ModelContext,
        repoStore: RepoStore,
        activityLog: ActivityLog,
        poster: GitHubCommentPoster,
        tokenLoader: @Sendable @escaping (RepoConfig) async -> String? = { await KeychainService.load(for: $0) }
    ) {
        self.context = context
        self.repoStore = repoStore
        self.activityLog = activityLog
        self.poster = poster
        self.tokenLoader = tokenLoader
    }

    // MARK: - Public API

    func mirrorOutbound(messageID: String) async {
        guard let message = findMessage(byMessageID: messageID),
              message.githubCommentID == nil,
              let thread = message.thread,
              thread.issueNumber > 0,
              let repo = configuredRepo(forThread: thread) else { return }
        await mirror(message: message, thread: thread, repo: repo)
    }

    func mirrorPendingInbound() async {
        let inboundRaw = MailMessage.Direction.inbound.rawValue
        let descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate {
                $0.directionRaw == inboundRaw && $0.githubCommentID == nil
            }
        )
        let pending = (try? context.fetch(descriptor)) ?? []

        // Group by (owner, repo) so we look up each RepoConfig once instead of per-message.
        var repoCache: [String: RepoConfig?] = [:]
        for message in pending {
            guard let thread = message.thread, thread.issueNumber > 0 else { continue }
            let key = "\(thread.issueRepoOwner)/\(thread.issueRepoName)"
            let repo = repoCache[key] ?? configuredRepo(forThread: thread)
            repoCache[key] = repo
            guard let repo, repo.mirrorEmailsToGitHub else { continue }
            await mirror(message: message, thread: thread, repo: repo)
        }
    }

    // MARK: - Core

    private func mirror(message: MailMessage, thread: MailThread, repo: RepoConfig) async {
        guard repo.mirrorEmailsToGitHub else { return }

        let body = Self.buildCommentBody(message: message, redactEmail: repo.redactEmailAddresses)
        let logTitle = "\(repo.owner)/\(repo.repo)#\(thread.issueNumber)"
        let logID = activityLog.start(kind: .postComment, title: logTitle)

        guard let token = await tokenLoader(repo), !token.isEmpty else {
            activityLog.finish(logID, status: .failure, detail: "No GitHub token available")
            return
        }

        do {
            let commentID = try await poster.postComment(
                owner: repo.owner,
                repo: repo.repo,
                issueNumber: thread.issueNumber,
                body: body,
                token: token
            )
            message.githubCommentID = commentID
            try? context.save()
            activityLog.finish(logID, status: .success, detail: "comment #\(commentID)")
        } catch {
            activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func configuredRepo(forThread thread: MailThread) -> RepoConfig? {
        repoStore.repos.first(where: {
            $0.owner == thread.issueRepoOwner && $0.repo == thread.issueRepoName
        })
    }

    private func findMessage(byMessageID id: String) -> MailMessage? {
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Body builder

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func buildCommentBody(message: MailMessage, redactEmail: Bool) -> String {
        let directionGlyph = message.direction == .inbound ? "📥" : "📤"
        let directionLabel = message.direction == .inbound ? "Reply from" : "Sent to"
        let address = message.direction == .inbound
            ? message.fromAddress
            : message.toAddresses.first ?? message.fromAddress
        let displayAddress = redactEmail ? Self.redact(address) : address
        let dateString = Self.isoFormatter.string(from: message.date)

        let stripped = HTMLSanitizer.stripQuotedReply(message.bodyPlain)
        let bodyText = stripped.cleaned.isEmpty ? message.bodyPlain : stripped.cleaned
        let quoted = bodyText
            .components(separatedBy: "\n")
            .map { "> " + $0 }
            .joined(separator: "\n")

        return """
        **\(directionGlyph) \(directionLabel) \(displayAddress)** · \(dateString)

        \(quoted)

        ---
        _Mirrored automatically by Feedbeek_
        """
    }

    /// Redacts an email's local-part to `a***@host.tld`. Keeps the first character so
    /// the recipient is still recognisable while not publishing the full address.
    static func redact(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first else { return email }
        return "\(first)***@\(parts[1])"
    }
}

@Observable
final class MailToGitHubMirrorHolder {
    let mirror: MailToGitHubMirror?
    init(_ mirror: MailToGitHubMirror?) { self.mirror = mirror }
}
