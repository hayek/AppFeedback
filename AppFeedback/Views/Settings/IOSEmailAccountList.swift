#if os(iOS)
import SwiftUI

struct IOSEmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @State private var showAddSheet = false
    @State private var pendingDeletion: MailAccount?

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts, id: \.id) { acc in
                    NavigationLink {
                        IOSEmailAccountEditor(accountID: acc.id)
                    } label: {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = acc
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if !acc.isDefaultSender {
                            Button {
                                store.setDefaultSender(acc)
                            } label: {
                                Label("Make Default", systemImage: "star.fill")
                            }
                            .tint(.accentColor)
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
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showAddSheet) {
            IOSAddEmailAccountSheet { _ in }
        }
        .confirmAccountDeletion(target: $pendingDeletion)
    }
}
#endif
