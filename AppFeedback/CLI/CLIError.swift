#if os(macOS)
import Foundation

enum CLIExitCode: Int32 {
    case success = 0
    case usage = 1
    case notFound = 2
    case noLocalData = 3
    case auth = 4
    case remote = 5
    case appNotRunning = 6
    case watchdog = 7
}

enum CLIError: Error {
    case usage(CLIUsageError)
    case notFound(code: String, message: String, hint: String? = nil, candidates: [String] = [])
    case noLocalData(message: String, hint: String?)
    case auth(message: String, hint: String?)
    case remote(message: String, hint: String? = nil)
    case appNotRunning

    var exitCode: CLIExitCode {
        switch self {
        case .usage:         return .usage
        case .notFound:      return .notFound
        case .noLocalData:   return .noLocalData
        case .auth:          return .auth
        case .remote:        return .remote
        case .appNotRunning: return .appNotRunning
        }
    }

    var code: String {
        switch self {
        case .usage(let error):            return error.code
        case .notFound(let code, _, _, _): return code
        case .noLocalData:                 return "no_local_data"
        case .auth:                        return "auth"
        case .remote:                      return "remote_failure"
        case .appNotRunning:               return "app_not_running"
        }
    }

    var message: String {
        switch self {
        case .usage(let error):               return error.message
        case .notFound(_, let message, _, _): return message
        case .noLocalData(let message, _):    return message
        case .auth(let message, _):           return message
        case .remote(let message, _):         return message
        case .appNotRunning:
            return "AppFeedback is not running. Writes and --refresh need the app open."
        }
    }

    var hint: String? {
        switch self {
        case .usage(let error):            return error.hint
        case .notFound(_, _, let hint, _): return hint
        case .noLocalData(_, let hint):    return hint
        case .auth(_, let hint):           return hint
        case .remote(_, let hint):         return hint
        case .appNotRunning:               return "Open AppFeedback, then re-run."
        }
    }

    var candidates: [String] {
        if case .notFound(_, _, _, let candidates) = self { return candidates }
        return []
    }
}
#endif
