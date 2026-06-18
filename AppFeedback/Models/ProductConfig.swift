import Foundation

struct ProductConfig: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var owner: String
    var repo: String
    var mirrorEmailsToGitHub: Bool
    var redactEmailAddresses: Bool
    var connectedRepoOwner: String?
    var connectedRepoName: String?
    /// Optional sidebar accent color, as a 6-digit hex string. `nil` = default.
    var colorHex: String?
    // App Store source config (Issuer/Key IDs + Apple app id are not secret; the .p8 lives in Keychain).
    var appStoreIssuerID: String?
    var appStoreKeyID: String?
    var appStoreAppAppleID: String?
    // Email feedback-inbox config: the MailAccount providing this product's feedback inbox.
    var feedbackInboxAccountID: UUID?

    init(
        id: UUID = UUID(),
        displayName: String,
        owner: String,
        repo: String,
        mirrorEmailsToGitHub: Bool = true,
        redactEmailAddresses: Bool = true,
        connectedRepoOwner: String? = nil,
        connectedRepoName: String? = nil,
        colorHex: String? = nil,
        appStoreIssuerID: String? = nil,
        appStoreKeyID: String? = nil,
        appStoreAppAppleID: String? = nil,
        feedbackInboxAccountID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.owner = owner
        self.repo = repo
        self.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        self.redactEmailAddresses = redactEmailAddresses
        self.connectedRepoOwner = connectedRepoOwner
        self.connectedRepoName = connectedRepoName
        self.colorHex = colorHex
        self.appStoreIssuerID = appStoreIssuerID
        self.appStoreKeyID = appStoreKeyID
        self.appStoreAppAppleID = appStoreAppAppleID
        self.feedbackInboxAccountID = feedbackInboxAccountID
    }
}
