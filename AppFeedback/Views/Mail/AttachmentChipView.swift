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

    @State private var state: ChipState = .idle
    @State private var resolvedURL: URL? = nil

    enum ChipState: Equatable {
        case idle
        case downloading
        case ready
        case failed(message: String)
    }

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
        .disabled(downloader == nil || uid == 0)
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

    private func tap() {
        guard let downloader else { return }
        if let url = resolvedURL, FileManager.default.fileExists(atPath: url.path) {
            openFile(url)
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
                openFile(url)
            } catch {
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    private func openFile(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        // iOS: for v1 the URL is stored in state; richer share-sheet presentation
        // arrives with the iOS settings tasks (Task 11 / Task 12).
        _ = url
        #endif
    }
}
