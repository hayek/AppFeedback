import SwiftUI
import SwiftData

@main
struct AppFeedbackApp: App {
    private let container: ModelContainer
    @State private var store: RepoStore
    @State private var syncStatus: CloudSyncStatus

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
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(syncStatus)
        }
        .modelContainer(container)
        #if os(macOS)
        Settings {
            SettingsView(store: store)
                .environment(syncStatus)
        }
        #endif
    }
}
