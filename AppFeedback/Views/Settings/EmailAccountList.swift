#if os(macOS)
import SwiftUI

struct EmailAccountList: View {
    @Environment(MailAccountStore.self) private var store
    @Binding var selection: UUID?
    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.accounts, id: \.id) { acc in
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
                    .tag(acc.id as UUID?)
                }
            }
            Divider()
            Button { showAddSheet = true } label: {
                Label("Add account", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .frame(minWidth: 220)
        .sheet(isPresented: $showAddSheet) {
            AddEmailAccountSheet { newID in selection = newID }
        }
    }
}
#endif
