import Foundation
import Observation
import SwiftData

/// App-level registry owning one `IssueLoader` per product plus the 15-minute foreground
/// refresh loop. Mirrors the grain of `MailSyncCoordinatorRegistry` /
/// `AppStoreReviewCoordinatorRegistry`: spin-up creates loaders, tear-down drops them,
/// `start()` runs the poll loop, `pollIfStale()` catches up after suspension.
///
/// Replaces `MacBackgroundRefreshDriver`: because this registry owns the UI's actual
/// loaders, its refreshes are visible in the app, and it runs regardless of whether
/// notifications are enabled (`diffAndNotify` self-gates on that).
@Observable @MainActor
final class IssueLoaderRegistry {
    private(set) var loaders: [UUID: IssueLoader] = [:]

    /// Stamped when a fan-out load completes — drives `pollIfStale()`.
    private(set) var lastRefreshAt: Date?
    /// Stamped when a full (non-incremental) pass completes — drives the daily sweep that
    /// prunes phantom issues (incremental `since:` fetches never surface deletions).
    private(set) var lastFullReconcileAt: Date?

    static let pollInterval: TimeInterval = 15 * 60
    static let fullReconcileInterval: TimeInterval = 24 * 3600

    private var products: [ProductConfig] = []
    private var loopTask: Task<Void, Never>?
    private let factory: (ProductConfig) -> IssueLoader
    private let tokenProvider: @Sendable (ProductConfig) async -> String?
    private let notificationService: NotificationService?
    private let clock: () -> Date

    init(
        factory: @escaping (ProductConfig) -> IssueLoader,
        tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { await KeychainService.load(for: $0) },
        notificationService: NotificationService? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.factory = factory
        self.tokenProvider = tokenProvider
        self.notificationService = notificationService
        self.clock = clock
    }

    /// Creates loaders for newly-added products (dispatching their initial load) and drops
    /// loaders for removed ones. Safe to call repeatedly.
    func syncWithProducts(_ repos: [ProductConfig]) {
        products = repos
        var newlyAdded: [ProductConfig] = []
        for repo in repos where loaders[repo.id] == nil {
            loaders[repo.id] = factory(repo)
            newlyAdded.append(repo)
        }
        let ids = Set(repos.map(\.id))
        loaders = loaders.filter { ids.contains($0.key) }
        if !newlyAdded.isEmpty {
            Task { await self.load(newlyAdded, fullReconcile: false) }
        }
    }

    /// Starts the foreground poll loop. Safe to call multiple times.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await self?.refreshTick()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One poll-loop iteration: load every repo (full reconcile once per 24h) then feed the
    /// notification differ (which self-gates on notifications being enabled).
    func refreshTick() async {
        let needsFull = lastFullReconcileAt
            .map { clock().timeIntervalSince($0) >= Self.fullReconcileInterval } ?? true
        await loadAll(fullReconcile: needsFull)
        await notificationService?.diffAndNotify(loadedByRepo: loadedGroups)
    }

    /// Catch-up poll after suspension (scene re-activation): a full tick, but only when the
    /// last refresh is older than the poll interval.
    func pollIfStale() async {
        let stale = lastRefreshAt
            .map { clock().timeIntervalSince($0) >= Self.pollInterval } ?? true
        guard stale else { return }
        await refreshTick()
    }

    /// Fan-out load across every product; stamps the refresh clocks.
    func loadAll(fullReconcile: Bool = false) async {
        await load(products, fullReconcile: fullReconcile)
        lastRefreshAt = clock()
        if fullReconcile { lastFullReconcileAt = clock() }
    }

    /// All currently-loaded (owner, repo, issues) groups — the notification differ's input.
    var loadedGroups: [NotificationService.RepoIssues] {
        products.compactMap { repo in
            guard let loader = loaders[repo.id],
                  case .loaded(let issues, _) = loader.state else { return nil }
            return (owner: repo.owner, repo: repo.repo, issues: issues)
        }
    }

    private func load(_ repos: [ProductConfig], fullReconcile: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                guard let loader = loaders[repo.id] else { continue }
                let tokenProvider = tokenProvider
                group.addTask {
                    // iCloud Keychain may not have synced this token yet on a fresh device;
                    // one short retry catches that without blocking the happy path.
                    for attempt in 0..<2 {
                        if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                        if let token = await tokenProvider(repo) {
                            await loader.load(token: token, fullReconcile: fullReconcile)
                            return
                        }
                    }
                }
            }
        }
    }
}
