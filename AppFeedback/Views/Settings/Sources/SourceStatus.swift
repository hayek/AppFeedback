import Foundation

/// Whether a per-product feedback source is configured. Derived purely from the
/// `ProductConfig` (which carries the App-Store ids and the feedback-inbox account id);
/// secrets (the .p8, the IMAP password) live in the Keychain and are not consulted here.
enum SourceStatus: Equatable {
    case off
    case configured
}

extension ProductConfig {
    /// App Store source is "configured" once an ASC app id is selected.
    /// (Issuer/Key id + the .p8 are gathered first, but the app id is the gate per the spec:
    /// `appStoreAppAppleID == nil ⇒ source off`.)
    var appStoreSourceStatus: SourceStatus {
        (appStoreAppAppleID?.isEmpty == false) ? .configured : .off
    }

    /// Email source is "configured" once a dedicated feedback-inbox MailAccount is linked.
    var emailSourceStatus: SourceStatus {
        feedbackInboxAccountID != nil ? .configured : .off
    }
}
