// AppFeedback/Views/Issues/AttachmentStripView.swift
import SwiftUI

struct AttachmentStripView: View {
    let attachments: [FeedbackAttachmentRef]

    @Environment(QuickLookPresenter.self) private var quickLook
    @Environment(FeedbackAttachmentDownloaderHolder.self) private var downloaderHolder
    @Environment(ThumbnailCache.self) private var thumbnailCache

    private var images: [FeedbackAttachmentRef] { attachments.filter(\.isImage) }
    private var files:  [FeedbackAttachmentRef] { attachments.filter { !$0.isImage } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { att in
                    AttachmentThumbnailView(
                        attachment: att,
                        downloader: downloaderHolder.downloader,
                        thumbnailCache: thumbnailCache,
                        onTap: { presentAll(startingAt: att) }
                    )
                }
                // H3 will replace this placeholder with AttachmentChipView(feedbackAttachment:downloader:onTap:)
                ForEach(files) { att in
                    Text(att.filename)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func presentAll(startingAt target: FeedbackAttachmentRef) {
        guard let downloader = downloaderHolder.downloader else { return }
        Task {
            var localURLs: [URL] = []
            var startIdx = 0
            for (i, att) in attachments.enumerated() {
                do {
                    let path = try await downloader.download(url: att.url, filename: att.filename)
                    localURLs.append(path)
                    if att.id == target.id { startIdx = i }
                } catch {
                    // Skip files that failed; keep gallery intact for the rest.
                }
            }
            await MainActor.run {
                quickLook.present(urls: localURLs, startingAt: startIdx)
            }
        }
    }
}
