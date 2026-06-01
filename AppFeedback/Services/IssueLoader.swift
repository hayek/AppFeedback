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
        case graphQLError(String)
        var errorDescription: String? {
            switch self {
            case .apiError(let code): return "GitHub API returned \(code)"
            case .graphQLError(let msg): return "GitHub GraphQL: \(msg)"
            }
        }
    }

    var state: State = .idle

    var isShowingCachedData: Bool {
        if case .loaded(_, let date) = state { return date == Date(timeIntervalSince1970: 0) }
        return false
    }

    var isInFlight: Bool { inFlight != nil }

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

    /// `fullReconcile` forces a non-incremental fetch (since: nil) so deletions upstream are
    /// detected — the incremental `since:` query never returns deleted issues, so without an
    /// occasional full pass a deleted issue lingers in the cache forever (a phantom).
    func load(token: String, fullReconcile: Bool = false) async {
        let task: Task<Void, Never>
        if !fullReconcile, let existing = inFlight, existing.token == token {
            task = existing.task
        } else {
            inFlight?.task.cancel()
            let newTask = Task { @MainActor [weak self] in
                await self?.performLoad(token: token, fullReconcile: fullReconcile)
                if self?.inFlight?.token == token { self?.inFlight = nil }
            }
            inFlight = (token, newTask)
            task = newTask
        }
        await task.value
    }

    private func performLoad(token: String, fullReconcile: Bool = false) async {
        if case .idle = state { loadFromCache() }
        let preLoadState = state
        // Keep showing cached data while fetching; only flip to .loading when we have
        // nothing to show. Otherwise SwiftUI Observation coalesces cache→loading writes
        // in the same tick and the cached state never renders.
        if case .loaded = state {} else { state = .loading }

        let entryID = activityLog?.start(kind: .fetchIssues, title: "\(config.owner)/\(config.repo)")

        // Capture fetch start before issuing the request — we use this as the next `since`
        // bound on success. Slight overlap on the next fetch is preferred over missing
        // updates that land mid-request.
        let fetchStartedAt = Date()
        let prior = readFetchState()
        let isIncremental = prior.lastFetchedAt != nil && !fullReconcile

        do {
            let outcome = try await fetchAllPages(
                token: token,
                since: isIncremental ? prior.lastFetchedAt : nil,
                etag: isIncremental ? prior.etag : nil,
                includeClosed: isIncremental
            )
            switch outcome {
            case .notModified:
                persistFetchState(lastFetchedAt: fetchStartedAt, etag: prior.etag)
                let issues = loadOpenIssuesFromCache()
                state = .loaded(issues, Date())
                if let entryID {
                    activityLog?.finish(entryID, status: .success, detail: "no changes")
                }
            case .updated(let fetched, let newEtag):
                mergeToCache(fetched, isFullRefresh: !isIncremental)
                persistFetchState(lastFetchedAt: fetchStartedAt, etag: newEtag)
                let issues = loadOpenIssuesFromCache()
                state = .loaded(issues, Date())
                if let entryID {
                    let n = fetched.count
                    activityLog?.finish(entryID, status: .success, detail: "\(n) update\(n == 1 ? "" : "s")")
                }
            }
        } catch {
            if case .loaded = preLoadState {
                state = preLoadState
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

    // MARK: - GraphQL fetch

    private enum FetchOutcome {
        case notModified
        case updated(issues: [FeedbackIssue], etag: String?)
    }

    private enum PageOutcome {
        case notModified
        case page(PageResult, etag: String?)
    }

    private func fetchAllPages(
        token: String,
        since: Date?,
        etag: String?,
        includeClosed: Bool
    ) async throws -> FetchOutcome {
        var collected: [FeedbackIssue] = []
        var cursor: String? = nil
        var firstPageEtag: String? = nil
        var pageIndex = 0

        // Only the first request carries the ETag — pagination beyond page 0 is reached
        // via `after: cursor` and won't have a matching cached response anyway. The 304
        // short-circuit therefore only fires on the initial request.
        var hasMore = true
        while hasMore {
            let outcome = try await fetchPage(
                token: token,
                cursor: cursor,
                since: since,
                etag: pageIndex == 0 ? etag : nil,
                includeClosed: includeClosed
            )
            switch outcome {
            case .notModified:
                return .notModified
            case .page(let page, let responseEtag):
                if pageIndex == 0 { firstPageEtag = responseEtag }
                collected.append(contentsOf: page.nodes)
                hasMore = page.hasNextPage
                cursor = page.endCursor
                pageIndex += 1
            }
        }

        return .updated(issues: collected, etag: firstPageEtag)
    }

    private struct PageResult {
        let nodes: [FeedbackIssue]
        let hasNextPage: Bool
        let endCursor: String?
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let issuesQuery = """
    query($owner: String!, $name: String!, $first: Int!, $after: String, $states: [IssueState!]!, $since: DateTime) {
      repository(owner: $owner, name: $name) {
        issues(first: $first, after: $after, states: $states, orderBy: {field: UPDATED_AT, direction: DESC}, filterBy: {since: $since}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number
            title
            body
            createdAt
            updatedAt
            state
            milestone { title }
            labels(first: 30) { nodes { name color } }
          }
        }
      }
    }
    """

    private func fetchPage(
        token: String,
        cursor: String?,
        since: Date?,
        etag: String?,
        includeClosed: Bool
    ) async throws -> PageOutcome {
        var variables: [String: Any] = [
            "owner": config.owner,
            "name": config.repo,
            "first": 100,
            "states": includeClosed ? ["OPEN", "CLOSED"] : ["OPEN"],
        ]
        if let cursor { variables["after"] = cursor }
        if let since {
            variables["since"] = Self.iso8601Formatter.string(from: since)
        }
        let body: [String: Any] = [
            "query": Self.issuesQuery,
            "variables": variables,
        ]

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoadError.apiError(0)
        }
        if http.statusCode == 304 {
            return .notModified
        }
        guard (200...299).contains(http.statusCode) else {
            throw LoadError.apiError(http.statusCode)
        }

        let responseEtag = http.value(forHTTPHeaderField: "ETag")
        let decoded = try Self.decodePage(data: data, owner: config.owner, repo: config.repo)
        return .page(decoded, etag: responseEtag)
    }

    private static func decodePage(data: Data, owner: String, repo: String) throws -> PageResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(GraphQLEnvelope.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw LoadError.graphQLError(errors.map(\.message).joined(separator: "; "))
        }
        guard let issues = envelope.data?.repository?.issues else {
            throw LoadError.graphQLError("missing repository.issues")
        }
        let nodes = issues.nodes.map { node -> FeedbackIssue in
            let parsed = IssueBodyParser.parse(node.body ?? "")
            let labels = (node.labels?.nodes ?? []).map {
                IssueLabel(name: $0.name, colorHex: $0.color)
            }
            return FeedbackIssue(
                number: node.number,
                title: node.title,
                createdAt: node.createdAt,
                rawBody: node.body ?? "",
                appName: parsed.app,
                appVersion: parsed.appVersion,
                device: parsed.device,
                osVersion: parsed.osVersion,
                email: parsed.email,
                description: parsed.description,
                labels: labels,
                updatedAt: node.updatedAt,
                state: IssueState(rawValue: node.state.lowercased()),
                milestoneTitle: node.milestone?.title,
                attachments: parsed.attachments
            )
        }
        return PageResult(
            nodes: nodes,
            hasNextPage: issues.pageInfo.hasNextPage,
            endCursor: issues.pageInfo.endCursor
        )
    }

    // MARK: - GraphQL response shapes

    private struct GraphQLEnvelope: Decodable {
        let data: DataPayload?
        let errors: [GraphQLError]?
    }
    private struct GraphQLError: Decodable {
        let message: String
    }
    private struct DataPayload: Decodable {
        let repository: Repository?
    }
    private struct Repository: Decodable {
        let issues: Issues
    }
    private struct Issues: Decodable {
        let pageInfo: PageInfo
        let nodes: [Node]
    }
    private struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
    private struct Milestone: Decodable {
        let title: String
    }
    private struct Node: Decodable {
        let number: Int
        let title: String
        let body: String?
        let createdAt: Date
        let updatedAt: Date
        let state: String
        let milestone: Milestone?
        let labels: LabelConnection?
    }
    private struct LabelConnection: Decodable {
        let nodes: [Label]
    }
    private struct Label: Decodable {
        let name: String
        let color: String
    }

    // MARK: - Cache

    private func loadFromCache() {
        let issues = loadOpenIssuesFromCache()
        guard !issues.isEmpty else { return }
        state = .loaded(issues, Date(timeIntervalSince1970: 0))
    }

    /// Removes a deleted issue from the cache and the current loaded state. The incremental
    /// fetch (`since:`) never returns deleted issues, so without this a deleted task lingers in
    /// the cache and reappears on the next launch (loaded from cache before the first fetch).
    func purgeFromCache(number: Int) {
        if let context = cacheContext {
            let owner = config.owner
            let name = config.repo
            let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
                cached.repoOwner == owner && cached.repoName == name && cached.number == number
            })
            for row in (try? context.fetch(descriptor)) ?? [] { context.delete(row) }
            try? context.save()
        }
        if case .loaded(let issues, let date) = state {
            state = .loaded(issues.filter { $0.number != number }, date)
        }
    }

    private func loadOpenIssuesFromCache() -> [FeedbackIssue] {
        guard let context = cacheContext else { return [] }
        let owner = config.owner
        let name = config.repo
        let openRaw = IssueState.open.rawValue
        let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
            cached.repoOwner == owner && cached.repoName == name && cached.state == openRaw
        })
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map { $0.toFeedbackIssue() }
    }

    /// Upserts fetched issues into the cache, preserving translation fields on existing rows.
    /// On a full refresh (no `since`) we trust the response as the canonical OPEN snapshot
    /// and prune stale OPEN rows that didn't appear. On incremental refresh we only mutate
    /// rows that came back — anything not in the response is unchanged on GitHub.
    private func mergeToCache(_ fetched: [FeedbackIssue], isFullRefresh: Bool) {
        guard let context = cacheContext else { return }
        let owner = config.owner
        let name = config.repo
        let openRaw = IssueState.open.rawValue
        let fetchedNumbers = Set(fetched.map(\.number))

        // Full refresh needs every cached row (so we can mark missing OPENs as closed).
        // Incremental refresh only needs to upsert what came back, so narrow the fetch.
        let descriptor: FetchDescriptor<CachedIssue> = isFullRefresh
            ? FetchDescriptor(predicate: #Predicate { cached in
                cached.repoOwner == owner && cached.repoName == name
            })
            : FetchDescriptor(predicate: #Predicate { cached in
                cached.repoOwner == owner && cached.repoName == name
                    && fetchedNumbers.contains(cached.number)
            })
        let existing = (try? context.fetch(descriptor)) ?? []
        let byNumber = Dictionary(uniqueKeysWithValues: existing.map { ($0.number, $0) })

        for issue in fetched {
            if let row = byNumber[issue.number] {
                row.updateFromRemote(issue)
            } else if (issue.state ?? .open) == .open {
                // Skip CLOSED issues we've never cached — not interesting to the app.
                context.insert(CachedIssue.from(issue, repoOwner: owner, repoName: name))
            }
        }

        if isFullRefresh {
            // Only OPEN states were requested; any cached OPEN row missing from the response
            // was closed/deleted upstream. Mark them closed so translations aren't lost in case
            // of reopen.
            for row in existing where row.state == openRaw && !fetchedNumbers.contains(row.number) {
                row.state = IssueState.closed.rawValue
            }
        }

        try? context.save()
    }

    // MARK: - Debug helpers

    #if DEBUG
    static func decodePageForTesting(data: Data, owner: String, repo: String) throws -> [FeedbackIssue] {
        try decodePage(data: data, owner: owner, repo: repo).nodes
    }
    #endif

    // MARK: - Fetch state persistence

    private func fetchStateRow(in context: ModelContext) -> RepoFetchState? {
        let owner = config.owner
        let name = config.repo
        var descriptor = FetchDescriptor<RepoFetchState>(predicate: #Predicate { state in
            state.repoOwner == owner && state.repoName == name
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func readFetchState() -> (lastFetchedAt: Date?, etag: String?) {
        guard let context = cacheContext, let row = fetchStateRow(in: context) else {
            return (nil, nil)
        }
        return (row.lastFetchedAt, row.etag)
    }

    private func persistFetchState(lastFetchedAt: Date, etag: String?) {
        guard let context = cacheContext else { return }
        if let row = fetchStateRow(in: context) {
            row.lastFetchedAt = lastFetchedAt
            if let etag { row.etag = etag }
        } else {
            context.insert(RepoFetchState(
                repoOwner: config.owner,
                repoName: config.repo,
                lastFetchedAt: lastFetchedAt,
                etag: etag
            ))
        }
        try? context.save()
    }
}
