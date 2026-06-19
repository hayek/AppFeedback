import SwiftUI

/// SCAFFOLD (Phase 2). The real feedback-inbox setup form — IMAP host/port/user/password +
/// Preset, "Test Connection", linking a MailAccount with feedbackProductID — is implemented in
/// **Phase 5**. This placeholder only establishes the navigation destination + the Off/Configured
/// status surface so the Sources section in `ProductSettingsView` compiles and routes here today.
struct EmailSourceForm: View {
    let store: ProductStore
    let product: ProductConfig

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(product.emailSourceStatus == .configured ? "Configured" : "Off")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Email Feedback Inbox")
            } footer: {
                Text("A dedicated IMAP feedback inbox (host, credentials, Test Connection) arrives in a later update.")
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
