import Foundation

/// Reserved GitHub label names this app reads/writes to model tasks.
enum AppFeedbackLabels {
    static let task           = "appfeedback:task"
    static let statusTodo       = "status:todo"
    static let statusInProgress = "status:in-progress"
    static let statusDone       = "status:done"
    static let priorityLow  = "priority:low"
    static let priorityMed  = "priority:med"
    static let priorityHigh = "priority:high"

    /// Every label this app manages, with the color GitHub should use when creating it.
    static let managed: [(name: String, color: String)] = [
        (task, "5319e7"),
        (statusTodo, "ededed"), (statusInProgress, "fbca04"), (statusDone, "0e8a16"),
        (priorityLow, "c2e0c6"), (priorityMed, "fef2c0"), (priorityHigh, "f9d0c4"),
    ]
}

enum TaskStatus: String, CaseIterable, Sendable {
    case todo
    case inProgress = "in-progress"
    case done

    var label: String { "status:\(rawValue)" }
    var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }

    /// First matching status label wins; defaults to `.todo`.
    init(labels: [String]) {
        for s in TaskStatus.allCases where labels.contains(s.label) { self = s; return }
        self = .todo
    }
}

enum TaskPriority: String, CaseIterable, Sendable {
    case low, med, high

    var label: String { "priority:\(rawValue)" }
    var sortRank: Int {                          // high first
        switch self { case .high: return 0; case .med: return 1; case .low: return 2 }
    }
    var displayName: String { rawValue.capitalized }

    /// First matching priority label wins; defaults to `.med`.
    init(labels: [String]) {
        for p in TaskPriority.allCases where labels.contains(p.label) { self = p; return }
        self = .med
    }
}
