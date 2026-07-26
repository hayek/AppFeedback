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

        default:
            return emit(error: .remote(message: "not implemented yet"))
        }
    }

    /// JSON error on stdout (so a failed call is still parseable) plus a one-liner on stderr.
    static func emit(error: CLIError) -> Int32 {
        var payload: [String: Any] = ["code": error.code, "message": error.message]
        if let hint = error.hint { payload["hint"] = hint }
        if !error.candidates.isEmpty { payload["candidates"] = error.candidates }
        if let data = try? JSONSerialization.data(withJSONObject: ["error": payload],
                                                  options: [.prettyPrinted, .sortedKeys]),
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
