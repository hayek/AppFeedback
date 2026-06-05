import SwiftUI
import SwiftData
import UserNotifications
import os

// Thread-safe snapshot of repo configs used by the FeedbackAttachmentDownloader
// tokenProvider closure, which must be @Sendable and synchronous.
private final class RepoConfigSnapshot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[RepoConfig]>(initialState: [])

    func update(_ repos: [RepoConfig]) {
        lock.withLock { $0 = repos }
    }

    func firstToken() -> String? {
        let repos = lock.withLock { $0 }
        for repo in repos {
            if let token = KeychainService.loadSync(for: repo) { return token }
        }
        return nil
    }

    func token(forOwner owner: String, repo: String) -> String? {
        let repos = lock.withLock { $0 }
        for config in repos where config.owner == owner && config.repo == repo {
            if let token = KeychainService.loadSync(for: config) { return token }
        }
        return nil
    }
}

@main
struct AppFeedbackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    private let repoConfigSnapshot = RepoConfigSnapshot()
    @State private var store: RepoStore
    @State private var versionStore: VersionStore
    @State private var replyTemplateStore: ReplyTemplateStore
    @State private var syncStatus: CloudSyncStatus
    @State private var activityLog: ActivityLog
    @State private var mailAccountStore: MailAccountStore
    @State private var gitHubAccountStore: GitHubAccountStore
    @State private var mailSettingsStore: MailSettingsStore
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
    @State private var coordinatorRegistry: MailSyncCoordinatorRegistry?
    @State private var mirrorHolder: MailToGitHubMirrorHolder
    @State private var mailLocalStateStore: MailAccountLocalStateStore
    @State private var mailDraftStore = MailDraftStore()
    @State private var quickLook = QuickLookPresenter()
    @State private var thumbnailCache = ThumbnailCache()
    @State private var feedbackAttachmentDownloaderHolder: FeedbackAttachmentDownloaderHolder
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
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
                    configurations: testConfig
                )
            } else {
                let cloudSchema = Schema([Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self])
                let localSchema = Schema([CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self, RepoFetchState.self, FeedbackAttachmentLocal.self])
                let cloudConfig = ModelConfiguration(
                    "cloud",
                    schema: cloudSchema,
                    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
                )
                let localConfig = ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
                container = try ModelContainer(
                    for: Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
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
        let mailSettingsStoreLocal = MailSettingsStore(context: ModelContext(container))
        let threadStoreLocal = MailThreadStore(context: ModelContext(container))
        if !isTesting {
            MailAccountMigration.runIfNeeded(store: mailAccountStoreLocal, settingsStore: mailSettingsStoreLocal)
            MailAccountMigration.runV2IfNeeded(
                accountStore: mailAccountStoreLocal,
                settingsStore: mailSettingsStoreLocal,
                threadStore: threadStoreLocal
            )
        }
        _mailAccountStore = State(initialValue: mailAccountStoreLocal)
        _mailSettingsStore = State(initialValue: mailSettingsStoreLocal)
        _threadStore = State(initialValue: threadStoreLocal)
        let localStateStoreLocal = MailAccountLocalStateStore(context: ModelContext(container))
        _mailLocalStateStore = State(initialValue: localStateStoreLocal)
        _seenStore = State(initialValue: SeenIssueStore(context: cloudContext))
        _hiddenAppStore = State(initialValue: hiddenAppStoreLocal)
        _store = State(initialValue: RepoStore(context: ModelContext(container), hiddenAppStore: hiddenAppStoreLocal))
        _gitHubAccountStore = State(initialValue: GitHubAccountStore(context: ModelContext(container)))
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
        _replyTemplateStore = State(initialValue: ReplyTemplateStore(context: ModelContext(container)))
        _cacheContext = State(initialValue: ModelContext(container))
        _syncStatus = State(initialValue: CloudSyncStatus())
        // Seed the snapshot so tokenProvider works even before the first repos observation.
        repoConfigSnapshot.update(_store.wrappedValue.repos)
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

        // Feedback-attachment downloader (GitHub issue attachments).
        let feedbackLocalStore = FeedbackAttachmentLocalStore(context: ModelContext(container))
        let snapshot = repoConfigSnapshot
        let feedbackDownloader = FeedbackAttachmentDownloader(
            session: .shared,
            localStore: feedbackLocalStore,
            tokenProvider: { url in
                // Route token lookup by owner/repo parsed from raw.githubusercontent.com URLs.
                guard url.host == "raw.githubusercontent.com" else { return nil }
                let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                let owner = String(parts[0])
                let repo = String(parts[1])
                return snapshot.token(forOwner: owner, repo: repo)
            }
        )
        _feedbackAttachmentDownloaderHolder = State(initialValue: FeedbackAttachmentDownloaderHolder(feedbackDownloader))

        #if canImport(SwiftMail)
        let titlesContainer = container
        let mirrorRef = mirrorLocal
        let serviceRef = service
        let activityLogRef = activityLogValue
        let registryFactory: (UUID) -> MailSyncCoordinator = { id in
            let provider = IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: id)
            return MailSyncCoordinator(
                client: provider,
                accountID: id,
                threadStore: threadStoreLocal,
                accountStore: mailAccountStoreLocal,
                settingsStore: mailSettingsStoreLocal,
                localState: localStateStoreLocal,
                activityLog: activityLogRef,
                mirror: mirrorRef,
                notificationService: serviceRef,
                knownIssueTitlesProvider: { @Sendable in
                    await MainActor.run {
                        let ctx = ModelContext(titlesContainer)
                        let cached = (try? ctx.fetch(FetchDescriptor<CachedIssue>())) ?? []
                        return cached.map { (owner: $0.repoOwner, repo: $0.repoName, number: $0.number, title: $0.title) }
                    }
                }
            )
        }
        let registry = MailSyncCoordinatorRegistry(
            accountStore: mailAccountStoreLocal,
            factory: registryFactory
        )
        registry.syncWithAccounts()
        _coordinatorRegistry = State(initialValue: registry)

        // The attachment downloader routes each fetch to the IMAP client of the account that owns
        // the message (its bytes live in THAT account's Sent/INBOX folder); nil → default sender.
        let defaultAccountID = mailAccountStoreLocal.defaultSender?.id ?? UUID()
        let attachmentLocalStore = MailAttachmentLocalStore(context: ModelContext(container))
        let downloader = AttachmentDownloader(
            clientForAccount: { accountID in
                IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: accountID ?? defaultAccountID)
            },
            localStore: attachmentLocalStore
        )
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(downloader))
        #else
        _coordinatorRegistry = State(initialValue: nil)
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
            RootView(store: store, seenStore: seenStore, cacheContext: cacheContext, versionStore: versionStore)
                #if !os(macOS)
                .overlay(QuickLookHost())
                #endif
                .environment(syncStatus)
                .environment(activityLog)
                .environment(mailAccountStore)
                .environment(gitHubAccountStore)
                .environment(mailSettingsStore)
                .environment(threadStore)
                .environment(replyTemplateStore)
                .environment(outboundTracker)
                .environment(outboundFailures)
                .environment(settingsNavigation)
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(downloaderHolder)
                .environment(\.mailSyncCoordinatorRegistry, coordinatorRegistry)
                .environment(mirrorHolder)
                .environment(mailLocalStateStore)
                .environment(mailDraftStore)
                .environment(quickLook)
                .environment(thumbnailCache)
                .environment(feedbackAttachmentDownloaderHolder)
                .environment(\.notificationService, notificationService)
                .task { await notificationService.requestAuthorizationIfNeeded() }
                .task(id: store.repos.map(\.id)) {
                    repoConfigSnapshot.update(store.repos)
                }
                .onAppear {
                    #if canImport(SwiftMail)
                    coordinatorRegistry?.start()
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
                        Task { await coordinatorRegistry?.pollNow() }
                    }
                    #endif
                    if phase == .background { iosRefreshDriver.scheduleNextRefresh() }
                }
                #elseif os(macOS)
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorRegistry?.pollNow() }
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
            // Replace the system Settings… menu item so Cmd-, opens our
            // standalone Window scene (Settings { } scene's resizability
            // is fundamentally restricted; a regular Window resizes normally).
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
            #endif
        }
        #if os(macOS)
        Window("Activity", id: "activity") {
            ActivityWindow()
                .environment(activityLog)
        }
        Window("Settings", id: "settings") {
            SettingsView(store: store)
                .environment(syncStatus)
                .environment(activityLog)
                .environment(mailAccountStore)
                .environment(gitHubAccountStore)
                .environment(mailSettingsStore)
                .environment(threadStore)
                .environment(replyTemplateStore)
                .environment(outboundTracker)
                .environment(outboundFailures)
                .environment(settingsNavigation)
                .environment(intelligenceSettings)
                .environment(intelligenceService)
                .environment(notificationSettings)
                .environment(notificationRouter)
                .environment(downloaderHolder)
                .environment(\.mailSyncCoordinatorRegistry, coordinatorRegistry)
                .environment(mirrorHolder)
                .environment(mailLocalStateStore)
                .environment(\.notificationService, notificationService)
        }
        .defaultSize(width: 720, height: 620)
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(macOS)
/// "Settings…" menu entry that opens our Window-scene-based Settings, with the
/// standard Cmd-, shortcut. We can't use SettingsLink because it's tied to the
/// Settings { } scene; instead we drive the openWindow environment action.
private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
#endif

// MARK: - EnvironmentKey for MailSyncCoordinatorRegistry

private struct MailSyncCoordinatorRegistryKey: EnvironmentKey {
    static let defaultValue: MailSyncCoordinatorRegistry? = nil
}

extension EnvironmentValues {
    var mailSyncCoordinatorRegistry: MailSyncCoordinatorRegistry? {
        get { self[MailSyncCoordinatorRegistryKey.self] }
        set { self[MailSyncCoordinatorRegistryKey.self] = newValue }
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
