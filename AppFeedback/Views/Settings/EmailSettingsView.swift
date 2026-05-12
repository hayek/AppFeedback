#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @State private var editingAccount: EditingAccount?

    var body: some View {
        Form {
            EmailAccountList(editingAccountID: Binding(
                get: { editingAccount?.id },
                set: { editingAccount = $0.map(EditingAccount.init(id:)) }
            ))
            MailDefaultsSection()
        }
        .formStyle(.grouped)
        .sheet(item: $editingAccount) { item in
            EmailAccountEditorSheet(accountID: item.id)
        }
    }

    private struct EditingAccount: Identifiable, Hashable {
        let id: UUID
    }
}
#endif
