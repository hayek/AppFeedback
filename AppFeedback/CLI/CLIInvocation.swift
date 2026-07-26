#if os(macOS)
import Foundation

struct CLIUsageError: Error, Equatable {
    let code: String        // missing_flag | unknown_flag | bad_value | missing_value | conflicting_flags
    let message: String
    var hint: String?
}

enum CLIState: String, CaseIterable { case open, closed, all }
enum CLISort: String, CaseIterable { case created, updated }
enum CLIOrder: String, CaseIterable { case desc, asc }
enum CLIChannel: String, CaseIterable { case auto, email, appStore = "app-store", comment }

struct CLIFlags {
    var product: String = ""
    var apps: [String] = []
    var labels: [String] = []
    var sources: [FeedbackSource] = []
    var types: [IssueType] = []
    var statuses: [TaskStatus] = []
    var priorities: [TaskPriority] = []
    var state: CLIState = .open
    var search: String?
    var since: Date?
    var updatedSince: Date?
    var minRating: Int?
    var maxRating: Int?
    var appVersion: String?
    var version: String?
    var hasTask: Bool?              // nil = no constraint
    var includeHidden = false
    var includeEmails = false
    var raw = false
    var refresh = false
    var json = true
    var limit = 20
    var offset = 0
    var sort: CLISort = .created
    var order: CLIOrder = .desc
    var timeout: TimeInterval = 30

    // Write-command payload
    var title: String?
    var notes: String?
    var body: String?
    var template: String?
    var channel: CLIChannel = .auto
    var taskNumber: Int?
    var feedbackNumbers: [Int] = []
}

enum CLIFeedbackVerb { case list(CLIFlags), show(Int, CLIFlags) }

enum CLITaskVerb {
    case list(CLIFlags), show(Int, CLIFlags)
    case create(CLIFlags), link(CLIFlags), unlink(CLIFlags)
}

enum CLICommand {
    case products(CLIFlags)
    case feedback(CLIFeedbackVerb)
    case tasks(CLITaskVerb)
    case respond(CLIFlags)
    case help(String?)
    case version
}

enum CLIInvocation {
    static let maxLimit = 200
    private static let nouns: Set<String> = ["products", "feedback", "tasks", "respond"]

    /// nil ⇒ not a CLI invocation (run the GUI). `.failure` ⇒ a CLI invocation that is
    /// malformed. The distinction is load-bearing: the dispatcher runs the GUI for nil and
    /// prints a usage error for `.failure`.
    static func parse(_ argv: [String], now: Date = Date()) -> Result<CLICommand, CLIUsageError>? {
        let args = Array(argv.dropFirst())
        guard let first = args.first else { return nil }

        if first == "--version" || first == "version" { return .success(.version) }
        if first == "--help" || first == "-h" || first == "help" {
            return .success(.help(args.count > 1 ? args[1] : nil))
        }
        guard nouns.contains(first) else { return nil }

        let rest = Array(args.dropFirst())
        do {
            switch first {
            case "products":
                return .success(.products(try parseFlags(rest, now: now)))
            case "feedback":
                return .success(try parseFeedback(rest, now: now))
            case "tasks":
                return .success(try parseTasks(rest, now: now))
            case "respond":
                return .success(try parseRespond(rest, now: now))
            default:
                return nil
            }
        } catch let error as CLIUsageError {
            return .failure(error)
        } catch {
            return .failure(CLIUsageError(code: "usage", message: error.localizedDescription))
        }
    }

    // MARK: - Per-noun grammar

    private static func parseFeedback(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, number, rest) = splitVerb(args, verbs: ["list", "show"])
        let flags = try requireProduct(try parseFlags(rest, now: now))
        switch verb {
        case "show":
            guard let number else {
                throw CLIUsageError(code: "missing_value", message: "feedback show needs an issue number")
            }
            return .feedback(.show(number, flags))
        default:
            return .feedback(.list(flags))
        }
    }

    private static func parseTasks(_ args: [String], now: Date) throws -> CLICommand {
        let (verb, number, rest) = splitVerb(args, verbs: ["list", "show", "create", "link", "unlink"])
        let flags = try requireProduct(try parseFlags(rest, now: now))
        switch verb {
        case "show":
            guard let number else {
                throw CLIUsageError(code: "missing_value", message: "tasks show needs a task number")
            }
            return .tasks(.show(number, flags))
        case "create":
            guard flags.title?.isEmpty == false else {
                throw CLIUsageError(code: "missing_flag", message: "tasks create requires --title")
            }
            return .tasks(.create(flags))
        case "link", "unlink":
            guard flags.taskNumber != nil else {
                throw CLIUsageError(code: "missing_flag", message: "tasks \(verb) requires --task")
            }
            guard !flags.feedbackNumbers.isEmpty else {
                throw CLIUsageError(code: "missing_flag", message: "tasks \(verb) requires --feedback")
            }
            return .tasks(verb == "link" ? .link(flags) : .unlink(flags))
        default:
            return .tasks(.list(flags))
        }
    }

    private static func parseRespond(_ args: [String], now: Date) throws -> CLICommand {
        let flags = try requireProduct(try parseFlags(args, now: now))
        guard flags.feedbackNumbers.count == 1 else {
            throw CLIUsageError(code: "missing_flag",
                                message: "respond requires exactly one --feedback <number>")
        }
        guard flags.body?.isEmpty == false || flags.template?.isEmpty == false else {
            throw CLIUsageError(code: "missing_flag", message: "respond requires --body or --template")
        }
        return .respond(flags)
    }

    // MARK: - Helpers

    private static func splitVerb(_ args: [String], verbs: Set<String>) -> (String, Int?, [String]) {
        var verb = "list"
        var number: Int?
        var rest = args
        if let first = rest.first, verbs.contains(first) {
            verb = first
            rest = Array(rest.dropFirst())
            if let candidate = rest.first, let parsed = Int(candidate) {
                number = parsed
                rest = Array(rest.dropFirst())
            }
        }
        return (verb, number, rest)
    }

    private static func requireProduct(_ flags: CLIFlags) throws -> CLIFlags {
        guard !flags.product.isEmpty else {
            throw CLIUsageError(code: "missing_flag", message: "--product is required",
                                hint: "run `\(CLIBranding.commandName) products` to list them")
        }
        return flags
    }

    /// `7d`/`24h` relative to `now`; `YYYY-MM-DD` as UTC midnight; full ISO8601.
    static func parseDate(_ raw: String, now: Date) -> Date? {
        if let unit = raw.last, "dh".contains(unit), let value = Double(raw.dropLast()) {
            return now.addingTimeInterval(-value * (unit == "d" ? 86_400 : 3_600))
        }
        if raw.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: raw) { return date }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    // MARK: - Flag parsing

    private static func parseFlags(_ args: [String], now: Date) throws -> CLIFlags {
        var flags = CLIFlags()
        var hasTaskSeen = false, noTaskSeen = false
        var index = 0

        func nextValue(for name: String) throws -> String {
            index += 1
            guard index < args.count else {
                throw CLIUsageError(code: "missing_value", message: "\(name) needs a value")
            }
            return args[index]
        }
        func parseEnum<T: RawRepresentable & CaseIterable>(_ name: String, _ raw: String) throws -> T
        where T.RawValue == String {
            guard let parsed = T(rawValue: raw) else {
                let valid = T.allCases.map { "\($0.rawValue)" }.joined(separator: ", ")
                throw CLIUsageError(code: "bad_value",
                                    message: "\(name): '\(raw)' is not valid. Use one of: \(valid)")
            }
            return parsed
        }
        func positiveInt(_ name: String, _ raw: String, min: Int) throws -> Int {
            guard let value = Int(raw), value >= min else {
                throw CLIUsageError(code: "bad_value", message: "\(name) must be an integer >= \(min)")
            }
            return value
        }

        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--") else {
                throw CLIUsageError(code: "unknown_flag", message: "unexpected argument '\(arg)'")
            }
            switch arg {
            case "--product":     flags.product = try nextValue(for: arg)
            case "--app":         flags.apps.append(try nextValue(for: arg))
            case "--label":       flags.labels.append(try nextValue(for: arg))
            case "--search":      flags.search = try nextValue(for: arg)
            case "--title":       flags.title = try nextValue(for: arg)
            case "--notes":       flags.notes = try nextValue(for: arg)
            case "--body":        flags.body = try nextValue(for: arg)
            case "--template":    flags.template = try nextValue(for: arg)
            case "--version":     flags.version = try nextValue(for: arg)
            case "--app-version": flags.appVersion = try nextValue(for: arg)

            case "--source":   flags.sources.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--type":     flags.types.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--status":   flags.statuses.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--priority": flags.priorities.append(try parseEnum(arg, try nextValue(for: arg)))
            case "--state":    flags.state = try parseEnum(arg, try nextValue(for: arg))
            case "--sort":     flags.sort = try parseEnum(arg, try nextValue(for: arg))
            case "--order":    flags.order = try parseEnum(arg, try nextValue(for: arg))
            case "--via":      flags.channel = try parseEnum(arg, try nextValue(for: arg))

            case "--since", "--updated-since":
                let raw = try nextValue(for: arg)
                guard let date = parseDate(raw, now: now) else {
                    throw CLIUsageError(code: "bad_value",
                        message: "\(arg): '\(raw)' is not a date. Use 7d, 24h, YYYY-MM-DD or ISO8601")
                }
                if arg == "--since" { flags.since = date } else { flags.updatedSince = date }

            case "--min-rating", "--max-rating":
                let raw = try nextValue(for: arg)
                guard let rating = Int(raw), (1...5).contains(rating) else {
                    throw CLIUsageError(code: "bad_value", message: "\(arg) must be 1-5")
                }
                if arg == "--min-rating" { flags.minRating = rating } else { flags.maxRating = rating }

            case "--limit":
                let limit = try positiveInt(arg, try nextValue(for: arg), min: 1)
                guard limit <= maxLimit else {
                    throw CLIUsageError(code: "bad_value", message: "--limit maximum is \(maxLimit)",
                                        hint: "page with --offset instead")
                }
                flags.limit = limit

            case "--offset":
                flags.offset = try positiveInt(arg, try nextValue(for: arg), min: 0)

            case "--timeout":
                let raw = try nextValue(for: arg)
                guard let seconds = Double(raw), seconds > 0 else {
                    throw CLIUsageError(code: "bad_value", message: "--timeout must be > 0")
                }
                flags.timeout = seconds

            case "--task":
                flags.taskNumber = try positiveInt(arg, try nextValue(for: arg), min: 1)

            case "--feedback":
                let raw = try nextValue(for: arg)
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let numbers = parts.compactMap { Int($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
                guard numbers.count == parts.count, !numbers.isEmpty else {
                    throw CLIUsageError(code: "bad_value",
                        message: "--feedback takes comma-separated issue numbers, e.g. 12,34")
                }
                flags.feedbackNumbers.append(contentsOf: numbers)

            case "--has-task":       hasTaskSeen = true; flags.hasTask = true
            case "--no-task":        noTaskSeen = true;  flags.hasTask = false
            case "--include-hidden": flags.includeHidden = true
            case "--include-emails": flags.includeEmails = true
            case "--raw":            flags.raw = true
            case "--refresh":        flags.refresh = true
            case "--json":           flags.json = true
            case "--text":           flags.json = false

            default:
                throw CLIUsageError(code: "unknown_flag", message: "unknown flag '\(arg)'",
                                    hint: "run `\(CLIBranding.commandName) help` for the full list")
            }
            index += 1
        }

        if hasTaskSeen && noTaskSeen {
            throw CLIUsageError(code: "conflicting_flags",
                                message: "--has-task and --no-task are mutually exclusive")
        }
        if let low = flags.minRating, let high = flags.maxRating, low > high {
            throw CLIUsageError(code: "bad_value", message: "--min-rating cannot exceed --max-rating")
        }
        return flags
    }
}
#endif
