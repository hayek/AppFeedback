import SwiftUI

struct MailMessageRowView: View {
    let message: MailMessage

    @Environment(MailAccountStore.self) private var accountStore
    @Environment(AttachmentDownloaderHolder.self) private var downloaderHolder: AttachmentDownloaderHolder?

    @State private var isExpanded: Bool = false

    private var attachments: [MailAttachment] { message.attachments ?? [] }

    private var senderLine: String {
        if let name = message.fromName, !name.isEmpty {
            return "\(name) (\(message.fromAddress))"
        }
        return message.fromAddress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                bodyView
                if !attachments.isEmpty {
                    attachmentsRow
                }
            } else {
                preview
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation { isExpanded.toggle() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !message.subject.isEmpty {
                Text(message.subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            HStack {
                Text("From: \(senderLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(message.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let trimmed = message.bodyPlain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
        Text(trimmed)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        if !attachments.isEmpty {
            Label(
                "\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")",
                systemImage: "paperclip"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bodyView: some View {
        // HTML rendering via WKWebView (iOS) / WebView (macOS) is deferred to a future task.
        // For v1 we always render bodyPlain as the source of truth.
        Text(message.bodyPlain).font(.body)
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
