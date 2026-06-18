#if os(iOS)
import Foundation
import BackgroundTasks
import SwiftData

@MainActor
final class iOSBackgroundRefreshDriver {
    static let taskIdentifier = "com.amirhayek.AppFeedback.refresh"

    private let store: ProductStore
    private let cacheContext: ModelContext
    private let notificationService: NotificationService
    private let settings: NotificationSettings
    private let activityLog: ActivityLog

    init(
        store: ProductStore,
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

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier, using: nil
        ) { [weak self] task in
            guard let self, let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            let work = Task { @MainActor in
                await self.runRefresh()
                refresh.setTaskCompleted(success: true)
                self.scheduleNextRefresh()
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    func scheduleNextRefresh() {
        guard settings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
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
