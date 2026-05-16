#if os(macOS)
import SwiftUI

/// Renders the configured-accounts section. Designed to be composed inside the parent
/// `Form` in `EmailSettingsView`, not used standalone.
struct EmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @Binding var editingAccountID: UUID?
    @State private var showAddSheet = false
    @State private var pendingDeletion: MailAccount?

    var body: some View {
        Section {
            if store.accounts.isEmpty {
                emptyState
            } else {
                ForEach(store.accounts, id: \.id) { acc in
                    HoverableAccountRow(
                        acc: acc,
                        onOpen: { editingAccountID = acc.id },
                        onDelete: { pendingDeletion = acc }
                    )
                    .contextMenu {
                        if !acc.isDefaultSender {
                            Button {
                                store.setDefaultSender(acc)
                            } label: {
                                Label("Make Default", systemImage: "star.fill")
                            }
                        }
                        Button(role: .destructive) {
                            pendingDeletion = acc
                        } label: {
                            Label("Delete Account", systemImage: "trash")
                        }
                    }
                }
            }
            addRow
        } header: {
            HStack {
                Text("Accounts").textCase(nil)
                Spacer()
                if store.accounts.count > 1 {
                    Text("\(store.accounts.count) configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddEmailAccountSheet { newID in
                editingAccountID = newID
            }
        }
        .confirmAccountDeletion(target: $pendingDeletion) { acc in
            if editingAccountID == acc.id { editingAccountID = nil }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack(spacing: 12) {
            MailProviderBadge(preset: .gmail, size: 28)
                .opacity(0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text("No accounts yet")
                    .font(.system(size: 13, weight: .medium))
                Text("Add a mailbox to start exchanging replies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var addRow: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 28, height: 28)
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text("Add Mail Account")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}

private struct HoverableAccountRow: View {
    let acc: MailAccount
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(MailAccountStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                MailProviderBadge(preset: acc.preset)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.smtpUsername.isEmpty ? "New account" : acc.smtpUsername)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(acc.preset.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isHovering {
                    hoverActions
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if acc.isDefaultSender {
                    defaultBadge
                        .transition(.scale.combined(with: .opacity))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .animation(.easeInOut(duration: 0.18), value: acc.isDefaultSender)
            .animation(.easeInOut(duration: 0.18), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 6) {
            if !acc.isDefaultSender {
                actionButton(systemImage: "star.fill", help: "Make Default", tint: .accentColor) {
                    store.setDefaultSender(acc)
                }
            }
            actionButton(systemImage: "trash", help: "Delete Account", tint: .red, action: onDelete)
        }
    }

    private var defaultBadge: some View {
        Text("Default")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(.tint)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.5)
            )
    }

    private func actionButton(systemImage: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.15)))
                .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
