#if os(macOS)
import Foundation
import SwiftData

/// Cached tasks for one repo plus the feedback→tasks reverse map. The map is built from each
/// task body's machine-managed addresses block, which is the source of truth for the
/// task↔feedback relationship.
struct TaskIndex {
    let tasks: [TaskItem]
    private let byFeedback: [Int: [TaskRef]]

    static func build(local: ModelContext, owner: String, repo: String) -> TaskIndex {
        let rows = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        let tasks = ProductResolver.partition(rows).tasks
            .map { TaskItem(issue: $0.toFeedbackIssue()) }
            .sorted { $0.number > $1.number }

        var map: [Int: [TaskRef]] = [:]
        for task in tasks {
            let ref = TaskRef(number: task.number, title: task.title,
                              status: task.displayStatus.rawValue,
                              priority: task.priority.rawValue,
                              isClosed: task.isClosed)
            for feedbackNumber in task.feedbackRefs {
                map[feedbackNumber, default: []].append(ref)
            }
        }
        for key in map.keys { map[key]?.sort { $0.number < $1.number } }
        return TaskIndex(tasks: tasks, byFeedback: map)
    }

    func refs(forFeedback number: Int) -> [TaskRef] { byFeedback[number] ?? [] }

    /// `--state open` (the default) hides completed tasks; `.all` shows everything;
    /// `.closed` shows only completed ones.
    ///
    /// The two dimensions overlap, because `displayStatus` folds "closed" into `.done`: a task the
    /// status filter calls `.done` is exactly one the `--state open` default rejects, which left
    /// the documented `tasks --status done` unsatisfiable for every product. An explicit
    /// `--status done` is the more specific intent, so it supersedes the state filter — which also
    /// matches the UI, where status is the *only* completion dimension (`filteredTasks` filters on
    /// `displayStatus` and has no state filter at all).
    func filter(_ flags: CLIFlags) -> [TaskItem] {
        let statusAsksForCompleted = flags.statuses.contains(.done)
        return tasks.filter { task in
            switch flags.state {
            case .open:   if task.isCompleted, !statusAsksForCompleted { return false }
            case .closed: if !task.isCompleted { return false }
            case .all:    break
            }
            if !flags.statuses.isEmpty, !flags.statuses.contains(task.displayStatus) { return false }
            if !flags.priorities.isEmpty, !flags.priorities.contains(task.priority) { return false }
            if let version = flags.version, task.milestoneTitle != version { return false }
            if let query = flags.search, !query.isEmpty, !task.matchesSearch(query) { return false }
            return true
        }
    }

    static func dto(_ task: TaskItem, config: ProductConfig) -> TaskItemDTO {
        TaskItemDTO(number: task.number, title: task.title,
                    status: task.displayStatus.rawValue, priority: task.priority.rawValue,
                    isClosed: task.isClosed, milestone: task.milestoneTitle,
                    feedback: task.feedbackRefs,
                    url: "https://github.com/\(config.owner)/\(config.repo)/issues/\(task.number)")
    }

    func detail(number: Int, config: ProductConfig, local: ModelContext) throws -> TaskDetail {
        guard let task = tasks.first(where: { $0.number == number }) else {
            throw CLIError.notFound(
                code: "task_not_found",
                message: "No cached task #\(number) in \(config.owner)/\(config.repo).",
                hint: "Run `\(CLIBranding.commandName) tasks --product <p>` to list them.")
        }
        return TaskDetail(number: task.number, title: task.title,
                          status: task.displayStatus.rawValue, priority: task.priority.rawValue,
                          isClosed: task.isClosed, milestone: task.milestoneTitle,
                          notes: FeedbackTaskRefParser.prose(of: task.body),
                          feedback: Self.linkedFeedback(task.feedbackRefs, config: config, local: local),
                          url: "https://github.com/\(config.owner)/\(config.repo)/issues/\(number)")
    }

    static func linkedFeedback(_ refs: [Int], config: ProductConfig,
                               local: ModelContext) -> [LinkedFeedback] {
        let owner = config.owner, repo = config.repo
        return refs.compactMap { reference in
            var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.number == reference
            })
            descriptor.fetchLimit = 1
            guard let row = (try? local.fetch(descriptor))?.first else { return nil }
            return LinkedFeedback(number: row.number, title: row.title, state: row.state)
        }
    }
}
#endif
