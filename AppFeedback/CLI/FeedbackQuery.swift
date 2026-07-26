#if os(macOS)
import Foundation
import SwiftData

enum FeedbackQuery {
    static let descriptionLimit = 500

    static func run(flags: CLIFlags, config: ProductConfig,
                    local: ModelContext, cloud: ModelContext,
                    index: TaskIndex) -> (items: [FeedbackItem], total: Int) {
        let owner = config.owner, repo = config.repo
        let rows = (try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []

        let hidden = flags.includeHidden ? [] : ProductResolver.hiddenApps(owner: owner, repo: repo, cloud: cloud)
        let verdicts = triageByNumber(local: local, owner: owner, repo: repo)

        var issues = ProductResolver.partition(rows).feedback
            .map { $0.toFeedbackIssue() }
            .filter { matches($0, flags: flags, hidden: hidden, index: index) }

        issues.sort { left, right in
            let leftKey = flags.sort == .created ? left.createdAt : (left.updatedAt ?? left.createdAt)
            let rightKey = flags.sort == .created ? right.createdAt : (right.updatedAt ?? right.createdAt)
            if leftKey != rightKey {
                return flags.order == .desc ? leftKey > rightKey : leftKey < rightKey
            }
            return flags.order == .desc ? left.number > right.number : left.number < right.number
        }

        let total = issues.count
        let page = Array(issues.dropFirst(flags.offset).prefix(flags.limit))
        let items = page.map { item(from: $0, flags: flags, config: config,
                                    index: index, triage: verdicts[$0.number]) }
        return (items, total)
    }

    // MARK: - Filtering

    private static func matches(_ issue: FeedbackIssue, flags: CLIFlags,
                                hidden: Set<String>, index: TaskIndex) -> Bool {
        if hidden.contains(issue.appName ?? "") { return false }

        switch flags.state {
        case .open:   if (issue.state ?? .open) != .open { return false }
        case .closed: if (issue.state ?? .open) != .closed { return false }
        case .all:    break
        }
        if !flags.apps.isEmpty, !flags.apps.contains(issue.appName ?? "") { return false }
        if !flags.sources.isEmpty, !flags.sources.contains(issue.source) { return false }
        if !flags.types.isEmpty {
            guard let type = issue.labels.issueType?.type, flags.types.contains(type) else { return false }
        }
        if !flags.labels.isEmpty {
            let names = Set(issue.labels.map(\.name))
            guard flags.labels.allSatisfy(names.contains) else { return false }
        }
        if let version = flags.appVersion, issue.appVersion != version { return false }
        if let since = flags.since, issue.createdAt < since { return false }
        if let since = flags.updatedSince, (issue.updatedAt ?? issue.createdAt) < since { return false }
        if flags.minRating != nil || flags.maxRating != nil {
            guard let rating = issue.rating else { return false }
            if let low = flags.minRating, rating < low { return false }
            if let high = flags.maxRating, rating > high { return false }
        }
        if let query = flags.search, !query.isEmpty {
            let needle = query.lowercased()
            let haystacks = [issue.title, issue.description, issue.appName ?? ""]
            guard haystacks.contains(where: { $0.lowercased().contains(needle) }) else { return false }
        }
        if let wantsTask = flags.hasTask {
            guard !index.refs(forFeedback: issue.number).isEmpty == wantsTask else { return false }
        }
        return true
    }

    // MARK: - Projection

    private static func item(from issue: FeedbackIssue, flags: CLIFlags, config: ProductConfig,
                             index: TaskIndex, triage: TriageVerdictRecord?) -> FeedbackItem {
        let (description, truncated) = truncate(issue.description)
        return FeedbackItem(
            number: issue.number,
            title: issue.title,
            app: issue.appName,
            appVersion: issue.appVersion,
            source: issue.source.rawValue,
            type: issue.labels.issueType?.type.rawValue,
            rating: issue.rating,
            state: (issue.state ?? .open).rawValue,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt ?? issue.createdAt,
            device: issue.device,
            os: issue.osVersion,
            email: issue.email.map { flags.includeEmails ? $0 : redact($0) },
            description: description,
            truncated: truncated,
            labels: issue.labels.map(\.name),
            tasks: index.refs(forFeedback: issue.number),
            triage: triage.map(triageInfo),
            url: url(for: issue.number, config: config))
    }

    static func detail(number: Int, flags: CLIFlags, config: ProductConfig,
                       local: ModelContext, cloud: ModelContext,
                       index: TaskIndex) throws -> FeedbackDetail {
        let issue = try rawIssue(number: number, config: config, local: local)
        return FeedbackDetail(
            number: issue.number, title: issue.title, app: issue.appName, appVersion: issue.appVersion,
            source: issue.source.rawValue, type: issue.labels.issueType?.type.rawValue,
            rating: issue.rating, state: (issue.state ?? .open).rawValue,
            createdAt: issue.createdAt, updatedAt: issue.updatedAt ?? issue.createdAt,
            device: issue.device, os: issue.osVersion,
            email: issue.email.map { flags.includeEmails ? $0 : redact($0) },
            description: issue.description,
            rawBody: flags.raw ? issue.rawBody : nil,
            labels: issue.labels.map(\.name),
            milestone: issue.milestoneTitle,
            attachments: issue.attachments.map {
                AttachmentDTO(filename: $0.filename, mimeType: $0.mimeType,
                              url: $0.url.absoluteString,
                              localPath: localAttachmentPath(for: $0, local: local))
            },
            translatedTitle: issue.translatedTitle, translatedBody: issue.translatedBody,
            thread: threadSummary(owner: config.owner, repo: config.repo, number: number, cloud: cloud),
            tasks: index.refs(forFeedback: number),
            triage: triageByNumber(local: local, owner: config.owner, repo: config.repo)[number]
                .map(triageInfo),
            url: url(for: number, config: config))
    }

    /// The unredacted issue, for callers that need the real reporter address (`respond`).
    static func rawIssue(number: Int, config: ProductConfig, local: ModelContext) throws -> FeedbackIssue {
        let owner = config.owner, repo = config.repo
        var descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.number == number
        })
        descriptor.fetchLimit = 1
        guard let row = (try? local.fetch(descriptor))?.first else {
            throw CLIError.notFound(
                code: "feedback_not_found",
                message: "No cached feedback #\(number) in \(owner)/\(repo).",
                hint: "It may be closed and never cached — see closedDataIncomplete in list output.")
        }
        let issue = row.toFeedbackIssue()
        if issue.labels.contains(where: { $0.name == AppFeedbackLabels.task }) {
            throw CLIError.notFound(code: "feedback_not_found",
                                    message: "#\(number) is not a feedback item.",
                                    hint: "#\(number) is a task. Use `tasks show \(number)`.")
        }
        return issue
    }

    // MARK: - Helpers

    static func url(for number: Int, config: ProductConfig) -> String {
        "https://github.com/\(config.owner)/\(config.repo)/issues/\(number)"
    }

    static func truncate(_ text: String) -> (String, Bool) {
        guard text.count > descriptionLimit else { return (text, false) }
        return (String(text.prefix(descriptionLimit)), true)
    }

    /// `amir@icloud.com` → `a***@icloud.com`, the shape the app uses when mirroring email.
    static func redact(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@"), atIndex != email.startIndex else { return "***" }
        return "\(email[email.startIndex])***\(email[atIndex...])"
    }

    private static func triageInfo(_ record: TriageVerdictRecord) -> TriageInfo {
        TriageInfo(state: record.state, kind: record.kind,
                   signal: record.signal.isEmpty ? nil : record.signal,
                   suggestedTaskNumber: record.suggestedTaskNumber,
                   createdTaskNumber: record.createdTaskNumber)
    }

    private static func triageByNumber(local: ModelContext, owner: String,
                                       repo: String) -> [Int: TriageVerdictRecord] {
        let rows = (try? local.fetch(FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []
        return Dictionary(rows.map { ($0.feedbackNumber, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func localAttachmentPath(for ref: FeedbackAttachmentRef,
                                            local: ModelContext) -> String? {
        let key = ref.url.absoluteString
        var descriptor = FetchDescriptor<FeedbackAttachmentLocal>(predicate: #Predicate { $0.url == key })
        descriptor.fetchLimit = 1
        return (try? local.fetch(descriptor))?.first?.localPath
    }

    private static func threadSummary(owner: String, repo: String, number: Int,
                                      cloud: ModelContext) -> ThreadSummary? {
        let threads = (try? cloud.fetch(FetchDescriptor<MailThread>(predicate: #Predicate {
            $0.issueRepoOwner == owner && $0.issueRepoName == repo && $0.issueNumber == number
        }))) ?? []
        guard !threads.isEmpty else { return nil }
        let messages = threads.flatMap(\.sortedDedupedMessages).sorted { $0.date < $1.date }
        guard !messages.isEmpty else { return nil }
        return ThreadSummary(messageCount: messages.count,
                             lastMessageAt: messages.last?.date,
                             lastDirection: messages.last?.direction.rawValue)
    }
}
#endif
