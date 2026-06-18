import Foundation
import SwiftData

/// LEGACY — read-only. Kept registered for one release so existing CloudKit `CD_Repo`
/// rows still load and can be copied into `Product` by `ProductMigration`. Remove the
/// release after Phase 0 ships. Do NOT add new fields here.
@Model
final class Repo {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var appColors: [String: String] = [:]
    var colorHex: String? = nil
    var createdAt: Date = Date()
    var mirrorEmailsToGitHub: Bool = true
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
