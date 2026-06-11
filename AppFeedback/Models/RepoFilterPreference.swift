import Foundation
import SwiftData

/// Per-repo persisted filter selections (Tasks, Versions, and feedback-list filters), stored as
/// JSON blobs so the model stays CloudKit-compatible (all properties optional/defaulted, no unique
/// constraints). Lives in the CloudKit-synced schema so selections follow the user to iOS.
@Model
final class RepoFilterPreference {
    var repoOwner = ""
    var repoName = ""
    var taskFiltersData: Data? = nil       // PersistedTaskFilters (no search)
    var versionFiltersData: Data? = nil    // PersistedVersionFilters (no search)
    var feedbackFiltersData: Data? = nil   // PersistedFeedbackFilters (no search)
    var updatedAt = Date.distantPast

    init(repoOwner: String, repoName: String) {
        self.repoOwner = repoOwner
        self.repoName = repoName
    }
}
