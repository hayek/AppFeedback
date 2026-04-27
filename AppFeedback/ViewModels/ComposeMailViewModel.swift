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

    private let settings: MailSettings
    private let sender: any MailSending
    private let activityLog: ActivityLog
    private let passwordLoader: @Sendable () async -> String?
    private let composer = MailComposer()

    init(recipient: String,
         issue: FeedbackIssue,
         repoOwner: String,
         repoName: String,
         settings: MailSettings,
         sender: any MailSending,
         activityLog: ActivityLog,
         passwordLoader: @Sendable @escaping () async -> String? = { await KeychainService.loadSMTPPassword() }) {
        self.recipient = recipient
        self.issue = issue
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.settings = settings
        self.sender = sender
        self.activityLog = activityLog
        self.passwordLoader = passwordLoader
    }

    var canSend: Bool {
        settings.credentials != nil
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.length > 0
    }

    func send() async {
        guard let credentials = settings.credentials else { return }

        guard let password = await passwordLoader(), !password.isEmpty else {
            let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")
            activityLog.finish(id, status: .failure, detail: "No SMTP password configured.")
            return
        }

        let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")

        let issueURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/\(issue.number)")
        let context = PlaceholderContext(
            sender: credentials,
            recipient: recipient,
            appName: issue.appName ?? repoName,
            issueTitle: issue.title,
            issueURL: issueURL,
            date: Date()
        )
        let draft = DraftMessage(recipient: recipient, subject: subject, body: body)
        let email = composer.compose(draft: draft, context: context, template: settings.template)

        do {
            try await sender.send(email, using: credentials, password: password)
            activityLog.finish(id, status: .success, detail: nil)
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
        }
    }
}
#endif
