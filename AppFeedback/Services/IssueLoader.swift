import Foundation
import Observation

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

    private let config: RepoConfig
    private let session: URLSession
    private let cacheURL: URL

    init(config: RepoConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheURL = caches
            .appendingPathComponent("AppFeedback")
            .appendingPathComponent("\(config.owner)-\(config.repo).json")
    }

    func load(token: String) async {
        if case .idle = state { loadFromCache() }
        state = .loading

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
                        description: parsed.description
                    )
                }
            saveToCache(issues)
            state = .loaded(issues, Date())
        } catch {
            if case .loaded = state { return }
            state = .failed(error)
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
        guard let data = try? Data(contentsOf: cacheURL),
              let issues = try? JSONDecoder().decode([FeedbackIssue].self, from: data)
        else { return }
        state = .loaded(issues, Date(timeIntervalSince1970: 0))
    }

    private func saveToCache(_ issues: [FeedbackIssue]) {
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(issues).write(to: cacheURL)
    }
}
