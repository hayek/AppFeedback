import Foundation
import SwiftData

enum VersionState: String, Sendable { case new, wip, released }

@Model
final class ProjectVersion: Identifiable {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var name: String = ""                 // e.g. "1.2.0" — milestone title / git tag base
    var releaseTitle: String = ""         // human title for the release, e.g. "Performance & polish"
    var changelog: String = ""            // canonical "what's new"
    var milestoneNumber: Int? = nil       // GitHub milestone number once created
    var releaseTag: String? = nil         // git tag once a Release is published
    var releasePublished: Bool = false
    var releasedAt: Date? = nil
    var createdAt: Date = Date()
    /// Optional per-version override of where the Release publishes (the "connected code repo").
    var connectedRepoOwner: String? = nil
    var connectedRepoName: String? = nil

    init(id: UUID = UUID(), repoOwner: String, repoName: String, name: String,
         releaseTitle: String = "", changelog: String = "", milestoneNumber: Int? = nil, releaseTag: String? = nil,
         releasePublished: Bool = false, releasedAt: Date? = nil, createdAt: Date = Date(),
         connectedRepoOwner: String? = nil, connectedRepoName: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.name = name
        self.releaseTitle = releaseTitle
        self.changelog = changelog
        self.milestoneNumber = milestoneNumber
        self.releaseTag = releaseTag
        self.releasePublished = releasePublished
        self.releasedAt = releasedAt
        self.createdAt = createdAt
        self.connectedRepoOwner = connectedRepoOwner
        self.connectedRepoName = connectedRepoName
    }

    func derivedState(anyTaskStarted: Bool) -> VersionState {
        if releasePublished { return .released }
        return anyTaskStarted ? .wip : .new
    }
}
