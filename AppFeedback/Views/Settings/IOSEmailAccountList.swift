#if os(iOS)
import SwiftUI

struct IOSEmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @State private var showAddSheet = false

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts, id: \.id) { acc in
                    NavigationLink(value: acc.id) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(acc.smtpUsername.isEmpty ? "New account" : acc.smtpUsername)
                                Text(acc.preset.displayName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if acc.isDefaultSender {
                                Text("Default").font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            }
                        }
                    }
                }
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
            Section {
                NavigationLink("Mail templates & defaults") {
                    IOSMailDefaultsView()
                }
            }
        }
        .navigationTitle("Email")
        .navigationDestination(for: UUID.self) { id in
            IOSEmailAccountEditor(accountID: id)
        }
        .sheet(isPresented: $showAddSheet) {
            IOSAddEmailAccountSheet { _ in }
        }
    }
}
#endif
