import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class IssueLoader {
    enum State {
        case idle
        case loading
        case loaded([FeedbackIssue], Date)
        case failed(Error)
    }

    enum LoadError: LocalizedError {
        case apiError(Int)
        var errorDescription: String? {
            if case .apiError(let code) = self { return "GitHub API returned \(code)" }
            return nil
        }
    }

    var state: State = .idle

    var isShowingCachedData: Bool {
        if case .loaded(_, let date) = state { return date == Date(timeIntervalSince1970: 0) }
        return false
    }

    private let config: RepoConfig
    private let session: URLSession
    private let cacheContext: ModelContext?
    private var inFlight: (token: String, task: Task<Void, Never>)?
    private let activityLog: ActivityLog?

    init(
        config: RepoConfig,
        session: URLSession = .shared,
        activityLog: ActivityLog? = nil,
        cacheContext: ModelContext? = nil
    ) {
        self.config = config
        self.session = session
        self.activityLog = activityLog
        self.cacheContext = cacheContext
    }

    func load(token: String) async {
        let task: Task<Void, Never>
        if let existing = inFlight, existing.token == token {
            task = existing.task
        } else {
            // New token (or no in-flight): supersede any prior task. The orphaned task
            // continues but its result is overwritten by ours when it lands.
            inFlight?.task.cancel()
            let newTask = Task { @MainActor [weak self] in
                await self?.performLoad(token: token)
                if self?.inFlight?.token == token { self?.inFlight = nil }
            }
            inFlight = (token, newTask)
            task = newTask
        }
        // Awaiters share the in-flight task; cancellation of one awaiter does not cancel
        // the shared work — other awaiters still get the result.
        await task.value
    }

    private func performLoad(token: String) async {
        if case .idle = state { loadFromCache() }
        let preLoadState = state   // snapshot before overwriting
        // Keep showing cached data while fetching; only flip to .loading when we have
        // nothing to show. Otherwise SwiftUI Observation coalesces cache→loading writes
        // in the same tick and the cached state never renders.
        if case .loaded = state {} else { state = .loading }

        let entryID = activityLog?.start(kind: .fetchIssues, title: "\(config.owner)/\(config.repo)")

        do {
            let raw = try await fetchAllPages(token: token)
            let issues = raw
                .filter { $0.pullRequest == nil }
                .map { gh -> FeedbackIssue in
                    let parsed = IssueBodyParser.parse(gh.body ?? "")
                    return FeedbackIssue(
                        number:      gh.number,
                        title:       gh.title,
                        createdAt:   gh.createdAt,
                        rawBody:     gh.body ?? "",
                        appName:     parsed.app,
                        appVersion:  parsed.appVersion,
                        device:      parsed.device,
                        osVersion:   parsed.osVersion,
                        email:       parsed.email,
                        description: parsed.description,
                        labels:      gh.labels.map { IssueLabel(name: $0.name, colorHex: $0.color) }
                    )
                }
            saveToCache(issues)
            state = .loaded(issues, Date())
            if let entryID {
                activityLog?.finish(entryID, status: .success, detail: "\(issues.count) issue\(issues.count == 1 ? "" : "s")")
            }
        } catch {
            if case .loaded = preLoadState {
                state = preLoadState   // restore cached data
                if let entryID {
                    activityLog?.finish(entryID, status: .failure, detail: error.localizedDescription)
                }
                return
            }
            state = .failed(error)
            if let entryID {
                activityLog?.finish(entryID, status: .failure, detail: error.localizedDescription)
            }
        }
    }

    private func fetchAllPages(token: String) async throws -> [GitHubIssue] {
        var page = 1
        var collected: [GitHubIssue] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        while true {
            var comps = URLComponents(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)/issues")!
            comps.queryItems = [
                URLQueryItem(name: "state",    value: "open"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page",     value: "\(page)"),
            ]
            var request = URLRequest(url: comps.url!)
            request.setValue("Bearer \(token)",                 forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LoadError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            let batch = try decoder.decode([GitHubIssue].self, from: data)
            collected.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return collected
    }

    private func loadFromCache() {
        guard let context = cacheContext else { return }
        let owner = config.owner
        let name = config.repo
        let predicate = #Predicate<CachedIssue> {
            $0.repoOwner == owner && $0.repoName == name
        }
        let descriptor = FetchDescriptor<CachedIssue>(predicate: predicate)
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        let issues = rows.map { $0.toFeedbackIssue() }
        state = .loaded(issues, Date(timeIntervalSince1970: 0))
    }

    private func saveToCache(_ issues: [FeedbackIssue]) {
        guard let context = cacheContext else { return }
        let owner = config.owner
        let name = config.repo
        let predicate = #Predicate<CachedIssue> {
            $0.repoOwner == owner && $0.repoName == name
        }
        if let existing = try? context.fetch(FetchDescriptor<CachedIssue>(predicate: predicate)) {
            for row in existing { context.delete(row) }
        }
        for issue in issues {
            context.insert(CachedIssue.from(issue, repoOwner: owner, repoName: name))
        }
        try? context.save()
    }
}
