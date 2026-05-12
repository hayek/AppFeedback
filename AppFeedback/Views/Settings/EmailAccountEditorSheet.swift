#if os(macOS)
import SwiftUI

/// Sheet chrome around `EmailAccountEditor`. Owns the title bar + Done button; defers all
/// editing UI to the existing editor view.
struct EmailAccountEditorSheet: View {
    let accountID: UUID

    @Environment(MailAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EmailAccountEditor(accountID: accountID)
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 660)
        .background(.windowBackground)
        .onChange(of: accountStillExists) { _, exists in
            if !exists { dismiss() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            MailProviderBadge(preset: account?.preset ?? .gmail, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(account?.preset.displayName ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if isDefault {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Label("Default sender", systemImage: "paperplane.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                }
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var account: MailAccount? { store.account(id: accountID) }

    private var titleText: String {
        guard let acc = account, !acc.smtpUsername.isEmpty else { return "New Account" }
        return acc.smtpUsername
    }

    private var isDefault: Bool { account?.isDefaultSender ?? false }

    private var accountStillExists: Bool { account != nil }
}
#endif
