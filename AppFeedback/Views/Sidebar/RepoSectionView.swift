import SwiftUI

struct RepoSectionView: View {
    let repo: RepoConfig
    let issues: [FeedbackIssue]
    let allApps: [String]          // retained param (callers still pass it); unused for selection now
    @Binding var selection: SidebarSelection?
    var store: RepoStore
    var seenStore: SeenIssueStore
    @State private var showRemoveConfirmation = false

    /// Unread feedback for this repo: feedback issues not yet marked seen, excluding tasks (which
    /// are GitHub issues too but never enter the seen store) and hidden apps, so the badge matches
    /// what's actually shown as unread in the list (mirrors IssueListViewModel.unreadIssues).
    private var unreadCount: Int {
        let seen = seenStore.seenNumbers(owner: repo.owner, repo: repo.repo)
        let hidden = store.hiddenAppsFor(repo.id)
        return issues.filter {
            !TaskItem.isTask($0) && !seen.contains($0.number) && !hidden.contains($0.appName ?? "")
        }.count
    }

    var body: some View {
        let accent: Color = repo.colorHex.map(Color.init(hex:)) ?? .secondary
        AppRowView(
            label: repo.displayName,
            count: unreadCount,
            color: accent,
            isSelected: selection == .allIssues(repoId: repo.id)
        )
        .tag(SidebarSelection.allIssues(repoId: repo.id))
        .contentShape(Rectangle())
        .onTapGesture { selection = .allIssues(repoId: repo.id) }
        .contextMenu {
            Menu {
                if repo.colorHex != nil {
                    Button {
                        store.setColor(nil, forRepo: repo.id)
                    } label: {
                        Label("Default", systemImage: "circle.dashed")
                    }
                    Divider()
                }
                ForEach(ColorPalette.swatches, id: \.self) { swatch in
                    Button {
                        store.setColor(swatch.hex, forRepo: repo.id)
                    } label: {
                        #if os(macOS)
                        Image(nsImage: ColorPalette.swatchImage(hex: swatch.hex))
                        #else
                        Circle().fill(Color(hex: swatch.hex))
                        #endif
                        Text(swatch.name)
                    }
                }
            } label: {
                Label("Color", systemImage: "paintpalette")
            }

            Divider()

            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label("Remove Repo", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Remove \"\(repo.displayName)\"?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if selection?.repoId == repo.id { selection = nil }
                Task { await store.remove(id: repo.id) }
            }
        } message: {
            Text("This will remove the repo from the sidebar. Your GitHub data will not be affected.")
        }
    }
}
