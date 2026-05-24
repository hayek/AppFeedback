import Foundation
import Observation
import UniformTypeIdentifiers
#if canImport(SwiftMail)
import SwiftMail
import AppFeedbackCore
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ComposeMailViewModel {
    var subject: String = ""
    var body: NSAttributedString = NSAttributedString(string: "")
    var pendingAttachments: [PendingAttachment] = []
    var attachmentError: String? = nil

    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let senderAccountID: UUID
    let inReplyTo: MailMessageHeaders?

    private let store: MailAccountStore
    private let settingsStore: MailSettingsStore
    private let threadStore: MailThreadStore?
    private let tracker: OutboundSendTracker?
    private let failureStore: OutboundFailureStore?
    private let sender: any MailSending
    private let activityLog: ActivityLog
    private let mirror: MailToGitHubMirror?
    private let passwordLoader: @Sendable (UUID) async -> String?
    private let composer = MailComposer()

    init(recipient: String,
         issue: FeedbackIssue,
         repoOwner: String,
         repoName: String,
         store: MailAccountStore,
         settingsStore: MailSettingsStore,
         threadStore: MailThreadStore? = nil,
         tracker: OutboundSendTracker? = nil,
         failureStore: OutboundFailureStore? = nil,
         sender: any MailSending,
         activityLog: ActivityLog,
         mirror: MailToGitHubMirror? = nil,
         inReplyTo: MailMessageHeaders? = nil,
         initialSubject: String? = nil,
         senderAccountID: UUID,
         passwordLoader: @Sendable @escaping (UUID) async -> String? = { @Sendable id in await KeychainService.loadSMTPPassword(for: id) }) {
        self.recipient = recipient
        self.issue = issue
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.senderAccountID = senderAccountID
        self.store = store
        self.settingsStore = settingsStore
        self.threadStore = threadStore
        self.tracker = tracker
        self.failureStore = failureStore
        self.sender = sender
        self.activityLog = activityLog
        self.mirror = mirror
        self.inReplyTo = inReplyTo
        self.passwordLoader = passwordLoader
        if inReplyTo != nil {
            self.subject = initialSubject ?? MailSubject.replyPrefixed(issue.title)
        } else if let initialSubject {
            self.subject = initialSubject
        } else {
            let template = settingsStore.settings.defaultSubjectTemplate
            if !template.isEmpty {
                self.subject = composer.applyPlaceholders(template, context: placeholderContext())
            }
        }
    }

    var canSend: Bool {
        currentCredentials() != nil
            && !subject.trimmingCharacters(in: .whitespaces).isEmpty
            && body.length > 0
            && attachmentError == nil
    }

    var template: MailTemplate {
        MailTemplate(
            headerHTML: settingsStore.settings.templateHeaderHTML,
            footerHTML: settingsStore.settings.templateFooterHTML
        )
    }

    func placeholderContext(date: Date = Date()) -> PlaceholderContext {
        let creds = currentCredentials() ?? SMTPCredentials.defaults(for: .gmail)
        let issueURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/issues/\(issue.number)")
        let body = issue.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlaceholderContext(
            sender: creds,
            recipient: recipient,
            appName: issue.appName ?? repoName,
            issueTitle: issue.title,
            issueURL: issueURL,
            feedbackBody: body.isEmpty ? nil : body,
            feedbackAttachments: issue.attachments,
            date: date
        )
    }

    private func currentCredentials() -> SMTPCredentials? {
        guard let acc = store.account(id: senderAccountID), !acc.smtpUsername.isEmpty else { return nil }
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

        let messageID = MessageIDGenerator.generate(
            repoOwner: repoOwner,
            repoName: repoName,
            issueNumber: issue.number
        )
        let replyHeaders = ReplyHeaderBuilder.build(parent: inReplyTo, newMessageID: messageID)

        let recordedMessage = threadStore?.recordOutbound(
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
            accountID: senderAccountID,
            replyHeaders: replyHeaders
        )
        // Retry case: first attempt may have left a persisted failure; clear it so the
        // shimmer is the only visible state during this send.
        failureStore?.clear(messageID)
        tracker?.markSending(messageID)

        let id = activityLog.start(kind: .sendEmail, title: "to \(recipient)")

        guard let password = await passwordLoader(senderAccountID), !password.isEmpty else {
            let detail = "No SMTP password configured."
            activityLog.finish(id, status: .failure, detail: detail)
            failureStore?.record(messageID, reason: detail)
            tracker?.clear(messageID)
            return
        }

        let context = placeholderContext()
        let draft = DraftMessage(recipient: recipient, subject: subject, body: body)
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template,
            messageID: messageID,
            replyHeaders: replyHeaders,
            attachments: pendingAttachments
        )

        do {
            try await sender.send(email, using: credentials, password: password)
            activityLog.finish(id, status: .success, detail: nil)
            recordedMessage?.sentAt = Date()
            tracker?.clear(messageID)

            if let mirror {
                Task { await mirror.mirrorOutbound(messageID: messageID) }
            }
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
            failureStore?.record(messageID, reason: error.localizedDescription)
            tracker?.clear(messageID)
        }
    }

    // MARK: - Attachment ingestion + validation

    func ingestURLs(_ urls: [URL]) {
        for url in urls {
            guard pendingAttachments.count < 3 else { break }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = mimeType(for: url)
            pendingAttachments.append(PendingAttachment(
                filename: url.lastPathComponent,
                mimeType: mime,
                data: data
            ))
        }
        revalidateAttachments()
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
        revalidateAttachments()
    }

    func revalidateAttachments() {
        let modeled = pendingAttachments.map {
            FeedbackAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        do {
            try FeedbackAttachmentValidator.validate(modeled)
            attachmentError = nil
        } catch let err as FeedbackAttachmentError {
            attachmentError = attachmentErrorMessage(for: err)
        } catch {
            attachmentError = "Attachment error: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private func attachmentErrorMessage(for error: FeedbackAttachmentError) -> String {
        switch error {
        case .tooManyAttachments(let limit, _):
            return "At most \(limit) attachments."
        case .fileTooLarge(let name, _, let limit):
            return "\(name) exceeds \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .totalSizeTooLarge(_, let limit):
            return "Total exceeds \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .unsupportedMimeType(let name, _):
            return "\(name): unsupported type."
        case .imageProcessingFailed(let name):
            return "\(name) could not be processed."
        }
    }

    // MARK: - Drop (macOS only)

    #if os(macOS)
    func handleDrop(providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.ingestURLs(urls) }
    }
    #endif
}
#endif
