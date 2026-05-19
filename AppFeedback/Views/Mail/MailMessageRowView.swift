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

    private var attachments: [MailAttachment] { message.attachments ?? [] }

    private var unreadDot: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .accessibilityLabel("New message")
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
            if isUnread { unreadDot }
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
        IssueBodyText(
            title: message.subject,
            body: showFull ? stripped.full : stripped.cleaned
        )
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

    private var attachmentsRow: some View {
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentChipView(
                    attachment: attachment,
                    uid: UInt32(max(0, message.uid)),
                    folder: message.folder,
                    downloader: downloaderHolder?.downloader,
                    folderBookmark: settingsStore.settings.attachmentFolderBookmark
                )
            }
        }
    }
}
