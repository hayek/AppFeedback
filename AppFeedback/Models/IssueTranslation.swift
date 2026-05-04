import Foundation
import SwiftData

/// Cloud-synced translation for one (repo, issue, target language) tuple.
/// Lives in the cloud schema so a translation computed on a device with on-device
/// Foundation Models (e.g. Apple Silicon Mac) propagates to devices that lack it
/// (e.g. older iPhones, iPads). The local `CachedIssue.translatedTitle`/`translatedBody`
/// fields are kept as a fast read-side cache; this model is the cross-device source of truth.
///
/// CloudKit constraint: every stored property must be optional or have a default.
@Model
final class IssueTranslation {
    var repoOwner: String = ""
    var repoName: String = ""
    var number: Int = 0
    /// The language code the title/body were translated INTO.
    var targetLanguage: String = ""
    /// The detected source language at translation time. Stored so views can decide
    /// whether to even offer "show translation" based on source ≠ target.
    var detectedLanguageCode: String?
    var translatedTitle: String?
    var translatedBody: String?
    var updatedAt: Date = Date()

    init(
        repoOwner: String,
        repoName: String,
        number: Int,
        targetLanguage: String,
        detectedLanguageCode: String? = nil,
        translatedTitle: String? = nil,
        translatedBody: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.number = number
        self.targetLanguage = targetLanguage
        self.detectedLanguageCode = detectedLanguageCode
        self.translatedTitle = translatedTitle
        self.translatedBody = translatedBody
        self.updatedAt = updatedAt
    }
}
