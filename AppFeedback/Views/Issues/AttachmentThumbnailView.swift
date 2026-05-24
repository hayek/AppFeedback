// AppFeedback/Views/Issues/AttachmentThumbnailView.swift
import SwiftUI

struct AttachmentThumbnailView: View {
    let attachment: FeedbackAttachmentRef
    let downloader: FeedbackAttachmentDownloader?
    let thumbnailCache: ThumbnailCache
    let onTap: () -> Void

    @State private var thumbnail: PlatformImage?
    @State private var loadFailed = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                if let thumb = thumbnail {
                    Image(platformImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if loadFailed {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let downloader else { return }
        if let cached = thumbnailCache.cached(for: attachment.url) {
            thumbnail = cached
            return
        }
        do {
            let path = try await downloader.download(url: attachment.url, filename: attachment.filename)
            thumbnail = await thumbnailCache.thumbnail(for: attachment.url, localPath: path)
        } catch {
            loadFailed = true
        }
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}
