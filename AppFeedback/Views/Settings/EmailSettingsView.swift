#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @State private var editingAccount: EditingAccount?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                EmailAccountList(editingAccountID: Binding(
                    get: { editingAccount?.id },
                    set: { editingAccount = $0.map(EditingAccount.init(id:)) }
                ))
                MailDefaultsSection()
            }
            .formStyle(.grouped)

            MailPlaceholdersList()
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editingAccount) { item in
            EmailAccountEditorSheet(accountID: item.id)
        }
    }

    private struct EditingAccount: Identifiable, Hashable {
        let id: UUID
    }
}
#endif
