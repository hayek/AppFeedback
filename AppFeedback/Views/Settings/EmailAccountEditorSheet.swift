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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            EmailAccountEditor(accountID: accountID)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 620)
        .onChange(of: accountStillExists) { _, exists in
            if !exists { dismiss() }
        }
    }

    private var title: String {
        guard let acc = store.account(id: accountID), !acc.smtpUsername.isEmpty else {
            return "Account"
        }
        return acc.smtpUsername
    }

    private var subtitle: String {
        store.account(id: accountID)?.preset.displayName ?? ""
    }

    private var accountStillExists: Bool {
        store.account(id: accountID) != nil
    }
}
#endif
