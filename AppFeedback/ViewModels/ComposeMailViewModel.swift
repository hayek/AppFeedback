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
    /// Mirrors `FeedbackAttachmentValidator.maxCount`, which isn't public in the SDK package.
    static let maxAttachments = 3
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
    /// Saves a copy of the sent message to the IMAP Sent folder. Injected so it's mockable in tests
    /// and absent (nil) when no IMAP context is available. Only invoked for providers that don't
    /// auto-file SMTP sends (see `SMTPCredentials.Preset.autosavesSentMail`).
    private let sentAppender: (@Sendable (SwiftMail.Email) async throws -> Void)?
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
         passwordLoader: @Sendable @escaping (UUID) async -> String? = { @Sendable id in await KeychainService.loadSMTPPassword(for: id) },
         sentAppender: (@Sendable (SwiftMail.Email) async throws -> Void)? = nil) {
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
        self.sentAppender = sentAppender
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

    /// An outbound message that was already recorded but never made it out over SMTP. Re-sending
    /// reuses its Message-Id and threading headers, so `recordOutbound` dedupes onto the existing
    /// row — the thread shows the same reply flipping Failed → Sending… → Sent rather than growing
    /// a second copy per attempt.
    struct ResendTarget {
        let messageID: String
        let replyHeaders: ReplyHeaderBuilder.Output?

        init(message: MailMessage) {
            messageID = message.messageID
            let inReplyTo = message.inReplyTo
            let references = message.referencesAsArray
            replyHeaders = (inReplyTo == nil && references.isEmpty)
                ? nil
                : ReplyHeaderBuilder.Output(inReplyTo: inReplyTo, references: references)
        }
    }

    @discardableResult
    func send(resending target: ResendTarget? = nil) async -> Bool {
        guard let credentials = currentCredentials() else { return false }

        let messageID = target?.messageID ?? MessageIDGenerator.generate(
            repoOwner: repoOwner,
            repoName: repoName,
            issueNumber: issue.number
        )
        // A retry keeps the headers the first attempt was recorded with; rebuilding them from
        // `inReplyTo` would re-derive a *new* message's position in the thread.
        let replyHeaders = target?.replyHeaders
            ?? (target == nil ? ReplyHeaderBuilder.build(parent: inReplyTo, newMessageID: messageID) : nil)

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
            return false
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
            // Persist the send timestamp immediately (not just a transient model mutation): the
            // enrichment gate requires sentAt != nil, and the "Sent" badge must survive relaunch.
            threadStore?.markSent(messageID: messageID)
            tracker?.clear(messageID)

            await saveCopyToSentIfNeeded(email, credentials: credentials)

            if let mirror {
                Task { await mirror.mirrorOutbound(messageID: messageID) }
            }
            return true
        } catch {
            activityLog.finish(id, status: .failure, detail: error.localizedDescription)
            failureStore?.record(messageID, reason: error.localizedDescription)
            tracker?.clear(messageID)
            return false
        }
    }

    /// Saves a copy of the just-sent message to the IMAP Sent folder for providers whose SMTP
    /// submission doesn't auto-file one (iCloud, custom). Best-effort and non-fatal — the SMTP send
    /// already succeeded; a failed APPEND only means the reply won't appear in the server Sent folder
    /// (so Sent-enrichment can't surface its attachments). Skipped for Gmail/Outlook, which auto-save
    /// (appending there would duplicate the message in the user's Sent mailbox).
    private func saveCopyToSentIfNeeded(_ email: SwiftMail.Email, credentials: SMTPCredentials) async {
        guard !credentials.preset.autosavesSentMail, let sentAppender else { return }
        do {
            try await sentAppender(email)
        } catch {
            print("[ComposeMailViewModel] append-to-Sent failed (non-fatal): \(error)")
        }
    }

    // MARK: - Attachment ingestion + validation

    func ingestURLs(_ urls: [URL]) {
        var inputs: [RawAttachmentInput] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            inputs.append(RawAttachmentInput(
                filename: url.lastPathComponent,
                mimeType: mimeType(for: url),
                data: data
            ))
        }
        ingest(inputs)
    }

    /// Preprocesses and pins picked bytes to the compose strip, whatever picked them —
    /// the Files importer, a macOS drop, or the iOS photo picker.
    func ingest(_ inputs: [RawAttachmentInput]) {
        var failed: [String] = []
        for input in inputs {
            guard pendingAttachments.count < Self.maxAttachments else { break }
            // Preprocess images (EXIF/GPS strip, HEIC→JPEG) before pinning to PendingAttachment.
            // Matters most for camera-roll picks, which carry location metadata.
            let modeled = FeedbackAttachment(filename: input.filename, mimeType: input.mimeType, data: input.data)
            let processed: FeedbackAttachment
            do {
                processed = try ImagePreprocessor.process(modeled)
            } catch {
                // Named, not skipped: to someone who just tapped a photo, a silent drop
                // reads as a broken button.
                failed.append(input.filename)
                continue
            }
            pendingAttachments.append(PendingAttachment(
                filename: processed.filename,
                mimeType: processed.mimeType,
                data: processed.data
            ))
        }
        revalidateAttachments()
        // A validator complaint about what *did* land is the more actionable message,
        // so it wins when both happen.
        if attachmentError == nil, !failed.isEmpty {
            attachmentError = "Couldn\u{2019}t read \(failed.joined(separator: ", "))."
        }
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
        let collector = URLCollector()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    collector.append(url)
                } else if let url = item as? URL {
                    collector.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [collector] in
            self.ingestURLs(collector.urls)
        }
    }
    #endif

    // MARK: -

    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        var urls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return _urls
        }
        func append(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            _urls.append(url)
        }
    }
}
#endif
