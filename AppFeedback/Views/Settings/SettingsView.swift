import SwiftUI

struct SettingsView: View {
    @Bindable var store: RepoStore
    @Environment(CloudSyncStatus.self) private var syncStatus
    @State private var showAdd = false
    @State private var editTarget: RepoConfig?
    @State private var hoveredId: UUID?

    private var allDisplayNames: [String] { store.repos.map(\.displayName).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            CloudSyncStatusRow(state: syncStatus.state)
            if store.repos.isEmpty {
                emptyState
            } else {
                repoList
            }
            addBar
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 340)
        #endif
        .sheet(isPresented: $showAdd) {
            AddEditRepoView(store: store)
        }
        .sheet(item: $editTarget) { repo in
            AddEditRepoView(store: store, existing: repo)
        }
    }

    // MARK: - Repo list

    private var repoList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(store.repos) { repo in
                    RepoRowView(
                        repo: repo,
                        color: ColorPalette.color(for: repo.displayName, in: allDisplayNames),
                        maskedToken: maskedToken(for: repo),
                        isHovered: hoveredId == repo.id,
                        onEdit: { editTarget = repo },
                        onDelete: {
                            KeychainService.delete(for: repo)
                            withAnimation(.easeOut(duration: 0.18)) {
                                store.remove(id: repo.id)
                            }
                        }
                    )
                    .onHover { hoveredId = $0 ? repo.id : nil }

                    if repo.id != store.repos.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func maskedToken(for repo: RepoConfig) -> String {
        let raw = KeychainService.load(for: repo) ?? ""
        guard !raw.isEmpty else { return "no token" }
        guard raw.count > 7 else { return "••••••••" }
        return String(raw.prefix(4)) + "••••••••"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("No Repositories")
                    .font(.system(size: 13, weight: .semibold))
                Text("Add a GitHub repo to start browsing feedback.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Add bar

    private var addBar: some View {
        HStack {
            Text("\(store.repos.count) repo\(store.repos.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Spacer()
            Button {
                showAdd = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add Repo")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.separator), alignment: .top)
    }
}

// MARK: - Repo row

private struct RepoRowView: View {
    let repo: RepoConfig
    let color: Color
    let maskedToken: String
    let isHovered: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.5), radius: 3)
                .padding(.leading, 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(repo.displayName)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Text("\(repo.owner)/\(repo.repo)")
                        .font(.system(size: 11).monospaced())
                        .foregroundStyle(.secondary)
                    Text(maskedToken)
                        .font(.system(size: 10, weight: .medium).monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Spacer()

            if isHovered {
                HStack(spacing: 8) {
                    Button("Edit") { onEdit() }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .buttonStyle(.plain)

                    Divider().frame(height: 12)

                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(Rectangle())
    }
}
