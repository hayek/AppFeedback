import SwiftUI
#if os(macOS)
import AppKit
#endif

enum SettingsTab: String, Hashable, CaseIterable {
    case products
    case email
    case intelligence
    case notifications
}

@Observable
final class SettingsNavigation {
    var selectedTab: SettingsTab = .products
    /// The product whose detail the Products tab should focus. nil ⇒ no/first selection.
    var selectedProductID: UUID?

    /// Focus the Products tab on a specific product (used by the sidebar "Settings…" item
    /// and the macOS Settings window, which share this object via the environment).
    func focus(productID: UUID) {
        selectedTab = .products
        selectedProductID = productID
    }
}

struct SettingsView: View {
    @Bindable var store: ProductStore
    @Environment(CloudSyncStatus.self) private var syncStatus
    @Environment(IntelligenceSettings.self) private var intelligenceSettings
    @Environment(IntelligenceService.self) private var intelligenceService
    @Environment(TriageSettings.self) private var triageSettings
    @Environment(NotificationSettings.self) private var notificationSettings
    @Environment(\.notificationService) private var notificationService
    @Environment(SettingsNavigation.self) private var navigation
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var showAdd = false
    @State private var tokens: [UUID: String] = [:]

    private var allDisplayNames: [String] { store.products.map(\.displayName).sorted() }

    var body: some View {
        #if os(iOS)
        iosBody
        #else
        macBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        @Bindable var nav = navigation
        return tabContent(selection: nav.selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(
                minWidth: 480, idealWidth: 720, maxWidth: .infinity,
                minHeight: 320, idealHeight: 620, maxHeight: .infinity
            )
            .background(
                SettingsToolbarAccessor(
                    selection: $nav.selectedTab,
                    hasNotifications: notificationService != nil
                )
                .frame(width: 0, height: 0)
            )
    }

    @ViewBuilder
    private func tabContent(selection: SettingsTab) -> some View {
        switch selection {
        case .products:
            ProductsSettingsTab(store: store, navigation: navigation)
        case .email:
            EmailSettingsView()
        case .intelligence:
            IntelligenceSettingsSection(
                settings: intelligenceSettings,
                availability: intelligenceService.availability,
                onOpenSystemSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.AppleIntelligenceSettings") {
                        NSWorkspace.shared.open(url)
                    }
                },
                triageSettings: triageSettings
            )
        case .notifications:
            if let notificationService {
                NotificationsSettingsView(settings: notificationSettings, service: notificationService)
            }
        }
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
                    ForEach(store.products) { product in
                        NavigationLink {
                            ProductSettingsView(store: store, product: product, embedInNavigation: false)
                        } label: {
                            iosRepoRow(product)
                        }
                    }
                    .onDelete { offsets in
                        Task {
                            for index in offsets {
                                await store.remove(id: store.products[index].id)
                            }
                        }
                    }

                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Product", systemImage: "plus.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                    }
                } header: {
                    Text("Products")
                } footer: {
                    if !store.products.isEmpty {
                        Text("Tap a product to configure its sources. Swipe left to remove.")
                    } else {
                        Text("Add a product to start browsing feedback.")
                    }
                }

                #if canImport(SwiftMail)
                Section {
                    NavigationLink {
                        IOSEmailAccountList()
                    } label: {
                        Label("Email", systemImage: "envelope")
                    }
                }
                #endif

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
                if !store.products.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        EditButton()
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddEditRepoView(store: store)
            }
            .task(id: store.products.map(\.id)) {
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

    private func iosRepoRow(_ repo: ProductConfig) -> some View {
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

    private func refreshTokens() async {
        await withTaskGroup(of: (UUID, String?).self) { group in
            for product in store.products {
                group.addTask { (product.id, await KeychainService.load(for: product)) }
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

}
