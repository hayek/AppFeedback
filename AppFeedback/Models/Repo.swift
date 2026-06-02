import Foundation
import SwiftData

@Model
final class Repo {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var appColors: [String: String] = [:]
    /// Optional sidebar accent color for this repo, as a 6-digit hex string. `nil` = default.
    var colorHex: String? = nil
    var createdAt: Date = Date()
    /// When true, every email this app sends or receives for an issue in this repo is
    /// also posted as a comment on the GitHub issue.
    var mirrorEmailsToGitHub: Bool = true
    /// When true, sender addresses in mirrored comments are redacted to `a***@host.tld`.
    /// Defaulted to `true` for public repos and `false` for private at the moment the
    /// repo is added; user-editable thereafter.
    var redactEmailAddresses: Bool = true
    var connectedRepoOwner: String? = nil
    var connectedRepoName: String? = nil

    init(
        id: UUID = UUID(),
        displayName: String,
        owner: String,
        repo: String,
        hiddenAppNames: [String] = [],
        appColors: [String: String] = [:],
        colorHex: String? = nil,
        createdAt: Date = Date(),
        mirrorEmailsToGitHub: Bool = true,
        redactEmailAddresses: Bool = true,
        connectedRepoOwner: String? = nil,
        connectedRepoName: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.hiddenAppNames = hiddenAppNames
        self.appColors = appColors
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        self.redactEmailAddresses = redactEmailAddresses
        self.connectedRepoOwner = connectedRepoOwner
        self.connectedRepoName = connectedRepoName
    }
}
