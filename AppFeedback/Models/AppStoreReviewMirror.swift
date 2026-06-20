import Foundation
import SwiftData

/// CloudKit-synced map from an App Store Connect review to the GitHub issue we synthesized for it.
/// Drives cross-device dedup (so two devices polling the same product don't create two issues),
/// edit detection (`contentHash`), and deletion handling. CloudKit requires every stored property
/// to be optional or to carry a default — hence the defaulted initializers below.
@Model
final class AppStoreReviewMirror {
    var reviewId: String = ""
    var productID: UUID = UUID()
    var issueNumber: Int = 0
    /// SHA-256 hex of the normalized `rating + "\n" + title + "\n" + body`.
    var contentHash: String = ""
    /// nil ⇒ no developer response; else "PENDING_PUBLISH" | "PUBLISHED".
    var responseState: String?
    /// `customerReviewResponses` id (for DELETE / edit), nil until a response is posted.
    var responseId: String?

    init(reviewId: String, productID: UUID, issueNumber: Int, contentHash: String,
         responseState: String? = nil, responseId: String? = nil) {
        self.reviewId = reviewId
        self.productID = productID
        self.issueNumber = issueNumber
        self.contentHash = contentHash
        self.responseState = responseState
        self.responseId = responseId
    }
}

/// Value snapshot of a product's App Store configuration, captured on the MainActor and handed to
/// the (off-MainActor) coordinator. Decouples the App-Store read path from the `Product`/`Repo`
/// rename: the wiring layer maps a `Product`/`ProductConfig` into this.
struct ASCProductConfig: Sendable, Equatable, Identifiable {
    let id: UUID              // product id
    let owner: String         // GitHub owner (the sink)
    let repo: String          // GitHub repo (the sink)
    let issuerID: String
    let keyID: String
    let appAppleID: String    // opaque ASC app id (numeric string)
}

extension ASCProductConfig {
    /// Builds a config from a product's GitHub coordinates + its ASC credentials, or nil when ASC
    /// isn't fully configured (all three of issuerID/keyID/appAppleID must be present & non-empty).
    static func make(id: UUID, owner: String, repo: String,
                     issuerID: String?, keyID: String?, appAppleID: String?) -> ASCProductConfig? {
        guard let issuerID, !issuerID.isEmpty,
              let keyID, !keyID.isEmpty,
              let appAppleID, !appAppleID.isEmpty else { return nil }
        return ASCProductConfig(id: id, owner: owner, repo: repo,
                                issuerID: issuerID, keyID: keyID, appAppleID: appAppleID)
    }
}
