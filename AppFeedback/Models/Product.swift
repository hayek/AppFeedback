import Foundation
import SwiftData

@Model
final class Product {
    var id: UUID = UUID()
    var displayName: String = ""
    var owner: String = ""
    var repo: String = ""
    var hiddenAppNames: [String] = []
    var appColors: [String: String] = [:]
    /// Optional sidebar accent color for this product, as a 6-digit hex string. `nil` = default.
    var colorHex: String? = nil
    var createdAt: Date = Date()
    /// When true, every email this app sends or receives for an issue in this product is
    /// also posted as a comment on the GitHub issue.
    var mirrorEmailsToGitHub: Bool = true
    /// When true, sender addresses in mirrored comments are redacted to `a***@host.tld`.
    var redactEmailAddresses: Bool = true
    var connectedRepoOwner: String? = nil
    var connectedRepoName: String? = nil
    // App Store source (the .p8 lives in Keychain, never here / never in CloudKit):
    var appStoreIssuerID: String? = nil
    var appStoreKeyID: String? = nil
    /// Opaque ASC app id (numeric string); nil ⇒ App Store source off.
    var appStoreAppAppleID: String? = nil
    /// → a MailAccount whose feedbackProductID == self.id; nil ⇒ email source off.
    var feedbackInboxAccountID: UUID? = nil

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
        connectedRepoName: String? = nil,
        appStoreIssuerID: String? = nil,
        appStoreKeyID: String? = nil,
        appStoreAppAppleID: String? = nil,
        feedbackInboxAccountID: UUID? = nil
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
        self.appStoreIssuerID = appStoreIssuerID
        self.appStoreKeyID = appStoreKeyID
        self.appStoreAppAppleID = appStoreAppAppleID
        self.feedbackInboxAccountID = feedbackInboxAccountID
    }
}
