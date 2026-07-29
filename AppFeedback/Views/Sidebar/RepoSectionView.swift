import SwiftUI

/// The actions exposed by a product's sidebar context menu, in display order.
/// `.settings` is the leading item (opens `ProductSettingsView`), followed by the existing
/// Color submenu and Remove. Extracted so the leading-Settings ordering is unit-testable.
enum ProductContextMenuAction: CaseIterable, Equatable {
    case settings
    case color
    case remove

    static var ordered: [ProductContextMenuAction] { [.settings, .color, .remove] }

    var title: String {
        switch self {
        case .settings: return "Settings…"
        case .color:    return "Color"
        case .remove:   return "Remove Product"
        }
    }

    var systemImage: String {
        switch self {
        case .settings: return "gearshape"
        case .color:    return "paintpalette"
        case .remove:   return "trash"
        }
    }
}

struct RepoSectionView: View {
    let repo: ProductConfig
    let issues: [FeedbackIssue]
    @Binding var selection: SidebarSelection?
    var store: ProductStore
    var seenStore: SeenIssueStore
    var onOpenSettings: (UUID) -> Void = { _ in }
    @State private var showRemoveConfirmation = false

    /// Unread feedback for this repo: feedback issues not yet marked seen, excluding tasks (which
    /// are GitHub issues too but never enter the seen store), so the badge matches what's actually
    /// shown as unread in the list (mirrors IssueListViewModel.unreadIssues).
    private var unreadCount: Int {
        let seen = seenStore.seenNumbers(owner: repo.owner, repo: repo.repo)
        return issues.filter { !TaskItem.isTask($0) && !seen.contains($0.number) }.count
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
            Button {
                onOpenSettings(repo.id)
            } label: {
                Label(ProductContextMenuAction.settings.title,
                      systemImage: ProductContextMenuAction.settings.systemImage)
            }

            Divider()

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
                Label(ProductContextMenuAction.color.title, systemImage: ProductContextMenuAction.color.systemImage)
            }

            Divider()

            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label(ProductContextMenuAction.remove.title, systemImage: ProductContextMenuAction.remove.systemImage)
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
            Text("This will remove the product from the sidebar. Your GitHub data will not be affected.")
        }
    }
}
