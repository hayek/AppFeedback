import SwiftUI
import SwiftData

@main
struct AppFeedbackApp: App {
    private let container: ModelContainer
    @State private var store: RepoStore
    @State private var syncStatus: CloudSyncStatus
    @State private var activityLog: ActivityLog
    @State private var mailSettings = MailSettings()
    @State private var seenStore: SeenIssueStore
    @State private var hiddenAppStore: HiddenAppStore
    @State private var cacheContext: ModelContext

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self])
            let localSchema = Schema([CachedIssue.self])
            let cloudConfig: ModelConfiguration = isTesting
                ? ModelConfiguration("cloud", schema: cloudSchema, isStoredInMemoryOnly: true)
                : ModelConfiguration(
                    "cloud",
                    schema: cloudSchema,
                    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
                )
            let localConfig: ModelConfiguration = isTesting
                ? ModelConfiguration("local", schema: localSchema, isStoredInMemoryOnly: true)
                : ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
            container = try ModelContainer(
                for: Repo.self, SeenIssue.self, HiddenApp.self, CachedIssue.self,
                configurations: cloudConfig, localConfig
            )
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let cloudContext = ModelContext(container)
        let hiddenAppStoreLocal = HiddenAppStore(context: cloudContext)
        _seenStore = State(initialValue: SeenIssueStore(context: cloudContext))
        _hiddenAppStore = State(initialValue: hiddenAppStoreLocal)
        _store = State(initialValue: RepoStore(context: ModelContext(container), hiddenAppStore: hiddenAppStoreLocal))
        _cacheContext = State(initialValue: ModelContext(container))
        _syncStatus = State(initialValue: CloudSyncStatus())
        let activityLogURL: URL? = isTesting ? nil : {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("AppFeedback", isDirectory: true)
            return supportDir.appendingPathComponent("activity.json")
        }()
        _activityLog = State(initialValue: ActivityLog(persistenceURL: activityLogURL))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, seenStore: seenStore, cacheContext: cacheContext)
                .environment(syncStatus)
                .environment(activityLog)
                .environment(mailSettings)
        }
        .modelContainer(container)
        .commands {
            #if os(macOS)
            CommandGroup(after: .windowList) {
                ActivityMenuCommand()
            }
            #endif
        }
        #if os(macOS)
        Window("Activity", id: "activity") {
            ActivityWindow()
                .environment(activityLog)
        }
        Settings {
            SettingsView(store: store)
                .environment(syncStatus)
                .environment(activityLog)
                .environment(mailSettings)
        }
        #endif
    }
}

#if os(macOS)
private struct ActivityMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Activity") {
            openWindow(id: "activity")
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
    }
}
#endif
