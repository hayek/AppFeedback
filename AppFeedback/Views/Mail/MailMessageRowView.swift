import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MailMessageRowView: View {
    let message: MailMessage

    @Environment(MailSettingsStore.self) private var settingsStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(AttachmentDownloaderHolder.self) private var downloaderHolder: AttachmentDownloaderHolder?
    @Environment(QuickLookPresenter.self) private var quickLook
    @Environment(ThumbnailCache.self) private var thumbnailCache

    private var isUnread: Bool { threadStore.isUnread(message) }

    private var sendState: MailSendState? {
        guard message.direction == .outbound else { return nil }
        // In-flight tracker wins so a retry's "sending…" overrides any stale persisted state.
        if outboundTracker.isSending(message.messageID) { return .sending }
        if let reason = outboundFailures.reason(for: message.messageID) { return .failed(reason) }
        if message.sentAt != nil { return .sent }
        return nil
    }

    @State private var showFull: Bool = false
    @State private var stripped: HTMLSanitizer.StrippedBody = .init(cleaned: "", full: "")

    private var attachments: [MailAttachment] { message.dedupedAttachments }
    private var inlineImages: [MailAttachment] { attachments.filter(\.isInlineImage) }
    private var regularAttachments: [MailAttachment] { attachments.filter { !$0.isInlineImage } }

    private var unreadDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .opacity(isUnread ? 1 : 0)
            .accessibilityLabel("New message")
            .accessibilityHidden(!isUnread)
    }

    private var senderLine: String {
        if let name = message.fromName, !name.isEmpty {
            return "\(name) (\(message.fromAddress))"
        }
        return message.fromAddress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
                .overlay(alignment: .leading) {
                    unreadDot
                        .offset(x: -12)
                        .allowsHitTesting(false)
                }
            bodyView
            if !attachments.isEmpty {
                attachmentsRow
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isUnread { threadStore.markSeen(message.messageID) }
        }
        .task(id: message.messageID) {
            stripped = HTMLSanitizer.stripQuotedReply(message.bodyPlain)
        }
    }

    private var header: some View {
        HStack {
            Menu {
                Button("Copy address") { copyFromAddress() }
            } label: {
                Text("From: \(senderLine)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .contextMenu {
                Button("Copy address") { copyFromAddress() }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ToggleableDateText(date: message.date)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                if let sendState = sendState {
                    MailSendStatusBadge(state: sendState)
                }
            }
            .lineLimit(1)
            .animation(.easeInOut(duration: 0.25), value: sendState)
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        if !message.subject.isEmpty {
            IssueTitleText(text: message.subject)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        IssueBodyText(plainBody: showFull ? stripped.full : stripped.cleaned)
        if stripped.hasQuoted {
            Button(showFull ? "Show cleaned text" : "Show full text") {
                showFull.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func copyFromAddress() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.fromAddress, forType: .string)
        #else
        UIPasteboard.general.string = message.fromAddress
        #endif
    }

    @ViewBuilder
    private var attachmentsRow: some View {
        if !inlineImages.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(inlineImages) { att in
                        MailAttachmentThumbnailView(
                            attachment: att,
                            accountID: message.accountID,
                            uid: UInt32(max(0, message.uid)),
                            uidValidity: UInt32(max(0, message.uidValidity)),
                            folder: message.folder,
                            folderBookmark: settingsStore.settings.attachmentFolderBookmark,
                            downloader: downloaderHolder?.downloader,
                            thumbnailCache: thumbnailCache,
                            onTap: { presentInlineGallery(startingAt: att) }
                        )
                    }
                }
            }
        }
        if !regularAttachments.isEmpty {
            HStack(spacing: 6) {
                ForEach(regularAttachments) { attachment in
                    AttachmentChipView(
                        attachment: attachment,
                        accountID: message.accountID,
                        uid: UInt32(max(0, message.uid)),
                        uidValidity: UInt32(max(0, message.uidValidity)),
                        folder: message.folder,
                        downloader: downloaderHolder?.downloader,
                        folderBookmark: settingsStore.settings.attachmentFolderBookmark
                    )
                }
            }
        }
    }

    private func presentInlineGallery(startingAt target: MailAttachment) {
        guard let downloader = downloaderHolder?.downloader else { return }
        Task {
            var localURLs: [URL] = []
            var startIdx = 0
            for (i, att) in inlineImages.enumerated() {
                do {
                    let url = try await downloader.download(
                        messageID: att.messageID,
                        accountID: message.accountID,
                        uid: UInt32(max(0, message.uid)),
                        uidValidity: UInt32(max(0, message.uidValidity)),
                        folder: message.folder,
                        partID: att.partID,
                        filename: att.filename.isEmpty ? "inline-\(att.partID).img" : att.filename,
                        folderBookmark: settingsStore.settings.attachmentFolderBookmark
                    )
                    localURLs.append(url)
                    if att.id == target.id { startIdx = i }
                } catch {
                    // Skip failures; keep gallery intact for the rest.
                }
            }
            await MainActor.run {
                quickLook.present(urls: localURLs, startingAt: startIdx)
            }
        }
    }
}
