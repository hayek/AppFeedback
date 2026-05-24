import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AttachmentChipView: View {
    let attachment: MailAttachment
    let uid: UInt32
    let folder: String
    let downloader: AttachmentDownloader?
    let folderBookmark: Data?

    let feedbackDownloader: FeedbackAttachmentDownloader?
    let feedbackOnTap: (() -> Void)?

    @State private var state: ChipState = .idle
    @State private var resolvedURL: URL? = nil

    @Environment(QuickLookPresenter.self) private var quickLook

    enum ChipState: Equatable {
        case idle
        case downloading
        case ready
        case failed(message: String)
    }

    // MARK: - Inits

    init(attachment: MailAttachment, uid: UInt32, folder: String, downloader: AttachmentDownloader?, folderBookmark: Data?) {
        self.attachment = attachment
        self.uid = uid
        self.folder = folder
        self.downloader = downloader
        self.folderBookmark = folderBookmark
        self.feedbackDownloader = nil
        self.feedbackOnTap = nil
    }

    init(feedbackAttachment: FeedbackAttachmentRef, downloader: FeedbackAttachmentDownloader?, onTap: @escaping () -> Void) {
        self.attachment = MailAttachment(
            messageID: "",
            partID: "",
            filename: feedbackAttachment.filename,
            mimeType: feedbackAttachment.mimeType,
            sizeBytes: feedbackAttachment.sizeBytes ?? 0
        )
        self.uid = 0
        self.folder = ""
        self.downloader = nil
        self.folderBookmark = nil
        self.feedbackDownloader = downloader
        self.feedbackOnTap = onTap
    }

    // MARK: - Body

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                icon
                Text(attachment.filename).font(.caption)
                if attachment.sizeBytes > 0 {
                    Text(byteSize).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.gray.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(feedbackOnTap == nil && (downloader == nil || uid == 0))
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .idle:
            Image(systemName: "paperclip")
        case .downloading:
            ProgressView().scaleEffect(0.6)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private var byteSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file)
    }

    // MARK: - Tap

    private func tap() {
        if let onTap = feedbackOnTap {
            onTap()
            return
        }
        guard let downloader else { return }
        if let url = resolvedURL, FileManager.default.fileExists(atPath: url.path) {
            quickLook.present(urls: [url])
            return
        }
        state = .downloading
        Task {
            do {
                let url = try await downloader.download(
                    messageID: attachment.messageID,
                    uid: uid,
                    folder: folder,
                    partID: attachment.partID,
                    filename: attachment.filename,
                    folderBookmark: folderBookmark
                )
                resolvedURL = url
                state = .ready
                quickLook.present(urls: [url])
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        }
    }
}
