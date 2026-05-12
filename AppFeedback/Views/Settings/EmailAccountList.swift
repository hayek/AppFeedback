#if os(macOS)
import SwiftUI

/// Renders the configured-accounts section. Designed to be composed inside the parent
/// `Form` in `EmailSettingsView`, not used standalone.
struct EmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @Binding var editingAccountID: UUID?
    @State private var showAddSheet = false

    var body: some View {
        Section("Accounts") {
            if store.accounts.isEmpty {
                Text("No email accounts configured.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts, id: \.id) { acc in
                    accountRow(acc)
                }
            }
            Button {
                showAddSheet = true
            } label: {
                Label("Add account", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddEmailAccountSheet { newID in
                editingAccountID = newID
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ acc: MailAccount) -> some View {
        Button {
            editingAccountID = acc.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(acc.smtpUsername.isEmpty ? "New account" : acc.smtpUsername)
                        .foregroundStyle(.primary)
                    Text(acc.preset.displayName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if acc.isDefaultSender {
                    Text("Default")
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
