import SwiftUI
import SwiftData
import UserNotifications

@main
struct AppFeedbackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    @State private var store: RepoStore
    @State private var syncStatus: CloudSyncStatus
    @State private var activityLog: ActivityLog
    @State private var mailAccountStore: MailAccountStore
    @State private var threadStore: MailThreadStore
    @State private var outboundTracker: OutboundSendTracker = OutboundSendTracker()
    @State private var outboundFailures: OutboundFailureStore
    @State private var settingsNavigation = SettingsNavigation()
    @State private var seenStore: SeenIssueStore
    @State private var hiddenAppStore: HiddenAppStore
    @State private var cacheContext: ModelContext
    @State private var intelligenceSettings: IntelligenceSettings
    @State private var intelligenceService: IntelligenceService
    @State private var notificationSettings: NotificationSettings
    @State private var notificationService: NotificationService
    @State private var notificationRouter: NotificationRouter
    @State private var downloaderHolder: AttachmentDownloaderHolder
    @State private var coordinatorHolder: MailSyncCoordinatorHolder
    @State private var mirrorHolder: MailToGitHubMirrorHolder
    @State private var mailLocalStateStore: MailAccountLocalStateStore
    #if os(iOS)
    @State private var iosRefreshDriver: iOSBackgroundRefreshDriver
    #elseif os(macOS)
    @State private var macRefreshDriver: MacBackgroundRefreshDriver
    #endif

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            if isTesting {
                // In-process test host: single in-memory config, no CloudKit validation.
                let testConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                container = try ModelContainer(
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self,
                    configurations: testConfig
                )
            } else {
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self])
                let localSchema = Schema([CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self, RepoFetchState.self])
                let cloudConfig = ModelConfiguration(
                    "cloud",
                    schema: cloudSchema,
                    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
                )
                let localConfig = ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
                container = try ModelContainer(
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self,
                    configurations: cloudConfig, localConfig
                )
            }
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        let cloudContext = ModelContext(container)
        let hiddenAppStoreLocal = HiddenAppStore(context: cloudContext)
        let mailAccountStoreLocal = MailAccountStore(context: ModelContext(container))
        if !isTesting {
            MailAccountMigration.runIfNeeded(store: mailAccountStoreLocal)
        }
        _mailAccountStore = State(initialValue: mailAccountStoreLocal)
        let threadStoreLocal = MailThreadStore(context: ModelContext(container))
        _threadStore = State(initialValue: threadStoreLocal)
        let localStateStoreLocal = MailAccountLocalStateStore(context: ModelContext(container))
        _mailLocalStateStore = State(initialValue: localStateStoreLocal)
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
        let failureStoreURL: URL? = isTesting ? nil : {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("AppFeedback", isDirectory: true)
            return supportDir.appendingPathComponent("outbound-failures.json")
        }()
        _outboundFailures = State(initialValue: OutboundFailureStore(persistenceURL: failureStoreURL))
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

        let mirrorLocal = MailToGitHubMirror(
            context: ModelContext(container),
            repoStore: _store.wrappedValue,
            activityLog: activityLogValue,
            poster: GitHubCommentPoster()
        )
        _mirrorHolder = State(initialValue: MailToGitHubMirrorHolder(mirrorLocal))

        #if canImport(SwiftMail)
        let imapProvider = IMAPClientProvider(accountStore: mailAccountStoreLocal)
        let localStateStore = localStateStoreLocal
        // Provide real CachedIssue titles to ThreadMatcher for backfill subject matching.
        // Capture `container` as a local constant so the @Sendable closure doesn't capture `self`.
        // The provider returns titles from ALL repos; ThreadMatcher.matchToIssue does not yet
        // disambiguate cross-repo title collisions — for v1, the highest-number heuristic is acceptable.
        let titlesContainer = container
        let coordinator = MailSyncCoordinator(
            client: imapProvider,
            threadStore: threadStoreLocal,
            accountStore: mailAccountStoreLocal,
            localState: localStateStore,
            activityLog: activityLogValue,
            mirror: mirrorLocal,
            notificationService: service,
            knownIssueTitlesProvider: { @Sendable in
                await MainActor.run {
                    let ctx = ModelContext(titlesContainer)
                    let cached = (try? ctx.fetch(FetchDescriptor<CachedIssue>())) ?? []
                    return cached.map { (owner: $0.repoOwner, repo: $0.repoName, number: $0.number, title: $0.title) }
                }
            }
        )
        _coordinatorHolder = State(initialValue: MailSyncCoordinatorHolder(coordinator))

        let attachmentLocalStore = MailAttachmentLocalStore(context: ModelContext(container))
        let downloader = AttachmentDownloader(client: imapProvider, localStore: attachmentLocalStore)
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(downloader))
        #else
        _coordinatorHolder = State(initialValue: MailSyncCoordinatorHolder(nil))
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(nil))
        #endif

        #if os(iOS)
        let driver = iOSBackgroundRefreshDriver(
            store: _store.wrappedValue,
            cacheContext: _cacheContext.wrappedValue,
            notificationService: service,
            settings: settings,
            activityLog: activityLogValue
        )
        driver.register()
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
                .environment(mailAccountStore)
                .environment(threadStore)
                .environment(outboundTracker)
                .environment(outboundFailures)
                .environment(settingsNavigation)
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(downloaderHolder)
                .environment(coordinatorHolder)
                .environment(mirrorHolder)
                .environment(mailLocalStateStore)
                .environment(\.notificationService, notificationService)
                .task { await notificationService.requestAuthorizationIfNeeded() }
                .onAppear {
                    #if canImport(SwiftMail)
                    Task { await coordinatorHolder.coordinator?.start() }
                    #endif
                }
                .onChange(of: notificationSettings.isEnabled) { _, isOn in
                    #if os(macOS)
                    if isOn { macRefreshDriver.startIfEnabled() } else { macRefreshDriver.stop() }
                    #else
                    if isOn { iosRefreshDriver.scheduleNextRefresh() } else { iosRefreshDriver.cancelPending() }
                    #endif
                }
                #if os(iOS)
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorHolder.coordinator?.pollNow() }
                    }
                    #endif
                    if phase == .background { iosRefreshDriver.scheduleNextRefresh() }
                }
                #elseif os(macOS)
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorHolder.coordinator?.pollNow() }
                    }
                    #endif
                }
                #endif
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
                .environment(mailAccountStore)
                .environment(threadStore)
                .environment(outboundTracker)
                .environment(outboundFailures)
                .environment(settingsNavigation)
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(downloaderHolder)
                .environment(coordinatorHolder)
                .environment(mirrorHolder)
                .environment(mailLocalStateStore)
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
