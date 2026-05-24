#if canImport(SwiftMail)
import SwiftUI
import UniformTypeIdentifiers
import AppFeedbackCore

/// In-place compose surface used by MailThreadView (replies) and IssueCardView (first-time
/// emails). Hydrates subject/body from MailDraftStore on appear, persists edits back so
/// drafts survive thread collapse and LazyVStack recycling, and clears the draft on Send
/// or explicit Discard.
struct InlineReplyView: View {
    let key: DraftKey
    let request: ComposeRequest
    var onClose: () -> Void

    @Environment(MailAccountStore.self) private var store
    @Environment(MailSettingsStore.self) private var settingsStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(MailDraftStore.self) private var drafts
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var viewModel: ComposeMailViewModel?
    @State private var headerPreview: String = ""
    @State private var footerPreview: String = ""
    @State private var showsDiscardConfirm: Bool = false
    @FocusState private var bodyFocused: Bool

    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var attachmentError: String?
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            Divider()
            if let vm = viewModel {
                if !hasCredentials {
                    missingCredentialsBanner
                }
                ComposeFormCore(
                    vm: vm,
                    headerPreview: headerPreview,
                    footerPreview: footerPreview,
                    sendLabel: "Send",
                    onSend: { send(vm: vm) },
                    onDiscard: { attemptDiscard(vm: vm) },
                    discardLabel: "Discard",
                    bodyFocus: $bodyFocused
                )
                .onAppear {
                    refreshPreviews(vm: vm)
                    bodyFocused = true
                }
                .onChange(of: vm.subject) { _, newValue in
                    drafts.setSubject(newValue, for: key)
                }
                .onChange(of: vm.body) { _, newValue in
                    drafts.setBody(newValue.string, for: key)
                }
                .onChange(of: settingsStore.settings.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
                .onChange(of: settingsStore.settings.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
                #if os(macOS)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers)
                    return true
                }
                #endif
                .fileImporter(
                    isPresented: $showFileImporter,
                    allowedContentTypes: [.png, .jpeg, .heic, .gif, .plainText, .json, .pdf],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result { ingestURLs(urls) }
                }

                attachmentStripSection(vm: vm)

            } else {
                ProgressView().padding(12).task { setupViewModel() }
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, 6)
        .alert("Discard draft?", isPresented: $showsDiscardConfirm) {
            Button("Discard", role: .destructive) {
                drafts.clear(key)
                onClose()
            }
            Button("Keep", role: .cancel) { }
        } message: {
            Text("This will discard the text you've typed.")
        }
    }

    // MARK: - Attachment strip + paperclip

    @ViewBuilder
    private func attachmentStripSection(vm: ComposeMailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.plain)
                .disabled(pendingAttachments.count >= 3)
                .padding(.leading, 12)
                .padding(.vertical, 6)

                Spacer()
            }

            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { att in
                            HStack(spacing: 6) {
                                Image(systemName: att.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(att.filename).font(.caption).lineLimit(1)
                                Button {
                                    pendingAttachments.removeAll { $0.id == att.id }
                                    revalidateAttachments(vm: vm)
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, 12)
            }

            if let attachmentError {
                Text(attachmentError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: request.inReplyTo == nil ? "envelope" : "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                if let vm = viewModel { attemptDiscard(vm: vm) } else { onClose() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close composer")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var headerTitle: String {
        let verb = request.inReplyTo == nil ? "New email to" : "Reply to"
        return "\(verb) \(request.recipient)"
    }

    private var hasCredentials: Bool {
        guard let id = request.senderAccountID ?? store.defaultSender?.id,
              let acc = store.account(id: id) else { return false }
        return !acc.smtpUsername.isEmpty
    }

    private var missingCredentialsBanner: some View {
        HStack {
            Image(systemName: "envelope.badge")
            Text("Configure email in Settings → Email to send from this app.")
            Spacer()
            #if os(macOS)
            Button("Open Settings…") {
                openWindow(id: "settings")
            }
            #endif
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }

    private var currentTemplate: MailTemplate {
        MailTemplate(
            headerHTML: settingsStore.settings.templateHeaderHTML,
            footerHTML: settingsStore.settings.templateFooterHTML
        )
    }

    private func refreshPreviews(vm: ComposeMailViewModel) {
        let context = vm.placeholderContext()
        let composer = MailComposer()
        let template = currentTemplate
        headerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.headerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        footerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.footerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attemptDiscard(vm: ComposeMailViewModel) {
        if vm.body.length > 0 {
            showsDiscardConfirm = true
        } else {
            drafts.clear(key)
            onClose()
        }
    }

    private func send(vm: ComposeMailViewModel) {
        Task {
            await vm.send()
            drafts.clear(key)
            onClose()
        }
    }

    private func setupViewModel() {
        let vm = ComposeMailViewModel(
            recipient: request.recipient,
            issue: request.issue,
            repoOwner: request.repoOwner,
            repoName: request.repoName,
            store: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            tracker: outboundTracker,
            failureStore: outboundFailures,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror,
            inReplyTo: request.inReplyTo,
            initialSubject: request.subjectOverride,
            senderAccountID: request.senderAccountID ?? store.defaultSender?.id ?? UUID()
        )

        if let existing = drafts.draft(for: key) {
            if !existing.subject.isEmpty { vm.subject = existing.subject }
            if !existing.body.isEmpty { vm.body = NSAttributedString(string: existing.body) }
        }

        viewModel = vm
    }

    // MARK: - Attachment ingestion + validation

    private func ingestURLs(_ urls: [URL]) {
        guard let vm = viewModel else { return }
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
        revalidateAttachments(vm: vm)
    }

    private func revalidateAttachments(vm: ComposeMailViewModel) {
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
        vm.pendingAttachments = pendingAttachments
        vm.attachmentError = attachmentError
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
    private func handleDrop(providers: [NSItemProvider]) {
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
        group.notify(queue: .main) { ingestURLs(urls) }
    }
    #endif
}
#endif
