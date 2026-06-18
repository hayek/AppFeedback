import Foundation
#if canImport(SwiftMail)
import SwiftMail

/// Sends release-notification emails — one per recipient, threaded into one of that
/// recipient's existing feedback threads — by reusing the app's normal mail send path
/// (`ComposeMailViewModel.send()`), and records each send via `VersionStore.recordSent`.
@MainActor
final class ReleaseNotificationService {
    struct Dependencies {
        let accountStore: MailAccountStore
        let settingsStore: MailSettingsStore
        let threadStore: MailThreadStore
        let outboundTracker: OutboundSendTracker
        let outboundFailures: OutboundFailureStore
        let sender: any MailSending
        let activityLog: ActivityLog
        let mirror: MailToGitHubMirror?
        let passwordLoader: @Sendable (UUID) async -> String?

        init(accountStore: MailAccountStore,
             settingsStore: MailSettingsStore,
             threadStore: MailThreadStore,
             outboundTracker: OutboundSendTracker,
             outboundFailures: OutboundFailureStore,
             sender: any MailSending,
             activityLog: ActivityLog,
             mirror: MailToGitHubMirror?,
             passwordLoader: @escaping @Sendable (UUID) async -> String? = { @Sendable id in await KeychainService.loadSMTPPassword(for: id) }) {
            self.accountStore = accountStore
            self.settingsStore = settingsStore
            self.threadStore = threadStore
            self.outboundTracker = outboundTracker
            self.outboundFailures = outboundFailures
            self.sender = sender
            self.activityLog = activityLog
            self.mirror = mirror
            self.passwordLoader = passwordLoader
        }
    }

    private let versionStore: VersionStore
    private let deps: Dependencies

    init(versionStore: VersionStore, deps: Dependencies) {
        self.versionStore = versionStore
        self.deps = deps
    }

    /// A release cannot be sent without a configured sending account.
    var hasSendingAccount: Bool { deps.accountStore.defaultSender != nil }

    /// Pure: pick the feedback whose thread is most recently active, else the lowest number.
    nonisolated static func chooseFeedbackNumber(candidates: [Int], lastActivityByFeedback: [Int: Date]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if let best = candidates
            .compactMap({ n in lastActivityByFeedback[n].map { (n, $0) } })
            .max(by: { $0.1 < $1.1 }) { return best.0 }
        return candidates.min()
    }

    /// Sends to each selected recipient sequentially; isolated failures are recorded, not fatal.
    /// `onProgress` reports (completed, total).
    func send(repo: ProductConfig,
              version: ProjectVersion,
              recipients: [ReleaseRecipient],
              feedback: [FeedbackIssue],
              template: ReleaseEmailTemplate,
              appName: String,
              onProgress: @escaping (Int, Int) -> Void) async {
        guard let account = deps.accountStore.defaultSender else { return }
        let feedbackByNumber = Dictionary(feedback.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })

        var done = 0
        for recipient in recipients {
            defer { done += 1; onProgress(done, recipients.count) }

            // Compute the most recent thread activity for each of this recipient's feedbacks.
            let lastActivity = recipient.feedbackNumbers.reduce(into: [Int: Date]()) { acc, n in
                let threads = deps.threadStore.threads(forIssue:
                    (owner: repo.owner, repo: repo.repo, number: n, title: feedbackByNumber[n]?.title ?? ""))
                if let latest = threads.map(\.lastMessageAt).max() { acc[n] = latest }
            }

            guard let chosen = Self.chooseFeedbackNumber(candidates: recipient.feedbackNumbers, lastActivityByFeedback: lastActivity),
                  let chosenFeedback = feedbackByNumber[chosen] else {
                versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                    recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                    threadIssueNumber: 0, status: .failed, errorDetail: "No feedback to thread into")
                continue
            }

            let rendered = template.render(appName: appName, version: version.name,
                whatsNew: version.changelog, feedbackNumbers: recipient.feedbackNumbers)

            let inReplyTo = latestHeaders(repo: repo, feedbackNumber: chosen, title: chosenFeedback.title)
            let vm = ComposeMailViewModel(
                recipient: recipient.email,
                issue: chosenFeedback,
                repoOwner: repo.owner,
                repoName: repo.repo,
                store: deps.accountStore,
                settingsStore: deps.settingsStore,
                threadStore: deps.threadStore,
                tracker: deps.outboundTracker,
                failureStore: deps.outboundFailures,
                sender: deps.sender,
                activityLog: deps.activityLog,
                mirror: deps.mirror,
                inReplyTo: inReplyTo,
                initialSubject: rendered.subject,
                senderAccountID: account.id,
                passwordLoader: deps.passwordLoader)
            vm.subject = rendered.subject
            vm.body = NSAttributedString(string: rendered.body)
            let didSend = await vm.send()

            versionStore.recordSent(repoOwner: repo.owner, repoName: repo.repo, versionName: version.name,
                recipientEmail: recipient.email, feedbackNumbers: recipient.feedbackNumbers,
                threadIssueNumber: chosen, status: didSend ? .sent : .failed,
                errorDetail: didSend ? nil : "Email send failed")
        }
    }

    /// Reply headers for the newest message in the most recently active thread for `feedbackNumber`,
    /// so the release email threads into that conversation (mirrors `MailThreadView.beginReply`).
    /// Returns `nil` when there is no existing thread/message — the email still sends as a fresh
    /// message and is recorded against the chosen feedback.
    private func latestHeaders(repo: ProductConfig, feedbackNumber: Int, title: String) -> MailMessageHeaders? {
        let threads = deps.threadStore.threads(forIssue:
            (owner: repo.owner, repo: repo.repo, number: feedbackNumber, title: title))
        guard let thread = threads.max(by: { $0.lastMessageAt < $1.lastMessageAt }),
              let last = thread.sortedDedupedMessages.last else { return nil }
        return MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray)
    }
}
#endif
