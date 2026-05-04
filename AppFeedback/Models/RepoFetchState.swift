import Foundation
import SwiftData

/// Per-repo, device-local fetch bookkeeping. Drives incremental issue sync —
/// `lastFetchedAt` becomes the GraphQL `since` filter on the next call, and
/// `etag` is sent as `If-None-Match` to short-circuit when nothing changed.
/// Local schema only — never synced via CloudKit.
@Model
final class RepoFetchState {
    var repoOwner: String = ""
    var repoName: String = ""
    var lastFetchedAt: Date?
    var etag: String?

    init(repoOwner: String, repoName: String, lastFetchedAt: Date? = nil, etag: String? = nil) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.lastFetchedAt = lastFetchedAt
        self.etag = etag
    }
}
