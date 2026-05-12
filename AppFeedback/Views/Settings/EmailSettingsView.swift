#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                EmailAccountList(selection: $selection)
                if let id = selectedID, store.account(id: id) != nil {
                    EmailAccountEditor(accountID: id)
                } else {
                    ContentUnavailableView(
                        "No account selected",
                        systemImage: "envelope",
                        description: Text("Add an account to start sending and receiving.")
                    )
                }
            }
            .frame(minHeight: 320)
            Divider()
            MailDefaultsSection()
        }
        .onAppear {
            if selection == nil {
                selection = store.defaultSender?.id ?? store.accounts.first?.id
            }
        }
    }

    private var selectedID: UUID? {
        if let s = selection, store.account(id: s) != nil { return s }
        return store.accounts.first?.id
    }
}
#endif
