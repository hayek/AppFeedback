import SwiftUI
import SwiftData
import UserNotifications
import os

// Thread-safe snapshot of repo configs used by the FeedbackAttachmentDownloader
// tokenProvider closure, which must be @Sendable and synchronous.
private final class ProductConfigSnapshot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[ProductConfig]>(initialState: [])

    func update(_ repos: [ProductConfig]) {
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

struct AppFeedbackApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    private let repoConfigSnapshot = ProductConfigSnapshot()
    @State private var store: ProductStore
    @State private var versionStore: VersionStore
    @State private var filterStore: FilterPreferenceStore
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
    @State private var triageSettings: TriageSettings
    @State private var triageCoordinator: FeedbackTriageCoordinator
    @State private var notificationSettings: NotificationSettings
    @State private var notificationService: NotificationService
    @State private var notificationRouter: NotificationRouter
    @State private var downloaderHolder: AttachmentDownloaderHolder
    @State private var coordinatorRegistry: MailSyncCoordinatorRegistry?
    @State private var mirrorHolder: MailToGitHubMirrorHolder
    @State private var feedbackMirrorHolder: MailToFeedbackMirrorHolder
    @State private var appStoreReviewMirrorStore: AppStoreReviewMirrorStore
    @State private var appStoreRegistry: AppStoreReviewCoordinatorRegistry
    @State private var issueLoaderRegistry: IssueLoaderRegistry
    #if os(macOS)
    @State private var cliResponder: CLIRequestResponder
    #endif
    @State private var mailLocalStateStore: MailAccountLocalStateStore
    @State private var mailDraftStore = MailDraftStore()
    @State private var quickLook = QuickLookPresenter()
    @State private var thumbnailCache = ThumbnailCache()
    @State private var feedbackAttachmentDownloaderHolder: FeedbackAttachmentDownloaderHolder
    #if os(iOS)
    @State private var iosRefreshDriver: iOSBackgroundRefreshDriver
    #endif

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        do {
            if isTesting {
                // In-process test host: single in-memory config, no CloudKit validation.
                let testConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
                container = try ModelContainer(
                    for: Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
                        RepoFilterPreference.self,
                        AppStoreReviewMirror.self,
                        TriageVerdictRecord.self,
                    configurations: testConfig
                )
            } else {
                let cloudSchema = Schema([Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self, RepoFilterPreference.self, AppStoreReviewMirror.self])
                let localSchema = Schema([CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self, RepoFetchState.self, FeedbackAttachmentLocal.self, TriageVerdictRecord.self])
                let cloudConfig = ModelConfiguration(
                    "cloud",
                    schema: cloudSchema,
                    cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
                )
                let localConfig = ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
                container = try ModelContainer(
                    for: Product.self, Repo.self, SeenIssue.self, HiddenApp.self, MailAccount.self,
                        GitHubAccount.self,
                        MailSettings.self,
                        MailThread.self, MailMessage.self, MailAttachment.self,
                        IssueTranslation.self, IssueSummaryCache.self,
                        ProjectVersion.self, SentReleaseNotification.self,
                        CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                        RepoFetchState.self, FeedbackAttachmentLocal.self,
                        ReplyTemplate.self,
                        RepoFilterPreference.self,
                        AppStoreReviewMirror.self,
                        TriageVerdictRecord.self,
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
            ProductMigration.run(context: cloudContext)
        }
        _mailAccountStore = State(initialValue: mailAccountStoreLocal)
        _mailSettingsStore = State(initialValue: mailSettingsStoreLocal)
        _threadStore = State(initialValue: threadStoreLocal)
        let localStateStoreLocal = MailAccountLocalStateStore(context: ModelContext(container))
        _mailLocalStateStore = State(initialValue: localStateStoreLocal)
        _seenStore = State(initialValue: SeenIssueStore(context: cloudContext))
        _hiddenAppStore = State(initialValue: hiddenAppStoreLocal)
        _store = State(initialValue: ProductStore(context: ModelContext(container), hiddenAppStore: hiddenAppStoreLocal))
        _gitHubAccountStore = State(initialValue: GitHubAccountStore(context: ModelContext(container)))
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
        _filterStore = State(initialValue: FilterPreferenceStore(context: ModelContext(container)))
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

        let triageSettingsLocal = TriageSettings()
        _triageSettings = State(initialValue: triageSettingsLocal)
        let triageCoordinatorLocal = FeedbackTriageCoordinator(
            provider: _intelligenceService.wrappedValue,
            store: TriageVerdictStore(context: ModelContext(container)),
            settings: triageSettingsLocal,
            applier: TaskServiceTriageApplier()
        )
        _triageCoordinator = State(initialValue: triageCoordinatorLocal)

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

        let feedbackMirrorLocal = MailToFeedbackMirror(
            context: ModelContext(container),
            productStore: _store.wrappedValue,
            activityLog: activityLogValue
        )
        _feedbackMirrorHolder = State(initialValue: MailToFeedbackMirrorHolder(feedbackMirrorLocal))

        // App Store Connect review registry: one coordinator per product that has ASC configured.
        let ascMirrorStore = AppStoreReviewMirrorStore(context: ModelContext(container))
        _appStoreReviewMirrorStore = State(initialValue: ascMirrorStore)
        let ascRegistry = AppStoreReviewCoordinatorRegistry { cfg in
            let auth = AppStoreConnectAuth(issuerID: cfg.issuerID, keyID: cfg.keyID,
                                           p8PEM: KeychainService.loadASCKeySync(for: cfg.id) ?? "")
            let client = AppStoreConnectClient(auth: auth, activityLog: activityLogValue)
            let owner = cfg.owner; let repo = cfg.repo
            return AppStoreReviewCoordinator(
                config: cfg, client: client, issueWriter: GitHubIssueWriter(),
                commentPoster: GitHubCommentPoster(), mirrorStore: ascMirrorStore,
                tokenLoader: { KeychainService.loadSync(for: ProductConfig(displayName: "", owner: owner, repo: repo)) },
                activityLog: activityLogValue)
        }
        let initialProducts = _store.wrappedValue.repos
        ascRegistry.syncWithProducts(initialProducts.compactMap {
            ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                  issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                  appAppleID: $0.appStoreAppAppleID)
        })
        _appStoreRegistry = State(initialValue: ascRegistry)

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
        let feedbackMirrorRef = feedbackMirrorLocal
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
                feedbackMirror: feedbackMirrorRef,
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

        // GitHub issue loaders: one registry owning the UI's loaders + the 15-min foreground
        // refresh loop, so periodic refreshes land in the loaders the UI actually renders.
        let cacheCtx = _cacheContext.wrappedValue
        let issueRegistry = IssueLoaderRegistry(
            factory: { cfg in IssueLoader(config: cfg, activityLog: activityLogValue, cacheContext: cacheCtx) },
            notificationService: service
        )
        issueRegistry.triageSink = { groups in
            await triageCoordinatorLocal.processLoaded(groups)
        }
        _issueLoaderRegistry = State(initialValue: issueRegistry)

        #if os(macOS)
        // Registered here rather than in a view so the CLI channel answers regardless of
        // window state. `respond` gets the same store instances the UI uses, so a reply sent
        // from the CLI is indistinguishable from one sent by hand.
        let replyDeps = CLIRequestHandlers.ReplyDependencies(
            accountStore: mailAccountStoreLocal,
            settingsStore: mailSettingsStoreLocal,
            threadStore: threadStoreLocal,
            tracker: _outboundTracker.wrappedValue,
            failureStore: _outboundFailures.wrappedValue,
            activityLog: activityLogValue,
            templateStore: _replyTemplateStore.wrappedValue,
            mirror: _mirrorHolder.wrappedValue.mirror,
            appStoreMirrorStore: ascMirrorStore,
            appStoreContext: { [registry = ascRegistry] productID in
                await registry.responderContext(productID: productID)
            })
        // Reads go through the app's OWN container. Opening a second one over the same store
        // files (what the CLI process does) from in here would duplicate the whole stack on
        // the main actor once per request.
        let cliContext = ModelContext(container)
        let responder = CLIRequestResponder { request in
            try await CLIRequestHandlers.handle(
                request,
                deps: CLIRequestHandlers.Dependencies(registry: issueRegistry,
                                                      local: cliContext, cloud: cliContext,
                                                      reply: replyDeps))
        }
        responder.start()
        _cliResponder = State(initialValue: responder)
        // Re-point whatever the user already installed, so a moved or rebuilt app self-heals.
        CLIInstaller.refreshInstalledLinks()
        #endif

        #if os(iOS)
        let driver = iOSBackgroundRefreshDriver(
            registry: issueRegistry,
            settings: settings,
            appStoreRegistry: ascRegistry
        )
        driver.register()
        _iosRefreshDriver = State(initialValue: driver)
        #endif
    }

    /// Injects the full set of shared environment objects into a view. Using one helper
    /// ensures all scenes (main WindowGroup, Activity window, Settings window)
    /// receive an identical, complete environment — no drift, no latent missing-@Environment crash.
    private func sharedEnvironment<V: View>(_ content: V) -> some View {
        content
            .environment(store)
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
            .environment(triageSettings)
            .environment(triageCoordinator)
            .environment(notificationSettings)
            .environment(notificationRouter)
            .environment(downloaderHolder)
            .environment(\.mailSyncCoordinatorRegistry, coordinatorRegistry)
            .environment(mirrorHolder)
            .environment(mailLocalStateStore)
            .environment(\.notificationService, notificationService)
            .environment(appStoreRegistry)
            .environment(mailDraftStore)
            .environment(quickLook)
            .environment(thumbnailCache)
            .environment(feedbackAttachmentDownloaderHolder)
    }

    var body: some Scene {
        WindowGroup {
            sharedEnvironment(
                RootView(store: store, seenStore: seenStore, cacheContext: cacheContext, versionStore: versionStore, filterStore: filterStore, issueLoaderRegistry: issueLoaderRegistry, appStoreReviewMirrorStore: appStoreReviewMirrorStore)
                    #if !os(macOS)
                    .overlay(QuickLookHost())
                    #endif
            )
                .task { await notificationService.requestAuthorizationIfNeeded() }
                .task(id: store.repos.map(\.id)) {
                    repoConfigSnapshot.update(store.repos)
                    appStoreRegistry.syncWithProducts(ascConfigs(from: store.repos))
                }
                .onAppear {
                    #if canImport(SwiftMail)
                    coordinatorRegistry?.start()
                    #endif
                    appStoreRegistry.start()
                    issueLoaderRegistry.start()
                }
                #if os(iOS)
                .onChange(of: notificationSettings.isEnabled) { _, isOn in
                    if isOn { iosRefreshDriver.scheduleNextRefresh() } else { iosRefreshDriver.cancelPending() }
                }
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorRegistry?.pollNow() }
                    }
                    #endif
                    if phase == .active {
                        Task { await appStoreRegistry.pollNow() }
                        Task { await issueLoaderRegistry.pollIfStale() }
                    }
                    if phase == .background { iosRefreshDriver.scheduleNextRefresh() }
                }
                #elseif os(macOS)
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorRegistry?.pollNow() }
                    }
                    #endif
                    if phase == .active {
                        Task { await appStoreRegistry.pollNow() }
                        Task { await issueLoaderRegistry.pollIfStale() }
                    }
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
            sharedEnvironment(SettingsView(store: store))
        }
        .defaultSize(width: 720, height: 620)
        .windowResizability(.contentMinSize)
        #endif
    }

    // MARK: - ASC helpers

    /// Maps the current product list into `[ASCProductConfig]` — only products that have all three
    /// ASC credential fields non-empty produce a config. When Phase 0/2 lands, the three ASC fields
    /// on `ProductConfig` are already read here via `$0.appStoreIssuerID` etc.
    private func ascConfigs(from products: [ProductConfig]) -> [ASCProductConfig] {
        products.compactMap {
            ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                  issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                  appAppleID: $0.appStoreAppAppleID)
        }
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
