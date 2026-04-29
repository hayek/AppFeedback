import Foundation
import Observation
#if canImport(SwiftMail)
import SwiftMail

@MainActor
@Observable
final class ComposeMailViewModel {
    var subject: String = ""
    var body: NSAttributedString = NSAttributedString(string: "")

    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?

    private let store: MailAccountStore
    private let threadStore: MailThreadStore?
    private let sender: any MailSending
    private let activityLog: ActivityLog
    private let passwordLoader: @Sendable () async -> String?
    private let composer = MailComposer()

    init(recipient: String,
         issue: FeedbackIssue,
         repoOwner: String,
         repoName: String,
         store: MailAccountStore,
         threadStore: MailThreadStore? = nil,
         sender: any MailSending,
         activityLog: ActivityLog,
         inReplyTo: MailMessageHeaders? = nil,
         initialSubject: String? = nil,
         passwordLoader: @Sendable @escaping () async -> String? = { await KeychainService.loadSMTPPassword() }) {
        self.recipient = recipient
        self.issue = issue
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.store = store
        self.threadStore = threadStore
        self.sender = sender
        self.activityLog = activityLog
        self.inReplyTo = inReplyTo
        self.passwordLoader = passwordLoader
        if inReplyTo != nil {
            self.subject = initialSubject ?? MailSubject.replyPrefixed(issue.title)
        }
    }

    var canSend: Bool {
        currentCredentials() != nil
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.length > 0
    }

    var template: MailTemplate {
        guard let acc = store.account else { return .empty }
        return MailTemplate(headerHTML: acc.templateHeaderHTML,
                            footerHTML: acc.templateFooterHTML)
    }

    func placeholderContext(date: Date = Date()) -> PlaceholderContext {
        let creds = currentCredentials() ?? SMTPCredentials.defaults(for: .gmail)
        let issueURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/\(issue.number)")
        return PlaceholderContext(
            sender: creds,
            recipient: recipient,
            appName: issue.appName ?? repoName,
            issueTitle: issue.title,
            issueURL: issueURL,
            date: date
        )
    }

    private func currentCredentials() -> SMTPCredentials? {
        guard let acc = store.account, !acc.smtpUsername.isEmpty else { return nil }
        return SMTPCredentials(
            preset: acc.preset,
            host: acc.smtpHost,
            port: acc.smtpPort,
            username: acc.smtpUsername,
            senderName: acc.senderName
        )
    }

    func send() async {
        guard let credentials = currentCredentials() else { return }

        guard let password = await passwordLoader(), !password.isEmpty else {
            let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")
            activityLog.finish(id, status: .failure, detail: "No SMTP password configured.")
            return
        }

        let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")

        let messageID = MessageIDGenerator.generate(
            repoOwner: repoOwner,
            repoName: repoName,
            issueNumber: issue.number
        )
        let replyHeaders = ReplyHeaderBuilder.build(parent: inReplyTo, newMessageID: messageID)

        let context = placeholderContext()
        let draft = DraftMessage(recipient: recipient, subject: subject, body: body)
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template,
            messageID: messageID,
            replyHeaders: replyHeaders
        )

        do {
            try await sender.send(email, using: credentials, password: password)

            // Persist the outbound message to the thread store so it appears inline in the thread.
            threadStore?.recordOutbound(
                messageID: messageID,
                repoOwner: repoOwner,
                repoName: repoName,
                issueNumber: issue.number,
                from: credentials.username,
                fromName: credentials.senderName.isEmpty ? nil : credentials.senderName,
                to: [recipient],
                cc: [],
                subject: subject,
                bodyPlain: body.string,
                bodyHTML: nil,
                date: Date(),
                replyHeaders: replyHeaders
            )

            activityLog.finish(id, status: .success, detail: nil)
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
        }
    }
}
#endif
