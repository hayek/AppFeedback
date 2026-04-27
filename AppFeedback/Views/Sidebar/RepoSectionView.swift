import SwiftUI

struct RepoSectionView: View {
    let repo: RepoConfig
    let issues: [FeedbackIssue]
    let allApps: [String]
    @Binding var selection: SidebarSelection?
    var store: RepoStore
    @State private var isExpanded = true
    @State private var showRemoveConfirmation = false

    var body: some View {
        let hiddenSet = store.hiddenAppsFor(repo.id)
        let visibleApps = allApps.filter { !hiddenSet.contains($0) }

        return DisclosureGroup(isExpanded: $isExpanded) {
            AppRowView(
                label: "All Issues",
                count: issues.count,
                color: .secondary,
                isSelected: selection == .allIssues(repoId: repo.id)
            )
            .onTapGesture { selection = .allIssues(repoId: repo.id) }
            .padding(.leading, 8)

            ForEach(visibleApps, id: \.self) { app in
                let count = issues.filter { $0.appName == app }.count
                let color: Color = {
                    if let hex = store.colorHexFor(app: app, in: repo.id) {
                        return Color(hex: hex)
                    }
                    return ColorPalette.color(for: app, in: allApps)
                }()
                AppRowView(
                    label: app,
                    count: count,
                    color: color,
                    isSelected: selection == .app(repoId: repo.id, appName: app)
                )
                .onTapGesture { selection = .app(repoId: repo.id, appName: app) }
                .padding(.leading, 8)
                .contextMenu {
                    Menu {
                        ForEach(ColorPalette.swatches, id: \.self) { swatch in
                            Button {
                                store.setColor(swatch.hex, forApp: app, in: repo.id)
                            } label: {
                                Image(nsImage: ColorPalette.swatchImage(hex: swatch.hex))
                                Text(swatch.name)
                            }
                        }
                    } label: {
                        Label("Color", systemImage: "paintpalette")
                    }
                    Divider()
                    Button {
                        if selection == .app(repoId: repo.id, appName: app) {
                            selection = nil
                        }
                        store.hideApp(app, in: repo.id)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        if selection == .app(repoId: repo.id, appName: app) {
                            selection = nil
                        }
                        store.hideApp(app, in: repo.id)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                    .tint(.orange)
                }
            }
        } label: {
            Text(repo.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .contextMenu {
                    if !hiddenSet.isEmpty {
                        Button {
                            store.unhideAllApps(in: repo.id)
                        } label: {
                            Label("Show All Hidden Apps", systemImage: "eye")
                        }
                        Divider()
                    }
                    Button(role: .destructive) {
                        showRemoveConfirmation = true
                    } label: {
                        Label("Remove Repo", systemImage: "trash")
                    }
                }
        }
        .confirmationDialog(
            "Remove \"\(repo.displayName)\"?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if selection?.repoId == repo.id {
                    selection = nil
                }
                Task { await store.remove(id: repo.id) }
            }
        } message: {
            Text("This will remove the repo from the sidebar. Your GitHub data will not be affected.")
        }
    }
}
