import SwiftUI

struct SettingsView: View {
    @Bindable var store: RepoStore
    @State private var showAdd = false
    @State private var editTarget: RepoConfig?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.repos) { repo in
                    repoRow(repo)
                }
            }
            .navigationTitle("Repos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) {
                NavigationStack { AddEditRepoView(store: store) }
            }
            .sheet(item: $editTarget) { repo in
                NavigationStack { AddEditRepoView(store: store, existing: repo) }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 320)
        #endif
    }

    private func repoRow(_ repo: RepoConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.displayName).font(.headline)
                Text("\(repo.owner)/\(repo.repo)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { editTarget = repo }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                KeychainService.delete(for: repo)
                store.remove(id: repo.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

}
