import SwiftUI
import SwiftData

@main
struct AppFeedbackApp: App {
    private let container: ModelContainer
    @State private var store: RepoStore
    @State private var syncStatus: CloudSyncStatus
    @State private var activityLog: ActivityLog
    @State private var mailSettings = MailSettings()

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            let schema = Schema([Repo.self])
            let config: ModelConfiguration = isTesting
                ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                : ModelConfiguration(
                    schema: schema,
                    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
                )
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        _store = State(initialValue: RepoStore(context: ModelContext(container)))
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
            RootView(store: store)
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
