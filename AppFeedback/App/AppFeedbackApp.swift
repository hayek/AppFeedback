import SwiftUI
import SwiftData
import UserNotifications

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
    @State private var intelligenceSettings: IntelligenceSettings
    @State private var intelligenceService: IntelligenceService
    @State private var notificationSettings: NotificationSettings
    @State private var notificationService: NotificationService
    @State private var notificationRouter: NotificationRouter
    #if os(iOS)
    @State private var iosRefreshDriver: iOSBackgroundRefreshDriver
    #elseif os(macOS)
    @State private var macRefreshDriver: MacBackgroundRefreshDriver
    #endif

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
        _intelligenceSettings = State(initialValue: IntelligenceSettings())
        _intelligenceService = State(initialValue: IntelligenceService())

        let settings = NotificationSettings()
        let router = NotificationRouter()
        let notifiedStore = NotifiedIssueStore()
        let service = NotificationService(
            center: UNUserNotificationCenter.current(),
            notifiedStore: notifiedStore,
            settings: settings,
            router: router
        )
        UNUserNotificationCenter.current().delegate = service

        _notificationSettings = State(initialValue: settings)
        _notificationRouter = State(initialValue: router)
        _notificationService = State(initialValue: service)

        let activityLogValue = _activityLog.wrappedValue
        #if os(iOS)
        let driver = iOSBackgroundRefreshDriver(
            store: _store.wrappedValue,
            cacheContext: _cacheContext.wrappedValue,
            notificationService: service,
            settings: settings,
            activityLog: activityLogValue
        )
        driver.register()
        driver.scheduleNextRefresh()
        _iosRefreshDriver = State(initialValue: driver)
        #elseif os(macOS)
        let driver = MacBackgroundRefreshDriver(
            store: _store.wrappedValue,
            cacheContext: _cacheContext.wrappedValue,
            notificationService: service,
            settings: settings,
            activityLog: activityLogValue
        )
        driver.startIfEnabled()
        _macRefreshDriver = State(initialValue: driver)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, seenStore: seenStore, cacheContext: cacheContext)
                .environment(syncStatus)
                .environment(activityLog)
                .environment(mailSettings)
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(\.notificationService, notificationService)
                .task { await notificationService.requestAuthorizationIfNeeded() }
                .onChange(of: notificationSettings.isEnabled) { _, isOn in
                    #if os(macOS)
                    if isOn { macRefreshDriver.startIfEnabled() } else { macRefreshDriver.stop() }
                    #else
                    if isOn { iosRefreshDriver.scheduleNextRefresh() }
                    #endif
                }
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
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(\.notificationService, notificationService)
        }
        .windowResizability(.contentMinSize)
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
