import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
private struct WindowResizableAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.styleMask.insert(.resizable)
            window.collectionBehavior.insert(.fullScreenNone)
            window.minSize = NSSize(width: 540, height: 380)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

struct SettingsView: View {
    @Bindable var store: RepoStore
    @Environment(CloudSyncStatus.self) private var syncStatus
    @Environment(IntelligenceSettings.self) private var intelligenceSettings
    @Environment(IntelligenceService.self) private var intelligenceService
    @Environment(NotificationSettings.self) private var notificationSettings
    @Environment(\.notificationService) private var notificationService
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showAdd = false
    @State private var editTarget: RepoConfig?
    @State private var hoveredId: UUID?
    @State private var tokens: [UUID: String] = [:]

    private var allDisplayNames: [String] { store.repos.map(\.displayName).sorted() }

    var body: some View {
        #if os(iOS)
        iosBody
        #else
        macBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        TabView {
            reposTab
                .tabItem { Label("Repos", systemImage: "folder") }
            EmailSettingsView()
                .tabItem { Label("Email", systemImage: "envelope") }
            IntelligenceSettingsSection(
                settings: intelligenceSettings,
                availability: intelligenceService.availability,
                onOpenSystemSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligenceSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
            .tabItem { Label("Intelligence", systemImage: "sparkles") }
            if let notificationService {
                NotificationsSettingsView(settings: notificationSettings, service: notificationService)
                    .tabItem { Label("Notifications", systemImage: "bell") }
            }
        }
        .frame(
            minWidth: 540, idealWidth: 720, maxWidth: .infinity,
            minHeight: 380, idealHeight: 620, maxHeight: .infinity
        )
        .background(WindowResizableAccessor())
    }
    #endif

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            Form {
                Section {
                    iCloudStatusRow
                }

                Section {
                    ForEach(store.repos) { repo in
                        NavigationLink {
                            AddEditRepoView(store: store, existing: repo, embedInNavigation: false)
                        } label: {
                            iosRepoRow(repo)
                        }
                    }
                    .onDelete { offsets in
                        Task {
                            for index in offsets {
                                await store.remove(id: store.repos[index].id)
                            }
                        }
                    }

                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Repository", systemImage: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                } header: {
                    Text("Repositories")
                } footer: {
                    if !store.repos.isEmpty {
                        Text("Tap a repository to edit. Swipe left to remove.")
                    } else {
                        Text("Add a GitHub repository to start browsing feedback.")
                    }
                }

                if let notificationService {
                    Section {
                        NavigationLink {
                            NotificationsSettingsView(settings: notificationSettings, service: notificationService)
                                .navigationTitle("Notifications")
                                .navigationBarTitleDisplayMode(.large)
                        } label: {
                            Label("Notifications", systemImage: "bell")
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !store.repos.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddEditRepoView(store: store)
            }
            .task(id: store.repos.map(\.id)) {
                await refreshTokens()
            }
        }
    }

    private var iCloudStatusRow: some View {
        let style = iCloudStyle(for: syncStatus.state)
        return HStack(spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 22))
                .foregroundStyle(style.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                    .font(.body)
                if let detail = style.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if style.showsOpenSettings {
                Button("Open") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private struct IOSCloudStyle {
        let icon: String
        let tint: Color
        let title: String
        let detail: String?
        let showsOpenSettings: Bool
    }

    private func iCloudStyle(for state: SyncState) -> IOSCloudStyle {
        switch state {
        case .unknown:
            return .init(icon: "icloud", tint: .secondary, title: "Checking iCloud…", detail: nil, showsOpenSettings: false)
        case .syncing:
            return .init(icon: "checkmark.icloud.fill", tint: .green, title: "Syncing via iCloud", detail: nil, showsOpenSettings: false)
        case .unavailable(let reason):
            let detail: String = switch reason {
            case .notSignedIn:            "Sign in to sync across devices."
            case .restricted:             "iCloud is restricted on this device."
            case .temporarilyUnavailable: "Try again in a moment."
            }
            return .init(icon: "icloud.slash.fill", tint: .orange, title: "iCloud Unavailable", detail: detail, showsOpenSettings: true)
        case .error(let message):
            return .init(icon: "exclamationmark.icloud.fill", tint: .red, title: "iCloud Error", detail: message, showsOpenSettings: false)
        }
    }

    private func iosRepoRow(_ repo: RepoConfig) -> some View {
        let color = ColorPalette.color(for: repo.displayName, in: allDisplayNames)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color.gradient)
                    .frame(width: 30, height: 30)
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("\(repo.owner)/\(repo.repo)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
    #endif

    private var reposTab: some View {
        VStack(spacing: 0) {
            CloudSyncStatusRow(state: syncStatus.state)
            if store.repos.isEmpty {
                emptyState
            } else {
                repoList
            }
            addBar
        }
        .sheet(isPresented: $showAdd) {
            AddEditRepoView(store: store)
        }
        .sheet(item: $editTarget) { repo in
            AddEditRepoView(store: store, existing: repo)
        }
        .task(id: store.repos.map(\.id)) {
            await refreshTokens()
        }
    }

    private func refreshTokens() async {
        await withTaskGroup(of: (UUID, String?).self) { group in
            for repo in store.repos {
                group.addTask { (repo.id, await KeychainService.load(for: repo)) }
            }
            var collected: [UUID: String] = [:]
            for await (id, token) in group {
                if let token { collected[id] = token }
            }
            // If a newer task(id:) run has superseded us, don't overwrite its result.
            guard !Task.isCancelled else { return }
            tokens = collected
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
                            Task {
                                await store.remove(id: repo.id)
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
        let raw = tokens[repo.id] ?? ""
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
