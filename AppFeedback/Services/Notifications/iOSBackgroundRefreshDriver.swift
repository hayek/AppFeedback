#if os(iOS)
import Foundation
import BackgroundTasks

/// BGTaskScheduler glue for background refresh. The actual fetch + notification diff is
/// `IssueLoaderRegistry.refreshTick()` — the same code path as the foreground poll loop —
/// so background-fetched data lands in the UI's own loaders.
@MainActor
final class iOSBackgroundRefreshDriver {
    static let taskIdentifier = "com.amirhayek.AppFeedback.refresh"

    private let registry: IssueLoaderRegistry
    private let settings: NotificationSettings
    private let appStoreRegistry: AppStoreReviewCoordinatorRegistry

    init(
        registry: IssueLoaderRegistry,
        settings: NotificationSettings,
        appStoreRegistry: AppStoreReviewCoordinatorRegistry
    ) {
        self.registry = registry
        self.settings = settings
        self.appStoreRegistry = appStoreRegistry
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
        request.earliestBeginDate = Date().addingTimeInterval(IssueLoaderRegistry.pollInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private func runRefresh() async {
        guard settings.isEnabled else { return }
        await registry.refreshTick()
        // The App Store registry's own poll loop is suspended while backgrounded, so this
        // background window must poll it explicitly.
        await appStoreRegistry.pollNow()
    }
}
#endif
