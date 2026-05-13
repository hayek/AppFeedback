#if os(macOS) || os(iOS)
import SwiftUI

/// In-line guidance card shown beneath the password field for providers that require an
/// app-specific password — turns silent auth failures into a single click to the
/// provider's app-password page.
struct MailProviderHintCard: View {
    let preset: SMTPCredentials.Preset
    let help: SMTPCredentials.Preset.Help
    let appPasswordURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MailProviderBadge(preset: preset, size: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text(help.title)
                    .font(.system(size: 12, weight: .medium))
                Text(help.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let appPasswordURL {
                    Button {
                        openURL(appPasswordURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text(help.linkLabel)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                    }
                    #if os(macOS)
                    .buttonStyle(.link)
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// SecureField that strips whitespace from any pasted/typed password as it's entered,
/// so users pasting app passwords with the four-group spacing don't see auth failures.
/// SMTP/IMAP passwords cannot legitimately contain whitespace, so this is safe across providers.
struct SanitizedPasswordField: View {
    let title: String
    var prompt: Text?
    @Binding var text: String

    var body: some View {
        SecureField(title, text: $text, prompt: prompt)
            .onChange(of: text) { _, new in
                let cleaned = new.filter { !$0.isWhitespace && !$0.isNewline }
                if cleaned != new { text = cleaned }
            }
    }
}
#endif
