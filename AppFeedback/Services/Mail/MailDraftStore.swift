import Foundation
import Observation

enum DraftKey: Hashable {
    case reply(threadID: UUID)
    case newEmail(repoOwner: String, repoName: String, issueNumber: Int, recipient: String)
}

struct Draft: Equatable {
    var subject: String
    var body: String

    init(subject: String = "", body: String = "") {
        self.subject = subject
        self.body = body
    }
}

@MainActor
@Observable
final class MailDraftStore {
    private var drafts: [DraftKey: Draft] = [:]
    private var openRequests: [DraftKey: ComposeRequest] = [:]

    func draft(for key: DraftKey) -> Draft? {
        drafts[key]
    }

    func setSubject(_ subject: String, for key: DraftKey) {
        var existing = drafts[key] ?? Draft()
        existing.subject = subject
        drafts[key] = existing
    }

    func setBody(_ body: String, for key: DraftKey) {
        var existing = drafts[key] ?? Draft()
        existing.body = body
        drafts[key] = existing
    }

    func clear(_ key: DraftKey) {
        drafts.removeValue(forKey: key)
    }

    func openRequest(for key: DraftKey) -> ComposeRequest? {
        openRequests[key]
    }

    func setOpenRequest(_ request: ComposeRequest, for key: DraftKey) {
        openRequests[key] = request
    }

    func clearOpenRequest(for key: DraftKey) {
        openRequests.removeValue(forKey: key)
    }
}
