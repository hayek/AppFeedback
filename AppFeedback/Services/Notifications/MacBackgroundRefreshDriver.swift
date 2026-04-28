#if os(macOS)
import Foundation
import SwiftData

@MainActor
final class MacBackgroundRefreshDriver {
    static let identifier = "com.amirhayek.AppFeedback.refresh"

    private let store: RepoStore
    private let cacheContext: ModelContext
    private let notificationService: NotificationService
    private let settings: NotificationSettings
    private let activityLog: ActivityLog
    private var scheduler: NSBackgroundActivityScheduler?

    init(
        store: RepoStore,
        cacheContext: ModelContext,
        notificationService: NotificationService,
        settings: NotificationSettings,
        activityLog: ActivityLog
    ) {
        self.store = store
        self.cacheContext = cacheContext
        self.notificationService = notificationService
        self.settings = settings
        self.activityLog = activityLog
    }

    func startIfEnabled() {
        guard settings.isEnabled, scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: Self.identifier)
        s.repeats = true
        s.interval = 15 * 60
        s.tolerance = 5 * 60
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.runRefresh()
                completion(.finished)
            }
        }
        scheduler = s
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    private func runRefresh() async {
        guard settings.isEnabled else { return }
        var loaded: [NotificationService.RepoIssues] = []
        for repo in store.repos {
            guard let token = await KeychainService.load(for: repo) else { continue }
            let loader = IssueLoader(
                config: repo, activityLog: activityLog, cacheContext: cacheContext
            )
            await loader.load(token: token)
            if case .loaded(let issues, _) = loader.state {
                loaded.append((repo.owner, repo.repo, issues))
            }
        }
        await notificationService.diffAndNotify(loadedByRepo: loaded)
    }
}
#endif
