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
        // Try with the cached file first, then force a fresh download. The retry catches
        // stale corrupt files left by a pre-decode-fix download (raw base64 written as
        // an image file) — forceRedownload deletes the stale file and refetches.
        for force in [false, true] {
            if let thumb = await fetch(downloader: downloader, keyURL: keyURL, force: force) {
                thumbnail = thumb
                return
            }
        }
        loadFailed = true
    }

    private func fetch(downloader: AttachmentDownloader, keyURL: URL, force: Bool) async -> PlatformImage? {
        do {
            let path = try await downloader.download(
                messageID: attachment.messageID,
                uid: uid,
                folder: folder,
                partID: attachment.partID,
                filename: attachment.filename.isEmpty ? "inline-\(attachment.partID).img" : attachment.filename,
                folderBookmark: folderBookmark,
                forceRedownload: force
            )
            return await thumbnailCache.thumbnail(for: keyURL, localPath: path)
        } catch {
            return nil
        }
    }
}
