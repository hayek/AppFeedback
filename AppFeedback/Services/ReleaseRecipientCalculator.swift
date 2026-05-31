import Foundation

struct ReleaseRecipient: Identifiable, Sendable, Hashable {
    let email: String
    let feedbackNumbers: [Int]    // this person's addressed feedbacks in the version, deduped+sorted
    var id: String { email }
}

enum ReleaseRecipientCalculator {
    /// Recipients = end-users whose feedback is addressed by a *completed* task in the version.
    /// Deduped by email; feedbacks without an email are dropped. Each recipient lists all of
    /// their addressed feedbacks across the version's completed tasks.
    static func recipients(versionNamed name: String, tasks: [TaskItem], feedback: [FeedbackIssue]) -> [ReleaseRecipient] {
        let emailByNumber: [Int: String] = feedback.reduce(into: [:]) { acc, f in
            if let e = f.email, !e.isEmpty { acc[f.number] = e }
        }
        let completedRefs = tasks
            .filter { $0.milestoneTitle == name && $0.isCompleted }
            .flatMap(\.feedbackRefs)

        var numbersByEmail: [String: Set<Int>] = [:]
        for number in completedRefs {
            guard let email = emailByNumber[number] else { continue }
            numbersByEmail[email, default: []].insert(number)
        }
        return numbersByEmail
            .map { ReleaseRecipient(email: $0.key, feedbackNumbers: $0.value.sorted()) }
            .sorted { $0.email < $1.email }
    }
}
