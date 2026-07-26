#if os(macOS)
import Foundation
import SwiftData

/// App-side half of the CLI channel. Observes request pings, runs the handler on the main
/// actor (every app service it calls is @MainActor), and writes the reply back.
///
/// Registration uses the SELECTOR-based API deliberately: it is the only
/// `DistributedNotificationCenter` overload that accepts a suspension behavior, and
/// `.deliverImmediately` is mandatory here — AppKit suspends delivery while the app is
/// inactive, which it always is when an agent drives a terminal, so the block-based API
/// would leave every request unanswered until the app next came forward.
final class CLIRequestResponder: NSObject {

    static let suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior = .deliverImmediately

    typealias Handler = @MainActor (CLIRequest) async throws -> CLIResponse

    private let directory: URL
    private let handler: Handler

    init(directory: URL = CLIIPCTransport.directory, handler: @escaping Handler) {
        self.directory = directory
        self.handler = handler
        super.init()
    }

    func start() {
        CLIIPCTransport.sweep(in: directory)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleNotification(_:)),
            name: Notification.Name(CLIBranding.requestNotification),
            object: nil, suspensionBehavior: Self.suspensionBehavior)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func handleNotification(_ notification: Notification) {
        guard let raw = notification.userInfo?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        Task { @MainActor [weak self] in await self?.handle(requestID: id) }
    }

    /// Reads the request, runs the handler, writes the response, pings back.
    /// A request this app has already consumed reads as missing and is ignored.
    @MainActor
    func handle(requestID: UUID) async {
        guard let request = try? CLIIPCTransport.readRequest(id: requestID, in: directory) else { return }
        var response: CLIResponse
        do {
            response = try await handler(request)
        } catch let error as CLIError {
            response = CLIResponse(id: requestID, ok: false, errorCode: error.code,
                                   errorMessage: error.message, errorHint: error.hint)
        } catch {
            response = CLIResponse(id: requestID, ok: false, errorCode: "remote_failure",
                                   errorMessage: error.localizedDescription)
        }
        try? CLIIPCTransport.write(response: response, in: directory)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(CLIBranding.responseNotification),
            object: nil, userInfo: ["id": requestID.uuidString], deliverImmediately: true)
    }
}

/// Executes each CLI request by calling exactly what the app's own UI calls.
@MainActor
enum CLIRequestHandlers {

    /// @MainActor because `TaskService()` is main-actor isolated, so its default value can only
    /// be built there.
    @MainActor
    struct Dependencies {
        let registry: IssueLoaderRegistry
        var taskService: TaskService = TaskService()
        var writer: any IssueWriting = GitHubIssueWriter()
        var tokenProvider: (ProductConfig) -> String? = { KeychainService.loadSync(for: $0) }
    }

    static func handle(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        switch request.kind {
        case .refresh:
            try await refresh(request, deps: deps)
            return CLIResponse(id: request.id, ok: true)
        case .createTask:
            return try await createTask(request, deps: deps)
        case .linkTask:
            return try await link(request, deps: deps, removing: false)
        case .unlinkTask:
            return try await link(request, deps: deps, removing: true)
        case .respond:
            throw CLIError.remote(message: "respond is not implemented yet.")
        }
    }

    private static func refresh(_ request: CLIRequest, deps: Dependencies) async throws {
        if let raw = request.payload["productID"], let id = UUID(uuidString: raw) {
            await deps.registry.load(productID: id)   // scoped to the product being asked about
        } else {
            await deps.registry.loadAll()
        }
    }

    // MARK: - tasks create

    static func createTask(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let store = try CLIStore.open()
        let config = try resolveConfig(request, store: store)
        let title = request.payload["title"] ?? ""
        let prose = request.payload["notes"] ?? ""
        let refs = numbers(request.payload["feedback"])
        let status = TaskStatus(rawValue: request.payload["status"] ?? "") ?? .todo
        let priority = TaskPriority(rawValue: request.payload["priority"] ?? "") ?? .med
        let versionName = request.payload["version"]
        let milestone = try milestoneNumber(forVersion: versionName, config: config, cloud: store.cloud)
        let warnings = warnAboutUncached(refs, config: config, local: store.local)

        let number: Int
        do {
            number = try await deps.taskService.createTask(
                repo: config, title: title, prose: prose, feedbackRefs: refs,
                status: status, priority: priority, milestoneNumber: milestone)
        } catch is TaskService.ServiceError {
            throw noToken(config)
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }

        await deps.registry.load(productID: config.id)   // so the app shows it immediately

        let created = TaskItemDTO(number: number, title: title, status: status.rawValue,
                                  priority: priority.rawValue, isClosed: status == .done,
                                  milestone: versionName, feedback: refs.sorted(),
                                  url: FeedbackQuery.url(for: number, config: config))
        return CLIResponse(id: request.id, ok: true, warnings: warnings,
                           json: CLIOutput.encode(created))
    }

    // MARK: - tasks link / unlink

    static func link(_ request: CLIRequest, deps: Dependencies, removing: Bool) async throws -> CLIResponse {
        let store = try CLIStore.open()
        let config = try resolveConfig(request, store: store)
        guard let taskNumber = request.payload["task"].flatMap(Int.init) else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--task is required"))
        }
        let refs = numbers(request.payload["feedback"])
        guard let token = deps.tokenProvider(config) else { throw noToken(config) }

        // The LIVE body is the source of truth — the cache can be a poll interval behind, and
        // rewriting from it would drop any edit made since.
        let live: FetchedIssue
        do {
            live = try await deps.writer.fetchIssue(owner: config.owner, repo: config.repo,
                                                    number: taskNumber, token: token)
        } catch {
            throw CLIError.notFound(
                code: "task_not_found",
                message: "Could not read task #\(taskNumber): \(error.localizedDescription)")
        }
        guard live.labels.contains(AppFeedbackLabels.task) else {
            throw CLIError.notFound(code: "task_not_found",
                                    message: "#\(taskNumber) is not a task.",
                                    hint: "It has no \(AppFeedbackLabels.task) label.")
        }

        let warnings = removing ? [] : warnAboutUncached(refs, config: config, local: store.local)
        let newBody = rewriteRefs(in: live.body, adding: removing ? [] : refs,
                                  removing: removing ? refs : [])
        do {
            // Only the body — labels, state and milestone are deliberately untouched.
            try await deps.writer.updateIssue(owner: config.owner, repo: config.repo,
                                              number: taskNumber, title: nil, body: newBody,
                                              labels: nil, milestoneNumber: nil, state: nil,
                                              token: token)
        } catch {
            throw CLIError.remote(message: error.localizedDescription)
        }
        await deps.registry.load(productID: config.id)

        let result = TaskDetail(
            number: taskNumber, title: live.title,
            status: TaskStatus(labels: live.labels).rawValue,
            priority: TaskPriority(labels: live.labels).rawValue,
            isClosed: live.state == "closed", milestone: nil,
            notes: FeedbackTaskRefParser.prose(of: newBody),
            feedback: TaskIndex.linkedFeedback(FeedbackTaskRefParser.parse(newBody),
                                               config: config, local: store.local),
            url: FeedbackQuery.url(for: taskNumber, config: config))
        return CLIResponse(id: request.id, ok: true, warnings: warnings,
                           json: CLIOutput.encode(result))
    }

    // MARK: - Shared helpers

    static func resolveConfig(_ request: CLIRequest, store: CLIStore) throws -> ProductConfig {
        guard let query = request.payload["product"] else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--product is required"))
        }
        return try ProductResolver.resolve(query, cloud: store.cloud)
    }

    static func numbers(_ raw: String?) -> [Int] {
        (raw ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func noToken(_ config: ProductConfig) -> CLIError {
        .auth(message: "No GitHub token for \(config.owner)/\(config.repo).",
              hint: "Re-authenticate in AppFeedback's Settings.")
    }

    /// nil version ⇒ nil milestone (leave it alone). A version with no milestone number is a
    /// hard error: collapsing it to `.some(nil)` would silently CLEAR the task's milestone.
    static func milestoneNumber(forVersion version: String?, config: ProductConfig,
                                cloud: ModelContext) throws -> Int? {
        guard let version, !version.isEmpty else { return nil }
        let owner = config.owner, repo = config.repo
        let versions = (try? cloud.fetch(FetchDescriptor<ProjectVersion>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        guard let match = versions.first(where: { $0.name == version }) else {
            throw CLIError.notFound(code: "version_not_found",
                                    message: "No version '\(version)' in \(owner)/\(repo).",
                                    hint: "Run `\(CLIBranding.commandName) products` to see the versions.",
                                    candidates: versions.map(\.name))
        }
        guard let number = match.milestoneNumber else {
            throw CLIError.notFound(code: "version_has_no_milestone",
                                    message: "Version '\(version)' has no GitHub milestone yet.",
                                    hint: "Create the milestone in AppFeedback first.")
        }
        return number
    }

    static func rewriteRefs(in body: String, adding: [Int], removing: [Int]) -> String {
        var refs = Set(FeedbackTaskRefParser.parse(body))
        refs.formUnion(adding)
        refs.subtract(removing)
        return FeedbackTaskRefParser.upsert(into: FeedbackTaskRefParser.prose(of: body),
                                            refs: refs.sorted())
    }

    /// Uncached numbers may be legitimately closed-and-never-cached, so warn rather than fail.
    static func warnAboutUncached(_ numbers: [Int], config: ProductConfig,
                                  local: ModelContext) -> [String] {
        let owner = config.owner, repo = config.repo
        return numbers.compactMap { number in
            var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.number == number
            })
            descriptor.fetchLimit = 1
            let exists = ((try? local.fetch(descriptor))?.first) != nil
            return exists ? nil : "#\(number) is not in the local cache — linking it anyway."
        }
    }
}
#endif
