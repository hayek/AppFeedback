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

        if allApps.count == 1, let singleApp = allApps.first {
            // ── Single-app repo: render a leaf AppRowView (no disclosure group) ──
            let count = issues.filter { $0.appName == singleApp }.count
            let color: Color = {
                if let hex = store.colorHexFor(app: singleApp, in: repo.id) {
                    return Color(hex: hex)
                }
                return ColorPalette.color(for: singleApp, in: allApps)
            }()
            AppRowView(
                label: singleApp,
                count: count,
                color: color,
                isSelected: selection == .app(repoId: repo.id, appName: singleApp)
            )
            .tag(SidebarSelection.app(repoId: repo.id, appName: singleApp))
            .contentShape(Rectangle())
            .onTapGesture { selection = .app(repoId: repo.id, appName: singleApp) }
            .contextMenu {
                // App-level actions
                Menu {
                    ForEach(ColorPalette.swatches, id: \.self) { swatch in
                        Button {
                            store.setColor(swatch.hex, forApp: singleApp, in: repo.id)
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
                Button {
                    if selection == .app(repoId: repo.id, appName: singleApp) {
                        selection = nil
                    }
                    store.hideApp(singleApp, in: repo.id)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }

                Divider()

                // Repo-level actions
                if !hiddenSet.isEmpty {
                    Button {
                        store.unhideAllApps(in: repo.id)
                    } label: {
                        Label("Show All Hidden Apps", systemImage: "eye")
                    }
                }
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Repo", systemImage: "trash")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    if selection == .app(repoId: repo.id, appName: singleApp) {
                        selection = nil
                    }
                    store.hideApp(singleApp, in: repo.id)
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .tint(.orange)
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
        } else {
            // ── Zero or multi-app repo: existing expandable disclosure group ──
            DisclosureGroup(isExpanded: $isExpanded) {
                AppRowView(
                    label: "All Apps",
                    count: issues.filter { !hiddenSet.contains($0.appName ?? "") }.count,
                    color: .secondary,
                    isSelected: selection == .allIssues(repoId: repo.id)
                )
                .tag(SidebarSelection.allIssues(repoId: repo.id))
                .contentShape(Rectangle())
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
                    .tag(SidebarSelection.app(repoId: repo.id, appName: app))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = .app(repoId: repo.id, appName: app) }
                    .padding(.leading, 8)
                    .contextMenu {
                        Menu {
                            ForEach(ColorPalette.swatches, id: \.self) { swatch in
                                Button {
                                    store.setColor(swatch.hex, forApp: app, in: repo.id)
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
}
