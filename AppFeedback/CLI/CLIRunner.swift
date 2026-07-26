#if os(macOS)
import Foundation

enum CLIRunner {
    static let watchdogSeconds: TimeInterval = 60

    /// Entry point from the dispatcher. Never returns.
    static func run(invocation: Result<CLICommand, CLIUsageError>) -> Never {
        // A wedged async path must never hang an agent indefinitely.
        let watchdog = Thread {
            Thread.sleep(forTimeInterval: watchdogSeconds)
            FileHandle.standardError.write(Data("\(CLIBranding.commandName): timed out\n".utf8))
            exit(CLIExitCode.watchdog.rawValue)
        }
        watchdog.stackSize = 1 << 16
        watchdog.start()

        Task {
            let code: Int32
            switch invocation {
            case .failure(let usage): code = emit(error: .usage(usage))
            case .success(let command): code = await execute(command)
            }
            exit(code)
        }
        // RunLoop, not dispatchMain(): distributed-notification replies arrive on a CFRunLoop
        // source, and dispatchMain() parks the thread without ever running the run loop.
        RunLoop.main.run()
        fatalError("unreachable")
    }

    static func execute(_ command: CLICommand) async -> Int32 {
        switch command {
        case .version:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            print("\(CLIBranding.commandName) \(version) (\(build))")
            return CLIExitCode.success.rawValue

        case .help(let topic):
            print(helpText(for: topic))
            return CLIExitCode.success.rawValue

        case .products(let flags):
            return await withStore(flags) { store, refreshTimedOut in
                let summaries = ProductResolver.all(cloud: store.cloud, local: store.local)
                let envelope = CLIEnvelope(asOf: summaries.compactMap(\.lastFetchedAt).max(),
                                           stale: false,
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           items: summaries)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(products: summaries)
            }

        case .feedback(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let result = FeedbackQuery.run(flags: flags, config: config,
                                               local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf, stale: isStale(asOf),
                    refreshTimedOut: refreshTimedOut ? true : nil,
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config), filters: describe(flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: result.total,
                                   hasMore: flags.offset + result.items.count < result.total),
                    items: result.items)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(feedback: result.items)
            }

        case .feedback(.show(let number, let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try FeedbackQuery.detail(number: number, flags: flags, config: config,
                                                      local: store.local, cloud: store.cloud, index: index)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           product: ProductResolver.ref(config), items: [detail])
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(detail: detail)
            }

        case .tasks(.list(let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let all = index.filter(flags).map { TaskIndex.dto($0, config: config) }
                let page = Array(all.dropFirst(flags.offset).prefix(flags.limit))
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(
                    asOf: asOf, stale: isStale(asOf),
                    refreshTimedOut: refreshTimedOut ? true : nil,
                    closedDataIncomplete: flags.state == .open ? nil : true,
                    product: ProductResolver.ref(config), filters: describe(flags),
                    page: PageInfo(limit: flags.limit, offset: flags.offset, total: all.count,
                                   hasMore: flags.offset + page.count < all.count),
                    items: page)
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(tasks: page)
            }

        case .tasks(.show(let number, let flags)):
            return await withStore(flags) { store, refreshTimedOut in
                let config = try ProductResolver.resolve(flags.product, cloud: store.cloud)
                let index = TaskIndex.build(local: store.local, owner: config.owner, repo: config.repo)
                let detail = try index.detail(number: number, config: config, local: store.local)
                let asOf = ProductResolver.lastFetchedAt(local: store.local,
                                                         owner: config.owner, repo: config.repo)
                let envelope = CLIEnvelope(asOf: asOf, stale: isStale(asOf),
                                           refreshTimedOut: refreshTimedOut ? true : nil,
                                           product: ProductResolver.ref(config), items: [detail])
                return flags.json ? CLIOutput.encode(envelope) : CLIText.render(taskDetail: detail)
            }

        case .tasks(.create(let flags)):
            return await sendWrite(kind: .createTask, flags: flags, payload: [
                "product": flags.product,
                "title": flags.title ?? "",
                "notes": flags.notes ?? "",
                "status": (flags.statuses.first ?? .todo).rawValue,
                "priority": (flags.priorities.first ?? .med).rawValue,
                "version": flags.version ?? "",
                "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ","),
            ])

        case .tasks(.link(let flags)):
            return await sendWrite(kind: .linkTask, flags: flags, payload: linkPayload(flags))

        case .tasks(.unlink(let flags)):
            return await sendWrite(kind: .unlinkTask, flags: flags, payload: linkPayload(flags))

        case .respond(let flags):
            return await sendWrite(kind: .respond, flags: flags, payload: [
                "product": flags.product,
                "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ","),
                "body": flags.body ?? "",
                "template": flags.template ?? "",
                "via": flags.channel.rawValue,
            ])

        default:
            return emit(error: .remote(message: "not implemented yet"))
        }
    }

    private static func linkPayload(_ flags: CLIFlags) -> [String: String] {
        ["product": flags.product,
         "task": flags.taskNumber.map(String.init) ?? "",
         "feedback": flags.feedbackNumbers.map(String.init).joined(separator: ",")]
    }

    /// Delegates a write to the running app and prints its result. The app runs the identical
    /// call its own UI makes, so behaviour cannot drift between the two.
    static func sendWrite(kind: CLIRequestKind, flags: CLIFlags,
                          payload: [String: String]) async -> Int32 {
        do {
            let response = try await CLIRequestClient.send(
                CLIRequest(kind: kind, payload: payload.filter { !$0.value.isEmpty }),
                timeout: flags.timeout)
            guard response.ok else { return emit(error: mapRemote(response)) }

            var envelope: [String: Any] = ["ok": true]
            if let json = response.json,
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                envelope["result"] = object
            }
            if !response.warnings.isEmpty { envelope["warnings"] = response.warnings }
            if let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                      options: [.prettyPrinted, .sortedKeys,
                                                                .withoutEscapingSlashes]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return CLIExitCode.success.rawValue
        } catch let error as CLIError {
            return emit(error: error)
        } catch {
            return emit(error: .remote(message: error.localizedDescription))
        }
    }

    /// Maps the app's typed failure back onto a CLI error so exit codes stay meaningful.
    static func mapRemote(_ response: CLIResponse) -> CLIError {
        let message = response.errorMessage ?? "The app reported a failure."
        switch response.errorCode {
        case "auth":
            return .auth(message: message, hint: response.errorHint)
        case let code? where code.hasSuffix("_not_found") || code == "version_has_no_milestone"
                          || code == "product_ambiguous" || code == "no_products":
            return .notFound(code: code, message: message, hint: response.errorHint)
        case "missing_flag", "bad_value", "unknown_flag", "conflicting_flags", "missing_value":
            return .usage(CLIUsageError(code: response.errorCode ?? "usage",
                                        message: message, hint: response.errorHint))
        default:
            return .remote(message: message, hint: response.errorHint)
        }
    }

    // MARK: - Shared plumbing

    /// Opens the store, runs `body`, prints what it returns. Every read command shares this so
    /// error mapping and exit codes stay in one place.
    ///
    /// With `--refresh`, the app is asked to poll GitHub FIRST and the store is opened only
    /// once it has answered — opening earlier would read pre-refresh data under a fresh
    /// `asOf`, which is worse than not refreshing at all. `refreshTimedOut` is passed to
    /// `body` so the envelope can say the data is stale rather than failing the read.
    static func withStore(_ flags: CLIFlags,
                          _ body: (CLIStore, Bool) throws -> String) async -> Int32 {
        do {
            var timedOut = false
            if flags.refresh {
                // Resolving the product needs the store, so open a short-lived one first.
                let productID = try? ProductResolver.resolve(flags.product,
                                                             cloud: CLIStore.open().cloud).id
                timedOut = try await requestRefresh(productID: productID, timeout: flags.timeout)
            }
            let store = try CLIStore.open()
            print(try body(store, timedOut))
            return CLIExitCode.success.rawValue
        } catch let error as CLIError {
            return emit(error: error)
        } catch {
            return emit(error: .noLocalData(message: error.localizedDescription, hint: nil))
        }
    }

    /// Returns true when the refresh timed out (answer from cache and say so). Only
    /// app-not-running is fatal.
    static func requestRefresh(productID: UUID?, timeout: TimeInterval) async throws -> Bool {
        var payload: [String: String] = [:]
        if let productID { payload["productID"] = productID.uuidString }
        do {
            _ = try await CLIRequestClient.send(CLIRequest(kind: .refresh, payload: payload),
                                                timeout: timeout)
            return false
        } catch CLIError.appNotRunning {
            throw CLIError.appNotRunning
        } catch {
            return true
        }
    }

    /// The app polls every 15 minutes; anything older than that is stale.
    static func isStale(_ asOf: Date?, now: Date = Date()) -> Bool {
        guard let asOf else { return true }
        return now.timeIntervalSince(asOf) > 15 * 60
    }

    /// Echoes the filters that were actually applied, so an agent can self-check a guessed value.
    static func describe(_ flags: CLIFlags) -> [String: String] {
        var described: [String: String] = ["state": flags.state.rawValue,
                                           "sort": flags.sort.rawValue,
                                           "order": flags.order.rawValue]
        if !flags.apps.isEmpty       { described["app"] = flags.apps.joined(separator: ",") }
        if !flags.labels.isEmpty     { described["label"] = flags.labels.joined(separator: ",") }
        if !flags.sources.isEmpty    { described["source"] = flags.sources.map(\.rawValue).joined(separator: ",") }
        if !flags.types.isEmpty      { described["type"] = flags.types.map(\.rawValue).joined(separator: ",") }
        if !flags.statuses.isEmpty   { described["status"] = flags.statuses.map(\.rawValue).joined(separator: ",") }
        if !flags.priorities.isEmpty { described["priority"] = flags.priorities.map(\.rawValue).joined(separator: ",") }
        if let search = flags.search { described["search"] = search }
        if let since = flags.since   { described["since"] = CLIOutput.iso8601.string(from: since) }
        if let since = flags.updatedSince { described["updatedSince"] = CLIOutput.iso8601.string(from: since) }
        if let low = flags.minRating  { described["minRating"] = String(low) }
        if let high = flags.maxRating { described["maxRating"] = String(high) }
        if let version = flags.appVersion { described["appVersion"] = version }
        if let version = flags.version    { described["version"] = version }
        if let hasTask = flags.hasTask    { described["hasTask"] = String(hasTask) }
        if flags.includeHidden       { described["includeHidden"] = "true" }
        return described
    }

    /// JSON error on stdout (so a failed call is still parseable) plus a one-liner on stderr.
    static func emit(error: CLIError) -> Int32 {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { payload["hint"] = hint }
        if !error.candidates.isEmpty { payload["candidates"] = error.candidates }
        if let data = try? JSONSerialization.data(withJSONObject: ["error": payload],
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        FileHandle.standardError.write(Data("\(CLIBranding.commandName): \(error.message)\n".utf8))
        return error.exitCode.rawValue
    }

    static func helpText(for topic: String?) -> String {
        let name = CLIBranding.commandName
        switch topic {
        case "feedback":
            return """
            \(name) feedback [list] --product <p> [filters]
            \(name) feedback show <number> --product <p> [--raw]

            Filters:
              --app <name>          repeatable; ORs together
              --state open|closed|all      default: open
              --source sdk|app-store|email
              --type bug|feature-request
              --label <name>        repeatable, exact match
              --search <text>       title, description, app name
              --since 7d|YYYY-MM-DD --updated-since ...
              --min-rating N --max-rating N     inclusive, 1-5
              --app-version <v>
              --has-task | --no-task
              --include-hidden      include apps hidden in the app
              --include-emails      unredacted reporter addresses
              --sort created|updated  --order desc|asc
              --limit N (<=200, default 20)  --offset N
              --refresh             ask the running app to poll GitHub first
              --text                human table (JSON is the default)
            """
        case "tasks":
            return """
            \(name) tasks [list] --product <p> [--status ...] [--priority ...] [--version <v>] [--search <t>]
            \(name) tasks show <number> --product <p>
            \(name) tasks create --product <p> --title <t> [--notes <n>] [--status todo|in-progress|done]
                                 [--priority low|med|high] [--version <v>] [--feedback 12,34]
            \(name) tasks link   --product <p> --task <n> --feedback 12,34
            \(name) tasks unlink --product <p> --task <n> --feedback 12

            create/link/unlink write to GitHub and need AppFeedback running.
            """
        case "respond":
            return """
            \(name) respond --product <p> --feedback <n> --body <text>
                            [--template <title>] [--via auto|email|app-store|comment]

            Sends immediately. Show the drafted reply to the user and get explicit
            agreement first. Needs AppFeedback running.
            """
        case "products":
            return """
            \(name) products [--refresh] [--text]

            Lists products with their feedback repo, connected code repo, app names,
            versions, counts and last-fetch time.
            """
        default:
            return """
            \(name) — read and act on app feedback

            Commands:
              products                    list products and what you can filter by
              feedback [list|show]        read feedback
              tasks [list|show|create|link|unlink]   read and write tasks
              respond                     reply to a feedback item
              help [<command>]            detailed help
              version

            Output is JSON on stdout by default; --text renders a human table.
            Start with `\(name) products` — every other command needs --product.
            """
        }
    }
}
#endif
