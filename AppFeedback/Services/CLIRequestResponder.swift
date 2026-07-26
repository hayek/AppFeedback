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
                                   errorMessage: error.message, errorHint: error.hint,
                                   errorExitCode: error.exitCode.rawValue)
        } catch {
            response = CLIResponse(id: requestID, ok: false, errorCode: "remote_failure",
                                   errorMessage: error.localizedDescription,
                                   errorExitCode: CLIExitCode.remote.rawValue)
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
        /// Everything `respond` needs. nil ⇒ replying is unavailable (tests, or a build
        /// without the mail stack).
        var reply: ReplyDependencies?
    }

    /// The app-side objects `respond` drives. These are the same instances the UI uses, so a
    /// CLI reply is indistinguishable from one sent by hand.
    @MainActor
    struct ReplyDependencies {
        let accountStore: MailAccountStore
        let settingsStore: MailSettingsStore
        let threadStore: MailThreadStore
        let tracker: OutboundSendTracker
        let failureStore: OutboundFailureStore
        let activityLog: ActivityLog
        let templateStore: ReplyTemplateStore
        var mirror: MailToGitHubMirror?
        var appStoreMirrorStore: AppStoreReviewMirrorStore?
        var appStoreContext: ((UUID) async -> AppStoreResponderContext?)?
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
            return try await respond(request, deps: deps)
        }
    }

    // MARK: - respond

    /// `--via auto` follows the source: App Store reviews get a developer response, anything
    /// with an address gets an email reply. An explicit `--via` always wins.
    static func channel(for issue: FeedbackIssue, requested: CLIChannel) throws -> CLIChannel {
        switch requested {
        case .comment:  return .comment
        case .appStore: return .appStore
        case .email:
            guard issue.email?.isEmpty == false else {
                throw CLIError.notFound(code: "no_reply_channel",
                                        message: "Feedback #\(issue.number) has no email address.",
                                        hint: "Use --via comment to comment on the issue instead.")
            }
            return .email
        case .auto:
            if issue.source == .appStore { return .appStore }
            if issue.email?.isEmpty == false { return .email }
            throw CLIError.notFound(
                code: "no_reply_channel",
                message: "Feedback #\(issue.number) has no email address and is not an App Store review.",
                hint: "Use --via comment to comment on the issue instead.")
        }
    }

    static func validateAppStoreBody(_ body: String) throws {
        guard body.count <= AppStoreResponseController.maxBodyLength else {
            throw CLIError.usage(CLIUsageError(
                code: "bad_value",
                message: "App Store responses are capped at \(AppStoreResponseController.maxBodyLength) "
                       + "characters; this is \(body.count).",
                hint: "Shorten the reply."))
        }
    }

    static func respond(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let store = try CLIStore.open()
        let config = try resolveConfig(request, store: store)
        guard let number = numbers(request.payload["feedback"]).first else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag", message: "--feedback is required"))
        }
        // The unredacted issue — the real recipient address is needed to actually send.
        let issue = try FeedbackQuery.rawIssue(number: number, config: config, local: store.local)
        guard let reply = deps.reply else {
            throw CLIError.remote(message: "Replying is unavailable in this build.")
        }

        let requested = CLIChannel(rawValue: request.payload["via"] ?? "auto") ?? .auto
        let selected = try channel(for: issue, requested: requested)

        var body = request.payload["body"] ?? ""
        if body.isEmpty, let title = request.payload["template"], !title.isEmpty {
            let templates = reply.templateStore.templates(owner: config.owner, repo: config.repo)
            guard let template = templates.first(where: {
                $0.title.compare(title, options: .caseInsensitive) == .orderedSame
            }) else {
                throw CLIError.notFound(code: "template_not_found",
                                        message: "No reply template titled '\(title)'.",
                                        candidates: templates.map(\.title))
            }
            body = template.body
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.usage(CLIUsageError(code: "bad_value", message: "The reply body is empty."))
        }

        switch selected {
        case .comment:
            guard let token = deps.tokenProvider(config) else { throw noToken(config) }
            let commentID: Int
            do {
                commentID = try await GitHubCommentPoster().postComment(
                    owner: config.owner, repo: config.repo, issueNumber: number,
                    body: body, token: token)
            } catch {
                throw CLIError.remote(message: error.localizedDescription)
            }
            return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(
                ["via": "comment", "commentID": String(commentID),
                 "url": FeedbackQuery.url(for: number, config: config)]))

        case .appStore:
            try validateAppStoreBody(body)
            return try await respondOnAppStore(request, issue: issue, config: config,
                                               body: body, deps: deps, reply: reply)

        case .email:
            #if canImport(SwiftMail)
            let sent = try await sendEmailReply(issue: issue, config: config, body: body, reply: reply)
            guard sent else {
                throw CLIError.remote(
                    message: "The send failed.",
                    hint: "Check Activity in AppFeedback for the reason (often a missing SMTP password).")
            }
            await deps.registry.load(productID: config.id)
            return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(
                ["via": "email", "to": FeedbackQuery.redact(issue.email ?? ""),
                 "url": FeedbackQuery.url(for: number, config: config)]))
            #else
            throw CLIError.remote(message: "This build has no mail stack.")
            #endif

        case .auto:
            throw CLIError.remote(message: "unreachable: auto resolves to a concrete channel")
        }
    }

    /// Drives the same controller the "Respond on App Store" panel uses.
    private static func respondOnAppStore(_ request: CLIRequest, issue: FeedbackIssue,
                                          config: ProductConfig, body: String,
                                          deps: Dependencies,
                                          reply: ReplyDependencies) async throws -> CLIResponse {
        guard let reviewId = AppStoreReviewIdExtractor.reviewId(fromBody: issue.rawBody) else {
            throw CLIError.notFound(code: "no_review_id",
                                    message: "Feedback #\(issue.number) carries no App Store review id.",
                                    hint: "Use --via comment instead.")
        }
        guard let mirrorStore = reply.appStoreMirrorStore,
              let productID = mirrorStore.mirror(reviewId: reviewId)?.productID,
              let contextProvider = reply.appStoreContext,
              let context = await contextProvider(productID) else {
            throw CLIError.remote(message: "The App Store source for this product is not active.",
                                  hint: "Open AppFeedback and confirm its App Store credentials.")
        }
        guard !context.isReadOnly else {
            throw CLIError.auth(message: "This App Store Connect key is read-only.",
                                hint: "Use a key with App Manager access to publish responses.")
        }

        let controller = AppStoreResponseController(
            reviewId: reviewId, productID: productID, issueNumber: issue.number,
            repoOwner: context.owner, repoName: context.repo,
            client: context.client, mirrorStore: mirrorStore,
            commentPoster: GitHubCommentPoster(),
            tokenLoader: { [owner = context.owner, repo = context.repo] in
                await KeychainService.load(for: ProductConfig(displayName: repo, owner: owner, repo: repo))
            },
            readOnly: context.isReadOnly, onReadOnly: context.onReadOnly)

        controller.draft = body
        await controller.submit()

        if let error = controller.lastError {
            throw appStoreError(error)
        }
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(
            ["via": "app-store", "reviewId": reviewId,
             "url": FeedbackQuery.url(for: issue.number, config: config)]))
    }

    private static func appStoreError(_ error: AppStoreResponseController.SubmitError) -> CLIError {
        switch error {
        case .tooLong(let over):
            return .usage(CLIUsageError(code: "bad_value",
                                        message: "The reply is \(over) characters over the App Store limit."))
        case .conflict:
            return .remote(message: "App Store Connect reported a conflict (409).",
                           hint: "A response may already exist — check the app.")
        case .validation(let message):
            return .remote(message: "App Store Connect rejected the response: \(message)")
        case .api(let code, let message):
            return code == 403
                ? .auth(message: "App Store Connect refused the write (403).",
                        hint: "The key is read-only or lacks App Manager access.")
                : .remote(message: "App Store Connect returned \(code): \(message ?? "no message")")
        case .network(let message):
            return .remote(message: "Network failure talking to App Store Connect: \(message)")
        }
    }

    #if canImport(SwiftMail)
    /// Mirrors `MailThreadView.beginReply` when a thread exists and `IssueCardView.replyToEmail`
    /// when it doesn't, then builds the view model exactly as `InlineReplyView.setupViewModel`
    /// does — including the IMAP Sent-folder appender — and calls the same `send()`.
    private static func sendEmailReply(issue: FeedbackIssue, config: ProductConfig,
                                       body: String, reply: ReplyDependencies) async throws -> Bool {
        guard let recipient = issue.email, !recipient.isEmpty else { return false }

        let threads = reply.threadStore.threads(forIssue: (owner: config.owner, repo: config.repo,
                                                           number: issue.number, title: issue.title))
        let lastMessage = threads
            .flatMap(\.sortedDedupedMessages)
            .sorted { $0.date < $1.date }
            .last

        guard let senderID = reply.accountStore.defaultSender?.id else {
            throw CLIError.auth(message: "No mail account is configured to send from.",
                                hint: "Add one in AppFeedback's Email settings.")
        }
        let appenderProvider = IMAPClientProvider(accountStore: reply.accountStore, accountID: senderID)

        let viewModel = ComposeMailViewModel(
            recipient: MailAddress.bare(from: recipient) ?? recipient,
            issue: issue, repoOwner: config.owner, repoName: config.repo,
            store: reply.accountStore, settingsStore: reply.settingsStore,
            threadStore: reply.threadStore, tracker: reply.tracker,
            failureStore: reply.failureStore, sender: MailSender(),
            activityLog: reply.activityLog, mirror: reply.mirror,
            inReplyTo: lastMessage.map { $0.headers },
            initialSubject: lastMessage.map { MailSubject.replyPrefixed($0.subject) },
            senderAccountID: senderID,
            sentAppender: { @Sendable email in try await appenderProvider.appendToSent(email) })

        // Same placeholder substitution the UI applies to template bodies.
        viewModel.body = NSAttributedString(
            string: MailComposer().applyPlaceholders(body, context: viewModel.placeholderContext()))
        return await viewModel.send()
    }
    #endif

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

    /// Distinguishes a locked keychain from a genuinely missing token — the fixes are
    /// completely different, and "re-authenticate" is bad advice for a locked screen.
    static func noToken(_ config: ProductConfig) -> CLIError {
        let status = KeychainService.loadWithStatus(for: config).status
        if KeychainService.isLocked(status) {
            return .auth(
                message: "The keychain is locked, so the GitHub token for "
                       + "\(config.owner)/\(config.repo) can't be read.",
                hint: "Unlock the Mac (these tokens sync via iCloud Keychain and are "
                    + "unreadable while the screen is locked or over SSH), then re-run.")
        }
        return .auth(message: "No GitHub token for \(config.owner)/\(config.repo).",
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
