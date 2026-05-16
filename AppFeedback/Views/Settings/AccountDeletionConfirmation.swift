import SwiftUI

private struct ConfirmAccountDeletion: ViewModifier {
    @Binding var target: MailAccount?
    let onDeleted: ((MailAccount) -> Void)?
    @Environment(MailAccountStore.self) private var store
    @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { target != nil },
                set: { if !$0 { target = nil } }
            ),
            presenting: target
        ) { acc in
            Button("Remove \(acc.smtpUsername.isEmpty ? "account" : acc.smtpUsername)", role: .destructive) {
                Task {
                    await store.deleteWithCredentials(acc)
                    registry?.syncWithAccounts()
                    onDeleted?(acc)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { acc in
            Text("Saved credentials for \(acc.smtpUsername.isEmpty ? "this mailbox" : acc.smtpUsername) will be removed from the Keychain.")
        }
    }
}

extension View {
    func confirmAccountDeletion(
        target: Binding<MailAccount?>,
        onDeleted: ((MailAccount) -> Void)? = nil
    ) -> some View {
        modifier(ConfirmAccountDeletion(target: target, onDeleted: onDeleted))
    }
}
