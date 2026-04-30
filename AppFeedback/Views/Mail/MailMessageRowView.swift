import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MailMessageRowView: View {
    let message: MailMessage

    @Environment(MailAccountStore.self) private var accountStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(AttachmentDownloaderHolder.self) private var downloaderHolder: AttachmentDownloaderHolder?

    private var isUnread: Bool { threadStore.isUnread(message) }

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
        VStack(alignment: .leading, spacing: 2) {
            if !message.subject.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isUnread { unreadDot }
                    Text(message.subject)
                        .font(.subheadline.weight(.semibold))
                }
            }
            HStack {
                if isUnread && message.subject.isEmpty { unreadDot }
                Menu {
                    Button("Copy address") { copyFromAddress() }
                } label: {
                    Text("From: \(senderLine)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .contextMenu {
                    Button("Copy address") { copyFromAddress() }
                }
                Spacer()
                ToggleableDateText(date: message.date)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        Text(showFull ? stripped.full : stripped.cleaned)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
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
                    account: accountStore.account
                )
            }
        }
    }
}
