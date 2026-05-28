// AppFeedback/Views/Mail/MailAttachmentThumbnailView.swift
import SwiftUI

struct MailAttachmentThumbnailView: View {
    let attachment: MailAttachment
    let uid: UInt32
    let folder: String
    let folderBookmark: Data?
    let downloader: AttachmentDownloader?
    let thumbnailCache: ThumbnailCache
    let onTap: () -> Void

    @State private var thumbnail: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Button(action: onTap) {
            Group {
                if let thumb = thumbnail {
                    Image(platformImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 120, maxHeight: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                        if loadFailed {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 80, height: 80)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let downloader, uid > 0 else { return }
        let key = "\(attachment.messageID)/\(attachment.partID)"
        let keyURL = URL(string: "imap-inline:///\(key)")!
        if let cached = thumbnailCache.cached(for: keyURL) {
            thumbnail = cached
            return
        }
        do {
            let path = try await downloader.download(
                messageID: attachment.messageID,
                uid: uid,
                folder: folder,
                partID: attachment.partID,
                filename: attachment.filename.isEmpty ? "inline-\(attachment.partID).img" : attachment.filename,
                folderBookmark: folderBookmark
            )
            if let thumb = await thumbnailCache.thumbnail(for: keyURL, localPath: path) {
                thumbnail = thumb
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}
